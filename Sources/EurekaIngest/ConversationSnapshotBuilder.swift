import EurekaKit
import Foundation

/// Builds the immutable summary input from the existing multi-source transcript reader.
///
/// Always reads with no message budget (`maxMessages: Int.max`), so the snapshot covers the whole
/// readable conversation rather than the UI's possibly truncated array. Message ids are the
/// reader's own ids, so citations map back onto the conversation view one to one.
public enum ConversationSnapshotBuilder {
    public enum Outcome: Equatable, Sendable {
        case snapshot(SummarySnapshot)
        case unsupported(String)
        case readFailed(String)
        case empty
    }

    public static func load(session: AgentSessionInfo) -> Outcome {
        if let reason = SummarySourceSupport.unsupportedReason(session.source) {
            return .unsupported(reason)
        }
        let path = session.transcriptPath
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .readFailed(L10n.format(
                "The session file is missing or unreadable: %@",
                zhHans: "会话文件不存在或不可读：%@", URL(fileURLWithPath: path).lastPathComponent))
        }
        let result = TranscriptReader.load(session: session, maxMessages: Int.max)
        let snapshot = build(from: result.messages)
        return snapshot.messages.isEmpty ? .empty : .snapshot(snapshot)
    }

    /// Normalization (pure, testable):
    /// - user / assistant / error keep their full text
    /// - a turn's tool trail becomes one compact `tools` line (repeated tools are folded, failed
    ///   steps are marked, nothing is invented for steps without a recorded result)
    /// - consecutive one-line tool notes (opencode / grok / cursor) fold into one `tools` line
    /// - thinking is excluded by policy and counted
    public static func build(from messages: [TranscriptMessage]) -> SummarySnapshot {
        var output: [SummarySnapshot.Message] = []
        var compacted = 0
        var thinking = 0
        var pendingNotes: [TranscriptMessage] = []

        func flushNotes() {
            guard let first = pendingNotes.first else { return }
            let names = pendingNotes.map {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            compacted += pendingNotes.count
            output.append(SummarySnapshot.Message(
                id: first.id, role: .tools,
                text: foldRepeats(names).joined(separator: " · "),
                timestamp: first.timestamp))
            pendingNotes = []
        }

        for message in messages {
            if message.role != .toolNote { flushNotes() }
            switch message.role {
            case .user, .assistant, .error:
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let role: SummarySnapshot.Role = message.role == .user
                    ? .user : (message.role == .assistant ? .assistant : .error)
                output.append(SummarySnapshot.Message(
                    id: message.id, role: role, text: text, timestamp: message.timestamp))
            case .turnTrail:
                guard !message.steps.isEmpty else { continue }
                compacted += message.steps.count
                output.append(SummarySnapshot.Message(
                    id: message.id, role: .tools, text: compactTrail(message.steps),
                    timestamp: message.timestamp))
            case .toolNote:
                pendingNotes.append(message)
            case .thinking:
                thinking += 1
            }
        }
        flushNotes()
        return SummarySnapshot(
            messages: output, compactedToolSteps: compacted, excludedThinking: thinking)
    }

    /// Details listed per tool group before folding the rest into a count
    static let detailsPerGroup = 6

    /// One line per tool group, in first-use order:
    /// `command exec_command ×3 (1 failed): swift build; swift test; …(+1)`
    static func compactTrail(_ steps: [ToolStep]) -> String {
        struct Group {
            var kind: ToolKind
            var name: String
            var count = 0
            var failed = 0
            var details: [String] = []
            /// Distinct details beyond the listing cap
            var unlisted = 0
            var subSteps = 0
        }
        var order: [String] = []
        var groups: [String: Group] = [:]
        for step in steps {
            let key = "\(step.kind.rawValue)|\(step.name)"
            if groups[key] == nil {
                order.append(key)
                groups[key] = Group(kind: step.kind, name: step.name)
            }
            groups[key]!.count += 1
            if step.isError { groups[key]!.failed += 1 }
            groups[key]!.subSteps += step.subSteps.count
            let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty, !groups[key]!.details.contains(detail) {
                if groups[key]!.details.count < detailsPerGroup {
                    groups[key]!.details.append(detail)
                } else {
                    groups[key]!.unlisted += 1
                }
            }
        }
        return order.compactMap { groups[$0] }.map { group in
            var line = "\(group.kind.rawValue) \(group.name)"
            if group.count > 1 { line += " ×\(group.count)" }
            if group.failed > 0 { line += " (\(group.failed) failed)" }
            if group.subSteps > 0 { line += " [subagent ran \(group.subSteps) steps]" }
            if !group.details.isEmpty {
                line += ": " + group.details.joined(separator: "; ")
                if group.unlisted > 0 { line += "; …(+\(group.unlisted) more)" }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Folds identical adjacent labels: ["🔧 read", "🔧 read", "🔧 bash"] → ["🔧 read ×2", "🔧 bash"]
    static func foldRepeats(_ labels: [String]) -> [String] {
        var result: [(String, Int)] = []
        for label in labels {
            if let last = result.last, last.0 == label {
                result[result.count - 1].1 += 1
            } else {
                result.append((label, 1))
            }
        }
        return result.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }
    }
}

/// App-managed working directory for summary runs. Every executor runs inside it, which is what
/// lets ingestion recognize internal runs: OpenCode has no ephemeral mode and records the run as a
/// session whose `directory` lies under this root.
public enum SummaryWorkspacePaths {
    /// `~/Library/Application Support/Eureka/summaries` (override with `EUREKA_SUMMARY_DIR`)
    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_SUMMARY_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return SpoolPaths.root(environment: [:])
            .appendingPathComponent("summaries", isDirectory: true)
    }

    /// Whether a session / event cwd belongs to an internal summary run
    public static func isInternal(
        _ cwd: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isInternal(cwd, under: root(environment: environment))
    }

    /// Same check against an already resolved root (for loops over many sessions)
    public static func isInternal(_ cwd: String?, under root: URL) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let rootPath = normalize(root.path)
        let path = normalize(cwd)
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Pure string normalization. Not `standardizedFileURL`: it drops `/private` only for paths
    /// that exist, so a run directory deleted after the run would stop matching its live root.
    static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        for alias in ["/private/tmp", "/private/var", "/private/etc"]
        where result == alias || result.hasPrefix(alias + "/") {
            result.removeFirst("/private".count)
            break
        }
        return result
    }
}
