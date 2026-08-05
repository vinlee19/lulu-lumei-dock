import EurekaIngest
import EurekaKit
import SwiftUI

/// 「轮次血缘」下钻页：轮次诊断列表 + 单轮血缘图。
///
/// **挂在 `SessionsView` 层替换整个内容区，而不是嵌在右栏。**
/// 右栏是 `HSplitView` 的一半（`minWidth 380`），最坏只有 ~423pt 宽，图根本铺不开；
/// 替换整页才拿得到 674 / 780 / 1270 三档宽度。骨架照 `PlansView` 的下钻样板。
struct TurnLineageView: View {
    /// 会话名（页头显示）
    let sessionName: String
    let turns: [TurnInput]
    let onBack: () -> Void
    /// 跳回会话页的某条消息
    var onJumpToMessage: ((Int) -> Void)?

    enum Pane: String, CaseIterable { case list = "轮次诊断", graph = "血缘图" }
    enum Density: String, CaseIterable { case comfortable = "舒适", compact = "紧凑" }

    @State private var pane: Pane
    @State private var current: Int
    @State private var density: Density = .comfortable
    @State private var expandedFolds: Set<TurnGraph.NodeID> = []
    /// 展开的子代理（键 = 类型|描述，跨轮切换保持稳定）
    @State private var expandedSubagents: Set<String> = []

    /// 离屏渲染/预览专用：指定初始页与初始轮（照 `AuditView(initialRiskOnly:)` 的注入约定）
    init(
        sessionName: String, turns: [TurnInput], onBack: @escaping () -> Void,
        onJumpToMessage: ((Int) -> Void)? = nil,
        initialPane: Pane = .list, initialTurn: Int = 0
    ) {
        self.sessionName = sessionName
        self.turns = turns
        self.onBack = onBack
        self.onJumpToMessage = onJumpToMessage
        self._pane = State(initialValue: initialPane)
        self._current = State(initialValue: initialTurn)
    }

    /// 逐轮诊断只算一次（切换轮次/密度都不必重算）
    private var diagnostics: [TurnDiagnostics] {
        turns.map { turn in
            TurnDiagnostics.evaluate(
                TurnGraphBuilder.build(turn), promptChars: turn.promptText.count)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if turns.isEmpty {
                EmptyStateView(
                    icon: "point.3.filled.connected.trianglepath.dotted",
                    title: "这个会话还没有可分析的轮次",
                    hint: "一轮 = 一次真实提问到它的回答之间的全部操作")
                    .padding(.top, 60)
                Spacer()
            } else {
                switch pane {
                case .list: turnList
                case .graph: graphPane
                }
            }
        }
        .background(Theme.surfaceSecondary)
    }

