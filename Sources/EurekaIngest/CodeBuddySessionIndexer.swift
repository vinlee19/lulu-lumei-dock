import EurekaKit
import Foundation

/// CodeBuddy session index: scans `projects/<cwd-slug>/*.jsonl` → AgentSessionInfo. id = file name
/// stem; title = latest ai-title > latest summary > summary of the first real user text; cwd from
/// the per-line cwd field; created/updated from the first/last line timestamp (epoch ms). Schema
/// verified against real sessions (2026-07, ~/.codebuddy).
public enum CodeBuddySessionIndexer {
    private static let headBytes = 256 * 1024
    private static let tailBytes = 64 * 1024

    public static func index(
        projectsRoot: URL = CodeBuddyPaths.projectsRoot(),
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
                includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                // The last write bounds the activity (no line can be newer than the file's
                // mtime), so files outside the window are skipped before reading them; reading
                // every file ever was most of a first install's discovery cost
                if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, now.timeIntervalSince(mtime) >= window {
                    continue
                }
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
        let size = UInt64(values.fileSize ?? 0)

        var cwd: String?
        var startedAt: Date?
        var firstUserText: String?
        // Title priority: ai-title(2) > summary(1) > first user text(0), each taking its last
        // occurrence
        var title: String?
        var titleRank = -1

        // Head: cwd / first-line time / first user text / early titles
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: headBytes)) ?? Data()
            if let text = String(data: head, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let object = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any]
                    else { continue }
                    if cwd == nil { cwd = object["cwd"] as? String }
                    if startedAt == nil {
                        startedAt = CodeBuddyTranscriptDecoder.timestamp(object)
                    }
                    switch object["type"] as? String {
                    case "ai-title", "summary":
                        let rank = object["type"] as? String == "ai-title" ? 2 : 1
                        if rank >= titleRank,
                           let candidate = CodeBuddyTranscriptDecoder.title(object) {
                            title = candidate
                            titleRank = rank
                        }
                    case "message":
                        if firstUserText == nil,
                           let userText = CodeBuddyTranscriptDecoder.userText(object) {
                            firstUserText = userText
                        }
                    default:
                        break
                    }
                }
            }

            // Tail: last-line time (session last active) + ai-title/summary generated only later in
            // the session
            if size > headBytes,
               (try? handle.seek(toOffset: size - UInt64(tailBytes))) != nil,
               let tail = try? handle.readToEnd(),
               let text = String(data: tail, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let object = try? JSONSerialization.jsonObject(
                        with: Data(line.utf8)) as? [String: Any]
                    else { continue }
                    switch object["type"] as? String {
                    case "ai-title", "summary":
                        let rank = object["type"] as? String == "ai-title" ? 2 : 1
                        if rank >= titleRank,
                           let candidate = CodeBuddyTranscriptDecoder.title(object) {
                            title = candidate
                            titleRank = rank
                        }
                    default:
                        break
                    }
                }
            }
        }
        if titleRank < 0, let firstUserText {
            title = summarizeTitle(firstUserText)
        }
        // Empty sessions with neither real user input nor a title stay out of the list
        guard title != nil else { return nil }

        // Last-line timestamp → lastActiveAt (the file may be rewritten whole, so mtime is
        // unreliable; fall back to mtime if missing)
        var lastActiveAt = values.contentModificationDate
            ?? Date(timeIntervalSince1970: 0)
        if let lastLineDate = lastLineTimestamp(file: file) {
            lastActiveAt = max(lastActiveAt, lastLineDate)
        }

        return AgentSessionInfo(
            source: .codebuddy,
            id: sessionId,
            cwd: cwd,
            name: title,
            startedAt: startedAt,
            lastActiveAt: lastActiveAt,
            sizeBytes: size,
            transcriptPath: file.path)
    }

    /// Timestamp of the last complete line (searched within the trailing 64KB)
    private static func lastLineTimestamp(file: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let from = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: from)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
                let date = CodeBuddyTranscriptDecoder.timestamp(object)
            else { continue }
            return date
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
