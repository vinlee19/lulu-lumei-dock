import Foundation

/// cwd → project name: walk up to the nearest `.git` **directory** (a real repo root).
/// A `.git` file (submodule/worktree) is not a root; keep walking up to the parent repo -
/// sessions run in a repo subdirectory/submodule land under the repo name instead of fragmenting
/// into several "projects" by the cwd's last component.
/// If none is found (not a git directory), fall back to the cwd's last component. Cached (looked
/// up for every line of every file).
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

    /// cwd → project root directory (the repo root, falling back to the cwd itself). Used for
    /// project-level skill/agent discovery.
    public func projectRoot(forCwd cwd: String?) -> URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return Self.resolveRoot(cwd: cwd)
    }

    public static func resolve(cwd: String) -> String {
        resolveRoot(cwd: cwd).lastPathComponent
    }

    /// Walks up to the nearest `.git` directory (a real repo root); falls back to the cwd.
    public static func resolveRoot(cwd rawCwd: String) -> URL {
        // Defensive: a dirty cwd containing control characters (e.g. fragments from raw-scanning a
        // binary source) makes URL.appendingPathComponent below throw an uncatchable ObjC exception
        // → crash. Truncate at the first control character/DEL.
        let cwd = String(rawCwd.unicodeScalars.prefix { $0.value >= 0x20 && $0.value != 0x7F })
        guard !cwd.isEmpty else { return URL(fileURLWithPath: "/") }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<12 {
            // home itself is not a project (some people keep their dotfiles in git)
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
