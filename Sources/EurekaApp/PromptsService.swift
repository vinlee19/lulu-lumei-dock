import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// Prompt 库服务：从会话 transcript 增量提取用户提问，统一浏览/搜索/复用。
///
/// 增量策略与 transcript_fts 同思路（指纹跳过）：`prompt_sessions` 记录每会话上次
/// 提取时间，`lastActiveAt` 未变的会话直接跳过（TranscriptReader 全量重解析是
/// 主要成本，一次全扫可达秒级）。提取 upsert 只刷新正文列，收藏/标签/使用计数
/// 是用户写入的事实，永不被提取覆盖（见 PromptsRepo.upsertExtracted）。
///
/// 会话列表来自 SessionBrowserService（注入，不重复发现）；扫描时机由 AppDelegate
/// 订阅 sessionBrowser 扫描完成事件后调 refresh()。
final class PromptsService: ObservableObject {
    @Published private(set) var prompts: [PromptEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanPhase: String?
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var totalCount = 0
    @Published private(set) var favoriteCount = 0
    /// 跨页直达目标（命令面板 / 会话详情跳入）
    var focusId: String?
    var searchText: String = "" { didSet { rebuild() } }
    var favoritesOnly = false { didSet { rebuild() } }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.prompts", qos: .userInitiated)
    private let sessionBrowser: SessionBrowserService
    private var store: EurekaStore?
    private var all: [PromptEntry] = []
    /// 会话元数据快照（提取时在队列上取好，避免行渲染回主线程再读 service）
    private var sessionsById: [String: AgentSessionInfo] = [:]

    init(sessionBrowser: SessionBrowserService) {
        self.sessionBrowser = sessionBrowser
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 增量提取：只重解析 `lastActiveAt` 晚于上次提取指纹的会话。
    /// 无会话数据时静默跳过（sessionBrowser 尚未扫描完，下一次扫描完成会再触发）。
    func refresh() {
        guard !scanning else { return }
        let sessions = Array(sessionBrowser.sessionsById.values)
        guard !sessions.isEmpty else { return }
        scanning = true
        publishPhase("正在提取用户提问…")
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.store else {
                DispatchQueue.main.async {
                    self.scanning = false
                    self.scanPhase = nil
                }
                return
            }
            let now = Date()
            let fingerprints = (try? store.prompts.extractionFingerprints()) ?? [:]
            let pending = sessions.filter { session in
                guard let last = fingerprints[session.id] else { return true }
                return session.lastActiveAt > last
            }
            var sessionMeta: [String: AgentSessionInfo] = [:]
            for session in sessions { sessionMeta[session.id] = session }
            if !pending.isEmpty {
                self.publishPhase("正在解析 \(pending.count) 个会话…")
                for (index, session) in pending.enumerated() {
                    let entries = PromptExtractor.extract(from: session, at: now)
                    try? store.prompts.upsertExtracted(entries, at: now)
                    try? store.prompts.markExtracted(
                        sessionId: session.id, source: session.source, at: now)
                    if index % 25 == 0 {
                        self.publishPhase(
                            "正在解析会话 \(index + 1)/\(pending.count)…")
                    }
                }
            }
            let entries = (try? store.prompts.all()) ?? []
            let favorites = (try? store.prompts.favoriteCount()) ?? 0
            DispatchQueue.main.async {
                self.all = entries
                self.sessionsById = sessionMeta
                self.totalCount = entries.count
                self.favoriteCount = favorites
                self.lastScanAt = now
                self.rebuild()
                self.scanning = false
                self.scanPhase = nil
            }
        }
    }

    private func publishPhase(_ phase: String) {
        DispatchQueue.main.async { self.scanPhase = phase }
    }

    /// 列表过滤：搜索（标题/正文/标签）+ 收藏开关；first_seen 倒序（最新提问在前）
    private func rebuild() {
        let lowered = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = all
        if favoritesOnly {
            result = result.filter(\.favorite)
        }
        if !lowered.isEmpty {
            result = result.filter { entry in
                entry.title.lowercased().contains(lowered)
                    || entry.text.lowercased().contains(lowered)
                    || entry.tags.contains { $0.lowercased().contains(lowered) }
            }
        }
        prompts = result
    }

    /// 供命令面板消费的全量快照（未过滤）
    func knowledgeSnapshot() -> [PromptEntry] {
        all
    }

    /// 会话显示名（列表行副标题；找不到时回退短 id）
    func sessionName(for entry: PromptEntry) -> String? {
        sessionsById[entry.sessionId]?.displayName
    }

    func entry(id: String) -> PromptEntry? {
        all.first { $0.id == id }
    }

    // MARK: - 用户操作（写库 + 同步内存态）

    func toggleFavorite(_ id: String) {
        guard var entry = mutableEntry(id) else { return }
        entry.favorite.toggle()
        applyMutation(entry)
        try? store?.prompts.setFavorite(id, favorite: entry.favorite)
        if entry.favorite { favoriteCount += 1 } else { favoriteCount = max(0, favoriteCount - 1) }
    }

    func setTags(_ id: String, tags: [String]) {
        guard var entry = mutableEntry(id) else { return }
        entry.tags = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        applyMutation(entry)
        try? store?.prompts.setTags(id, tags: entry.tags)
    }

    /// 复制到剪贴板并计一次使用
    func copyToPasteboard(_ id: String) {
        guard let entry = entry(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        recordUse(id)
    }

    func recordUse(_ id: String) {
        guard var entry = mutableEntry(id) else { return }
        entry.useCount += 1
        entry.lastUsedAt = Date()
        applyMutation(entry)
        try? store?.prompts.recordUse(id)
    }

    func delete(_ id: String) {
        all.removeAll { $0.id == id }
        totalCount = all.count
        try? store?.prompts.delete(id: id)
        rebuild()
    }

    /// 跨页直达落点：找到条目则置 focus（由 PromptsView onAppear/onChange 消费）
    func revealPrompt(_ id: String) {
        focusId = id
    }

    private func mutableEntry(_ id: String) -> PromptEntry? {
        all.first { $0.id == id }
    }

    /// 把单条变更写回 all + prompts（两条列表都持有同一条目时保持一致）
    private func applyMutation(_ entry: PromptEntry) {
        if let index = all.firstIndex(where: { $0.id == entry.id }) {
            all[index] = entry
        }
        if let index = prompts.firstIndex(where: { $0.id == entry.id }) {
            prompts[index] = entry
        }
    }
}
