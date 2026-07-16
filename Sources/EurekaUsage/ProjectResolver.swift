import Foundation

/// cwd → 项目名：向上找最近的 `.git` **目录**（真仓库根）。
/// `.git` 文件（子模块/worktree）不算根，继续向上找父仓库——
/// 在 repo 子目录/子模块里跑的会话归到仓库名下，而不是按 cwd 末段碎成多个"项目"。
/// 找不到（非 git 目录）回退 cwd 末段。带缓存（每文件每行都要查）。
public final class ProjectResolver {
    private var cache: [String: String] = [:]

    public init() {}

    public func projectName(forCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let hit = cache[cwd] { return hit }
        let name = Self.resolve(cwd: cwd)
        cache[cwd] = name
        return name
    }

    /// cwd → 项目根目录（仓库根，找不到回退 cwd 本身）。项目级技能/agent 发现用。
    public func projectRoot(forCwd cwd: String?) -> URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return Self.resolveRoot(cwd: cwd)
    }

    public static func resolve(cwd: String) -> String {
        resolveRoot(cwd: cwd).lastPathComponent
    }

    /// 向上找最近的 `.git` 目录（真仓库根）；找不到回退 cwd。
    public static func resolveRoot(cwd rawCwd: String) -> URL {
        // 防御：含控制字符的脏 cwd（如来自二进制来源裸扫的碎片）会让下面的
        // URL.appendingPathComponent 抛不可捕获的 ObjC 异常 → 崩溃。截断到首个控制字符/DEL。
        let cwd = String(rawCwd.unicodeScalars.prefix { $0.value >= 0x20 && $0.value != 0x7F })
        guard !cwd.isEmpty else { return URL(fileURLWithPath: "/") }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<12 {
            // home 本身不算项目（有人会 git 管理 dotfiles）
            if dir.path == home || dir.path == "/" { break }
            var isDirectory: ObjCBool = false
            let gitPath = dir.appendingPathComponent(".git").path
            if fm.fileExists(atPath: gitPath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL
    }
}