    // MARK: - 页头

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            Text("轮次血缘").font(.system(size: 15, weight: .bold))
            Text(sessionName)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 12)
            if pane == .graph, turns.count > 1 {
                turnStepper
            }
            if pane == .graph {
                CapsuleTabTray {
                    ForEach(Density.allCases, id: \.self) { item in
                        CapsuleTabButton(
                            title: item.rawValue, fillWidth: false, isSelected: density == item
                        ) { density = item }
                    }
                }
                .fixedSize()
            }
            CapsuleTabTray {
                ForEach(Pane.allCases, id: \.self) { item in
                    CapsuleTabButton(
                        title: item.rawValue, fillWidth: false, isSelected: pane == item
                    ) { pane = item }
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var turnStepper: some View {
        HStack(spacing: 4) {
            Button { current = max(0, current - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(current <= 0)
            Text("\(current + 1) / \(turns.count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { current = min(turns.count - 1, current + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(current >= turns.count - 1)
        }
        .fixedSize()
    }

    // MARK: - 血缘图

    private var graphPane: some View {
        // 宽度由视口给：引擎按它反推每层列数，层宽因此有上界，横向永不裁剪
        GeometryReader { proxy in
            ScrollView(.vertical) {
                board(width: proxy.size.width)
            }
        }
    }

    @ViewBuilder
    private func board(width: CGFloat) -> some View {
        let index = min(max(0, current), turns.count - 1)
        let turn = turns[index]
        let metrics = density == .compact
            ? TurnGraphLayout.Metrics.compact(width: max(320, width - 32))
            : TurnGraphLayout.Metrics.standard(width: max(320, width - 32))
        let graph = TurnGraphBuilder.build(
            turn,
            options: .init(
                maxColumns: metrics.maxColumns, expandedFolds: expandedFolds,
                expandedSubagents: expandedSubagents))
        let result = TurnGraphLayout.layout(graph, metrics: metrics)
        TurnLineageBoardView(
            result: result,
            diagnostics: TurnDiagnostics.evaluate(graph, promptChars: turn.promptText.count),
            hasThinking: graph.hasThinking,
            onJumpToMessage: onJumpToMessage,
            onToggleSubagent: { node in
                let key = "\(node.title)|\(node.subtitle)"
                // 副标在收起态带了「N 步」后缀，用前缀匹配找回原键
                let existing = expandedSubagents.first { key.hasPrefix($0) }
                if let existing {
                    expandedSubagents.remove(existing)
                } else {
                    expandedSubagents.insert(key)
                }
            },
            onToggleFold: { id in
                // 折叠/展开一律**不做动画**：LazyVStack 内结构性动画会残留幽灵空白
                if expandedFolds.contains(id) {
                    expandedFolds.remove(id)
                } else {
                    expandedFolds.insert(id)
                }
            })
    }

    // MARK: - 轮次诊断列表

    private var turnList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                KnowledgeListContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(diagnostics.enumerated()), id: \.offset) { index, item in
                            turnRow(index: index, item: item)
                            if index < diagnostics.count - 1 {
                                Divider().opacity(0.4).padding(.leading, 44)
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
    }

    private var summaryCard: some View {
        let summary = TurnDiagnosticsSummary(diagnostics)
        return StatOverviewCard(
            value: "\(summary.turnCount)", unit: "轮",
            subtitle: summary.averageExploreRatio > 0
                ? String(format: "平均定位开销 %.0f%%", summary.averageExploreRatio * 100)
                : nil,
            distributionTitle: "轮次质量",
            segments: [
                .init(label: "干净", count: summary.cleanTurns, color: Theme.enabledGreen),
                .init(label: "有提示", count: summary.noticeTurns, color: Theme.gold),
                .init(label: "有问题", count: summary.badTurns, color: Theme.failureRed),
            ],
            trailingNote: summary.totalReread + summary.totalRetry > 0
                ? "回读 \(summary.totalReread) · 重试 \(summary.totalRetry)" : nil)
    }

    private func turnRow(index: Int, item: TurnDiagnostics) -> some View {
        let turn = turns[index]
        return KnowledgeRow(onOpen: {
            current = index
            pane = .graph
        }) {
            HStack(spacing: 10) {
                Circle()
                    .fill(severityColor(item.severity))
                    .frame(width: 8, height: 8)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("第 \(index + 1) 轮")
                            .font(.system(size: 11.5, weight: .semibold))
                            .fixedSize()
                        Text(turn.promptText.isEmpty ? "（无提问，会话恢复）" : turn.promptText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    if item.signals.isEmpty {
                        Text("没有发现问题")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(item.signals.map(\.title).joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(severityColor(item.severity))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    metric("\(item.stepCount)", "步")
                    if item.rereadCount > 0 { metric("\(item.rereadCount)", "回读") }
                    if item.retryMax > 0 { metric("\(item.retryMax)", "重试") }
                    if item.subagentCount > 0 { metric("\(item.subagentCount)", "子代理") }
                }
                .fixedSize()
            }
        } menu: {
            Button("看血缘图") { current = index; pane = .graph }
            if let messageId = turn.promptMessageId, let onJumpToMessage {
                Button("跳到这一轮的提问") { onJumpToMessage(messageId) }
            }
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 8.5)).foregroundStyle(.tertiary)
        }
        .frame(minWidth: 26)
    }

    private func severityColor(_ severity: TurnDiagnostics.Severity) -> Color {
        switch severity {
        case .clean: return Theme.enabledGreen
        case .notice: return Theme.goldFg
        case .bad: return Theme.failureRed
        }
    }
}
