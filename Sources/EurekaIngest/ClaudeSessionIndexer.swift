import Foundation
import EurekaKit

/// 会话索引条目（项目会话管理用，Claude/Codex 通用）
public struct AgentSessionInfo: Equatable, Sendable, Identifiable {
    public var source: AgentSource
    public var id: String          // session uuid
    public var cwd: String?
    /// ai-title / 首条 prompt 摘要；nil = 只能显示短 id
    public var name: String?
    /// 会话首次活跃时间（transcript 首行时间戳）；nil = 头部无时间戳
    public var startedAt: Date?
    public var lastActiveAt: Date
    public var sizeBytes: UInt64
    public var transcriptPath: String

    /// 展示名：name 空白时回退「会话 <id前8>」（空串 name 会渲染成空行，统一在此兜底）
    public var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "会话 \(id.prefix(8))" : trimmed
    }

    /// 会话跨度：首次 → 最后活跃；startedAt 缺失时 nil
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

/// 扫描 ~/.claude/projects 建会话索引：
/// 文件 = 会话（mtime = 最近活跃，size 可排序），名字从文件头部 64KB 提取
/// （ai-title 在首轮响应后生成，通常都在头部；超长首轮退首条 prompt）。
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
        // 最近优先，截断后才做文件头解析（控制 IO）
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

    /// 头部 64KB：cwd + 名字（ai-title 优先、首条真实 prompt 兜底）+ 会话开始时间（首行时间戳）
    static func headInfo(
        fileURL: URL, headBytes: Int = 65536
    ) -> (cwd: String?, name: String?, startedAt: Date?) {
        guard
            let handle = FileHandle(forReadingAtPath: fileURL.path),
            let data = try? handle.read(upToCount: headBytes)
        else { return (nil, nil, nil) }
        try? handle.close()

        var cwd: String?
        var aiTitle: String?
        var firstPrompt: String?
        var startedAt: Date?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any]
            else { continue }  // 头窗截断的半行会落到这里，安全跳过
            if cwd == nil { cwd = root["cwd"] as? String }
            if startedAt == nil, let ts = root["timestamp"] as? String {
                startedAt = ClaudeSessionFirstTimestamp.parse(ts)
            }
            switch root["type"] as? String {
            case "ai-title":
                if aiTitle == nil { aiTitle = root["aiTitle"] as? String }
            case "user":
                guard firstPrompt == nil,
                      root["isMeta"] as? Bool != true,
                      let message = root["message"] as? [String: Any],
                      let content = message["content"] as? String
                else { continue }
                firstPrompt = summarizeTitle(content)
            default:
                break
            }
            if cwd != nil && aiTitle != nil && startedAt != nil { break }
        }
        return (cwd, aiTitle ?? firstPrompt, startedAt)
    }
}
