import Foundation

/// 逐轮诊断指标：把血缘图的形状翻译成「提示词/上下文哪里没给好」。
///
/// 每条指标都必须能指回一个**可执行的改进动作**，否则就是装饰。
/// 纯函数（EurekaKit），输入是已经构好的图 —— 因为诊断的定义就依赖图的结构
/// （回读边、重试环），从原始步骤序列上重算一遍等于把规则写两份。
public struct TurnDiagnostics: Equatable, Sendable {
    /// 严重度：只有三档，避免变成没人看的评分表
    public enum Severity: Int, Comparable, Sendable {
        case clean = 0
        case notice = 1
        case bad = 2
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 一条命中的信号（只在命中时产生，不命中不占位）
    public struct Signal: Equatable, Sendable, Identifiable {
        public var id: String { rule }
        /// 规则 id（稳定，落库/聚合用）
        public var rule: String
        public var title: String
        /// 指回的提示词问题 —— 这句话才是用户要看的
        public var advice: String
        public var severity: Severity
        /// 命中的量（回读 3 次 / 重试 2 轮）
        public var count: Int
    }

    public var turnIndex: Int
    public var promptChars: Int
    public var stepCount: Int
    public var nodeCount: Int
    /// 检索 + 读取节点数（探索开销的分子）
    public var exploreNodes: Int
    /// 回读**次数**（不是边数）。同一条回读边会被去重成一条并累加 `repeatCount`，
    /// 而用户关心的是「回去了几次」，所以这里累加次数而不是数边。
    public var rereadCount: Int
    public var reworkCount: Int
    /// 最长的一条重试环绕了几圈
    public var retryMax: Int
    public var errorSteps: Int
    public var subagentCount: Int
    public var askedUser: Bool
    /// 同一个文件在这一轮里被改了多少次（最多的那个）。
    /// 实机验证过的强信号：真实会话里出现过 `Edit X.java ×8` —— 一轮之内把同一个文件
    /// 改了 8 遍，多半是没想清就动手。这类反复不产生回边，光看边会漏掉。
    public var maxEditChurn: Int
    /// 被反复改的那个文件（展示用）
    public var churnTarget: String
    public var signals: [Signal]

    /// 探索开销比：定位代码花了多少比重。**提示词没点名文件时会显著偏高。**
    public var exploreRatio: Double {
        nodeCount > 0 ? Double(exploreNodes) / Double(nodeCount) : 0
    }

    /// 整轮严重度 = 最严重的那条信号
    public var severity: Severity {
        signals.map(\.severity).max() ?? .clean
    }

    // MARK: - 阈值（集中在这里，别散落在判断里）

    public enum Threshold {
        /// 探索占比超过一半 ⇒ 大半轮在找东西
        public static let exploreRatioBad = 0.5
        public static let exploreRatioNotice = 0.35
        /// 探索占比只在步数够多时才有意义（3 步的轮子里 2 步检索不说明问题）
        public static let exploreMinNodes = 6
        public static let rereadNotice = 1
        public static let rereadBad = 3
        public static let reworkNotice = 1
        public static let retryNotice = 1
        public static let retryBad = 3
        /// 同一文件改 3 次 = 提醒，5 次 = 有问题
        public static let churnNotice = 3
        public static let churnBad = 5
    }

    // MARK: - 评估

    public static func evaluate(_ graph: TurnGraph.Graph, promptChars: Int) -> TurnDiagnostics {
        let toolNodes = graph.nodes.filter { $0.kind.toolKind != nil || $0.kind == .subagent }
        let exploreNodes = graph.nodes.filter { node in
            guard let kind = node.kind.toolKind else { return false }
            return kind == .read || kind == .search
        }.count
        // 累加 repeatCount 而不是数边：同一条回读/重试边被去重成一条，次数在 repeatCount 里
        let reread = graph.backEdges.filter { $0.role == .dataFlow }
            .reduce(0) { $0 + $1.repeatCount }
        let rework = graph.backEdges.filter { $0.role == .rework }
            .reduce(0) { $0 + $1.repeatCount }
        let retryMax = graph.backEdges.filter { $0.role == .retry }
            .map(\.repeatCount).max() ?? 0
        let errorSteps = graph.nodes.filter(\.isError).count
        let subagents = graph.nodes.filter { $0.kind == .subagent }.count
        let askedUser = graph.nodes.contains {
            $0.title == "AskUserQuestion" || $0.title == "ask_user_question"
        }
        let stepCount = graph.nodes.reduce(0) { $0 + $1.stepIndices.count }
        let churn = graph.nodes
            .filter { $0.kind == .tool(.edit) }
            .max { $0.occurrences < $1.occurrences }

        var diagnostics = TurnDiagnostics(
            turnIndex: graph.turnIndex,
            promptChars: promptChars,
            stepCount: stepCount,
            nodeCount: toolNodes.count,
            exploreNodes: exploreNodes,
            rereadCount: reread,
            reworkCount: rework,
            retryMax: retryMax,
            errorSteps: errorSteps,
            subagentCount: subagents,
            askedUser: askedUser,
            maxEditChurn: churn?.occurrences ?? 0,
            churnTarget: churn?.subtitle ?? "",
            signals: [])
        diagnostics.signals = diagnostics.deriveSignals()
        return diagnostics
    }

