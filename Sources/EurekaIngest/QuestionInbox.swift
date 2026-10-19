import Darwin
import EurekaKit
import Foundation

/// 灵动岛答题的 app 一端（另一端是 `lululumei-ask` hook，见 Sources/eureka-ask/main.swift）。
///
/// 目录约定（都在 spool 根目录下）：
/// - `island-heartbeat`：app 每 5 秒写入自己的 pid。hook 看它判断岛在不在，不在就立刻退出，只留 Claude 自己的确认界面；
/// - `questions/<id>.json`：hook 等待期间存在，退出时自己删掉；
/// - `answers/<id>.json`：这里写入答案（或「收起」），hook 读到后删掉。
///
/// hook 被 SIGKILL 之类收不到的信号终止时不会删问题文件 → 这里按文件里的 pid 判活，死了就清掉。
public struct QuestionInbox {
    public let root: URL

    public init(root: URL = SpoolPaths.root()) {
        self.root = root
    }

    public var questionsDir: URL { root.appendingPathComponent("questions", isDirectory: true) }
    public var answersDir: URL { root.appendingPathComponent("answers", isDirectory: true) }
    public var heartbeatURL: URL { root.appendingPathComponent("island-heartbeat") }

    // MARK: 心跳

    public func writeHeartbeat(pid: Int32 = getpid()) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("\(pid)\n".utf8).write(to: heartbeatURL, options: .atomic)
    }

    /// 功能关闭 / app 退出时调用：hook 立刻知道岛不在
    public func removeHeartbeat() {
        try? FileManager.default.removeItem(at: heartbeatURL)
    }

    // MARK: 读取

    /// 等待中的问题（按创建时间）。hook 进程已不在的顺手清掉；读不懂的文件跳过（hook 会自己删）。
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

    /// 解析 hook 写的问题文件。id 以文件名为准（与答案文件名一致），不信文件内容里的 id。
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
        // 有一个问题读不懂就整张不接：漏答任何一个问题，hook 都不会放行，用户白点
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

    /// `<id>.json` → id；只接受字母数字、`-`、`_`（hook 生成的 UUID 只含这些），其余（路径分隔符等）一律拒绝
    static func questionId(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        let id = String(name.dropLast(".json".count))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return id
    }

    // MARK: 回答

    public enum Reply: Equatable, Sendable {
        /// 键是问题原文
        case answer([String: String])
        /// 岛上收起这道题，或它已在 Claude 自己的确认界面里答完：hook 静默退出
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
        // 先写临时文件再 rename：hook 每 100ms 读一次，绝不能读到半个文件
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
