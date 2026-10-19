import Darwin
import EurekaKit
import Foundation

/// The app end of island answering (the other end is the `lululumei-ask` hook, see
/// Sources/eureka-ask/main.swift).
///
/// Directory conventions (all under the spool root):
/// - `island-heartbeat`: the app writes its own pid every 5 seconds. The hook reads it to tell
///   whether the island is there; if not, it exits at once, leaving only Claude's own confirmation
///   UI;
/// - `questions/<id>.json`: exists while the hook waits; the hook deletes it on exit;
/// - `answers/<id>.json`: the answer (or "dismiss") is written here; the hook deletes it after
///   reading.
///
/// When the hook is killed by an uncatchable signal like SIGKILL it can't delete the question file
/// → liveness is checked here via the pid in the file, and dead ones are cleaned up.
public struct QuestionInbox {
    public let root: URL

    public init(root: URL = SpoolPaths.root()) {
        self.root = root
    }

    public var questionsDir: URL { root.appendingPathComponent("questions", isDirectory: true) }
    public var answersDir: URL { root.appendingPathComponent("answers", isDirectory: true) }
    public var heartbeatURL: URL { root.appendingPathComponent("island-heartbeat") }

    // MARK: Heartbeat

    public func writeHeartbeat(pid: Int32 = getpid()) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: heartbeatURL, options: .atomic)
    }

    /// Called when the feature is turned off / the app quits: the hook learns immediately that the
    /// island is gone
    public func removeHeartbeat() {
        try? FileManager.default.removeItem(at: heartbeatURL)
    }

    // MARK: Reading

    /// Pending questions (by creation time). Ones whose hook process is gone are cleaned up along
    /// the way; unreadable files are skipped (the hook deletes them itself).
    public func pending(isProcessAlive: (Int32) -> Bool = QuestionInbox.processIsAlive) -> [PendingQuestion] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: questionsDir.path) else { return [] }
        var result: [PendingQuestion] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = questionsDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let question = Self.decode(data, fileName: name)
            else { continue }
            guard isProcessAlive(question.hookPid) else {
                try? fm.removeItem(at: url)
                continue
            }
            result.append(question)
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    /// Parses a question file written by the hook. The id comes from the file name (matching the
    /// answer file name); the id inside the file content is not trusted.
    public static func decode(_ data: Data, fileName: String) -> PendingQuestion? {
        guard
            let id = questionId(fromFileName: fileName),
            let object = try? JSONSerialization.jsonObject(with: data),
            let record = object as? [String: Any],
            let pid = record["pid"] as? Int, pid > 0, pid <= Int(Int32.max),
            let toolInput = record["toolInput"] as? [String: Any],
            let rawQuestions = toolInput["questions"] as? [[String: Any]]
        else { return nil }
        let questions = rawQuestions.compactMap(decodeQuestion)
        // If any question is unreadable, reject the whole card: with any question unanswered the
        // hook never lets it through, and the user's clicks are wasted
        guard !questions.isEmpty, questions.count == rawQuestions.count else { return nil }
        let createdMs = record["createdAtMs"] as? Double ?? 0
        return PendingQuestion(
            id: id,
            source: .claude,
            sessionId: record["sessionId"] as? String,
            cwd: record["cwd"] as? String,
            transcriptPath: record["transcriptPath"] as? String,
            hookPid: Int32(pid),
            createdAt: Date(timeIntervalSince1970: createdMs / 1000),
            questions: questions)
    }

    private static func decodeQuestion(_ raw: [String: Any]) -> AskQuestion? {
        guard
            let text = raw["question"] as? String, !text.isEmpty,
            let rawOptions = raw["options"] as? [[String: Any]]
        else { return nil }
        let options = rawOptions.compactMap { option -> AskOption? in
            guard let label = option["label"] as? String, !label.isEmpty else { return nil }
            return AskOption(label: label, description: option["description"] as? String ?? "")
        }
        guard !options.isEmpty else { return nil }
        return AskQuestion(
            question: text,
            header: raw["header"] as? String ?? "",
            options: options,
            multiSelect: raw["multiSelect"] as? Bool ?? false)
    }

    /// `<id>.json` → id; only letters, digits, `-` and `_` are accepted (the UUIDs the hook
    /// generates contain only these); anything else (path separators etc.) is rejected
    static func questionId(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let id = String(name.dropLast(".json".count))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return id
    }

    // MARK: Answering

    public enum Reply: Equatable, Sendable {
        /// Keys are the question text
        case answer([String: String])
        /// The question was dismissed on the island, or already answered in Claude's own
        /// confirmation UI: the hook exits silently
        case dismiss
    }

    public func send(_ reply: Reply, to questionId: String) throws {
        guard Self.questionId(fromFileName: questionId + ".json") != nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let body: [String: Any]
        switch reply {
        case .answer(let answers): body = ["action": "answer", "answers": answers]
        case .dismiss: body = ["action": "dismiss"]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        let fm = FileManager.default
        try fm.createDirectory(at: answersDir, withIntermediateDirectories: true)
        // Write a temp file then rename: the hook reads every 100ms and must never see half a file
        let target = answersDir.appendingPathComponent("\(questionId).json")
        let tmp = answersDir.appendingPathComponent(".\(questionId).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        guard rename(tmp.path, target.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