    private func deriveSignals() -> [Signal] {
        var signals: [Signal] = []

        if nodeCount >= Threshold.exploreMinNodes {
            if exploreRatio >= Threshold.exploreRatioBad {
                signals.append(Signal(
                    rule: "explore-heavy", title: "大半轮在找文件",
                    advice: "提示词里直接点名文件/目录，或先贴关键片段，能省掉这段定位",
                    severity: .bad, count: exploreNodes))
            } else if exploreRatio >= Threshold.exploreRatioNotice {
                signals.append(Signal(
                    rule: "explore-heavy", title: "定位开销偏高",
                    advice: "如果你已经知道改哪个文件，写进提示词会更快",
                    severity: .notice, count: exploreNodes))
            }
        }

        if rereadCount >= Threshold.rereadBad {
            signals.append(Signal(
                rule: "reread", title: "反复回读同一处",
                advice: "上下文没一次给够：把相关文件/约束一次性给全，别让它来回翻",
                severity: .bad, count: rereadCount))
        } else if rereadCount >= Threshold.rereadNotice {
            signals.append(Signal(
                rule: "reread", title: "有回读",
                advice: "同一处被读了不止一次，考虑一开始就把它放进上下文",
                severity: .notice, count: rereadCount))
        }

        if reworkCount >= Threshold.reworkNotice {
            signals.append(Signal(
                rule: "rework", title: "改完又回头看",
                advice: "改之前没看清：让它先读后改，或在提示词里给出确切的改动位置",
                severity: .notice, count: reworkCount))
        }

        if retryMax >= Threshold.retryBad {
            signals.append(Signal(
                rule: "retry", title: "反复重试",
                advice: "验收标准不清：把「怎样算成功」（命令、期望输出）写进提示词",
                severity: .bad, count: retryMax))
        } else if retryMax >= Threshold.retryNotice {
            signals.append(Signal(
                rule: "retry", title: "有失败重试",
                advice: "给出明确的验证命令，能让它一次做对",
                severity: .notice, count: retryMax))
        }

        if maxEditChurn >= Threshold.churnBad {
            signals.append(Signal(
                rule: "churn", title: "同一文件反复改",
                advice: "\(churnTarget) 被改了 \(maxEditChurn) 次：多半是没想清就动手，"
                    + "下次先让它给出改动方案再落笔",
                severity: .bad, count: maxEditChurn))
        } else if maxEditChurn >= Threshold.churnNotice {
            signals.append(Signal(
                rule: "churn", title: "改了好几遍",
                advice: "\(churnTarget) 被改了 \(maxEditChurn) 次，可以先要一份改动清单",
                severity: .notice, count: maxEditChurn))
        }

        if askedUser {
            signals.append(Signal(
                rule: "clarify", title: "反问了你",
                advice: "提问有歧义：把选择项与约束提前写清，可省掉一次往返",
                severity: .notice, count: 1))
        }

        return signals
    }
}

// MARK: - 跨会话聚合

/// 多轮 → 一份汇总（跨会话诊断页用）。同样是纯函数。
public struct TurnDiagnosticsSummary: Equatable, Sendable {
    public var turnCount: Int
    public var cleanTurns: Int
    public var noticeTurns: Int
    public var badTurns: Int
    public var totalReread: Int
    public var totalRework: Int
    public var totalRetry: Int
    /// 出现过「同一文件反复改」的轮数
    public var churnTurns: Int
    /// 规则 id → 命中轮数（哪类问题最常犯）
    public var ruleHits: [String: Int]
    /// 平均探索开销比（只统计步数够多的轮，否则被大量小轮稀释）
    public var averageExploreRatio: Double

    public init(_ items: [TurnDiagnostics]) {
        turnCount = items.count
        cleanTurns = items.filter { $0.severity == .clean }.count
        noticeTurns = items.filter { $0.severity == .notice }.count
        badTurns = items.filter { $0.severity == .bad }.count
        totalReread = items.reduce(0) { $0 + $1.rereadCount }
        totalRework = items.reduce(0) { $0 + $1.reworkCount }
        totalRetry = items.reduce(0) { $0 + $1.retryMax }
        churnTurns = items.filter {
            $0.maxEditChurn >= TurnDiagnostics.Threshold.churnNotice
        }.count
        var hits: [String: Int] = [:]
        for item in items {
            for signal in item.signals { hits[signal.rule, default: 0] += 1 }
        }
        ruleHits = hits
        let measurable = items.filter {
            $0.nodeCount >= TurnDiagnostics.Threshold.exploreMinNodes
        }
        averageExploreRatio = measurable.isEmpty
            ? 0
            : measurable.reduce(0.0) { $0 + $1.exploreRatio } / Double(measurable.count)
    }
}
