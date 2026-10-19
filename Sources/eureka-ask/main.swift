import Foundation

// eureka-ask: Claude Code's PermissionRequest(matcher: AskUserQuestion) hook, letting the user
// answer questions on the Dynamic Island.
// Built as `eureka-ask`; the app installs it at the stable path as `lululumei-ask`.
//
// A PermissionRequest hook runs alongside Claude's own confirmation UI (terminal picker / desktop
// confirmation card), and whichever answers first wins: answered on the island, Claude withdraws
// its own UI; answered in Claude, the output here is no longer used.
//
// It and the relay are **two programs** with exactly opposite constraints: the relay is always
// silent, <50ms, report-only; this one blocks waiting for the user's click, then writes the answer
// to stdout -- when Claude reads `decision.behavior: "allow"` + an `updatedInput` carrying
// `answers`, it proceeds with those answers. So it is registered only on AskUserQuestion and must
// never hang on any other tool (stdout would be read as an allow decision).
//
// Contract with the app (`EurekaIngest.QuestionInbox` is the other end):
//   <root>/island-heartbeat          the app writes its own pid every 5 seconds;
//                                    not updated for over 15 seconds = island gone
//   <root>/questions/<id>.json       exists while this process waits; deleted on exit
//   <root>/answers/<id>.json         the app writes {"action":"answer","answers":{question:answer}}
//                                    or {"action":"dismiss"} (question dismissed on the island /
//                                    already answered in Claude)
//
// In every case that doesn't qualify (not AskUserQuestion / island gone / timeout / dismissed /
// error / terminated by a signal) it **silently exits 0 and writes not a single byte to stdout** --
// leaving it to Claude's own confirmation UI, never answering on the user's behalf.

let maxStdinBytes = 1_048_576
/// Wait at most 10 minutes; the timeout given to this hook in settings.json is 610 seconds, leaving
/// margin to wrap up
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

/// Whether the island is there: the heartbeat file is fresh enough and the app process recorded in
/// it is still alive
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

/// When terminated by Claude (timeout / user interrupts in the terminal), delete the question file
/// so the island card is withdrawn. Only async-signal-safe calls are allowed in the signal handler:
/// the path is converted to a C string up front, and the handler does only unlink + _exit. The app
/// has its own fallback: it also cleans up when the pid in the question file is gone, so
/// uncatchable signals like SIGKILL leave no orphan card.
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

    // The PermissionRequest input has no tool_use_id, so each wait uses a fresh id
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
        // The app quit / hung during the wait: nobody is showing the island card anymore, so
        // there's no point blocking for 10 minutes
        if Date().timeIntervalSince(lastAliveCheck) >= 2 {
            lastAliveCheck = Date()
            guard islandIsAlive(root: root) else { return }
        }
        usleep(pollInterval)
    }
}

/// Emits output only when `action == "answer"` and every question has a non-empty answer; otherwise
/// stays silent (leaving it to Claude's own confirmation UI)
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

    // updatedInput replaces the whole tool input: carry questions back unchanged, only adding
    // answers
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
