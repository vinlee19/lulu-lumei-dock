import EurekaKit
import SwiftUI

/// 限额面板：5h / 周窗口用量进度条 + 重置时间。数据不可得即整块隐藏。
struct LimitsPanelView: View {
    @ObservedObject var service: RateLimitsService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let codex = service.codex {
                    LimitCard(snapshot: codex)
                }
                if let grok = service.grok {
                    LimitCard(snapshot: grok)
                }

                if service.claudeEnabled {
                    if let claude = service.claude {
                        LimitCard(snapshot: claude)
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
                    Text("还没有 Codex/Grok 限额快照（跑一次 codex 或 grok 后出现）")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text("Codex/Grok 限额来自本地日志快照（零网络请求）；Claude 限额走非官方接口，失效时自动隐藏。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
        }
        .onAppear { service.refresh() }
    }
}

private struct LimitCard: View {
    let snapshot: RateLimitSnapshot

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
                        .background(Capsule().fill(Theme.limits.opacity(0.15)))
                        .foregroundStyle(Theme.limits)
                }
                Spacer()
                if snapshot.isStale {
                    Text("截至 \(snapshot.asOf, format: .dateTime.hour().minute())")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            if let primary = snapshot.primary {
                WindowGauge(
                    label: Self.windowLabel(primary.windowMinutes, fallback: "5 小时窗口"),
                    window: primary)
            }
            if let secondary = snapshot.secondary {
                WindowGauge(
                    label: Self.windowLabel(secondary.windowMinutes, fallback: "每周窗口"),
                    window: secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill(Theme.limits)))
    }

    /// 窗口时长 → 中文标签（Codex 5h/周；Grok 周/月单窗）
    static func windowLabel(_ minutes: Int, fallback: String) -> String {
        switch minutes {
        case 300: return "5 小时窗口"
        case 10080: return "每周窗口"
        case 43200: return "每月窗口"
        default: return fallback
        }
    }
}

private struct WindowGauge: View {
    let label: String
    let window: RateLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(barColor)
                if let resets = window.resetsAt {
                    Text("· \(resets, format: .relative(presentation: .named)) 重置")
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
            Text("Claude Code 限额")
                .font(.system(size: 12, weight: .medium))
            Text("显示订阅 5 小时 / 每周窗口用量。需要读取钥匙串中的 Claude Code 凭证并调用非官方接口（官方变更后会自动隐藏，不影响其他功能）。首次启用会弹一次钥匙串授权，选「始终允许」即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Toggle("启用（非官方接口）", isOn: $service.claudeEnabled)
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cardFill(Theme.limits)))
    }
}
