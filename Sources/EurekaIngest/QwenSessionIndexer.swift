import EurekaKit
import Foundation

/// Qwen 会话行解析（projects/<encoded>/chats/<uuid>.jsonl，v0.20 实勘）。
/// 混血格式：Claude 式信封 {uuid, sessionId, timestamp, type, cwd} +
/// Gemini 式 payload message:{role, parts:[{text}|{text,thought}|{functionCall}]}。
/// token 在 type=system/subtype=ui_telemetry 的 api_response 事件里（见 QwenUsageScanner）。
enum QwenChatDecoder {
    struct Message {
        var uuid: String?
        var timestamp: Date?
        /// user / assistant / system
        var type: String
        var cwd: String?
        /// 可见正文（text parts 拼接，thought parts 跳过）
        var text: String
        /// functionCall parts 的工具名列表
        var toolCalls: [String]
    }

    static func parseMessage(_ root: [String: Any]) -> Message? {
        guard let type = root["type"] as? String else { return nil }
        var text: [String] = []
        var tools: [String] = []
        if let message = root["message"] as? [String: Any],
           let parts = message["parts"] as? [[String: Any]] {
            for part in parts {
                if let call = part["functionCall"] as? [String: Any] {
                    tools.append((call["name"] as? String) ?? "?")
                    continue
                }
                // thought parts 是思考轨迹，不进正文
                if (part["thought"] as? Bool) == true { continue }
                if let piece = part["text"] as? String, !piece.isEmpty {
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
            toolCalls: tools)
    }

    /// ui_telemetry 行 → api_response 事件（token 采集用）
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

/// Qwen 会话索引：扫 `projects/*/chats/*.jsonl` → AgentSessionInfo。
/// cwd 取伴随 runtime.json 的 work_dir（缺失回退消息行 cwd 字段）。
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

        // 伴随 runtime.json：work_dir + started_at
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

        // 名字 = 首条真实 user 消息摘要；cwd 缺失时回退消息行 cwd 字段
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
        guard name != nil else { return nil }  // 无真实用户输入的空会话不进列表

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
