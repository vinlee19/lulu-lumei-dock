import EurekaKit
import Foundation

/// Gemini CLI session line parsing (chats/session-*.jsonl, format surveyed on v0.51).
/// First line is the header; message lines are {id, timestamp, type: user|gemini|info|error,
/// content, tokens?, model?}; `{"$set":{...}}` patch lines (lastUpdated/summary state sync)
/// are always skipped.
enum GeminiChatDecoder {
    struct Header {
        var sessionId: String
        var startTime: Date?
    }

    struct Tokens {
        var input: Int
        var output: Int
        var cached: Int
        var thoughts: Int
    }

    struct Message {
        var id: String?
        var timestamp: Date?
        /// user / gemini / info / error
        var type: String
        var text: String
        var tokens: Tokens?
        var model: String?
    }

    static func parseHeader(_ root: [String: Any]) -> Header? {
        guard let sessionId = root["sessionId"] as? String else { return nil }
        let start = (root["startTime"] as? String).flatMap(KimiWireDecoder.parseISO)
        return Header(sessionId: sessionId, startTime: start)
    }

    /// Message line → Message; header/$set/lines without type return nil
    static func parseMessage(_ root: [String: Any]) -> Message? {
        guard root["$set"] == nil, let type = root["type"] as? String else { return nil }
        var tokens: Tokens?
        if let raw = root["tokens"] as? [String: Any] {
            tokens = Tokens(
                input: (raw["input"] as? NSNumber)?.intValue ?? 0,
                output: (raw["output"] as? NSNumber)?.intValue ?? 0,
                cached: (raw["cached"] as? NSNumber)?.intValue ?? 0,
                thoughts: (raw["thoughts"] as? NSNumber)?.intValue ?? 0)
        }
        return Message(
            id: root["id"] as? String,
            timestamp: (root["timestamp"] as? String).flatMap(KimiWireDecoder.parseISO),
            type: type,
            text: text(from: root["content"]),
            tokens: tokens,
            model: root["model"] as? String)
    }

    /// content comes in two shapes: a plain string (gemini lines) or a [{text}] array (user/info
    /// lines)
    static func text(from content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    /// Environment note the CLI injects at startup (not real user input)
    static func isSessionContext(_ text: String) -> Bool {
        text.hasPrefix("<session_context>")
    }
}

/// Gemini session index: scans `tmp/<slug>/chats/session-*.jsonl` → AgentSessionInfo.
/// cwd is resolved from the slug via projects.json; the name is a summary of the first real
/// user message (session_context injections are skipped).
public enum GeminiSessionIndexer {
    /// Name/head extraction reads only the file head (session_context includes a directory tree,
    /// possibly tens of KB)
    private static let headBytes = 512 * 1024

    public static func index(
        tmpRoot: URL = GeminiPaths.tmpRoot(),
        projectsFile: URL = GeminiPaths.projectsFile(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let slugToProject = GeminiPaths.slugToProject(projectsFile: projectsFile)
        var results: [AgentSessionInfo] = []
        let slugDirs = (try? fm.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for slugDir in slugDirs where isDirectory(slugDir) {
            let chatsDir = slugDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("session-")
                && file.pathExtension.lowercased() == "jsonl" {
                // Filter by the mtime window before reading content: out-of-window files skip even
                // the 512KB head read
                guard let mtime = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                    now.timeIntervalSince(mtime) < window
                else { continue }
                guard let info = sessionInfo(
                    file: file, cwd: slugToProject[slugDir.lastPathComponent])
                else { continue }
                results.append(info)
            }
        }
        return Array(results.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }

    static func sessionInfo(file: URL, cwd: String?) -> AgentSessionInfo? {
        guard let values = try? file.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        guard let text = String(data: head, encoding: .utf8)
            ?? String(data: head, encoding: .ascii) else { return nil }

        var header: GeminiChatDecoder.Header?
        var name: String?
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any] else { continue }
            if header == nil, let parsed = GeminiChatDecoder.parseHeader(object) {
                header = parsed
                continue
            }
            if name == nil, let message = GeminiChatDecoder.parseMessage(object),
               message.type == "user",
               !GeminiChatDecoder.isSessionContext(message.text) {
                name = summarizeTitle(message.text)
                break
            }
        }
        guard let header else { return nil }
        // Empty sessions with only injected context and no real user input stay out of the list
        guard name != nil else { return nil }

        return AgentSessionInfo(
            source: .gemini,
            id: header.sessionId,
            cwd: cwd,
            name: name,
            startedAt: header.startTime,
            lastActiveAt: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            sizeBytes: UInt64(values.fileSize ?? 0),
            transcriptPath: file.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
