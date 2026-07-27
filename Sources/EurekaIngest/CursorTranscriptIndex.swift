import Foundation

/// Cursor 的会话转录文件索引：`~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`。
///
/// Cursor 3.13.10 起除了往 `state.vscdb` 写，还会为每个 agent 回合落一份 Claude 式 JSONL。
/// 两条通道的分工（别把它们当成互相替代）：
///   - **库**是唯一完整来源：全部历史、token、ctx%、todos、子会话；
///   - **转录**只覆盖「这个特性上线之后」的回合，没有 token / ctx%，
///     但它有库没有的两样东西——显式的 `turn_ended`，和路径里自带的工程 slug。
///
/// slug 是有损编码（`/` 与 `.` 都变 `-`，`Users-wl-xiao-vinlee-workspace-a-b` 反解不回去），
/// 所以 cwd **不靠反解**：把已知的 workspace 目录正向编码成 slug 去比对，命中才算数。
public enum CursorTranscriptIndex {
    public struct Entry: Equatable, Sendable {
        public var composerId: String
        public var url: URL
        /// 工程目录；`empty-window` 或比不上已知 workspace 时为 nil
        public var cwd: String?
    }

    private static let lock = NSLock()
    private static var cache: [String: (value: [Entry], at: Date)] = [:]
    /// 一个新回合会**新建**文件，缓存太久就会漏掉整轮 → 比 workspace 索引短得多
    private static let cacheTTL: TimeInterval = 3

    /// `<cliHome>/projects` 下所有转录文件
    public static func entries(
        cliHome: URL = CursorPaths.cliHome(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        now: Date = Date()
    ) -> [Entry] {
        lock.lock()
        if let cached = cache[cliHome.path], now.timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        // 已知 workspace 目录 → slug，用于正向匹配（不反解有损 slug）
        var slugToCwd: [String: String] = [:]
        for cwd in CursorWorkspaceIndex.folders(root: workspaceStorageRoot, now: now).values {
            slugToCwd[slug(forPath: cwd)] = cwd
        }

        let fm = FileManager.default
        let projectsRoot = cliHome.appendingPathComponent("projects", isDirectory: true)
        var results: [Entry] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let cwd = slugToCwd[projectDir.lastPathComponent]
            let transcriptsRoot = projectDir
                .appendingPathComponent("agent-transcripts", isDirectory: true)
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: transcriptsRoot, includingPropertiesForKeys: nil)) ?? []
            for sessionDir in sessionDirs {
                let composerId = sessionDir.lastPathComponent
                guard !composerId.isEmpty else { continue }
                let file = sessionDir.appendingPathComponent("\(composerId).jsonl")
                guard fm.fileExists(atPath: file.path) else { continue }
                results.append(Entry(composerId: composerId, url: file, cwd: cwd))
            }
        }

        lock.lock()
        cache[cliHome.path] = (results, now)
        lock.unlock()
        return results
    }

    /// 有转录文件的会话 id 集合（库侧 tailer 用它让出生命周期事件的所有权）
    public static func ownedComposerIds(
        cliHome: URL = CursorPaths.cliHome(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        now: Date = Date()
    ) -> Set<String> {
        Set(entries(cliHome: cliHome, workspaceStorageRoot: workspaceStorageRoot, now: now)
            .map(\.composerId))
    }

    /// 绝对路径 → Cursor 的项目目录名。实勘 `/Users/wl.xiao/vinlee/workspace/aftership-semantic-layer`
    /// → `Users-wl-xiao-vinlee-workspace-aftership-semantic-layer`：去掉开头的 `/`，
    /// 其余 `/` 与 `.` 全换成 `-`。
    public static func slug(forPath path: String) -> String {
        var text = path
        if text.hasPrefix("/") { text.removeFirst() }
        return text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// 仅供测试：清缓存，免得临时目录之间串台
    public static func resetCacheForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
