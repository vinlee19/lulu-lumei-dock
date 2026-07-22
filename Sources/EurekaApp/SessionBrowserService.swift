import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// 项目会话浏览：Claude + Codex 双源、按项目分组、搜索、会话级费用。
/// 自带只读 EurekaStore 连接（WAL 并发读安全；UsageService 先启动负责迁移）。
final class SessionBrowserService: ObservableObject {
    struct SessionCost: Equatable {
        var totalTokens: Int
        var costUSD: Double?
    }

    struct ProjectGroup: Identifiable {
        var id: String { name }
        var name: String
        var sessions: [AgentSessionInfo]
        var totalBytes: UInt64
        var latestActiveAt: Date
        var totalCostUSD: Double?
        /// 项目总时长 = 组内各会话跨度求和
        var totalDuration: TimeInterval
    }

    /// rawValue 为稳定持久化 token；label 为界面展示文案（解耦，改文案不动存档）。
    /// 前三档为扁平列表排序维度；「项目」为按项目分组视图。
    enum SortMode: String, CaseIterable {
        case time
        case size
        case duration
        case project

        var label: String {
            switch self {
            case .time: return "活跃"      // 最近活跃时间
            case .size: return "占用"      // transcript 磁盘占用
            case .duration: return "耗时"  // 会话首末活动跨度
            case .project: return "项目"
            }
        }

        /// 页签图标（SF Symbol，同侧边栏/设置页的胶囊页签风格）
        var icon: String {
            switch self {
            case .time: return "clock.fill"
            case .size: return "internaldrive.fill"
            case .duration: return "hourglass"
            case .project: return "folder.fill"
            }
        }
    }

    /// 全部会话的账本总览（不受搜索/截断影响）
    struct Summary: Equatable {
        var totalBytes: UInt64 = 0
        var sessionCount: Int = 0
        var totalCostUSD: Double?
    }

    /// 全文搜索命中（消息级）：snippet 已按查询词就近裁剪
    struct FullTextHit: Identifiable, Equatable {
        var id: Int64
        var source: AgentSource
        var sessionId: String
        var sessionName: String?
        var messageIdx: Int
        var role: String
        var ts: Date?
        var snippet: String
    }

