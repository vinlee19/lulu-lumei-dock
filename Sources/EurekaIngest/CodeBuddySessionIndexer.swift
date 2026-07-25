import EurekaKit
import Foundation

/// CodeBuddy 会话索引：扫 `projects/<cwd-slug>/*.jsonl` → AgentSessionInfo。
/// id = 文件名 stem；标题 = 最新 ai-title > 最新 summary > 首条真实 user 文本摘要；
/// cwd 取行内 cwd 字段；created/updated 取首/末行 timestamp（epoch ms）。
/// schema 已对真实会话核验（2026-07，~/.codebuddy）。
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
        // 标题优先级：ai-title(2) > summary(1) > 首条 user 文本(0)，取各自最后出现
        var title: String?
        var titleRank = -1

        // 头部：cwd / 首行时间 / 首条 user 文本 / 早段标题
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

            // 尾部：末行时间（会话最后活跃）+ 后段才生成的 ai-title/summary
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
        // 无真实用户输入也无标题的空会话不进列表
        guard title != nil else { return nil }

        // 末行时间戳 → lastActiveAt（文件可能整写，mtime 不可靠；缺失回退 mtime）
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

    /// 末个完整行的 timestamp（尾部 64KB 内找）
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
