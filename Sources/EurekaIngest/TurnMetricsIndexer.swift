import EurekaKit
import EurekaStore
import Foundation

/// 逐轮诊断指标的增量索引：会话 transcript → 切轮 → 构图 → 评估 → 落 `turn_metrics`。
///
/// **为什么必须落库**：跨会话诊断要扫本机 ~2GB / 2000 个文件。虽然纯 JSON 解析只要几秒，
/// 但不该在每次开页/每次启动都重付一遍 IO；而且趋势需要历史（会话文件会被轮转、删除）。
/// 指标本身很小（~500 会话 × 20–200 轮 ≈ 50k 行）。
///
/// **水位用 size+mtime 指纹而不是 offset**：轮次指标是**整轮聚合**，逐行增量拿不到轮边界。
/// 文件一变就整文件重切轮 + 整体替换，单事务原子。样板照 `TranscriptSearchIndexer`。
public struct TurnMetricsIndexer {
    private let store: EurekaStore

    public init(store: EurekaStore) { self.store = store }

    /// 按默认磁盘根路径发现全部会话并索引一轮（生产入口）。
    /// **发现走 `AgentSessionDiscovery` 共享**：发现本身约 60s，是主要成本，
    /// 全文索引与本索引器共用一次结果，不各扫一遍。
    @discardableResult
    public func indexOnce() throws -> Int {
        try indexOnce(sessions: AgentSessionDiscovery.forIndexing())
    }

    /// 注入会话列表的索引一轮（测试入口；生产走 `indexOnce()`）。返回本轮重建的文件数。
    @discardableResult
    public func indexOnce(sessions: [AgentSessionInfo]) throws -> Int {
        // 共享库的源（opencode/hermes/cursor）以 transcriptPath 为主键会互相整片覆盖；
        // antigravity 是 protobuf 解不出内容。口径与 TranscriptSearchIndexer 一致。
        let supported = sessions.filter {
            !$0.source.usesSharedSessionDatabase && $0.source != .antigravity
        }
        let known = try store.turnMetrics.fingerprints()
        var rebuilt = 0

        for session in supported {
            let path = session.transcriptPath
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
            else { continue }
            // 指纹一致就跳过。实测 267 个候选里 263 个可跳，只有正在写的会话需要重建。
            if let fingerprint = known[path],
                fingerprint.size == size, abs(fingerprint.mtime - mtime) < 0.001 {
                continue
            }
            let rows = Self.rows(for: session)
            try store.turnMetrics.replace(path: path, size: size, mtime: mtime, rows: rows)
            rebuilt += 1
        }
        // **空集绝不 prune**：发现一旦返回空（IO 抖动、权限、根目录暂时读不到），
        // `prune(keeping: [])` 会把整个索引删干净，用户看到的就是「诊断页突然没数据了」，
        // 而且要再付一次 130s 全量重扫。宁可留着可能过时的行，也不能凭一次空结果清库。
        if !supported.isEmpty {
            try store.turnMetrics.prune(keeping: Set(supported.map(\.transcriptPath)))
        }
        return rebuilt
    }

    /// 一个会话 → 逐轮指标行。纯函数（除了读文件），便于单测。
    public static func rows(for session: AgentSessionInfo) -> [TurnMetricRow] {
        let messages = TranscriptReader.load(session: session).messages
        return TurnSlicer.slice(messages).map { turn in
            let graph = TurnGraphBuilder.build(turn)
            let diagnostics = TurnDiagnostics.evaluate(
                graph, promptChars: turn.promptText.count)
            return TurnMetricRow(
                source: session.source.rawValue,
                sessionId: session.id,
                turnIndex: turn.turnIndex,
                promptMessageId: turn.promptMessageId,
                // 无时间戳的源退回会话开始时间，别拿 1970 冒充
                ts: turn.startedAt ?? session.startedAt ?? Date(),
                durationMs: turn.duration.map { Int($0 * 1000) },
                promptChars: diagnostics.promptChars,
                stepCount: diagnostics.stepCount,
                nodeCount: diagnostics.nodeCount,
                exploreNodes: diagnostics.exploreNodes,
                rereadCount: diagnostics.rereadCount,
                reworkCount: diagnostics.reworkCount,
                retryMax: diagnostics.retryMax,
                editChurn: diagnostics.maxEditChurn,
                errorSteps: diagnostics.errorSteps,
                subagentCount: diagnostics.subagentCount,
                askedUser: diagnostics.askedUser,
                severity: diagnostics.severity.rawValue,
                rules: diagnostics.signals.map(\.rule))
        }
    }
}
