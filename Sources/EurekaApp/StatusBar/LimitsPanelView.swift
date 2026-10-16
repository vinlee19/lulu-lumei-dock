import EurekaKit
import SwiftUI

/// 限额面板：5h / 周窗口用量进度条 + 重置时间。数据不可得即整块隐藏。
struct LimitsPanelView: View {
    @ObservedObject var service: RateLimitsService
    @ObservedObject var settings: AppSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.module) {
                if let codex = service.codex {
                    LimitCard(snapshot: codex, forecasts: service.forecasts)
                }
                if let grok = service.grok {
                    LimitCard(snapshot: grok, forecasts: service.forecasts)
                }

                if let antigravity = service.antigravity {
                    LimitCard(snapshot: antigravity, forecasts: service.forecasts)
                }

                if service.claudeEnabled {
                    if let claude = service.claude {
                        LimitCard(snapshot: claude, forecasts: service.forecasts)
                    }
                    if let hint = service.claudeFailureHint {
                        Text(hint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                    }
                } else {
                    ClaudeOptInCard(service: service)
                }

                if service.codex == nil && service.grok == nil && !service.claudeEnabled {
                    Text(L10n.text("No Codex/Grok limit snapshot yet (appears after you run codex or grok once)", zhHans: "还没有 Codex/Grok 限额快照（跑一次 codex 或 grok 后出现）"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                AntigravityOptInRow(settings: settings, service: service)

                Text(L10n.text("Codex/Grok limits come from a local log snapshot (no network). Claude limits use an unofficial API and hide themselves when it fails. OpenCode / Antigravity / Kimi / Gemini / Qwen / Hermes / CodeBuddy / Qoder / Cursor / Trae have no local limit source (Kimi quota is only on its membership page; Hermes bills through each provider subscription; Cursor quota is only on the website and in the IDE, with no local snapshot; Trae's session database is SQLCipher-encrypted, so no usage can be read locally), so they are not shown.", zhHans: "Codex/Grok 限额来自本地日志快照（零网络请求）；Claude 限额走非官方接口，失效时自动隐藏。OpenCode / Antigravity / Kimi / Gemini / Qwen / Hermes / CodeBuddy / Qoder / Cursor / Trae 无本地限额数据源（Kimi 配额仅官网会员页可见；Hermes 经各 provider 订阅计费；Cursor 配额只在官网与 IDE 内可见，本地不落配额快照；Trae 的会话库经 SQLCipher 加密，本地读不到任何用量），故不显示。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.spacing.page)
        }
        .onAppear { service.refresh() }
    }
}

/// Antigravity 实验开关：控制用量扫描（格式未公开，默认关）
private struct AntigravityOptInRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var service: RateLimitsService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L10n.text("Antigravity usage (experimental)", zhHans: "Antigravity 用量统计（实验）"), isOn: $settings.antigravityExperimentalEnabled)
                .font(.system(size: 11))
                .onChange(of: settings.antigravityExperimentalEnabled) { _, _ in service.refresh() }
            Text(L10n.text(
                "Reads unpublished per-call tokens from the Antigravity session database (priced as API-equivalent from public rates) and shows them on the Usage page. The format can change between versions and hides itself when it cannot be parsed. Antigravity weekly / 5-hour quotas are fetched live by agy and are not stored locally, so they are not shown yet.",
                zhHans: "解析 Antigravity 会话库里未公开的逐次调用 token（按公开价格折算 API 等价费用），结果在用量页。格式随版本可能变化，解析不了时自动隐藏。Antigravity 的每周 / 5 小时额度只由 agy 在线获取、不落本地，暂不显示。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }
}

private struct LimitCard: View {
    let snapshot: RateLimitSnapshot
    /// 预计打满时刻（key = "source#primary/secondary"，见 RateLimitsService.forecasts）
    var forecasts: [String: Date] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.source.displayName)
                    .font(.system(size: 12, weight: .medium))
                if let plan = snapshot.planType {
                    Text(plan)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.brandFill(0.14)))
                        .foregroundStyle(Theme.brandFg)
                }
                Spacer()
                if snapshot.isStale {
                    Text(Calendar.current.isDateInToday(snapshot.asOf)
                        ? L10n.format(
                            "As of %@",
                            zhHans: "截至 %@",
                            snapshot.asOf.formatted(.dateTime.hour().minute()))
                        : L10n.format(
                            "As of %@",
                            zhHans: "截至 %@",
                            snapshot.asOf.formatted(.dateTime.month().day().hour().minute())))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
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
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    /// 窗口时长 → 中文标签（Codex 5h/周；Grok 周/月单窗）
    static func windowLabel(_ minutes: Int, fallback: String) -> String {
        switch minutes {
        case 300: return L10n.text("5-hour window", zhHans: "5 小时窗口")
        case 10080: return L10n.text("Weekly window", zhHans: "每周窗口")
        case 43200: return L10n.text("Monthly window", zhHans: "每月窗口")
        default: return fallback
        }
    }
}

private struct WindowGauge: View {
    let label: String
    let window: RateLimitWindow
    /// 按最近用量速度外推的预计打满时刻（无风险 = nil，不显示）
    var fullAt: Date?

    /// The window rolled over after the snapshot was taken: its percentage is history, not
    /// state. Draw it dimmed and say "已重置" instead of a past-tense "上周 重置".
    private var hasReset: Bool { window.hasReset() }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if let fullAt, !hasReset {
                    Text(L10n.format(
                        "⏳ Full around %@",
                        zhHans: "⏳ 预计 %@ 打满",
                        fullAt.formatted(.dateTime.hour().minute())))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(hasReset ? Color.secondary : barColor)
                if hasReset {
                    Text(L10n.text("· Reset, snapshot is stale", zhHans: "· 已重置，快照过期"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help(L10n.text("The snapshot is older than this window's reset, so the percentage is not current usage. Run that CLI once to refresh it.", zhHans: "快照晚于这个窗口的重置时刻，百分比已不代表当前用量；跑一次该 CLI 会刷新"))
                } else if let resets = window.resetsAt {
                    Text(L10n.format(
                        "· %@ reset",
                        zhHans: "· %@ 重置",
                        resets.formatted(.relative(presentation: .named))))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [barColor.opacity(0.65), barColor],
                            startPoint: .leading, endPoint: .trailing))
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
                .font(.system(size: 12, weight: .medium))
            Text(L10n.text("Shows subscription usage for the 5-hour and weekly windows. This reads the Claude Code credential from the Keychain and calls an unofficial API (it hides itself if the API changes, and nothing else is affected). The first time you turn it on, macOS asks for Keychain access — choose Always Allow.", zhHans: "显示订阅 5 小时 / 每周窗口用量。需要读取钥匙串中的 Claude Code 凭证并调用非官方接口（官方变更后会自动隐藏，不影响其他功能）。首次启用会弹一次钥匙串授权，选「始终允许」即可。"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Toggle(L10n.text("Enable (unofficial API)", zhHans: "启用（非官方接口）"), isOn: $service.claudeEnabled)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }
}
