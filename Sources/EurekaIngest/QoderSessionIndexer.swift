import EurekaKit
import Foundation

/// Qoder session index: scans `~/.qoder-cn/projects/*/*.jsonl` → AgentSessionInfo.
/// id = file name stem; title priority custom-title > ai-title > last-prompt > first real user
/// body; cwd from the workspace-directories line (falls back to the message-line cwd);
/// created/updated from the first/last ISO timestamps (falls back to file dates). The
/// subagents/ subdirectory is not indexed (subagents are not listed separately).
public enum QoderSessionIndexer {
    /// Per-file read cap: title lines (custom/ai/last-prompt) are scattered across the file, so it
    /// must be read in full to get the priority right
    private static let maxBytes = 8 * 1024 * 1024

    public static func index(
        projectsRoot: URL = QoderPaths.projectsRoot(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        var results: [AgentSessionInfo] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs where isDirectory(projectDir) {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir,
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

        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var cwd: String?
        var firstAt: Date?
        var lastAt: Date?
        var customTitle: String?
        var aiTitle: String?
        var lastPrompt: String?
        var firstUserText: String?

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if cwd == nil { cwd = QoderTranscriptDecoder.cwd(object) }
            if let ts = QoderTranscriptDecoder.timestamp(object) {
                if firstAt == nil { firstAt = ts }
                lastAt = ts
            }
            if let (isCustom, title) = QoderTranscriptDecoder.titleLine(object) {
                if isCustom { customTitle = title } else { aiTitle = title }
            } else if let prompt = QoderTranscriptDecoder.lastPrompt(object) {
                lastPrompt = prompt
            } else if firstUserText == nil,
                      let userText = QoderTranscriptDecoder.userPromptText(object) {
                firstUserText = summarizeTitle(userText)
            }
        }

        let name = customTitle ?? aiTitle
            ?? lastPrompt.flatMap { summarizeTitle($0) }
            ?? firstUserText

        return AgentSessionInfo(
            source: .qoder,
            id: sessionId,
            cwd: cwd,
            name: name,
            startedAt: firstAt,
            lastActiveAt: lastAt ?? values.contentModificationDate
                ?? Date(timeIntervalSince1970: 0),
            sizeBytes: UInt64(values.fileSize ?? 0),
            transcriptPath: file.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
