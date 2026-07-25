import EurekaKit
import Foundation

/// Qoder 会话索引：扫 `~/.qoder-cn/projects/*/*.jsonl` → AgentSessionInfo。
/// id = 文件名 stem；标题优先级 custom-title > ai-title > last-prompt > 首条真实 user 正文；
/// cwd 取 workspace-directories 行（缺失回退消息行 cwd）；created/updated 取首/末 ISO
/// 时间戳（缺失回退文件日期）。subagents/ 子目录不索引（子代理不单列）。
public enum QoderSessionIndexer {
    /// 单文件读取上限：标题行（custom/ai/last-prompt）散布全文，读全量才能拿准优先级
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