    @Published private(set) var groups: [ProjectGroup] = []
    /// 扁平列表（time/size/duration 三档；project 档时为空，走 groups）
    @Published private(set) var flatSessions: [AgentSessionInfo] = []
    /// 各来源会话数（全集口径，来源 chips 计数用；不受搜索/筛选影响）
    @Published private(set) var sourceCounts: [AgentSource: Int] = [:]
    @Published private(set) var summary = Summary()
    /// id → 会话索引信息（用量"按会话"排行 join 会话名 + 跨页签跳转用），refresh 完成时填充
    @Published private(set) var sessionsById: [String: AgentSessionInfo] = [:]
    @Published private(set) var costs: [String: SessionCost] = [:]
    /// 每会话对话数
    @Published private(set) var promptCounts: [String: Int] = [:]
    @Published private(set) var scanning = false
    /// 当前选中的会话（详情栏渲染对象）
    @Published private(set) var selected: AgentSessionInfo?
    @Published private(set) var transcript: [TranscriptMessage] = []
    @Published private(set) var transcriptTruncated = false
    @Published private(set) var transcriptLoading = false
    @Published var sortMode: SortMode = .time {
        didSet { rebuild() }
    }
    @Published var searchText = "" {
        didSet {
            rebuild()
            scheduleFullTextSearch()
        }
    }
    /// 全文搜索命中（搜索词 ≥2 字符时异步填充）
    @Published private(set) var fullTextHits: [FullTextHit] = []
    /// 全文命中点击后待跳转的消息 id（transcript 加载完成后由详情页消费）
    @Published private(set) var pendingJumpMessageId: Int?
    /// 来源筛选（nil = 全部）
    @Published var sourceFilter: AgentSource? {
        didSet { rebuild() }
    }
    /// 按时间/大小最多展示多少个会话（0 = 全部）；搜索态忽略此限制
    @Published var displayLimit: Int = 10 {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.sessions", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var sessions: [AgentSessionInfo] = []
    /// 待跳转的会话 id（索引未就绪时记下，refresh 完成后消费）
    private var pendingRevealId: String?
    /// 全文搜索防抖
    private var searchWorkItem: DispatchWorkItem?
    // 以下仅 queue 上访问
    private var store: EurekaStore?
    private var pricing = PricingTable(models: [])
    private var storeLoaded = false

    /// 惰性打开只读 store 连接（refresh / 全文搜索共用，仅 queue 上调用）
    private func loadStoreIfNeeded() {
        guard !storeLoaded else { return }
        storeLoaded = true
        store = try? EurekaStore(path: EurekaStore.defaultURL())
        pricing = PricingTable.load(
            bundledURL: AppResources.bundle.url(forResource: "pricing", withExtension: "json"),
            overrideURL: SpoolPaths.root().appendingPathComponent("pricing.json"))
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            self.loadStoreIfNeeded()
            var indexed = ClaudeSessionIndexer.index(
                projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot())
            indexed += CodexSessionIndexer.index(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot())
            indexed += OpencodeSessionIndexer.index(dbPath: OpencodePaths.db())
            indexed += GrokSessionIndexer.index(sessionsRoot: GrokPaths.sessionsRoot())
            indexed += AntigravitySessionIndexer.index(
                conversationsRoot: AntigravityPaths.conversationsRoot())
            indexed += KimiSessionIndexer.index(sessionsRoot: KimiPaths.sessionsRoot())
            indexed += GeminiSessionIndexer.index(
                tmpRoot: GeminiPaths.tmpRoot(), projectsFile: GeminiPaths.projectsFile())
            indexed += QwenSessionIndexer.index(projectsRoot: QwenPaths.projectsRoot())
            // 按 id 去重（Claude 嵌套子代理目录等可能重复索引同一会话；
            // ForEach 重复 id 会导致列表渲染出空白行）
            var seenIds = Set<String>()
            indexed = indexed.filter { seenIds.insert($0.id).inserted }

            // 会话级费用：逐会话×模型聚合后按价格表折算
            var costMap: [String: SessionCost] = [:]
            if let store = self.store,
               let totals = try? store.usage.totalsForSessions(indexed.map(\.id)) {
                for (sessionId, rows) in totals {
                    var tokens = 0
                    var cost: Double?
                    for row in rows {
                        tokens += row.inputTokens + row.outputTokens
                            + row.cacheReadTokens + row.cacheCreationTokens
                        if let rowCost = self.pricing.cost(of: row) {
                            cost = (cost ?? 0) + rowCost
                        }
                    }
                    costMap[sessionId] = SessionCost(totalTokens: tokens, costUSD: cost)
                }
            }

            let prompts = (try? self.store?.sessionStats.promptCounts(
                for: indexed.map(\.id))) ?? [:]

            DispatchQueue.main.async {
                self.sessions = indexed
                self.sessionsById = Dictionary(
                    indexed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.costs = costMap
                self.promptCounts = prompts
                self.scanning = false
                self.rebuild()
                // 索引就绪后消费待跳转请求（用量"按会话"排行点击时索引可能还没建）
                if let pending = self.pendingRevealId {
                    self.pendingRevealId = nil
                    if let hit = self.sessionsById[pending] {
                        self.select(hit)
                    }
                }
            }
        }
    }

    private func rebuild() {
        // 总览：全部会话，不过滤、不截断
        let allCosts = sessions.compactMap { costs[$0.id]?.costUSD }
        summary = Summary(
            totalBytes: sessions.reduce(0) { $0 + $1.sizeBytes },
            sessionCount: sessions.count,
            totalCostUSD: allCosts.isEmpty ? nil : allCosts.reduce(0, +))
        sourceCounts = sessions.reduce(into: [:]) { $0[$1.source, default: 0] += 1 }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var visible = sessions
        if let filter = sourceFilter {
            visible = visible.filter { $0.source == filter }
        }
        if !query.isEmpty {
            // 搜索态：全量匹配，不截断
            visible = visible.filter { session in
                let haystack = [
                    session.name, session.id, session.cwd,
                ].compactMap { $0?.lowercased() }.joined(separator: " ")
                return haystack.contains(query)
            }
        }

        // 扁平三档：排序 + 截断，不做项目分组
        if sortMode != .project {
            switch sortMode {
            case .time: visible.sort { $0.lastActiveAt > $1.lastActiveAt }
            case .size: visible.sort { $0.sizeBytes > $1.sizeBytes }
            case .duration: visible.sort { ($0.duration ?? 0) > ($1.duration ?? 0) }
            case .project: break
            }
            if query.isEmpty, displayLimit > 0 {
                visible = Array(visible.prefix(displayLimit))
            }
            flatSessions = visible
            groups = []
            return
        }

        // 项目档：按项目分组（组间按最近活跃排，组内按最近活跃排）；
        // 非搜索态按最近活跃截断到 displayLimit 后再分组
        if query.isEmpty, displayLimit > 0 {
            visible.sort { $0.lastActiveAt > $1.lastActiveAt }
            visible = Array(visible.prefix(displayLimit))
        }
        var byProject: [String: [AgentSessionInfo]] = [:]
        for session in visible {
            let name = resolver.projectName(forCwd: session.cwd) ?? "（未知项目）"
            byProject[name, default: []].append(session)
        }
        var result: [ProjectGroup] = byProject.map { name, sessions in
            let groupCosts = sessions.compactMap { costs[$0.id]?.costUSD }
            return ProjectGroup(
                name: name,
                sessions: sessions.sorted { $0.lastActiveAt > $1.lastActiveAt },
                totalBytes: sessions.reduce(0) { $0 + $1.sizeBytes },
                latestActiveAt: sessions.map(\.lastActiveAt).max() ?? .distantPast,
                totalCostUSD: groupCosts.isEmpty ? nil : groupCosts.reduce(0, +),
                totalDuration: sessions.reduce(0) { $0 + ($1.duration ?? 0) }
            )
        }
        result.sort { $0.latestActiveAt > $1.latestActiveAt }
        flatSessions = []
        groups = result
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 全文搜索

    /// 防抖 250ms 后在后台查 FTS 索引；查询 <2 字符直接清空结果
    private func scheduleFullTextSearch() {
        searchWorkItem?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            fullTextHits = []
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadStoreIfNeeded()
            let hits = (try? self.store?.search.search(query, limit: 50)) ?? []
            let mapped = hits.map { hit in
                FullTextHit(
                    id: hit.docId,
                    source: AgentSource(rawValue: hit.source) ?? .claude,
                    sessionId: hit.sessionId,
                    sessionName: nil,
                    messageIdx: hit.messageIdx,
                    role: hit.role,
                    ts: hit.ts,
                    snippet: Self.snippet(around: query, in: hit.text))
            }
            DispatchQueue.main.async {
                // 结果落地前查询又变了 → 丢弃过期结果
                guard self.searchText.trimmingCharacters(in: .whitespaces) == query else { return }
                self.fullTextHits = mapped.map { hit in
                    var enriched = hit
                    enriched.sessionName = self.sessionsById[hit.sessionId]?.name
                    return enriched
                }
            }
        }
        searchWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// 就近裁剪命中片段：命中词前后各留 radius 字符，越界加省略号
    static func snippet(around query: String, in text: String, radius: Int = 40) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = collapsed.range(of: query, options: [.caseInsensitive]) else {
            return String(collapsed.prefix(radius * 2))
        }
        let start = collapsed.index(
            range.lowerBound, offsetBy: -radius, limitedBy: collapsed.startIndex)
            ?? collapsed.startIndex
        let end = collapsed.index(
            range.upperBound, offsetBy: radius, limitedBy: collapsed.endIndex)
            ?? collapsed.endIndex
        var result = String(collapsed[start..<end])
        if start > collapsed.startIndex { result = "…" + result }
        if end < collapsed.endIndex { result += "…" }
        return result
    }

    /// 全文命中点击：选中会话并记录待跳转消息（transcript 加载完成后由详情页消费）
    func revealMessage(sessionId: String, messageIdx: Int) {
        pendingJumpMessageId = messageIdx
        reveal(sessionId: sessionId)
    }

    /// 详情页 transcript 加载完成后取走待跳转消息 id（取即清）
    func consumePendingJump() -> Int? {
        defer { pendingJumpMessageId = nil }
        return pendingJumpMessageId
    }

    // MARK: - 选中与对话记录

    /// 跨页签跳转：按 id 选中会话（索引未就绪时记下，refresh 完成后自动选中）
    func reveal(sessionId: String) {
        if let hit = sessionsById[sessionId] {
            select(hit)
            return
        }
        pendingRevealId = sessionId
        refresh()
    }

    /// 选中会话并在后台加载对话记录
    func select(_ session: AgentSessionInfo?) {
        selected = session
        transcript = []
        transcriptTruncated = false
        guard let session else { return }
        transcriptLoading = true
        queue.async { [weak self] in
            let result = TranscriptReader.load(session: session)
            DispatchQueue.main.async {
                guard let self, self.selected?.id == session.id else { return }
                self.transcript = result.messages
                self.transcriptTruncated = result.truncated
                self.transcriptLoading = false
            }
        }
    }

    // MARK: - 恢复与删除

    /// 恢复命令（详情栏展示 + 复制 + 终端执行共用）
    func resumeCommand(for session: AgentSessionInfo) -> String {
        let resume: String
        switch session.source {
        case .claude: resume = "claude --resume \(session.id)"
        case .codex: resume = "codex resume \(session.id)"
        case .opencode: resume = "opencode --session \(session.id)"  // 用 --session 重新进入指定会话（opencode 1.17+）
        case .grok: resume = "grok --resume \(session.id)"
        case .antigravity: resume = "agy --conversation \(session.id)"
        case .kimi: resume = "kimi --session \(session.id)"
        case .gemini: resume = "gemini --resume \(session.id)"
        case .qwen: resume = "qwen --resume \(session.id)"
        }
        guard let cwd = session.cwd else { return resume }
        return "cd '\(cwd)' && " + resume
    }

    /// 拷贝恢复命令到剪贴板
    func copyResumeCommand(_ session: AgentSessionInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand(for: session), forType: .string)
    }

