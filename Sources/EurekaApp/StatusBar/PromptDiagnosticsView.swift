import Charts
import EurekaKit
import EurekaStore
import SwiftUI

/// 「诊断」页签：跨会话的提示词质量。回答的是「我最常犯哪类毛病、在变好还是变坏」。
///
/// 骨架与四大知识页同构（`header + Divider + ScrollView{ 总览卡 / 来源 chips / 内容 }`）。
/// 趋势用 `BarMark` —— 保持全仓只有 BarMark 的现状，不为一张图引入 `LineMark`。
struct PromptDiagnosticsView: View {
    @ObservedObject var service: PromptDiagnosticsService
    @ObservedObject var sessionBrowser: SessionBrowserService

    /// 规则 id → 展示名与建议（与 `TurnDiagnostics` 的规则表对应）
    private static let ruleTitles: [String: (title: String, advice: String)] = [
        "explore-heavy": ("定位开销高", "提示词里直接点名文件/目录，能省掉找文件那段"),
        "reread": ("回读同一处", "上下文没一次给够：相关文件一次性给全"),
        "rework": ("改完又回看", "让它先读后改，或给出确切的改动位置"),
        "retry": ("失败重试", "把「怎样算成功」（命令、期望输出）写进提示词"),
        "churn": ("同一文件反复改", "先要一份改动方案再落笔"),
        "clarify": ("反问澄清", "把选择项与约束提前写清，省掉一次往返"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = service.lastError {
                        noticeCard(error, tint: Theme.failureRed)
                    }
                    if service.totalRows == 0 {
                        emptyState
                    } else {
                        statsCard
                        sourceBar
                        habitsCard
                        trendCard
                        worstCard
                    }
                }
                .padding(22)
            }
            .background(Theme.surfaceSecondary)
        }
        .onAppear { service.load() }
    }

    // MARK: - 页头

    private var header: some View {
        HStack(spacing: 12) {
            Text("诊断").font(.system(size: 15, weight: .bold))
            Text("跨会话的提示词质量")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 12)
            CapsuleTabTray {
                ForEach([7, 30, 90], id: \.self) { days in
                    CapsuleTabButton(
                        title: "\(days) 天", fillWidth: false,
                        isSelected: service.windowDays == days
                    ) { service.windowDays = days }
                }
            }
            .fixedSize()
            if service.loading { ProgressView().controlSize(.small) }
            RefreshButton(help: "重新扫描全部会话并重算逐轮指标") { service.rescan() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 总览

    private var statsCard: some View {
        let aggregate = service.aggregate
        return StatOverviewCard(
            value: "\(aggregate.turnCount)", unit: "轮",
            subtitle: aggregate.averageExploreRatio > 0
                ? String(format: "平均定位开销 %.0f%%", aggregate.averageExploreRatio * 100)
                : nil,
            distributionTitle: "轮次质量",
            segments: [
                .init(label: "干净", count: aggregate.cleanTurns, color: Theme.enabledGreen),
                .init(label: "有提示", count: aggregate.noticeTurns, color: Theme.gold),
                .init(label: "有问题", count: aggregate.badTurns, color: Theme.failureRed),
            ],
            trailingNote: "全库 \(service.totalRows) 轮")
    }

    private var sourceBar: some View {
        let counts = service.aggregate.bySource
        return SourceFilterBar(
            selected: Binding(
                get: { service.sourceFilter },
                set: { service.sourceFilter = $0 }),
            allLabel: "全部", allIcon: "waveform.path.ecg",
            totalCount: counts.values.reduce(0, +),
            sources: counts.filter { $0.value > 0 }
                .sorted { ($0.value, $0.key) > ($1.value, $1.key) }
                .compactMap { AgentSource(rawValue: $0.key) },
            count: { counts[$0.rawValue] ?? 0 })
    }

    // MARK: - 最常犯的毛病（这一块才是页面的主角）

    private var habitsCard: some View {
        let hits = service.aggregate.ruleHits.sorted { $0.value > $1.value }
        let maxHits = hits.first?.value ?? 1
        return SectionCard("最常犯的毛病") {
            if hits.isEmpty {
                Text("这段时间没有命中任何规则 —— 提示词写得挺好")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(hits, id: \.key) { rule, count in
                let info = Self.ruleTitles[rule] ?? (rule, "")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(info.title)
                            .font(.system(size: 11.5, weight: .semibold))
                            .frame(width: 96, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.hairline)
                                Capsule()
                                    .fill(Theme.brand.opacity(0.7))
                                    .frame(
                                        width: proxy.size.width
                                            * CGFloat(count) / CGFloat(max(1, maxHits)))
                            }
                        }
                        .frame(height: 6)
                        Text("\(count) 轮")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    // 建议永远跟着数字走：光看「回读 37 轮」不知道该改什么
                    Text(info.advice)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 96 + 8)
                }
            }
        }
    }

    // MARK: - 趋势

    private var trendCard: some View {
        SectionCard("每天的轮次与问题轮") {
            if service.series.isEmpty {
                Text("这段时间没有数据").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(service.series, id: \.day) { point in
                        BarMark(
                            x: .value("日期", point.day, unit: .day),
                            y: .value("轮数", point.total - point.bad))
                            .foregroundStyle(Theme.enabledGreen.opacity(0.55))
                        BarMark(
                            x: .value("日期", point.day, unit: .day),
                            y: .value("有问题", point.bad))
                            .foregroundStyle(Theme.failureRed.opacity(0.75))
                    }
                }
                .frame(height: 120)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            }
        }
    }

    // MARK: - 最差的轮（可跳过去看图）

    private var worstCard: some View {
        SectionCard("最该回头看的轮次") {
            if service.worst.isEmpty {
                Text("没有命中问题的轮次").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(Array(service.worst.enumerated()), id: \.offset) { _, row in
                worstRow(row)
            }
        }
    }

    private func worstRow(_ row: TurnMetricRow) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(row.severity == 2 ? Theme.failureRed : Theme.gold)
                .frame(width: 7, height: 7)
            if let source = AgentSource(rawValue: row.source) {
                SourceBadge(source: source, size: 12)
            }
            Text("第 \(row.turnIndex + 1) 轮")
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
            Text(row.rules.compactMap { Self.ruleTitles[$0]?.title }.joined(separator: " · "))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(row.ts, format: .dateTime.month().day())
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
            Button("看血缘图") {
                // 复用既有的 reveal 链路：切到会话页 → 选中会话 → 打开那一轮的图
                sessionBrowser.revealTurn(sessionId: row.sessionId, turnIndex: row.turnIndex)
                NotificationCenter.default.post(
                    name: .eurekaRevealSession, object: row.sessionId)
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 空态与提示

    private var emptyState: some View {
        EmptyStateView(
            icon: "waveform.path.ecg",
            title: service.loading ? "正在扫描会话…" : "还没有可分析的轮次",
            hint: "逐轮指标随用量扫描每分钟增量更新；首次全量约几秒，也可以点右上角立即重扫",
            actionTitle: service.loading ? nil : "立即扫描",
            action: service.loading ? nil : { service.rescan() })
            .padding(.top, 50)
    }

    private func noticeCard(_ text: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 12)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(tint.opacity(0.10)))
    }
}
