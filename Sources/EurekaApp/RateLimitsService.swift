import EurekaIngest
import EurekaKit
import EurekaUsage
import Foundation

/// 限额服务：Codex / Grok（本地日志快照，零网络）+ Claude（opt-in 非官方接口）。
/// Provider 返回 nil = 该来源整块隐藏。
final class RateLimitsService: ObservableObject {
    @Published private(set) var codex: RateLimitSnapshot?
    @Published private(set) var grok: RateLimitSnapshot?
    @Published private(set) var claude: RateLimitSnapshot?
    @Published private(set) var claudeFailureHint: String?

    /// 非官方接口默认关闭
    @Published var claudeEnabled: Bool = UserDefaults.standard.bool(forKey: "claudeLimitsEnabled") {
        didSet {
            UserDefaults.standard.set(claudeEnabled, forKey: "claudeLimitsEnabled")
            if claudeEnabled {
                refresh()
            } else {
                claude = nil
                claudeFailureHint = nil
            }
        }
    }

    private let codexProvider = CodexRateLimitProvider(
        sessionsRoot: CodexRolloutTailer.defaultSessionsRoot())
    // Grok 配额同 Codex：本地日志快照、零网络、失败即隐藏 → 无需 opt-in
    private let grokProvider = GrokRateLimitProvider(logURL: GrokPaths.unifiedLog())
    private let claudeProvider = ClaudeOAuthUsageProvider()
    private var timer: Timer?
    private var refreshing = false

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let wantClaude = claudeEnabled
        Task { [weak self] in
            guard let self else { return }
            let codexSnapshot = await self.codexProvider.snapshot()
            let grokSnapshot = await self.grokProvider.snapshot()
            let claudeSnapshot = wantClaude ? await self.claudeProvider.snapshot() : nil
            let hint = wantClaude ? self.claudeProvider.lastFailure : nil
            await MainActor.run {
                self.codex = codexSnapshot
                self.grok = grokSnapshot
                self.claude = claudeSnapshot
                self.claudeFailureHint = hint
                self.refreshing = false
            }
        }
    }
}