    /// 在 Terminal 新窗口/标签执行恢复命令（osascript；命令内双引号/反斜杠转义）
    func resumeInTerminal(_ session: AgentSessionInfo) {
        let command = resumeCommand(for: session)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// 删除会话（移废纸篓，可恢复）：claude/codex/grok/antigravity/kimi 支持（opencode 存共享库，不支持）。
    /// Claude 会话若有嵌套子代理目录（<session>/…）一并清理；grok 是整个 <uuid>/ 目录；
    /// antigravity 是 <uuid>.db（连 -wal/-shm）；kimi 是整个 session_<uuid>/ 目录。
    func deleteSessions(_ toDelete: [AgentSessionInfo], completion: ((Int) -> Void)? = nil) {
        let deletable = toDelete.filter { $0.source != .opencode }
        guard !deletable.isEmpty else {
            completion?(0)
            return
        }
        if let selectedId = selected?.id, deletable.contains(where: { $0.id == selectedId }) {
            select(nil)
        }
        queue.async { [weak self] in
            let fm = FileManager.default
            var trashed = 0
            for session in deletable {
                let fileURL = URL(fileURLWithPath: session.transcriptPath)
                // grok：transcriptPath = <uuid>/chat_history.jsonl，删整个会话目录
                if session.source == .grok {
                    let sessionDir = fileURL.deletingLastPathComponent()
                    if (try? fm.trashItem(at: sessionDir, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                    continue
                }
                // kimi：transcriptPath = session_<uuid>/agents/main/wire.jsonl，上翻三级删整个会话目录
                if session.source == .kimi {
                    let sessionDir = fileURL
                        .deletingLastPathComponent()   // main/
                        .deletingLastPathComponent()   // agents/
                        .deletingLastPathComponent()   // session_<uuid>/
                    if (try? fm.trashItem(at: sessionDir, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                    continue
                }
                // antigravity：transcriptPath = <uuid>.db，连同 -wal/-shm 一并删
                if session.source == .antigravity {
                    if (try? fm.trashItem(at: fileURL, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                    for suffix in ["-wal", "-shm"] {
                        let sidecar = URL(fileURLWithPath: session.transcriptPath + suffix)
                        if fm.fileExists(atPath: sidecar.path) {
                            try? fm.trashItem(at: sidecar, resultingItemURL: nil)
                        }
                    }
                    continue
                }
                if (try? fm.trashItem(at: fileURL, resultingItemURL: nil)) != nil {
                    trashed += 1
                }
                // Claude 嵌套目录（subagents 等）：<dir>/<sessionId>/
                let nested = fileURL.deletingPathExtension()
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue {
                    try? fm.trashItem(at: nested, resultingItemURL: nil)
                }
            }
            DispatchQueue.main.async { completion?(trashed) }
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }
}
