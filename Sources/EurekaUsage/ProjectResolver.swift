import Foundation

/// cwd → project name: walk up to the nearest `.git` **directory** (a real repo root).
/// A `.git` file (submodule/worktree) is not a root; keep walking up to the parent repo -
/// sessions run in a repo subdirectory/submodule land under the repo name instead of fragmenting
/// into several "projects" by the cwd's last component.
/// If none is found (not a git directory), fall back to the cwd's last component. Cached (looked
/// up for every line of every file).
///
/// Two modes. `.repository` (the default) is the rule above, and it is what the usage scanners
/// store in `usage_records.project`, so it must not change or the ledger splits old rows from
/// new ones. `.project` is for pages that resolve names when they display them (prompts,
/// sessions) and adds two rules for what a person calls a project:
/// - a worktree (its `.git` file points into `<main>/.git/worktrees/`) is its main repo, not a
///   project of its own named after the worktree folder;
/// - a repo that directly holds two or more independent clones is a shell (a workspace folder
///   kept in git); a cwd inside it but outside those clones belongs to the shell's child folder
///   on its path, so a plain folder like `workspace/olap-poc` is "olap-poc", not "workspace".
/// Config discovery (project `.mcp.json`, skills, agents) keeps `.repository`: a worktree's
/// project files live in the worktree itself.
public final class ProjectResolver {
    public enum Mode: Sendable { case repository, project }

    private let mode: Mode
    private var cache: [String: String] = [:]

    public init(mode: Mode = .repository) {
        self.mode = mode
    }

    public func projectName(forCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        if let hit = cache[cwd] { return hit }
        let name = Self.resolve(cwd: cwd, mode: mode)
        cache[cwd] = name
        return name
    }

    /// cwd → project root directory (the repo root, falling back to the cwd itself). Used for
    /// project-level skill/agent discovery.
    public func projectRoot(forCwd cwd: String?) -> URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return Self.resolveRoot(cwd: cwd)
    }

    public static func resolve(cwd: String, mode: Mode = .repository) -> String {
        resolveRoot(cwd: cwd, mode: mode).lastPathComponent
    }

    /// Walks up to the nearest `.git` directory (a real repo root); falls back to the cwd.
    /// `.project` mode also maps worktrees to their main repo and splits shell repos (see the
    /// type comment).
    public static func resolveRoot(cwd rawCwd: String, mode: Mode = .repository) -> URL {
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
            if fm.fileExists(atPath: gitPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    guard mode == .project else { return dir }
                    return shellChild(of: dir, containing: cwd) ?? dir
                }
                if mode == .project, let main = worktreeMainRoot(gitFile: gitPath) {
                    return main
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL
    }

    /// `gitdir: <main>/.git/worktrees/<name>` → `<main>`, when that repo still exists. Submodule
    /// pointers (`gitdir: ../.git/modules/…`) return nil, so the walk continues upward.
    static func worktreeMainRoot(gitFile path: String) -> URL? {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data.prefix(4096), encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard target.hasPrefix("/"), let range = target.range(of: "/.git/worktrees/") else { return nil }
        let main = URL(fileURLWithPath: String(target[..<range.lowerBound])).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: main.appendingPathComponent(".git").path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return main
    }

    /// When `repo` directly holds two or more independent clones (children with a `.git`
    /// directory; submodules have a `.git` file and don't count) and `cwd` sits below `repo`,
    /// returns `repo`'s child folder on the path to `cwd`. Clones themselves never reach here:
    /// the upward walk stops at their own `.git` first.
    static func shellChild(of repo: URL, containing cwd: String) -> URL? {
        let cwdURL = URL(fileURLWithPath: cwd).standardizedFileURL
        let repoComponents = repo.pathComponents
        let cwdComponents = cwdURL.pathComponents
        guard cwdComponents.count > repoComponents.count,
              Array(cwdComponents.prefix(repoComponents.count)) == repoComponents else { return nil }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: repo, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var clones = 0
        for child in children {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: child.appendingPathComponent(".git").path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                clones += 1
                if clones >= 2 { break }
            }
        }
        guard clones >= 2 else { return nil }
        return repo.appendingPathComponent(cwdComponents[repoComponents.count], isDirectory: true)
    }
}
