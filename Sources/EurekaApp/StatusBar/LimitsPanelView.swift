import EurekaKit
import SwiftUI

/// Rate-limit panel: 5h / weekly window usage progress bars + reset times. The whole block hides
/// when data is unavailable.
struct LimitsPanelView: View {
    @ObservedObject var service: RateLimitsService
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.module) {
                HStack(spacing: 8) {
                    Spacer()
                    if service.isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                    RefreshButton(help: L10n.text("Refresh limits (Antigravity / OpenCode at most every 2 min)", zhHans: "刷新限额（Antigravity / OpenCode 最多 2 分钟一次）")) {
                        service.refresh(.manual)
                    }
                }
                if let codex = service.codex {
                    LimitCard(snapshot: codex, forecasts: service.forecasts)
                }
                if let grok = service.grok {
                    LimitCard(snapshot: grok, forecasts: service.forecasts)
                }

                if let opencodeGo = service.opencodeGo {
                    LimitCard(snapshot: opencodeGo, forecasts: service.forecasts)
                }

                if service.claudeEnabled {
                    if let claude = service.claude {
                        LimitCard(snapshot: claude, forecasts: service.forecasts)
                    }
                    if let hint = service.claudeFailureHint {
                        Text(hint)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.orange)
                    }
                } else {
                    ClaudeOptInCard(service: service)
                }

                if service.codex == nil && service.grok == nil && !service.claudeEnabled {
                    Text(L10n.text("No Codex/Grok limit snapshot yet (appears after you run codex or grok once)", zhHans: "还没有 Codex/Grok 限额快照（跑一次 codex 或 grok 后出现）"))
                        .font(Theme.font.themed(11))
                        .foregroundStyle(.secondary)
                }

                // Antigravity reads as one section: its quota card sits right above its switch
                if let antigravity = service.antigravity {
                    LimitCard(snapshot: antigravity, forecasts: service.forecasts)
                } else if service.isProbing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(L10n.text("Getting Antigravity quota from agy /usage…", zhHans: "正在通过 agy /usage 获取 Antigravity 额度…"))
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if let hint = service.antigravityFailureHint {
                    Text(hint)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.orange)
                }
                AntigravityOptInRow(settings: settings, service: service)

                Text(L10n.text("Codex/Grok limits come from a local log snapshot (no network). Claude limits come first from Claude Code's own cached answer (~/.claude.json, no request) and fall back to an unofficial API, paced and backing off when rate-limited. Antigravity quotas (agy /usage) and the OpenCode Go allowance (opencode's own server, shown while the opencode service runs; without a Go plan or Console sign-in the card says so) come from each CLI itself and are fetched only when this page opens or you press refresh. Kimi / Gemini / Qwen / Hermes / CodeBuddy / Qoder / Cursor / Trae have no local limit source (Kimi quota is only on its membership page; Hermes bills through each provider subscription; Cursor quota is only on the website and in the IDE, with no local snapshot; Trae's session database is SQLCipher-encrypted, so no usage can be read locally), so they are not shown.", zhHans: "Codex/Grok 限额来自本地日志快照（零网络请求）；Claude 限额优先读 Claude Code 自己缓存的最近结果（~/.claude.json，零请求），过旧时才走非官方接口，并限速、遇到限流自动退避。Antigravity 额度（agy /usage）与 OpenCode Go 额度（opencode 自己的服务，opencode 后台服务在运行时显示；没订阅或没登录 Console 时卡片会说明）由各自 CLI 提供，只在打开本页或点刷新时获取。Kimi / Gemini / Qwen / Hermes / CodeBuddy / Qoder / Cursor / Trae 无本地限额数据源（Kimi 配额仅官网会员页可见；Hermes 经各 provider 订阅计费；Cursor 配额只在官网与 IDE 内可见，本地不落配额快照；Trae 的会话库经 SQLCipher 加密，本地读不到任何用量），故不显示。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.page)
        }
        .onAppear { service.refresh(.pageOpen) }
    }
}

/// Antigravity experiment toggle: controls usage scanning (format undocumented, off by default)
private struct AntigravityOptInRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var service: RateLimitsService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A switch like the Claude opt-in below, not the default checkbox it used to be
            Toggle(L10n.text("Antigravity token usage on the Usage page (experimental)", zhHans: "Antigravity token 用量统计（用量页，实验）"), isOn: $settings.antigravityExperimentalEnabled)
                .font(Theme.font.themed(11))
                .toggleStyle(.themedSwitch)
                .controlSize(.small)
                .onChange(of: settings.antigravityExperimentalEnabled) { _, _ in service.refresh() }
            Text(L10n.text(
                "Reads unpublished per-call tokens from the Antigravity session database (priced as API-equivalent from public rates) and shows them on the Usage page. The format can change between versions and hides itself when it cannot be parsed. The quota card above does not depend on this switch: it comes from agy's own /usage command, run only when this page opens or you press refresh (at most every 2 minutes).",
                zhHans: "解析 Antigravity 会话库里未公开的逐次调用 token（按公开价格折算 API 等价费用），结果在用量页。格式随版本可能变化，解析不了时自动隐藏。上方的额度卡片不受这个开关影响：它来自 agy 自带的 /usage 命令，只在打开本页或点刷新时运行（最多 2 分钟一次）。"))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
    }
}

