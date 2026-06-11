import Foundation
import EurekaKit

/// 会话索引条目（项目会话管理用）
public struct ClaudeSessionInfo: Equatable, Sendable, Identifiable {
    public var id: String          // session uuid（文件名）
    public var cwd: String?
    /// ai-title 优先，退首条 prompt 摘要；nil = 只能显示短 id
    public var name: String?
    public var lastActiveAt: Date
    public var sizeBytes: UInt64
    public var transcriptPath: String

    public init(
        id: String, cwd: String?, name: String?,
        lastActiveAt: Date, sizeBytes: UInt64, transcriptPath: String
    ) {
        self.id = id
        self.cwd = cwd
        self.name = name
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
    ) -> [ClaudeSessionInfo] {
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
            return ClaudeSessionInfo(
                id: file.deletingPathExtension().lastPathComponent,
                cwd: head.cwd,
                name: head.name,
                lastActiveAt: mtime,
                sizeBytes: size,
                transcriptPath: file.path
            )
        }
    }

    /// 头部 64KB：cwd + 名字（ai-title 优先、首条真实 prompt 兜底）
    static func headInfo(fileURL: URL, headBytes: Int = 65536) -> (cwd: String?, name: String?) {
        guard
            let handle = FileHandle(forReadingAtPath: fileURL.path),
            let data = try? handle.read(upToCount: headBytes)
        else { return (nil, nil) }
        try? handle.close()

        var cwd: String?
        var aiTitle: String?
        var firstPrompt: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any]
            else { continue }  // 头窗截断的半行会落到这里，安全跳过
            if cwd == nil { cwd = root["cwd"] as? String }
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
            if cwd != nil && aiTitle != nil { break }
        }
        return (cwd, aiTitle ?? firstPrompt)
    }
}
