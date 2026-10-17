import Foundation

// eureka-relay: the forwarder invoked by Claude Code hooks / Codex notify.
// Built as `eureka-relay`; the app installs it at the stable path as `lululumei-relay`
// (the old name is kept there as a symlink so pre-0.36 configs keep working).
//
// Subcommands:
//   eureka-relay claude-hook            # reads the hook JSON from stdin
//   eureka-relay trae-hook              # same as above (Trae CN's hooks are Claude-compatible)
//   eureka-relay codex-notify '<json>'  # reads the notify JSON from argv
//   eureka-relay codex-notify --chain <original notify argv...> '<json>'
//                                       # same as above, but first forwards the JSON verbatim
//                                       # to the chained original notify program
//   eureka-relay inject --event <name> --session <id> [--source claude|codex|trae]
//                       [--cwd <path>] [--title <text>]   # test injection
//
// Hard constraints: always exit 0; stdout/stderr absolutely silent (UserPromptSubmit stdout is
// injected into the model's context); <50ms end to end; stdin capped at 1MB. Errors go only
// to relay-error.log.
//
// The silence rule applies **equally to Claude / Codex / Trae**: all three read PreToolUse /
// PermissionRequest stdout as an allow/block decision (Trae's hook output contract explicitly
// honours `hookSpecificOutput` and `permissionDecision`), so any single byte could allow or
// block a tool call. We only report; we never take part in the decision.

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

/// Concrete device path of this process's **controlling terminal** (e.g. `/dev/ttys004`);
/// nil when there is none.
///
/// Uses `sysctl(KERN_PROC_PID)` to read `kinfo_proc.kp_eproc.e_tdev`, then `devname` to name it,
/// **not** `ttyname(open("/dev/tty"))` -- in practice the latter only returns the generic alias
/// `"/dev/tty"`, which says nothing about which terminal it is (the st_rdev from `fstat` is the
/// generic clone device too, equally useless).
/// Nor `ttyname(fd)`: the hook's stdin is a pipe and stdout/stderr may be taken over by the CLI,
/// so any of them can fail.
/// Asking for the "controlling terminal" is immune to fd redirection. One syscall, microseconds.
func currentTTY() -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let device = info.kp_eproc.e_tdev
    // -1 = no controlling terminal (processes started by launchd / setsid)
    guard device != -1, device != 0 else { return nil }
    guard let name = devname(device, S_IFCHR) else { return nil }
    return "/dev/" + String(cString: name)
}

/// Terminal attribution: the hook is a child of the CLI, which is a child of the terminal, so the
/// environment this process **inherits** already says which terminal the session runs in.
///
/// Reads only env + one `ttyname` -- microseconds. **Never starts a subprocess** (it would
/// threaten the <50ms budget, which is also why we don't copy CodeIsland's `tmux display-message` call).
func terminalContext(
    _ env: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    var result: [String: String] = [:]
    // "iTerm.app" / "Apple_Terminal" / "ghostty" / "vscode" …
    if let value = env["TERM_PROGRAM"], !value.isEmpty { result["app"] = value }
    // macOS injects this only into GUI-launched processes; it is the most precise terminal
    // identifier (used to activate the app by bundle id)
    if let value = env["__CFBundleIdentifier"], !value.isEmpty { result["bundleId"] = value }
    if let value = env["TMUX_PANE"], !value.isEmpty { result["tmuxPane"] = value }
    if let tty = currentTTY() { result["tty"] = tty }
    return result
}

/// Serializes the terminal context; returns nil when it is entirely empty (the key is then
/// absent from the envelope). Uses JSONSerialization rather than string concatenation: env
/// values come from the user's environment and must be escaped correctly.
func terminalContextJSON() -> Data? {
    let context = terminalContext()
    guard !context.isEmpty else { return nil }
    return try? JSONSerialization.data(withJSONObject: context)
}