private struct LimitCard: View {
    let snapshot: RateLimitSnapshot
    /// Expected full-at times (key = "source#primary/secondary", see RateLimitsService.forecasts)
    var forecasts: [String: Date] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.source.displayName)
                    .font(Theme.font.themed(12, .medium))
                if let plan = snapshot.planType {
                    Text(plan)
                        .font(Theme.font.themed(9, .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.brandFill(0.14)))
                        .foregroundStyle(Theme.brandFg)
                } else if let status = snapshot.planStatus {
                    // Muted: nothing is wrong, there is just no plan to meter
                    Text(Self.statusBadge(status))
                        .font(Theme.font.themed(9, .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.isStale {
                    Text(L10n.format("As of %@", zhHans: "截至 %@", asOfText))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.orange)
                } else {
                    // Fresh data says how fresh, ticking, so the refresh cadence is visible
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.updatedText(snapshot.asOf, now: context.date))
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.tertiary)
                    }
                    .help(L10n.format("Updated %@", zhHans: "更新于 %@", asOfText))
                }
            }
            if let primary = snapshot.primary {
                WindowGauge(
                    label: primary.label ?? Self.windowLabel(primary.windowMinutes, fallback: L10n.text("5-hour window", zhHans: "5 小时窗口")),
                    window: primary,
                    fullAt: forecasts["\(snapshot.source.rawValue)#primary"])
            }
            if let secondary = snapshot.secondary {
                WindowGauge(
                    label: secondary.label ?? Self.windowLabel(secondary.windowMinutes, fallback: L10n.text("Weekly window", zhHans: "每周窗口")),
                    window: secondary,
                    fullAt: forecasts["\(snapshot.source.rawValue)#secondary"])
            }
            if let status = snapshot.planStatus {
                Text(Self.statusExplanation(status, source: snapshot.source))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(snapshot.scopedWindows.enumerated()), id: \.offset) { _, window in
                WindowGauge(
                    label: Self.scopedLabel(window),
                    window: window,
                    note: window.capShareOfParent.map {
                        L10n.format("cap %@%% of weekly", zhHans: "上限为周额度的 %@%%", String(Int($0.rounded())))
                    })
            }
            if let credits = snapshot.credits {
                let line = RateLimitCreditsText.line(for: credits, source: snapshot.source)
                Text(line.text)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(line.help ?? line.text)
            }
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
    }

    private var asOfText: String {
        Calendar.current.isDateInToday(snapshot.asOf)
            ? snapshot.asOf.formatted(.dateTime.hour().minute())
            : snapshot.asOf.formatted(.dateTime.month().day().hour().minute())
    }

    static func statusBadge(_ status: RateLimitPlanStatus) -> String {
        switch status {
        case .signedOut: return L10n.text("Not signed in", zhHans: "未登录")
        case .noPlan: return L10n.text("No subscription", zhHans: "无订阅")
        }
    }

    /// What the missing plan means and how to get the meters (only OpenCode reports these today)
    static func statusExplanation(_ status: RateLimitPlanStatus, source: AgentSource) -> String {
        switch (status, source) {
        case (.signedOut, .opencode):
            return L10n.text("opencode is not signed in to OpenCode Console, so there is no OpenCode Go usage to show. Sign in to the Console account that holds your Go plan.", zhHans: "opencode 没有登录 OpenCode Console，所以看不到 OpenCode Go 用量。登录持有 Go 订阅的 Console 账号后这里会显示。")
        case (.noPlan, .opencode):
            return L10n.text("This OpenCode account has no OpenCode Go subscription. Subscribe at opencode.ai to see Go usage here.", zhHans: "这个 OpenCode 账号没有 OpenCode Go 订阅，在 opencode.ai 订阅后这里会显示 Go 用量。")
        case (.signedOut, _):
            return L10n.text("Not signed in, so there is no plan usage to show.", zhHans: "未登录，看不到订阅用量。")
        case (.noPlan, _):
            return L10n.text("This account has no subscription with usage limits.", zhHans: "这个账号没有带限额的订阅。")
        }
    }

    /// "Updated just now" / "Updated 3 min. ago" (relative, in the interface language)
    static func updatedText(_ asOf: Date, now: Date) -> String {
        now.timeIntervalSince(asOf) < 60
            ? L10n.text("Updated just now", zhHans: "刚刚更新")
            : L10n.format("Updated %@", zhHans: "%@更新", relativeLabel(asOf, relativeTo: now))
    }

    /// "Weekly window · Fable": the window's own label plus the model bucket it counts against.
    /// A window of unknown length (OpenCode Go's rolling meter) reads "Rolling window".
    static func scopedLabel(_ window: RateLimitWindow) -> String {
        let fallback = window.windowMinutes == 0
            ? L10n.text("Rolling window", zhHans: "滚动窗口")
            : L10n.text("Weekly window", zhHans: "每周窗口")
        let base = window.label ?? windowLabel(window.windowMinutes, fallback: fallback)
        guard let scope = window.scope else { return base }
        return "\(base) · \(scope)"
    }

    /// Window duration → localized label (Codex 5h/weekly; Grok weekly/monthly single window)
    static func windowLabel(_ minutes: Int, fallback: String) -> String {
        switch minutes {
        case 300: return L10n.text("5-hour window", zhHans: "5 小时窗口")
        case 1440: return L10n.text("Daily window", zhHans: "每日窗口")
        case 10080: return L10n.text("Weekly window", zhHans: "每周窗口")
        case 43200: return L10n.text("Monthly window", zhHans: "每月窗口")
        default: return fallback
        }
    }
}

