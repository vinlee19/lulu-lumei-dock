import Foundation

// eureka-relay：被 Claude Code hooks / Codex notify 调用的转发器。
//
// 子命令：
//   eureka-relay claude-hook            # 读 stdin 的 hook JSON
//   eureka-relay codex-notify '<json>'  # 读 argv 的 notify JSON
//   eureka-relay inject --event <名> --session <id> [--source claude|codex]
//                       [--cwd <路径>] [--title <文本>]   # 测试注入
//
// 硬约束：永远 exit 0；stdout/stderr 绝对静默（UserPromptSubmit 的 stdout 会注入
// 模型上下文）；全程 <50ms；stdin 限读 1MB。错误只写 relay-error.log。

let maxStdinBytes = 1_048_576

func spoolRoot() -> URL {
    let env = ProcessInfo.processInfo.environment
    if let custom = env["EUREKA_SPOOL_DIR"], !custom.isEmpty {
        return URL(fileURLWithPath: custom, isDirectory: true)
    }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("Eureka", isDirectory: true)
}

func logError(_ message: String) {
    let url = spoolRoot().appendingPathComponent("relay-error.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// 把事件原子写入 spool：先写 tmp/ 再 rename 进 events/，监听方永远看到完整文件
func writeEvent(channel: String, payloadJSON: Data) {
    let root = spoolRoot()
    let eventsDir = root.appendingPathComponent("events", isDirectory: true)
    let tmpDir = root.appendingPathComponent("tmp", isDirectory: true)
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // payload 必须是合法 JSON，否则包成 {"_raw": "..."}
        let payload: Data
        if (try? JSONSerialization.jsonObject(with: payloadJSON)) != nil {
            payload = payloadJSON
        } else {
            let wrapped = ["_raw": String(data: payloadJSON, encoding: .utf8) ?? "<binary>"]
            payload = try JSONSerialization.data(withJSONObject: wrapped)
        }

        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        var body = Data("{\"v\":1,\"channel\":\"\(channel)\",\"receivedAtMs\":\(nowMs),\"payload\":".utf8)
        body.append(payload)
        body.append(Data("}".utf8))

        let name = "\(nowMs)-\(getpid())-\(UUID().uuidString.prefix(8)).json"
        let tmpURL = tmpDir.appendingPathComponent(name)
        try body.write(to: tmpURL)
        try fm.moveItem(at: tmpURL, to: eventsDir.appendingPathComponent(name))
    } catch {
        logError("writeEvent(\(channel)): \(error)")
    }
}

func readStdin(limit: Int) -> Data {
    var data = Data()
    let input = FileHandle.standardInput
    while data.count < limit {
        guard let chunk = try? input.read(upToCount: min(65536, limit - data.count)),
              !chunk.isEmpty else { break }
        data.append(chunk)
    }
    return data
}

/// inject 子命令：把演示/测试事件合成为与真实 hook/notify 完全相同的 payload
func runInject(_ args: [String]) {
    var options: [String: String] = [:]
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg.hasPrefix("--"), index + 1 < args.count {
            options[String(arg.dropFirst(2))] = args[index + 1]
            index += 2
        } else {
            index += 1
        }
    }
    guard let event = options["event"] else {
        logError("inject: 缺少 --event")
        return
    }
    let session = options["session"] ?? "inject-\(getpid())"
    let cwd = options["cwd"] ?? FileManager.default.currentDirectoryPath
    let title = options["title"]

    func emitClaude(_ extra: [String: Any]) {
        var payload: [String: Any] = ["session_id": session, "cwd": cwd]
        payload.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            writeEvent(channel: "claude-hook", payloadJSON: data)
        }
    }

    switch event {
    case "user-prompt-submit":
        emitClaude(["hook_event_name": "UserPromptSubmit", "prompt": title ?? "演示任务"])
    case "stop":
        emitClaude(["hook_event_name": "Stop", "stop_hook_active": false])
    case "notification-permission":
        emitClaude([
            "hook_event_name": "Notification",
            "message": title ?? "Claude needs your permission to use Bash",
            "notification_type": "permission_prompt",
        ])
    case "notification-idle":
        emitClaude([
            "hook_event_name": "Notification",
            "message": title ?? "Claude is waiting for your input",
            "notification_type": "idle_prompt",
        ])
    case "post-tool-use":
        emitClaude(["hook_event_name": "PostToolUse", "tool_name": "Bash"])
    case "session-end":
        emitClaude(["hook_event_name": "SessionEnd", "reason": title ?? "other"])
    case "codex-complete":
        let payload: [String: Any] = [
            "type": "agent-turn-complete",
            "thread-id": session,
            "turn-id": "turn-\(Int(Date().timeIntervalSince1970))",
            "cwd": cwd,
            "input-messages": [title ?? "演示任务"],
            "last-assistant-message": "任务完成。",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            writeEvent(channel: "codex-notify", payloadJSON: data)
        }
    default:
        logError("inject: 未知事件 \(event)")
    }
}

// ---- 入口 ----

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude-hook":
    let stdin = readStdin(limit: maxStdinBytes)
    if !stdin.isEmpty {
        writeEvent(channel: "claude-hook", payloadJSON: stdin)
    }
case "codex-notify":
    // notify 程序收到的 JSON 是最后一个参数
    if let json = arguments.dropFirst().last, !json.isEmpty {
        writeEvent(channel: "codex-notify", payloadJSON: Data(json.utf8))
    }
case "inject":
    runInject(Array(arguments.dropFirst()))
default:
    logError("未知子命令: \(arguments.first ?? "<空>")")
}
exit(0)
