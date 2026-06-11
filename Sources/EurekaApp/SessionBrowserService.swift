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
    }

    enum SortMode: String, CaseIterable {
        case time = "按时间"
        case size = "按大小"
    }

    @Published private(set) var groups: [ProjectGroup] = []
    @Published private(set) var costs: [String: SessionCost] = [:]
    /// 每会话对话数
    @Published private(set) var promptCounts: [String: Int] = [:]
    @Published private(set) var scanning = false
    @Published var sortMode: SortMode = .time {
        didSet { rebuild() }
    }
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.sessions", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var sessions: [AgentSessionInfo] = []
    // 以下仅 queue 上访问
    private var store: EurekaStore?
    private var pricing = PricingTable(models: [])
    private var storeLoaded = false

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            if !self.storeLoaded {
                self.storeLoaded = true
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
                self.pricing = PricingTable.load(
                    bundledURL: Bundle.module.url(forResource: "pricing", withExtension: "json"),
                    overrideURL: SpoolPaths.root().appendingPathComponent("pricing.json"))
            }
            var indexed = ClaudeSessionIndexer.index(
                projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot())
            indexed += CodexSessionIndexer.index(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot())

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
                self.costs = costMap
                self.promptCounts = prompts
                self.scanning = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var byProject: [String: [AgentSessionInfo]] = [:]
        for session in sessions {
            if !query.isEmpty {
                let haystack = [
                    session.name, session.id, session.cwd,
                ].compactMap { $0?.lowercased() }.joined(separator: " ")
                guard haystack.contains(query) else { continue }
            }
            let name = resolver.projectName(forCwd: session.cwd) ?? "（未知项目）"
            byProject[name, default: []].append(session)
        }
        var result: [ProjectGroup] = byProject.map { name, sessions in
            let groupCosts = sessions.compactMap { costs[$0.id]?.costUSD }
            return ProjectGroup(
                name: name,
                sessions: sessions,
                totalBytes: sessions.reduce(0) { $0 + $1.sizeBytes },
                latestActiveAt: sessions.map(\.lastActiveAt).max() ?? .distantPast,
                totalCostUSD: groupCosts.isEmpty ? nil : groupCosts.reduce(0, +)
            )
        }
        switch sortMode {
        case .time:
            result.sort { $0.latestActiveAt > $1.latestActiveAt }
            for index in result.indices {
                result[index].sessions.sort { $0.lastActiveAt > $1.lastActiveAt }
            }
        case .size:
            result.sort { $0.totalBytes > $1.totalBytes }
            for index in result.indices {
                result[index].sessions.sort { $0.sizeBytes > $1.sizeBytes }
            }
        }
        groups = result
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 拷贝恢复命令到剪贴板
    func copyResumeCommand(_ session: AgentSessionInfo) {
        let resume = session.source == .claude
            ? "claude --resume \(session.id)"
            : "codex resume \(session.id)"
        var command = resume
        if let cwd = session.cwd {
            command = "cd '\(cwd)' && " + resume
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