private struct WindowGauge: View {
    let label: String
    let window: RateLimitWindow
    /// Expected full-at time extrapolated from recent usage speed (no risk = nil, not shown)
    var fullAt: Date?
    /// Muted qualifier after the label (a scoped window's share of the weekly allowance)
    var note: String?

    /// The window rolled over after the snapshot was taken: its percentage is history, not
    /// state. Draw it dimmed and say "Reset" instead of a past-tense "reset last week".
    private var hasReset: Bool { window.hasReset() }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                if let note {
                    Text("· \(note)")
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let fullAt, !hasReset {
                    Text(L10n.format("⏳ Full around %@", zhHans: "⏳ 预计 %@ 打满", fullAt.formatted(.dateTime.hour().minute())))
                        .font(Theme.font.themed(10, .medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(Theme.font.themedMono(11, .semibold))
                    .foregroundStyle(hasReset ? Color.secondary : barColor)
                if hasReset {
                    Text(L10n.text("· Reset, snapshot is stale", zhHans: "· 已重置，快照过期"))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.tertiary)
                        .help(L10n.text("The snapshot is older than this window's reset, so the percentage is not current usage. Run that CLI once to refresh it.", zhHans: "快照晚于这个窗口的重置时刻，百分比已不代表当前用量；跑一次该 CLI 会刷新"))
                } else if let resets = window.resetsAt {
                    Text(L10n.format("· resets %@", zhHans: "· %@ 重置", relativeLabel(resets)))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Theme.barFill(barColor, from: 0.65))
                        .frame(width: max(
                            4, proxy.size.width * min(window.usedPercent, 100) / 100))
                        .opacity(hasReset ? 0.3 : 1)
                }
            }
            .frame(height: 6)
        }
    }

    private var barColor: Color {
        Theme.percentColor(window.usedPercent)
    }
}

private struct ClaudeOptInCard: View {
    @ObservedObject var service: RateLimitsService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Claude Code limits", zhHans: "Claude Code 限额"))
                .font(Theme.font.themed(12, .medium))
            Text(L10n.text("Shows subscription usage for the 5-hour and weekly windows. It first reads the answer Claude Code itself cached in ~/.claude.json (only that entry and the account's plan fields); when that is older than 10 minutes it reads the Claude Code credential from the Keychain and calls an unofficial API (it hides itself if the API changes, and nothing else is affected). The first time you turn it on, macOS asks for Keychain access — choose Always Allow.", zhHans: "显示订阅 5 小时 / 每周窗口用量。优先读 Claude Code 自己缓存在 ~/.claude.json 里的最近结果（只读这一项和账号的套餐字段）；超过 10 分钟才读取钥匙串中的 Claude Code 凭证并调用非官方接口（官方变更后会自动隐藏，不影响其他功能）。首次启用会弹一次钥匙串授权，选「始终允许」即可。"))
                .font(Theme.font.themed(10.5))
                .foregroundStyle(.secondary)
            Toggle(L10n.text("Enable (unofficial API)", zhHans: "启用（非官方接口）"), isOn: $service.claudeEnabled)
                .font(Theme.font.themed(11))
                .toggleStyle(.themedSwitch)
                .controlSize(.small)
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
    }
}