/// Atomically writes the event into the spool: write to tmp/ first, then rename into events/,
/// so watchers always see a complete file
func writeEvent(channel: String, payloadJSON: Data) {
    let root = spoolRoot()
    let eventsDir = root.appendingPathComponent("events", isDirectory: true)
    let tmpDir = root.appendingPathComponent("tmp", isDirectory: true)
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // payload must be valid JSON; otherwise wrap it as {"_raw": "..."}
        let payload: Data
        if (try? JSONSerialization.jsonObject(with: payloadJSON)) != nil {
            payload = payloadJSON
        } else {
            let wrapped = ["_raw": String(data: payloadJSON, encoding: .utf8) ?? "<binary>"]
            payload = try JSONSerialization.data(withJSONObject: wrapped)
        }

        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        // terminal lives at the **envelope level** rather than inside payload: terminal attribution
        // is an environment property of this relay call, not hook payload content; it also avoids
        // parsing + re-serializing payload (saves time, and can't corrupt it).
        var body = Data("{\"v\":1,\"channel\":\"\(channel)\",\"receivedAtMs\":\(nowMs)".utf8)
        if let terminal = terminalContextJSON() {
            body.append(Data(",\"terminal\":".utf8))
            body.append(terminal)
        }
        body.append(Data(",\"payload\":".utf8))
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

/// Launches the chained notify command with the payload appended, exactly as Codex would
/// have launched it, and does not wait for it.
///
/// This is the one place the relay starts a process, and only for a notify slot it shares:
/// Codex allows a single top-level `notify`, so when another program held it the installer
/// wrapped that program's argv behind `--chain`. Not waiting keeps the <50ms budget; once the
/// relay exits, launchd adopts and reaps the child. stdio is inherited — it is whatever Codex
/// handed the notify slot, i.e. what the original program would have received anyway.
func spawnChained(_ argv: [String]) {
    guard let program = argv.first, !program.isEmpty else { return }
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    defer { cArgs.forEach { free($0) } }
    var pid: pid_t = 0
    // posix_spawnp: Codex resolves a bare program name through PATH, so must we.
    let status = posix_spawnp(&pid, program, nil, nil, cArgs, environ)
    if status != 0 {
        logError("codex-notify --chain: 无法启动 \(program): \(String(cString: strerror(status)))")
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

/// inject subcommand: synthesizes demo/test events into payloads identical to real hook/notify ones
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

    // --source trae uses the trae-hook channel (same payload shape; the app infers source from
    // channel only)
    let hookChannel = options["source"] == "trae" ? "trae-hook" : "claude-hook"

    func emitClaude(_ extra: [String: Any]) {
        var payload: [String: Any] = ["session_id": session, "cwd": cwd]
        payload.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            writeEvent(channel: hookChannel, payloadJSON: data)
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
        let tool = options["tool"] ?? "Bash"
        var extra: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": tool]
        if let title {
            // Command-style tools go into command, the rest into file_path (so the audit can parse
            // out a detail)
            let key = ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool)
                ? "file_path" : "command"
            extra["tool_input"] = [key: title]
        }
        emitClaude(extra)
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

// ---- Entry point ----

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude-hook":
    let stdin = readStdin(limit: maxStdinBytes)
    if !stdin.isEmpty {
        writeEvent(channel: "claude-hook", payloadJSON: stdin)
    }
case "trae-hook":
    // Trae CN's hook payload carries its own hook_event_name (unlike Codex, which needs the event
    // name from argv), so this mirrors claude-hook word for word; only the channel differs.
    let stdin = readStdin(limit: maxStdinBytes)
    if !stdin.isEmpty {
        writeEvent(channel: "trae-hook", payloadJSON: stdin)
    }
case "codex-hook":
    // Codex hooks, like Claude's, pass the payload JSON over stdin, but **without the event name**
    // (Claude has hook_event_name) -> the event name arrives as the second argument, written into
    // the command line at install time.
    // stdout stays absolutely silent: Codex's PermissionRequest very likely reads stdout as an
    // authorization decision, like Claude's PreToolUse, so any single byte could allow or block
    // a tool call.
    let codexEvent = arguments.count > 1 ? arguments[1] : ""
    let stdin = readStdin(limit: maxStdinBytes)
    if !codexEvent.isEmpty, !stdin.isEmpty {
        // Merge the event name into the payload so downstream needn't guess; on parse failure pass
        // it through verbatim (the app tolerates the missing name)
        if var root = (try? JSONSerialization.jsonObject(with: stdin)) as? [String: Any] {
            root["hook_event_name"] = codexEvent
            if let merged = try? JSONSerialization.data(withJSONObject: root) {
                writeEvent(channel: "codex-hook", payloadJSON: merged)
            }
        } else {
            writeEvent(channel: "codex-hook", payloadJSON: stdin)
        }
    }
case "codex-notify":
    // The notify program receives the JSON as the last argument (Codex appends only this one to
    // the end of the configured argv)
    var rest = Array(arguments.dropFirst())
    let chained = rest.first == "--chain"
    if chained {
        rest.removeFirst()
        // rest = [original argv…, json]. Forward first, so the original program is notified
        // even if recording our own event fails.
        guard rest.count >= 2 else {
            logError("codex-notify --chain: 缺少被串联的命令或载荷")
            break
        }
        spawnChained(rest)
    }
    if let json = rest.last, !json.isEmpty {
        writeEvent(channel: "codex-notify", payloadJSON: Data(json.utf8))
    }
case "inject":
    runInject(Array(arguments.dropFirst()))
default:
    logError("未知子命令: \(arguments.first ?? "<空>")")
}
exit(0)
