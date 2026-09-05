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
    /// 高频重复组（除噪除琐碎后按指纹聚类，refresh 队列算好缓存 —— 不在 body 里逐次算）
    @Published private(set) var groups: [PromptGroup] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanPhase: String?
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var totalCount = 0
    @Published private(set) var favoriteCount = 0
    /// 默认被折叠的条数（噪音/琐碎/长粘贴且未收藏），统计卡提示用
    @Published private(set) var foldedCount = 0
    /// 评价缓存（prompt_id → 四层信号聚合结果；提取管线算好落库，这里只读回）。
    /// 缺行 = 该源不可评价或库尚未重扫 —— UI 必须静默无点，不显示"clean"
    @Published private(set) var evalById: [String: PromptEval] = [:]
    /// 跨页直达目标（命令面板 / 会话详情跳入）
    var focusId: String?
    var searchText: String = "" { didSet { scheduleRebuild(debounce: true) } }
    var favoritesOnly = false { didSet { scheduleRebuild(debounce: false) } }
    /// 显示全部（含琐碎/长粘贴/存量噪音）；搜索时无视此开关不隐藏（搜索意图明确）
    var showAll = false { didSet { scheduleRebuild(debounce: false) } }

    /// 提取是后台增能（用户没在等它），utility 避免和 UI 关键路径抢核 ——
    /// 首次全量提取要重解析全部会话，userInitiated 会在启动预热时压住主界面
    private let queue = DispatchQueue(label: "com.vinlee.eureka.prompts", qos: .utility)
    /// 过滤代际：慢结果回主线程时已被更新的输入超越则丢弃
    private var rebuildGeneration = 0
    private let sessionBrowser: SessionBrowserService
    private var store: EurekaStore?
    private var all: [PromptEntry] = []
    /// id → 条目索引（与 all 同步维护）：详情直达、组成员展开、标注写回都按 id 找，
    /// 线性扫 all 在万级库上每展开一个组就要扫全库 N 遍
    private var byId: [String: PromptEntry] = [:]
    /// 复用价值分类缓存（refresh 队列算好；主线程读写）。
    /// 内存派生不入库：阈值迭代不需要刷库或迁移 schema
    private var kindById: [String: PromptKind] = [:]
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
                    // 每会话一个池：messages/轮次图等瞬态在会话间及时释放，
                    // 全量重扫（迁移后指纹清空）才不会把上百个会话的解析产物
                    // 一路积累到队列块结束（实测峰值 5.5GB 的主因之一）
                    autoreleasepool {
                        // load 一次共享给提取与评价（全量重解析是主要成本，绝不双调）
                        let messages = TranscriptReader.load(session: session).messages
                        let entries = PromptExtractor.extract(
                            messages: messages, session: session, at: now)
                        try? store.prompts.upsertExtracted(entries, at: now)
                        let evals = Self.evaluate(
                            messages: messages, session: session,
                            extractedIds: Set(entries.map(\.id)))
                        try? store.prompts.upsertEval(evals)
                        try? store.prompts.markExtracted(
                            sessionId: session.id, source: session.source, at: now)
                    }
                    if index % 25 == 0 {
                        self.publishPhase(
                            "正在解析会话 \(index + 1)/\(pending.count)…")
                    }
                }
            }
            let entries = (try? store.prompts.all()) ?? []
            let favorites = (try? store.prompts.favoriteCount()) ?? 0
            let evals = (try? store.prompts.evalMap()) ?? [:]
            // 分类 + 聚类都在这条队列上一次算完缓存（几千条 O(n)，不进 UI 渲染路径）
            var kinds: [String: PromptKind] = [:]
            kinds.reserveCapacity(entries.count)
            var folded = 0
            for entry in entries {
                let kind = PromptClassifier.classify(entry.text)
                kinds[entry.id] = kind
                if !entry.favorite, Self.isFoldable(kind) {
                    folded += 1
                }
            }
            let groups = PromptGrouping.groups(from: entries, minCount: 3) { entry in
                let kind = kinds[entry.id] ?? .instruction
                return kind != .noise && kind != .trivial
            }
            let index = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async {
                self.all = entries
                self.byId = index
                self.kindById = kinds
                self.groups = groups
                self.evalById = evals
                self.foldedCount = folded
                self.sessionsById = sessionMeta
                self.totalCount = entries.count
                self.favoriteCount = favorites
                self.lastScanAt = now
                self.scheduleRebuild(debounce: false)
                self.scanning = false
                self.scanPhase = nil
            }
        }
    }

    private func publishPhase(_ phase: String) {
        DispatchQueue.main.async { self.scanPhase = phase }
    }

    /// 一个会话的全部 prompt 评价：切轮 → （仅 full 档）建图跑轮内诊断 → 聚合四层信号。
    /// 只评价真的入库的 prompt（被 extract 滤掉的噪音不评）；excluded 源返回空。
    /// 纯计算，跑在提取队列上。
    static func evaluate(
        messages: [TranscriptMessage], session: AgentSessionInfo,
        extractedIds: Set<String>
    ) -> [PromptEval] {
        let capability = PromptEvalCapability.level(for: session.source)
        guard capability != .excluded, !extractedIds.isEmpty else { return [] }
        let turns = TurnSlicer.slice(messages)
        var evals: [PromptEval] = []
        for (index, turn) in turns.enumerated() {
            guard let messageId = turn.promptMessageId else { continue }
            let promptId = PromptEntry.makeId(
                source: session.source, sessionId: session.id, messageIdx: messageId)
            guard extractedIds.contains(promptId) else { continue }
            // 构图只对 full 档做（toolNote 源的图退化到全 0，白付构图成本）
            let diagnostics = capability == .full
                ? TurnDiagnostics.evaluate(
                    TurnGraphBuilder.build(turn), promptChars: turn.promptText.count)
                : nil
            // 下一条真实提问（跳过无提问的续跑轮）
            let next = turns[(index + 1)...]
                .first { $0.promptMessageId != nil }?.promptText
            if let eval = PromptEvaluator.evaluate(
                promptId: promptId, turn: turn, diagnostics: diagnostics,
                nextPromptText: next, capability: capability) {
                evals.append(eval)
            }
        }
        return evals
    }

    /// 列表过滤：搜索（正文/标签，标题是正文首行故已被覆盖）+ 收藏开关；
    /// first_seen 倒序（最新提问在前）。全文 lowercased 扫描随库增长可达几十 MB/次，
    /// 放全局后台队列做（不进提取队列——utility 的提取全量跑时会把搜索排到最后）；
    /// 搜索输入 250ms 防抖（与 ⌘K 同参），收藏开关/刷新即时执行。
    private func scheduleRebuild(debounce: Bool) {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.25 : 0)) { [weak self] in
            guard let self, self.rebuildGeneration == generation else { return }
            let lowered = self.searchText
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let onlyFavorites = self.favoritesOnly
            let snapshot = self.all
            let kinds = self.kindById
            // 默认折叠低价值分类（噪音/琐碎/长粘贴）；收藏的永远保留；
            // 搜索时不隐藏 —— 用户明确在找，就该什么都能找到
            let hideFolded = !self.showAll && lowered.isEmpty
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var result = snapshot
                if hideFolded {
                    result = result.filter { entry in
                        if entry.favorite { return true }
                        let kind = kinds[entry.id] ?? .instruction
                        return kind == .instruction || kind == .followup
                    }
                }
                if onlyFavorites {
                    result = result.filter(\.favorite)
                }
                if !lowered.isEmpty {
                    result = result.filter { entry in
                        entry.text.lowercased().contains(lowered)
                            || entry.tags.contains { $0.lowercased().contains(lowered) }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.rebuildGeneration == generation else { return }
                    self.prompts = result
                }
            }
        }
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
        byId[id]
    }

    /// 默认折叠的低复用价值分类（噪音/琐碎/长粘贴）；收藏的条目不折叠
    private static func isFoldable(_ kind: PromptKind?) -> Bool {
        kind == .noise || kind == .trivial || kind == .paste
    }

    // MARK: - 用户操作（写库 + 同步内存态）

    func toggleFavorite(_ id: String) {
        guard var entry = mutableEntry(id) else { return }
        entry.favorite.toggle()
        applyMutation(entry)
        try? store?.prompts.setFavorite(id, favorite: entry.favorite)
        favoriteCount = max(0, favoriteCount + (entry.favorite ? 1 : -1))
        // 折叠数只算未收藏的低价值条目：收藏即从折叠里拿出来，取消收藏再放回去
        if Self.isFoldable(kindById[id]) {
            foldedCount = max(0, foldedCount + (entry.favorite ? -1 : 1))
        }
    }

    func setTags(_ id: String, tags: [String]) {
        guard var entry = mutableEntry(id) else { return }
        entry.tags = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        applyMutation(entry)
        try? store?.prompts.setTags(id, tags: entry.tags)
    }

    /// 条目的复用价值分类（refresh 缓存；未知按 instruction 保守处理）
    func kind(of id: String) -> PromptKind {
        kindById[id] ?? .instruction
    }

    /// 条目的评价结果；nil = 该源不可评价或尚未重扫（UI 静默，不显示"clean"）
    func eval(of id: String) -> PromptEval? {
        evalById[id]
    }

    /// 「以此提问在终端启动新会话」的完整命令；源不在白名单（claude/codex）时 nil
    func launchCommand(for id: String) -> String? {
        guard let entry = entry(id: id),
              let cli = PromptLaunchCommand.cliExecutable(for: entry.source)
        else { return nil }
        return PromptLaunchCommand.build(cli: cli, cwd: entry.cwd, prompt: entry.text)
    }

    /// 在 Terminal 新窗口以此提问启动新会话，并计一次复用
    func launchInTerminal(_ id: String) {
        guard let command = launchCommand(for: id) else { return }
        TerminalRunner.run(command: command)
        recordUse(id)
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

    /// 从库中移除：库里是软删除（行留着挡住重提取的复活，见 PromptsRepo.hide），
    /// 内存态全部同步更新 —— 列表、索引、统计数、分类/评价缓存、高频组 —— 不走异步
    /// rebuild（删除要即时反馈），也不等下次 refresh（组的 ×N 与收藏数不能错到那时候）。
    func delete(_ id: String) {
        guard let entry = byId[id] else { return }
        all.removeAll { $0.id == id }
        prompts.removeAll { $0.id == id }
        byId[id] = nil
        totalCount = all.count
        if entry.favorite {
            favoriteCount = max(0, favoriteCount - 1)
        } else if Self.isFoldable(kindById[id]) {
            foldedCount = max(0, foldedCount - 1)
        }
        kindById[id] = nil
        evalById[id] = nil
        let index = byId
        groups = PromptGrouping.removing(memberId: id, from: groups) { index[$0] }
        try? store?.prompts.hide(id)
    }

    /// 跨页直达落点：找到条目则置 focus（由 PromptsView onAppear/onChange 消费）
    func revealPrompt(_ id: String) {
        focusId = id
    }

    private func mutableEntry(_ id: String) -> PromptEntry? {
        byId[id]
    }

    /// 把单条变更写回 all + byId + prompts（三处都持有同一条目时保持一致）
    private func applyMutation(_ entry: PromptEntry) {
        byId[entry.id] = entry
        if let index = all.firstIndex(where: { $0.id == entry.id }) {
            all[index] = entry
        }
        if let index = prompts.firstIndex(where: { $0.id == entry.id }) {
            prompts[index] = entry
        }
    }
}
