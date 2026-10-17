import Foundation

/// Per-turn diagnostic metrics: translate the shape of the lineage graph into "where the
/// prompt/context fell short".
///
/// Every metric must point back to an **actionable improvement**; otherwise it is decoration.
/// Pure function (EurekaKit) whose input is the already-built graph — the diagnostics are defined in terms of graph structure
/// (read-back edges, retry loops), so recomputing them from the raw step sequence would mean writing the rules twice.
public struct TurnDiagnostics: Equatable, Sendable {
    /// Severity: only three levels, so it doesn't turn into a scorecard nobody reads
    public enum Severity: Int, Comparable, Sendable {
        case clean = 0
        case notice = 1
        case bad = 2
        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One triggered signal (produced only when triggered; takes no slot otherwise)
    public struct Signal: Equatable, Sendable, Identifiable {
        public var id: String { rule }
        /// Rule id (stable; used for persistence/aggregation)
        public var rule: String
        public var title: String
        /// The prompt problem it points back to — this sentence is what the user actually reads
        public var advice: String
        public var severity: Severity
        /// The triggered amount (read back 3 times / retried 2 rounds)
        public var count: Int
    }

    public var turnIndex: Int
    public var promptChars: Int
    public var stepCount: Int
    public var nodeCount: Int
    /// Search + read node count (numerator of the exploration cost)
    public var exploreNodes: Int
    /// Read-back **count** (not edge count). Identical read-back edges are deduped into one with an
    /// accumulated `repeatCount`, and the user cares about "how many times it went back", so this
    /// sums counts rather than counting edges.
    public var rereadCount: Int
    public var reworkCount: Int
    /// How many laps the longest retry loop went around
    public var retryMax: Int
    public var errorSteps: Int
    public var subagentCount: Int
    public var askedUser: Bool
    /// How many times the same file was edited in this turn (the most-edited one). A strong signal
    /// verified on real data: a real session showed `Edit X.java ×8` — editing the same file 8
    /// times within one turn usually means acting before thinking it through. Such repetition
    /// creates no back-edge, so edges alone miss it.
    public var maxEditChurn: Int
    /// The repeatedly edited file (for display)
    public var churnTarget: String
    public var signals: [Signal]

    /// Exploration cost ratio: how much of the turn went into locating code. **Noticeably high when
    /// the prompt names no files.**
    public var exploreRatio: Double {
        nodeCount > 0 ? Double(exploreNodes) / Double(nodeCount) : 0
    }

    /// Turn severity = the most severe signal
    public var severity: Severity {
        signals.map(\.severity).max() ?? .clean
    }

    // MARK: - Thresholds (kept here, not scattered across the checks)

    public enum Threshold {
        /// Exploration share above half ⇒ most of the turn was spent searching
        public static let exploreRatioBad = 0.5
        public static let exploreRatioNotice = 0.35
        /// Exploration share is only meaningful with enough steps (2 searches in a 3-step turn
        /// proves nothing)
        public static let exploreMinNodes = 6
        public static let rereadNotice = 1
        public static let rereadBad = 3
        public static let reworkNotice = 1
        public static let retryNotice = 1
        public static let retryBad = 3
        /// Same file edited 3 times = notice, 5 times = problem
        public static let churnNotice = 3
        public static let churnBad = 5
    }

    // MARK: - Evaluation

