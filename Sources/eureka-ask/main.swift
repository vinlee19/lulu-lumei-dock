import Foundation

// eureka-ask：Claude Code 的 PermissionRequest(matcher: AskUserQuestion) hook，让用户在灵动岛上回答提问。
// Built as `eureka-ask`; the app installs it at the stable path as `lululumei-ask`.
//
// PermissionRequest 的 hook 与 Claude 自己的确认界面（终端选择框 / 桌面端确认卡）同时运行，
// 谁先给出回答用谁：岛上答了，Claude 撤掉自己的界面；在 Claude 里答了，这里的输出不再被采用。
//
// 它和 relay 是**两个程序**，约束正好相反：relay 永远静默、<50ms、只报告；
// 这里要挂起等用户点选，再把答案写到 stdout —— Claude 读到
// `decision.behavior: "allow"` + 带 `answers` 的 `updatedInput` 就按这份答案执行。
// 所以它只注册在 AskUserQuestion 上，绝不能挂到别的工具（stdout 会被当成放行决定）。
//
// 与 app 的约定（`EurekaIngest.QuestionInbox` 是另一端）：
//   <root>/island-heartbeat          app 每 5 秒写入自己的 pid；超过 15 秒没更新 = 岛不在
//   <root>/questions/<id>.json       本进程等待期间存在；退出时删除
//   <root>/answers/<id>.json         app 写入 {"action":"answer","answers":{问题:答案}}
//                                    或 {"action":"dismiss"}（岛上收起这道题 / 已在 Claude 里答完）
//
// 任何不满足的情况（不是 AskUserQuestion / 岛不在 / 超时 / 收起 / 出错 / 被信号终止）
// 都**静默 exit 0、stdout 不写一个字节** —— 交给 Claude 自己的确认界面，绝不会被代答。

let maxStdinBytes = 1_048_576
/// 最多等 10 分钟；settings.json 里给这条 hook 的 timeout 是 610 秒，留出收尾余量
let answerDeadline: TimeInterval = 600
let heartbeatMaxAge: TimeInterval = 15
let pollInterval: useconds_t = 100_000

func spoolRoot() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let custom = env["EUREKA_SPOOL_DIR"], !custom.isEmpty {
        return URL(fileURLWithPath: custom, isDirectory: true)
    }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Eureka", isDirectory: true)
}

func readStdin(limit: Int) -> Data {
    var data = Data()
    while data.count < limit {
        let chunk = FileHandle.standardInput.readData(ofLength: min(65_536, limit - data.count))
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

/// 岛在不在：心跳文件够新，且里面记的 app 进程还活着
func islandIsAlive(root: URL) -> Bool {
    let url = root.appendingPathComponent("island-heartbeat")
    guard
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let modified = attributes[.modificationDate] as? Date,
        Date().timeIntervalSince(modified) <= heartbeatMaxAge,
        let text = try? String(contentsOf: url, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
}

func writeAtomically(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
    try data.write(to: tmp)
    guard rename(tmp.path, url.path) == 0 else {
        try? FileManager.default.removeItem(at: tmp)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// 被 Claude 终止（超时 / 用户在终端中断）时删掉问题文件，岛上的卡随之撤掉。
/// 信号处理里只能用 async-signal-safe 调用：路径预先转成 C 字符串，处理函数里只有 unlink + _exit。
/// app 另有兜底：问题文件里的 pid 不在了也会清掉，SIGKILL 这类收不到的信号也不会留下孤卡。
var pendingQuestionCPath: UnsafeMutablePointer<CChar>?

func installSignalCleanup(path: String) {
    pendingQuestionCPath = strdup(path)
    for signal in [SIGTERM, SIGINT, SIGHUP] {
        Foundation.signal(signal) { _ in
            if let path = pendingQuestionCPath { unlink(path) }
            _exit(0)
        }
    }
}

func run() {
    let input = readStdin(limit: maxStdinBytes)
    guard
        let object = try? JSONSerialization.jsonObject(with: input),
        let payload = object as? [String: Any],
        payload["tool_name"] as? String == "AskUserQuestion",
        let toolInput = payload["tool_input"] as? [String: Any],
        let questions = toolInput["questions"] as? [[String: Any]], !questions.isEmpty
    else { return }

    let root = spoolRoot()
    guard islandIsAlive(root: root) else { return }

    let fm = FileManager.default
    let questionsDir = root.appendingPathComponent("questions", isDirectory: true)
    let answersDir = root.appendingPathComponent("answers", isDirectory: true)
    guard
        (try? fm.createDirectory(at: questionsDir, withIntermediateDirectories: true)) != nil,
        (try? fm.createDirectory(at: answersDir, withIntermediateDirectories: true)) != nil
    else { return }

    // PermissionRequest 的输入里没有 tool_use_id，每次等待用一个新 id
    let id = UUID().uuidString
    let questionURL = questionsDir.appendingPathComponent("\(id).json")
    let answerURL = answersDir.appendingPathComponent("\(id).json")

    var record: [String: Any] = [
        "v": 1,
        "id": id,
        "pid": Int(getpid()),
        "createdAtMs": Int(Date().timeIntervalSince1970 * 1000),
        "toolInput": toolInput,
    ]
    for (key, field) in [("sessionId", "session_id"), ("cwd", "cwd"), ("transcriptPath", "transcript_path")] {
        if let value = payload[field] as? String { record[key] = value }
    }
    guard
        let recordData = try? JSONSerialization.data(withJSONObject: record),
        (try? writeAtomically(recordData, to: questionURL)) != nil
    else { return }
    installSignalCleanup(path: questionURL.path)
    defer { unlink(questionURL.path) }

    let deadline = Date().addingTimeInterval(answerDeadline)
    var lastAliveCheck = Date()
    while Date() < deadline {
        if let data = try? Data(contentsOf: answerURL) {
            try? fm.removeItem(at: answerURL)
            emitAnswer(data, toolInput: toolInput)
            return
        }
        // 等待期间 app 退出 / 卡死：岛上的卡已经没人显示，进程没必要再挂 10 分钟
        if Date().timeIntervalSince(lastAliveCheck) >= 2 {
            lastAliveCheck = Date()
            guard islandIsAlive(root: root) else { return }
        }
        usleep(pollInterval)
    }
}

/// 只有 `action == "answer"` 且每个问题都有非空答案才输出；否则静默（交给 Claude 自己的确认界面）
func emitAnswer(_ data: Data, toolInput: [String: Any]) {
    guard
        let object = try? JSONSerialization.jsonObject(with: data),
        let reply = object as? [String: Any],
        reply["action"] as? String == "answer",
        let answers = reply["answers"] as? [String: String],
        let questions = toolInput["questions"] as? [[String: Any]]
    else { return }
    let asked = questions.compactMap { $0["question"] as? String }
    guard
        asked.count == questions.count,
        asked.allSatisfy({ !(answers[$0] ?? "").isEmpty })
    else { return }

    // updatedInput 会整个替换工具输入：原样带回 questions，只补上 answers
    var updatedInput = toolInput
    updatedInput["answers"] = answers
    let output: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": [
                "behavior": "allow",
                "updatedInput": updatedInput,
            ],
        ],
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: output) else { return }
    FileHandle.standardOutput.write(json)
}

run()
exit(0)
