import EurekaKit
import Foundation

/// Qwen session line parsing (projects/<encoded>/chats/<uuid>.jsonl, surveyed on v0.20).
/// Hybrid format: Claude-style envelope {uuid, sessionId, timestamp, type, cwd} +
/// Gemini-style payload message:{role, parts:[{text}|{text,thought}|{functionCall}]}.
/// Tokens live in api_response events with type=system/subtype=ui_telemetry (see QwenUsageScanner).
enum QwenChatDecoder {
    struct Message {
        var uuid: String?
        var timestamp: Date?
        /// user / assistant / system
        var type: String
        var cwd: String?
        /// Visible body (text parts joined; thought parts go separately into `thoughts`)
        var text: String
        /// Tool names of the functionCall parts
        var toolCalls: [String]
        /// **Plaintext thinking** (`{text, thought:true}` parts). Qwen neither encrypts nor strips
        /// it; a single part was observed at 5000+ characters. It used to be dropped by `continue`
        /// along with the body.
        var thoughts: [String] = []
    }

    static func parseMessage(_ root: [String: Any]) -> Message? {
        guard let type = root["type"] as? String else { return nil }
        var text: [String] = []
        var tools: [String] = []
        var thoughts: [String] = []
        if let message = root["message"] as? [String: Any],
           let parts = message["parts"] as? [[String: Any]] {
            for part in parts {
                if let call = part["functionCall"] as? [String: Any] {
                    tools.append((call["name"] as? String) ?? "?")
                    continue
                }
                guard let piece = part["text"] as? String, !piece.isEmpty else { continue }
                // thought parts are thinking text, collected separately from the visible answer
                if (part["thought"] as? Bool) == true {
                    thoughts.append(piece)
                } else {
                    text.append(piece)
                }
            }
        }
        return Message(
            uuid: root["uuid"] as? String,
            timestamp: (root["timestamp"] as? String).flatMap(KimiWireDecoder.parseISO),
            type: type,
            cwd: root["cwd"] as? String,
            text: text.joined(separator: "\n"),
            toolCalls: tools,
            thoughts: thoughts)
    }

    /// ui_telemetry line → api_response event (for token collection)
    static func apiResponse(_ root: [String: Any]) -> [String: Any]? {
        guard root["type"] as? String == "system",
              root["subtype"] as? String == "ui_telemetry",
              let payload = root["systemPayload"] as? [String: Any],
              let event = payload["uiEvent"] as? [String: Any],
              event["event.name"] as? String == "qwen-code.api_response"
        else { return nil }
        return event
    }
}

/// Qwen session index: scans `projects/*/chats/*.jsonl` → AgentSessionInfo. cwd comes from the
/// companion runtime.json's work_dir (falls back to the message line's cwd field).
public enum QwenSessionIndexer {
    private static let headBytes = 256 * 1024

    public static func index(
        projectsRoot: URL = QwenPaths.projectsRoot(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        var results: [AgentSessionInfo] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs where isDirectory(projectDir) {
            let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                guard let info = sessionInfo(file: file),
                      now.timeIntervalSince(info.lastActiveAt) < window
                else { continue }
                results.append(info)
            }
        }
        return Array(results.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }

    static func sessionInfo(file: URL) -> AgentSessionInfo? {
        guard let values = try? file.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        let sessionId = file.deletingPathExtension().lastPathComponent

        // Companion runtime.json: work_dir + started_at
        var cwd: String?
        var startedAt: Date?
        let runtimeURL = file.deletingPathExtension()
            .appendingPathExtension("runtime.json")
        if let data = try? Data(contentsOf: runtimeURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cwd = root["work_dir"] as? String
            if let epoch = (root["started_at"] as? NSNumber)?.doubleValue {
                startedAt = Date(timeIntervalSince1970: epoch)
            }
        }

        // Name = summary of the first real user message; falls back to the message line's cwd field
        // when cwd is missing
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        var name: String?
        if let text = String(data: head, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                    let message = QwenChatDecoder.parseMessage(object)
                else { continue }
                if cwd == nil { cwd = message.cwd }
                if startedAt == nil { startedAt = message.timestamp }
                if message.type == "user", !message.text.isEmpty {
                    name = summarizeTitle(message.text)
                    break
                }
            }
        }
        guard name != nil else { return nil }  // Empty sessions with no real user input stay out of the list

        return AgentSessionInfo(
            source: .qwen,
            id: sessionId,
            cwd: cwd,
            name: name,
            startedAt: startedAt,
            lastActiveAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            sizeBytes: UInt64(values.fileSize ?? 0),
            transcriptPath: file.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