    public static func evaluate(_ graph: TurnGraph.Graph, promptChars: Int) -> TurnDiagnostics {
        let toolNodes = graph.nodes.filter { $0.kind.toolKind != nil || $0.kind == .subagent }
        let exploreNodes = graph.nodes.filter { node in
            guard let kind = node.kind.toolKind else { return false }
            return kind == .read || kind == .search
        }.count
        // Sum repeatCount instead of counting edges: identical read-back/retry edges are deduped
        // into one, with the count in repeatCount
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
                    rule: "explore-heavy", title: L10n.text("Most of the turn spent finding files", zhHans: "大半轮在找文件"),
                    advice: L10n.text("Name the files or directories in your prompt, or paste the key snippets to save this lookup time", zhHans: "提示词里直接点名文件/目录，或先贴关键片段，能省掉这段定位"),
                    severity: .bad, count: exploreNodes))
            } else if exploreRatio >= Threshold.exploreRatioNotice {
                signals.append(Signal(
                    rule: "explore-heavy", title: L10n.text("High lookup overhead", zhHans: "定位开销偏高"),
                    advice: L10n.text("If you know which file to change, name it in the prompt to save time", zhHans: "如果你已经知道改哪个文件，写进提示词会更快"),
                    severity: .notice, count: exploreNodes))
            }
        }

        if rereadCount >= Threshold.rereadBad {
            signals.append(Signal(
                rule: "reread", title: L10n.text("Repeatedly rereading the same place", zhHans: "反复回读同一处"),
                advice: L10n.text("Provide the relevant files and constraints up front so the agent doesn't have to keep looking back", zhHans: "上下文没一次给够：把相关文件/约束一次性给全，别让它来回翻"),
                severity: .bad, count: rereadCount))
        } else if rereadCount >= Threshold.rereadNotice {
            signals.append(Signal(
                rule: "reread", title: L10n.text("Rereading detected", zhHans: "有回读"),
                advice: L10n.text("The same place was read more than once; consider including it in the context from the start", zhHans: "同一处被读了不止一次，考虑一开始就把它放进上下文"),
                severity: .notice, count: rereadCount))
        }

        if reworkCount >= Threshold.reworkNotice {
            signals.append(Signal(
                rule: "rework", title: L10n.text("Looking back after editing", zhHans: "改完又回头看"),
                advice: L10n.text("Ask the agent to read before editing, or specify the exact location to change in your prompt", zhHans: "改之前没看清：让它先读后改，或在提示词里给出确切的改动位置"),
                severity: .notice, count: reworkCount))
        }

        if retryMax >= Threshold.retryBad {
            signals.append(Signal(
                rule: "retry", title: L10n.text("Repeated retries", zhHans: "反复重试"),
                advice: L10n.text("Make acceptance criteria clear: include the commands and expected output that define success in your prompt", zhHans: "验收标准不清：把「怎样算成功」（命令、期望输出）写进提示词"),
                severity: .bad, count: retryMax))
        } else if retryMax >= Threshold.retryNotice {
            signals.append(Signal(
                rule: "retry", title: L10n.text("Retry after failure", zhHans: "有失败重试"),
                advice: L10n.text("Provide an explicit verification command to help the agent get it right the first time", zhHans: "给出明确的验证命令，能让它一次做对"),
                severity: .notice, count: retryMax))
        }

        if maxEditChurn >= Threshold.churnBad {
            signals.append(Signal(
                rule: "churn", title: L10n.text("Repeated edits to the same file", zhHans: "同一文件反复改"),
                advice: L10n.format("%@ was edited %@ times: the agent likely started before thinking it through; next time, ask for a change plan before editing",
                    zhHans: "%@ 被改了 %@ 次：多半是没想清就动手，下次先让它给出改动方案再落笔",
                    churnTarget, String(maxEditChurn)),
                severity: .bad, count: maxEditChurn))
        } else if maxEditChurn >= Threshold.churnNotice {
            signals.append(Signal(
                rule: "churn", title: L10n.text("Several rounds of edits", zhHans: "改了好几遍"),
                advice: L10n.format("%@ was edited %@ times; consider asking for a change list first",
                    zhHans: "%@ 被改了 %@ 次，可以先要一份改动清单", churnTarget, String(maxEditChurn)),
                severity: .notice, count: maxEditChurn))
        }

        if askedUser {
            signals.append(Signal(
                rule: "clarify", title: L10n.text("Asked you for clarification", zhHans: "反问了你"),
                advice: L10n.text("Clarify the choices and constraints up front to avoid an extra round trip", zhHans: "提问有歧义：把选择项与约束提前写清，可省掉一次往返"),
                severity: .notice, count: 1))
        }

        return signals
    }
}

// MARK: - Cross-session aggregation

/// Many turns → one summary (for the cross-session diagnostics page). Also a pure function.
public struct TurnDiagnosticsSummary: Equatable, Sendable {
    public var turnCount: Int
    public var cleanTurns: Int
    public var noticeTurns: Int
    public var badTurns: Int
    public var totalReread: Int
    public var totalRework: Int
    public var totalRetry: Int
    /// Number of turns where "same file edited repeatedly" occurred
    public var churnTurns: Int
    /// Rule id → number of turns triggered (which problems occur most)
    public var ruleHits: [String: Int]
    /// Average exploration cost ratio (only over turns with enough steps, otherwise diluted by many
    /// small turns)
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
