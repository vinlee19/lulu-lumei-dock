import Foundation
import EurekaKit

/// Session index entry (for project session management; shared by Claude/Codex)
public struct AgentSessionInfo: Equatable, Sendable, Identifiable {
    public var source: AgentSource
    public var id: String          // session uuid
    public var cwd: String?
    /// Session name (custom-title sidecar / inline → legacy ai-title → first-prompt summary); nil =
    /// only the short id can be shown
    public var name: String?
    /// When the session was first active (transcript first-line timestamp); nil = no timestamp in
    /// the head
    public var startedAt: Date?
    public var lastActiveAt: Date
    public var sizeBytes: UInt64
    public var transcriptPath: String

    /// Display name: falls back to the localized "Session <first 8 of id>" when name is blank (an
    /// empty name would render as a blank row; the fallback lives here in one place)
    public var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.format("Session %@", zhHans: "会话 %@", String(id.prefix(8))) : trimmed
    }

    /// Session span: first → last active; nil when startedAt is missing
    public var duration: TimeInterval? {
        startedAt.map { lastActiveAt.timeIntervalSince($0) }.map { max(0, $0) }
    }

    public init(
        source: AgentSource = .claude,
        id: String, cwd: String?, name: String?,
        startedAt: Date? = nil,
        lastActiveAt: Date, sizeBytes: UInt64, transcriptPath: String
    ) {
        self.source = source
        self.id = id
        self.cwd = cwd
        self.name = name
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.sizeBytes = sizeBytes
        self.transcriptPath = transcriptPath
    }
}

/// Scans ~/.claude/projects to build the session index:
/// file = session (mtime = last active, size sortable); cwd / start time come from the file's first
/// 64KB, the name first from the sidecar `<id>/custom-title.json` (see `ClaudeSessionTitle`), with
/// the head only as a fallback.
public enum ClaudeSessionIndexer {
    public static func index(
        projectsRoot: URL,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        var candidates: [(URL, Date, UInt64)] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]),
                    let mtime = values.contentModificationDate
                else { continue }
                guard now.timeIntervalSince(mtime) < window else { continue }
                candidates.append((file, mtime, UInt64(values.fileSize ?? 0)))
            }
        }
        // Most recent first; only parse file heads after truncating (bounds IO)
        candidates.sort { $0.1 > $1.1 }
        return candidates.prefix(maxSessions).map { file, mtime, size in
            let head = headInfo(fileURL: file)
            return AgentSessionInfo(
                source: .claude,
                id: file.deletingPathExtension().lastPathComponent,
                cwd: head.cwd,
                name: head.name,
                startedAt: head.startedAt,
                lastActiveAt: mtime,
                sizeBytes: size,
                transcriptPath: file.path
            )
        }
    }

    /// First 64KB: cwd + name + session start time (first-line timestamp).
    /// Name priority: sidecar `custom-title.json` → inline custom-title in the head → legacy
    /// ai-title → first real prompt. Desktop's first inline custom-title sits at a median offset of
    /// 189KB, so the 64KB head usually misses it and the sidecar goes first (one small read). The
    /// head is not widened to find titles — that would be 300 sessions × 64KB of JSON parsing.
    static func headInfo(
        fileURL: URL, headBytes: Int = 65536
    ) -> (cwd: String?, name: String?, startedAt: Date?) {
        guard
            let handle = FileHandle(forReadingAtPath: fileURL.path),
            let data = try? handle.read(upToCount: headBytes)
        else { return (nil, nil, nil) }
        try? handle.close()

        var cwd: String?
        var customTitle = ClaudeSessionTitle.sidecar(transcriptURL: fileURL)
        var aiTitle: String?
        var firstPrompt: String?
        var startedAt: Date?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any]
            else { continue }  // A half line cut off by the head window lands here; skip it safely
            if cwd == nil { cwd = root["cwd"] as? String }
            if startedAt == nil, let ts = root["timestamp"] as? String {
                startedAt = ClaudeSessionFirstTimestamp.parse(ts)
            }
            if let (isCustom, title) = ClaudeSessionTitle.line(root) {
                // The inline custom-title carries the same value as the sidecar; without a sidecar
                // it is the name
                if isCustom { customTitle = customTitle ?? title }
                else if aiTitle == nil { aiTitle = title }
            } else if root["type"] as? String == "user",
                      firstPrompt == nil,
                      root["isMeta"] as? Bool != true,
                      let message = root["message"] as? [String: Any],
                      let content = message["content"] as? String {
                firstPrompt = summarizeTitle(content)
            }
            // custom-title and ai-title never coexist in one file: either one is enough to stop
            if cwd != nil && startedAt != nil && (customTitle != nil || aiTitle != nil) { break }
        }
        return (cwd, customTitle ?? aiTitle ?? firstPrompt, startedAt)
    }
}
