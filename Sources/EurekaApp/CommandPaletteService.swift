import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// ⌘K 全局搜索：内存元数据匹配（即时）+ FTS 正文命中（knowledge_fts / transcript_fts），
/// 250ms 防抖、≥2 字符起搜（沿用会话全文搜索惯例）。FTS 打不开时静默降级为纯元数据。
/// 线程模型与其它 service 一致：主线程读发布数据、私有队列跑 FTS、回主线程发布（不用 @MainActor）。
///
/// `Kind`/`Hit` 与 `merge`/`snippet` 两个纯函数实际定义在 `EurekaKit.CommandPalette`
/// （见该文件顶部注释）：eureka-tests 链不到这个 app 壳目标的目标码，纯逻辑得放低一层
/// 才能被测——这里用 typealias 转发，调用方写法不变。
final class CommandPaletteService: ObservableObject {
    typealias Kind = CommandPalette.Kind
    typealias Hit = CommandPalette.Hit

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var searching = false

    private let sessionBrowser: SessionBrowserService
    private let skillMemory: SkillMemoryService
    private let plans: PlansService
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "com.vinlee.eureka.palette", qos: .userInitiated)
    private var store: EurekaStore?
    private var pending: DispatchWorkItem?

    init(
        sessionBrowser: SessionBrowserService,
        skillMemory: SkillMemoryService,
        plans: PlansService,
        settings: AppSettings
    ) {
        self.sessionBrowser = sessionBrowser
        self.skillMemory = skillMemory
        self.plans = plans
        self.settings = settings
    }

    func reset() {
        query = ""
        hits = []
    }

    private func schedule() {
        pending?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            hits = []
            searching = false
            return
        }
        searching = true
        let item = DispatchWorkItem { [weak self] in self?.perform(trimmed) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func perform(_ query: String) {
        // 1) 主线程取元数据命中（services 的发布数据只能主线程读）
        let lowered = query.lowercased()
        var metadata: [Hit] = []
        for session in sessionBrowser.sessionsById.values
        where session.displayName.lowercased().contains(lowered)
            || session.id.lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .session, key: session.id, title: session.displayName,
                subtitle: session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                snippet: nil, sessionId: session.id, messageIdx: nil))
        }
        let snapshot = skillMemory.knowledgeSnapshot()
        for skill in snapshot.skills
        where skill.name.lowercased().contains(lowered)
            || (skill.description ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .skill, key: skill.path, title: skill.name,
                subtitle: skill.source.rawValue, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        for memory in snapshot.memories
        where memory.title.lowercased().contains(lowered)
            || (memory.summary ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: memory.kind == .instructions ? .instruction : .memory,
                key: memory.path, title: memory.title,
                subtitle: memory.projectName ?? memory.scope,
                snippet: nil, sessionId: nil, messageIdx: nil))
        }
        for plan in plans.knowledgeSnapshot()
        where plan.title.lowercased().contains(lowered)
            || (plan.summary ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .plan, key: plan.path, title: plan.title,
                subtitle: plan.project, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        // 2) FTS 下队列（正文命中），回主线程合并。transcript FTS 受设置页「跨会话全文搜索索引」
        // 开关约束（会话侧索引惯例）；knowledge FTS 是知识面扫描的伴生索引，不受该开关管。
        // AppSettings 整体 @MainActor；perform 靠调用方保证跑在主线程（同 WellnessMonitor 的
        // MainActor.assumeIsolated 用法），下队列前先取好，避免把 MainActor 值带进私有队列闭包。
        let transcriptSearchEnabled = MainActor.assumeIsolated { settings.fullTextSearchEnabled }
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            var content: [Hit] = []
            if let store = self.store {
                for hit in (try? store.knowledge.search(query, limit: 20)) ?? [] {
                    let kind: Kind = switch hit.kind {
                    case "skill": .skill
                    case "instruction": .instruction
                    case "plan": .plan
                    default: .memory
                    }
                    content.append(Hit(
                        kind: kind, key: hit.path, title: hit.title,
                        subtitle: hit.project ?? hit.source,
                        snippet: CommandPalette.snippet(hit.text, query: query),
                        sessionId: nil, messageIdx: nil))
                }
                if transcriptSearchEnabled {
                    for hit in (try? store.search.search(query, limit: 20)) ?? [] {
                        content.append(Hit(
                            kind: .session, key: hit.sessionId,
                            title: "会话 \(hit.sessionId.prefix(8))",
                            subtitle: hit.role,
                            snippet: CommandPalette.snippet(hit.text, query: query),
                            sessionId: hit.sessionId, messageIdx: hit.messageIdx))
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query
                else { return }  // 查询已变，丢弃过期结果
                var merged = CommandPalette.merge(metadata + content, perKindCap: 6)
                // 会话命中补真实名字
                merged = merged.map { hit in
                    var hit = hit
                    if hit.kind == .session, let id = hit.sessionId,
                       let info = self.sessionBrowser.sessionsById[id] {
                        hit.title = info.displayName
                    }
                    return hit
                }
                self.hits = merged
                self.searching = false
            }
        }
    }
}
