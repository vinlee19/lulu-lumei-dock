import EurekaKit
import Foundation

/// Ownership scope of a skill / agent: system-level (user home root) or project-level (under a
/// project's cwd)
public enum SkillScope: Equatable, Sendable {
    case system
    case project(String)  // associated project name

    /// Project name (nil for system-level)
    public var projectName: String? {
        if case .project(let name) = self { return name }
        return nil
    }
    public var isProject: Bool { projectName != nil }
}

/// Project-level root: the skills / agents directory under a project's cwd (shared by skills and
/// agents)
public struct ProjectScopedRoot: Equatable, Sendable {
    public var root: URL
    public var source: AgentSource
    public var projectName: String
    public init(root: URL, source: AgentSource, projectName: String) {
        self.root = root
        self.source = source
        self.projectName = projectName
    }
}

/// Skill provenance: user-created/installed, or bundled with the tool (plugin / .system / bundled /
/// builtin)
public enum SkillOrigin: String, Equatable, Sendable {
    case user      // created or installed by the user (editable, can be enabled/disabled)
    case bundled   // shipped with the tool (read-only; only for the detail matrix / cross-source checks)
}

/// A skill (Claude/Codex `SKILL.md`)
public struct SkillEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var source: AgentSource
    public var name: String
    public var description: String?
    public var path: String       // absolute path of SKILL.md
    public var directory: String  // absolute path of the skill directory
    public var enabled: Bool      // true in the enabled area; false in the *.eureka-disabled area
    public var scope: SkillScope  // system-level or project-level
    public var origin: SkillOrigin  // user-created or bundled with the tool
    public var sizeBytes: UInt64
    public var modifiedAt: Date

    public init(
        source: AgentSource, name: String, description: String?,
        path: String, directory: String, enabled: Bool,
        scope: SkillScope = .system,
        origin: SkillOrigin = .user,
        sizeBytes: UInt64, modifiedAt: Date
    ) {
        self.source = source
        self.name = name
        self.description = description
        self.path = path
        self.directory = directory
        self.enabled = enabled
        self.scope = scope
        self.origin = origin
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

/// A session a memory points at.
///
/// A Claude memory maps to one session (frontmatter `metadata.originSessionId`); Codex's
/// `MEMORY.md` is **one file aggregating many sessions** (one `thread_id=` per line in the body's
/// `### rollout_summary_files` section, 15 observed locally), so this must be multi-valued.
public struct MemorySessionRef: Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    /// Actual transcript path; nil = the record file is gone (greyed out in the UI, not navigable)
    public var path: String?
    public var exists: Bool { path != nil }

    public init(sessionId: String, path: String?) {
        self.sessionId = sessionId
        self.path = path
    }
}

public enum MemoryEntryKind: String, Equatable, Sendable {
    /// User-maintained persistent instructions such as CLAUDE.md / AGENTS.md.
    case instructions
    /// Memory documents the user created; normal create/edit/delete applies.
    case userManaged
    /// Local memory state Codex generates in the background; view-only.
    case generated
}

/// A memory/instruction file (CLAUDE.md / AGENTS.md / markdown under a memory directory)
public struct MemoryEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var source: AgentSource
    /// Display scope used for grouping: the global label / project name / file name. **Not a
    /// title**: dozens of memories in one project all carry the same project name here, so using it
    /// as the title would make the whole column identical (see `title`).
    public var scope: String
    public var path: String
    public var kind: MemoryEntryKind
    /// Owning project name; nil = system-level memory (global / user-created), non-nil = that
    /// project's memory
    public var projectName: String?
    public var sizeBytes: UInt64
    public var modifiedAt: Date
    /// Entry title: frontmatter `name` first, otherwise the file name (without extension)
    public var title: String
    /// frontmatter `description`
    public var summary: String?
    /// frontmatter `metadata.type`; `.other` when absent
    public var memoryType: MemoryType
    /// frontmatter `metadata.originSessionId`: the session this memory was born in
    public var originSessionId: String?
    /// Actual transcript path of the origin session; nil = session deleted (greyed out in the
    /// graph, not navigable)
    public var originSessionPath: String?
    /// **All** sessions this memory points at. Claude has 0/1 (equal to originSessionId); Codex's
    /// MEMORY.md aggregates many sessions, 15 observed locally. The UI shows a single button or a
    /// dropdown accordingly.
    public var relatedSessions: [MemorySessionRef]
    /// Raw `[[wiki link]]` text from the body (resolving them into edges happens in EurekaKit; the
    /// index layer only collects)
    public var links: [String]
    /// Set **only on the index file** (MEMORY.md): entry file names listed as markdown links in the
    /// body.
    /// Reconciling them with the files actually in the directory yields "dead memories nobody
    /// indexed" and "entries pointing at nothing".
    /// Not merged into `links`: the index would then draw dozens of contains edges in the graph,
    /// burying the reference edges that actually matter.
    public var indexedTargets: [String]
    /// Index file of the memory library (`<library>/MEMORY.md`)
    public var isIndex: Bool
    /// Owning memory library: `"<source>:<encoded-project-dir>"`; nil = not part of any memory
    /// library
    public var libraryKey: String?
    public var isEditable: Bool { kind != .generated }
    public var isDeletable: Bool { kind != .generated }

    /// Matchable aliases for `[[link]]`: file basename + frontmatter name
    public var linkAliases: [String] {
        let basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return [basename, title]
    }

    public init(
        source: AgentSource, scope: String, path: String,
        projectName: String? = nil,
        kind: MemoryEntryKind = .userManaged,
        sizeBytes: UInt64, modifiedAt: Date,
        title: String? = nil,
        summary: String? = nil,
        memoryType: MemoryType = .other,
        originSessionId: String? = nil,
        originSessionPath: String? = nil,
        relatedSessions: [MemorySessionRef] = [],
        links: [String] = [],
        indexedTargets: [String] = [],
        isIndex: Bool = false,
        libraryKey: String? = nil
    ) {
        self.source = source
        self.scope = scope
        self.path = path
        self.kind = kind
        self.projectName = projectName
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.title = title ?? URL(fileURLWithPath: path)
            .deletingPathExtension().lastPathComponent
        self.summary = summary
        self.memoryType = memoryType
        self.originSessionId = originSessionId
        self.originSessionPath = originSessionPath
        // Fold Claude's single-valued origin into the multi-valued list too; the UI reads only one
        // field
        self.relatedSessions = relatedSessions.isEmpty
            ? (originSessionId.map { [MemorySessionRef(sessionId: $0, path: originSessionPath)] } ?? [])
            : relatedSessions
        self.links = links
        self.indexedTargets = indexedTargets
        self.isIndex = isIndex
        self.libraryKey = libraryKey
    }
}

/// Scans Claude / Codex skill and memory files. Pure file IO and stateless, so it is easy to
/// unit-test (env overrides the path roots).
public enum SkillMemoryIndexer {
    private static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Path roots (EUREKA_* overrides, same convention as the other scanners)

    public static func claudeSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Project-level skill roots: `<root>/<agentDir>/skills` under each repo root (the Skills page
    /// and cloud backup share the same discovery rule).
    /// Extracted from the former inline logic in SkillMemoryService.refresh so SyncSourceCatalog
    /// can reuse it without drift.
    public static func projectSkillRoots(
        repoRoots: [(root: URL, name: String)]
    ) -> [ProjectScopedRoot] {
        var roots: [ProjectScopedRoot] = []
        for (root, name) in repoRoots {
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".claude/skills", isDirectory: true),
                source: .claude, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".codex/skills", isDirectory: true),
                source: .codex, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".opencode/skills", isDirectory: true),
                source: .opencode, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".grok/skills", isDirectory: true),
                source: .grok, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".gemini/skills", isDirectory: true),
                source: .gemini, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".kimi-code/skills", isDirectory: true),
                source: .kimi, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".qwen/skills", isDirectory: true),
                source: .qwen, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".cursor/skills", isDirectory: true),
                source: .cursor, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".codebuddy/skills", isDirectory: true),
                source: .codebuddy, projectName: name))
            roots.append(ProjectScopedRoot(
                root: root.appendingPathComponent(".qoder/skills", isDirectory: true),
                source: .qoder, projectName: name))
            roots.append(ProjectScopedRoot(
                root: TraePaths.projectSkillsRoot(repoRoot: root),
                source: .trae, projectName: name))
            for skillsRoot in ZcodePaths.projectSkillsRoots(repoRoot: root) {
                roots.append(ProjectScopedRoot(
                    root: skillsRoot, source: .zcode, projectName: name))
            }
        }
        return roots
    }

    public static func codexSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CODEX_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".codex/skills", isDirectory: true)
    }

    public static func claudeHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude", isDirectory: true)
    }

    public static func codexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".codex", isDirectory: true)
    }

    /// Disabled area (a sibling directory Eureka manages; non-destructive, reversible):
    /// ~/.claude/skills → ~/.claude/skills.eureka-disabled
    public static func disabledRoot(for skillsRoot: URL) -> URL {
        skillsRoot.deletingLastPathComponent()
            .appendingPathComponent(skillsRoot.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }

    /// Claude plugin skill roots (built-in/bundled):
    /// `~/.claude/plugins/cache/<marketplace>/<plugin>/[<version>/]skills`.
    /// The hierarchy may or may not include a version segment, so both levels are probed; returns
    /// every skills directory that exists.
    public static func claudePluginSkillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let fm = FileManager.default
        let cache = claudeHome(environment: environment)
            .appendingPathComponent("plugins/cache", isDirectory: true)
        func subdirs(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        var roots: [URL] = []
        func collect(_ dir: URL) {
            let skills = dir.appendingPathComponent("skills", isDirectory: true)
            if fm.fileExists(atPath: skills.path) { roots.append(skills) }
        }
        for marketplace in subdirs(cache) {
            for plugin in subdirs(marketplace) {
                collect(plugin)                       // plugin/skills (no version)
                for version in subdirs(plugin) { collect(version) }  // plugin/version/skills
            }
        }
        return roots
    }

    /// Normalizes a skill name for cross-source/stats matching: lowercase; for `plugin:skill` take
    /// the part after the colon.
    public static func normalizeSkillName(_ name: String) -> String {
        let lower = name.lowercased()
        if let colon = lower.lastIndex(of: ":") {
            return String(lower[lower.index(after: colon)...])
        }
        return lower
    }

    // MARK: - Skills

    public static func indexSkills(
        claudeSkillsRoot: URL, codexSkillsRoot: URL,
        /// `~/.codex/memories/skills`: Codex puts skills into that memories git repo too
        /// (`publish-draft-pr` observed locally). If it isn't collected here, the memory scan
        /// treats it as a "memory".
        codexMemorySkillsRoot: URL? = nil,
        opencodeSkillsRoot: URL? = nil,
        grokSkillsRoot: URL? = nil,
        kimiSkillsRoot: URL? = nil,
        geminiSkillsRoot: URL? = nil,
        qwenSkillsRoot: URL? = nil,
        antigravitySkillsRoots: [URL] = [],
        hermesSkillsRoot: URL? = nil,
        hermesDisabledSkills: Set<String> = [],
        cursorSkillsRoot: URL? = nil,
        codeBuddySkillsRoot: URL? = nil,
        qoderSkillsRoot: URL? = nil,
        /// zcode: skills live in the shared `~/.agents/skills` (SKILL.md has the same shape as
        /// Claude's)
        zcodeSkillsRoot: URL? = nil,
        /// Trae's **writable** skill roots, one per channel (`~/.trae-cn/skills`,
        /// `~/.trae/skills`). The read-only `builtin_skills` / `builtin/global/skills` go through
        /// `bundledRoots`.
        traeSkillsRoots: [URL] = [],
        projectSkillRoots: [ProjectScopedRoot] = [],
        bundledRoots: [(root: URL, source: AgentSource)] = []
    ) -> [SkillEntry] {
        var result: [SkillEntry] = []
        // System-level (user home root + disabled area)
        result += scanSkillRoot(claudeSkillsRoot, source: .claude, enabled: true, scope: .system)
        result += scanSkillRoot(
            disabledRoot(for: claudeSkillsRoot), source: .claude, enabled: false, scope: .system)
        result += scanSkillRoot(codexSkillsRoot, source: .codex, enabled: true, scope: .system)
        result += scanSkillRoot(
            disabledRoot(for: codexSkillsRoot), source: .codex, enabled: false, scope: .system)
        if let codexMemorySkillsRoot {
            result += scanSkillRoot(
                codexMemorySkillsRoot, source: .codex, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: codexMemorySkillsRoot), source: .codex, enabled: false,
                scope: .system)
        }
        if let opencodeSkillsRoot {
            result += scanSkillRoot(
                opencodeSkillsRoot, source: .opencode, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: opencodeSkillsRoot), source: .opencode, enabled: false, scope: .system)
        }
        if let grokSkillsRoot {
            result += scanSkillRoot(
                grokSkillsRoot, source: .grok, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: grokSkillsRoot), source: .grok, enabled: false, scope: .system)
        }
        if let kimiSkillsRoot {
            result += scanSkillRoot(
                kimiSkillsRoot, source: .kimi, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: kimiSkillsRoot), source: .kimi, enabled: false, scope: .system)
        }
        // cursor: ~/.cursor/skills (SKILL.md has the same shape as Claude's).
        // The sibling ~/.cursor/skills-cursor holds official built-in skills shipped with the
        // client that the user can't modify; not listed.
        if let cursorSkillsRoot {
            result += scanSkillRoot(
                cursorSkillsRoot, source: .cursor, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: cursorSkillsRoot), source: .cursor, enabled: false,
                scope: .system)
        }
        // gemini: ~/.gemini/skills (SKILL.md has the same shape as Claude's; Antigravity shares
        // this directory, so it is attributed to Gemini once to avoid listing it under both
        // sources)
        if let geminiSkillsRoot {
            result += scanSkillRoot(
                geminiSkillsRoot, source: .gemini, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: geminiSkillsRoot), source: .gemini, enabled: false, scope: .system)
        }
        // qwen: ~/.qwen/skills (SKILL.md has the same shape as Claude's)
        if let qwenSkillsRoot {
            result += scanSkillRoot(
                qwenSkillsRoot, source: .qwen, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: qwenSkillsRoot), source: .qwen, enabled: false, scope: .system)
        }
        // antigravity user-level skills ~/.gemini/antigravity/skills (**not** ~/.gemini/skills,
        // which is Gemini's and already attributed to gemini once); built-in builtin/skills go
        // through bundledRoots
        for root in antigravitySkillsRoots {
            result += scanSkillRoot(root, source: .antigravity, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: root), source: .antigravity, enabled: false, scope: .system)
        }
        // codebuddy: ~/.codebuddy/skills (SKILL.md has the same shape as Claude's, 23 observed
        // locally)
        if let codeBuddySkillsRoot {
            result += scanSkillRoot(
                codeBuddySkillsRoot, source: .codebuddy, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: codeBuddySkillsRoot), source: .codebuddy, enabled: false,
                scope: .system)
        }
        // qoder: ~/.qoder-cn/skills (same shape as codebuddy; Qoder is not installed on this
        // machine, so this is unverified)
        if let qoderSkillsRoot {
            result += scanSkillRoot(
                qoderSkillsRoot, source: .qoder, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: qoderSkillsRoot), source: .qoder, enabled: false, scope: .system)
        }
        // zcode: ~/.agents/skills (shared skill root; where the ZCode CLI desktop app installs
        // skills by default)
        if let zcodeSkillsRoot {
            result += scanSkillRoot(
                zcodeSkillsRoot, source: .zcode, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: zcodeSkillsRoot), source: .zcode, enabled: false, scope: .system)
        }
        // trae: `<dataFolder>/skills` (SKILL.md has the same shape as Claude's: frontmatter
        // name/description).
        // Both channels (CN / international) may be installed at once, so scan each; a same-named
        // skill shows up as two entries because they really are two apps' separate configs and must
        // not be counted as one.
        for root in traeSkillsRoots {
            result += scanSkillRoot(root, source: .trae, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: root), source: .trae, enabled: false, scope: .system)
        }
        // hermes: category directory tree; enabled state comes from config.yaml, not directory
        // location (see scanHermesSkillTree)
        if let hermesSkillsRoot {
            result += scanHermesSkillTree(
                hermesSkillsRoot, disabledNames: hermesDisabledSkills)
        }
        // Project-level (skills root under each project's cwd + disabled area)
        for project in projectSkillRoots {
            let scope = SkillScope.project(project.projectName)
            result += scanSkillRoot(
                project.root, source: project.source, enabled: true, scope: scope)
            result += scanSkillRoot(
                disabledRoot(for: project.root), source: project.source, enabled: false, scope: scope)
        }
        // Built-in/bundled roots (plugin / .system / bundled / builtin): read-only, tagged
        // origin=.bundled, no disabled area
        for bundled in bundledRoots {
            result += scanSkillRoot(
                bundled.root, source: bundled.source, enabled: true,
                scope: .system, origin: .bundled)
        }
        // Keep one entry per path (system-level is scanned first, so it wins): when a project root
        // coincides with a system root (e.g. a session ran in ~ and the repo root fell back to
        // home), the same SKILL.md is scanned twice, and since SkillEntry.id = path, duplicate ids
        // leave empty holes in SwiftUI's ForEach/LazyVGrid.
        var seenPaths = Set<String>()
        result = result.filter { seenPaths.insert($0.path).inserted }
        // Enabled first, then by name
        return result.sorted {
            ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    static func scanSkillRoot(
        _ root: URL, source: AgentSource, enabled: Bool,
        scope: SkillScope = .system, origin: SkillOrigin = .user
    ) -> [SkillEntry] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var result: [SkillEntry] = []
        for dir in dirs {
            let dirName = dir.lastPathComponent
            if dirName.hasPrefix(".") { continue }  // skip system directories such as .system
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let skillFile = dir.appendingPathComponent("SKILL.md")
            guard fm.fileExists(atPath: skillFile.path) else { continue }
            let values = try? skillFile.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let (name, desc) = parseFrontmatter(readHead(skillFile) ?? "")
            result.append(SkillEntry(
                source: source,
                name: name ?? dirName,
                description: desc,
                path: skillFile.path,
                directory: dir.path,
                enabled: enabled,
                scope: scope,
                origin: origin,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return result
    }

    /// Hermes skill tree scan: `skills/<category>/<name>/SKILL.md`, plus two other depths --
    /// `<category>/<subcategory>/<name>/` and top-level without a category -- so SKILL.md must be
    /// found **recursively** (`scanSkillRoot` only looks at direct children and can't cope).
    ///
    /// Enabled state ignores directories: Hermes uses `skills.disabled` in `config.yaml` (matched
    /// by frontmatter `name`), and moving a directory would break its `.bundled_manifest` md5
    /// bookkeeping → `disabledNames` is read by the caller (the app layer, which can also use
    /// EurekaInstall's HermesConfigEditor) and passed in.
    static func scanHermesSkillTree(
        _ root: URL, disabledNames: Set<String> = []
    ) -> [SkillEntry] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var result: [SkillEntry] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            // Support directories (a skill's own assets) and tool/cache directories never contain
            // standalone skills; prune the whole subtree
            if Self.hermesPrunedDirs.contains(name) {
                walker.skipDescendants()
                continue
            }
            guard name == "SKILL.md" else { continue }
            let dir = url.deletingLastPathComponent()
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let (frontName, desc) = parseFrontmatter(readHead(url) ?? "")
            let skillName = frontName ?? dir.lastPathComponent
            result.append(SkillEntry(
                source: .hermes,
                name: skillName,
                description: desc,
                path: url.path,
                directory: dir.path,
                enabled: !disabledNames.contains(skillName),
                scope: .system,     // Hermes has no project-level skills (only skills.external_dirs)
                origin: .user,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return result.sorted {
            ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Directories skipped wholesale while recursing: a skill's own asset directories +
    /// archive/cache/dependency directories
    private static let hermesPrunedDirs: Set<String> = [
        "references", "templates", "assets", "scripts",
        ".hub", ".archive", ".curator_backups", ".git", ".github",
        "venv", ".venv", "node_modules", "site-packages",
        "__pycache__", ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ]

    // MARK: - Memory

    public static func indexMemory(
        claudeHome: URL, codexHome: URL, opencodeHome: URL,
        claudeProjectsRoot: URL,
        grokMemoryRoot: URL? = nil,
        kimiHome: URL? = nil,
        geminiHome: URL? = nil,
        qwenHome: URL? = nil,
        hermesHome: URL? = nil,
        codeBuddyMemoryRoot: URL? = nil,
        qoderMemoriesRoot: URL? = nil,
        /// `~/.trae-cn/memory` (only the CN build has a memory library)
        traeMemoryRoot: URL? = nil,
        /// Trae's dotfile root per channel (`~/.trae-cn`, `~/.trae`). Hand-written user rules come
        /// in two coexisting forms:
        /// a single `<root>/user_rules.md` file (Trae's frontend calls it legacy) and a
        /// `<root>/user_rules/*.md` directory.
        traeRulesHomes: [URL] = [],
        projectRoots: [(root: URL, name: String)] = [],
        codexInstructionScopes: [(directory: URL, projectName: String, scope: String)] = []
    ) -> [MemoryEntry] {
        let fm = FileManager.default
        var result: [MemoryEntry] = []

        /// Non-nil `libraryKey` = this entry belongs to a memory library; `sessionRoot` = the
        /// session directory next to that library (`~/.claude/projects/<encoded>/`), used to check
        /// whether the origin session's transcript still exists.
        func add(
            _ url: URL, source: AgentSource, scope: String,
            projectName: String? = nil, kind: MemoryEntryKind = .userManaged,
            libraryKey: String? = nil, sessionRoot: URL? = nil,
            relatedSessions: [MemorySessionRef] = []
        ) {
            guard fm.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return }
            let isLibraryIndex = libraryKey != nil && url.lastPathComponent == "MEMORY.md"
            let document = parseMemoryDocument(url, markdownLinks: isLibraryIndex)
            let sessionId = document.fields["originsessionid"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var sessionPath: String?
            if let sessionId, !sessionId.isEmpty, let sessionRoot {
                let candidate = sessionRoot.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) { sessionPath = candidate.path }
            }
            result.append(MemoryEntry(
                source: source, scope: scope, path: url.path,
                projectName: projectName,
                kind: kind,
                sizeBytes: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                title: document.fields["name"].flatMap { $0.isEmpty ? nil : $0 },
                summary: document.fields["description"].flatMap { $0.isEmpty ? nil : $0 },
                memoryType: MemoryType(loose: document.fields["type"]),
                originSessionId: (sessionId?.isEmpty ?? true) ? nil : sessionId,
                originSessionPath: sessionPath,
                relatedSessions: relatedSessions,
                links: document.links,
                // Only the index file has its markdown links parsed (md links in an ordinary memory
                // body reference external docs, not "indexed" semantics)
                indexedTargets: isLibraryIndex ? document.indexedTargets : [],
                // Only a MEMORY.md inside a memory library is an index. Hermes's memories/MEMORY.md
                // is memory content it writes itself (not any library's table of contents), so the
                // check must include libraryKey.
                isIndex: isLibraryIndex,
                libraryKey: libraryKey))
        }

        /// Codex loads only the first existing file of override/AGENTS at each directory level.
        func addEffectiveCodexInstruction(
            directory: URL, scope: String, projectName: String? = nil
        ) {
            let override = directory.appendingPathComponent("AGENTS.override.md")
            let standard = directory.appendingPathComponent("AGENTS.md")
            if fm.fileExists(atPath: override.path) {
                add(override, source: .codex, scope: scope,
                    projectName: projectName, kind: .instructions)
            } else {
                add(standard, source: .codex, scope: scope,
                    projectName: projectName, kind: .instructions)
            }
        }

        // Claude global CLAUDE.md
        add(claudeHome.appendingPathComponent("CLAUDE.md"), source: .claude,
            scope: L10n.text("Global", zhHans: "全局"), kind: .instructions)
        // Claude user-level rules ~/.claude/rules/**/*.md (official: rules without paths: load
        // every session, rules with a paths: frontmatter load on demand when a file matches) →
        // instructions, scope = path relative to rules
        for rule in enumerateRules(claudeHome.appendingPathComponent("rules", isDirectory: true)) {
            add(rule.url, source: .claude, scope: rule.scope, kind: .instructions)
        }
        // Claude ~/.claude/memories/**/*.md (user-created memories)
        for file in enumerateMarkdown(claudeHome.appendingPathComponent("memories", isDirectory: true)) {
            add(file, source: .claude, scope: file.deletingPathExtension().lastPathComponent)
        }
        // Claude project memory libraries: projects/<encoded>/memory/**/*.md (MEMORY.md = that
        // library's index)
        let projectDirs = ((try? fm.contentsOfDirectory(
            at: claudeProjectsRoot, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for proj in projectDirs {
            let memDir = proj.appendingPathComponent("memory", isDirectory: true)
            guard fm.fileExists(atPath: memDir.path) else { continue }
            let projName = resolveProjectName(
                projectDir: proj, knownRoots: projectRoots)
            for file in enumerateMarkdown(memDir) {
                add(file, source: .claude, scope: projName, projectName: projName,
                    libraryKey: "claude:\(proj.lastPathComponent)", sessionRoot: proj)
            }
        }

        // Codex global persistent instructions: AGENTS.override.md takes precedence over AGENTS.md.
        addEffectiveCodexInstruction(directory: codexHome, scope: L10n.text("Global", zhHans: "全局"))
        // Codex memory = the **top-level** md files of `~/.codex/memories/` (observed as a
        // three-stage pipeline: raw_memories.md → MEMORY.md → memory_summary.md), generated in the
        // background, view-only.
        //
        // **Top level only, never recurse**: this directory is a git repo Codex created, mixing in
        // three kinds of non-memory content -- `rollout_summaries/` (per-session summaries, the
        // evidence attachments for MEMORY.md), `extensions/` (meta-instructions teaching Codex how
        // to maintain memory), `skills/` (**skills**, see codexMemorySkillsRoot in indexSkills).
        // Recursing would count all 20 files as memories, 17 of which are not.
        for file in enumerateMarkdownShallow(
            codexHome.appendingPathComponent("memories", isDirectory: true)) {
            // Codex has no frontmatter; session ownership is written in the body's
            // rollout_summary_files section
            let refs = readHead(file, bytes: 262_144).map(extractCodexSessionRefs) ?? []
            add(file, source: .codex,
                scope: file.deletingPathExtension().lastPathComponent, kind: .generated,
                relatedSessions: refs)
        }

        // opencode global AGENTS.md (~/.config/opencode/AGENTS.md, following the AGENTS.md
        // standard)
        add(opencodeHome.appendingPathComponent("AGENTS.md"), source: .opencode,
            scope: L10n.text("Global", zhHans: "全局"), kind: .instructions)
        // opencode memories/**/*.md (createMemory writes here; the index must match to avoid dead
        // paths)
        for file in enumerateMarkdown(opencodeHome.appendingPathComponent("memories", isDirectory: true)) {
            add(file, source: .opencode, scope: file.deletingPathExtension().lastPathComponent)
        }

        // grok cross-session memory ~/.grok/memory/**/*.md (experimental feature; the directory may
        // not exist)
        if let grokMemoryRoot {
            for file in enumerateMarkdown(grokMemoryRoot) {
                add(file, source: .grok, scope: file.deletingPathExtension().lastPathComponent)
            }
        }

        // kimi global memory ~/.kimi-code/AGENTS.md (Kimi's only global memory file,
        // AGENTS.md-first)
        if let kimiHome {
            add(kimiHome.appendingPathComponent("AGENTS.md"), source: .kimi,
                scope: L10n.text("Global", zhHans: "全局"), kind: .instructions)
        }

        // gemini global memory ~/.gemini/GEMINI.md (GEMINI.md-first)
        if let geminiHome {
            add(geminiHome.appendingPathComponent("GEMINI.md"), source: .gemini,
                scope: L10n.text("Global", zhHans: "全局"), kind: .instructions)
        }

        // qwen: global memories/*.md + project-level projects/<encoded>/memory/**/*.md
        // (Claude-style layout)
        if let qwenHome {
            for file in enumerateMarkdown(
                qwenHome.appendingPathComponent("memories", isDirectory: true)) {
                add(file, source: .qwen, scope: file.deletingPathExtension().lastPathComponent)
            }
            let qwenProjects = ((try? fm.contentsOfDirectory(
                at: qwenHome.appendingPathComponent("projects", isDirectory: true),
                includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for proj in qwenProjects {
                let memDir = proj.appendingPathComponent("memory", isDirectory: true)
                guard fm.fileExists(atPath: memDir.path) else { continue }
                let projName = resolveProjectName(
                    projectDir: proj, knownRoots: projectRoots)
                for file in enumerateMarkdown(memDir) {
                    add(file, source: .qwen, scope: projName, projectName: projName,
                        libraryKey: "qwen:\(proj.lastPathComponent)", sessionRoot: proj)
                }
            }
        }

        // hermes: three profile-level instruction files, **no notion of project-level memory**.
        //   memories/MEMORY.md = agent's own notes, memories/USER.md = user profile,
        //   SOUL.md = persona identity.
        // MEMORY/USER bodies use a flat format of "entries joined by \n§\n" with character caps
        //   (2200 / 1375); an external edit that breaks the format or exceeds the cap trips Hermes's
        //   drift protection: it saves a .bak and then **refuses further writes**.
        if let hermesHome {
            let memories = hermesHome.appendingPathComponent("memories", isDirectory: true)
            // MEMORY / USER are **memories the agent writes itself** (not user-maintained
            // instructions) → Memory; SOUL is the persona identity setting, equivalent to a system
            // prompt → Instructions.
            add(memories.appendingPathComponent("MEMORY.md"), source: .hermes,
                scope: "MEMORY", kind: .userManaged)
            add(memories.appendingPathComponent("USER.md"), source: .hermes,
                scope: "USER", kind: .userManaged)
            add(hermesHome.appendingPathComponent("SOUL.md"), source: .hermes,
                scope: "SOUL", kind: .instructions)
        }

        // codebuddy global memory ~/.codebuddy/memery/**/*.md (the official spelling really is
        // memery; don't "fix" it)
        if let codeBuddyMemoryRoot {
            for file in enumerateMarkdown(codeBuddyMemoryRoot) {
                add(file, source: .codebuddy,
                    scope: file.deletingPathExtension().lastPathComponent)
            }
        }

        // qoder global memory memories/<user-hash>/global/<category>/**/*.md:
        // scope is the category path relative to global/ (falls back to the file name when there is
        // no category)
        if let qoderMemoriesRoot {
            for file in enumerateMarkdown(qoderMemoriesRoot) {
                add(file, source: .qoder,
                    scope: qoderMemoryScope(file: file, root: qoderMemoriesRoot))
            }
        }

        // trae memory library (**CN build only**):
        //   memory/user_profile.md                        ← global user profile
        //   memory/projects/<encoded>/project_memory.md   ← project memory
        //   memory/projects/<encoded>/<YYYYMMDD>/topics.md ← daily session topic summary (read-only log)
        // All three are written by Trae itself → **Memory**; hand-written user rules go to
        // **Instructions** separately below.
        // `session_memory_<id>.jsonl` is not collected: it is a per-turn log, and not markdown.
        if let traeMemoryRoot {
            add(traeMemoryRoot.appendingPathComponent("user_profile.md"),
                source: .trae, scope: L10n.text("Global", zhHans: "全局"), kind: .userManaged)
            let projectsRoot = traeMemoryRoot
                .appendingPathComponent("projects", isDirectory: true)
            for projectDir in subdirectories(of: projectsRoot) {
                let projectName = resolveTraeProjectName(
                    projectDir: projectDir, knownRoots: projectRoots)
                let libraryKey = "trae:\(projectDir.lastPathComponent)"
                add(projectDir.appendingPathComponent("project_memory.md"),
                    source: .trae, scope: projectName, projectName: projectName,
                    kind: .userManaged, libraryKey: libraryKey)
                for dayDir in subdirectories(of: projectDir) {
                    let topics = dayDir.appendingPathComponent("topics.md")
                    // Which sessions this summary covers. path is always nil -- Trae has no
                    // navigable transcript file, so the UI greys them out (same as the CLAUDE.md
                    // rule "grey out when originSessionPath == nil").
                    let refs = TraeSessionIndexer.parseTopics(fileURL: topics)
                        .map { MemorySessionRef(sessionId: $0.sessionId, path: nil) }
                    add(topics, source: .trae,
                        scope: "\(projectName) · \(dayDir.lastPathComponent)",
                        projectName: projectName, kind: .generated,
                        libraryKey: libraryKey, relatedSessions: refs)
                }
            }
        }

        // trae hand-written user rules → **Instructions** (each channel has its own set; scope uses
        // the dotfile directory name to tell them apart)
        for home in traeRulesHomes {
            let scope = home.lastPathComponent
            add(home.appendingPathComponent("user_rules.md"),
                source: .trae, scope: scope, kind: .instructions)
            for file in enumerateMarkdown(
                home.appendingPathComponent("user_rules", isDirectory: true)) {
                add(file, source: .trae,
                    scope: "\(scope) · \(file.deletingPathExtension().lastPathComponent)",
                    kind: .instructions)
            }
        }

        // trae project rules <repo>/.trae/rules/*.md (including the old single-file name
        // project_rules.md) → Instructions
        for (root, name) in projectRoots {
            for file in enumerateMarkdown(TraePaths.projectRulesRoot(repoRoot: root)) {
                add(file, source: .trae,
                    scope: file.deletingPathExtension().lastPathComponent,
                    projectName: name, kind: .instructions)
            }
        }

        // cursor project rules <repo>/.cursor/rules/*.mdc (the convention from the official
        // create-rule skill): this is Cursor's only local "memory" form -- it has no global memory
        // directory; `cursor/memoriesEnabled` refers to server-side memory. .mdc is just markdown
        // with YAML frontmatter, collected separately by extension.
        for (root, name) in projectRoots {
            let rulesDir = root.appendingPathComponent(".cursor/rules", isDirectory: true)
            for file in enumerateFiles(rulesDir, extensions: ["mdc", "md"]) {
                add(file, source: .cursor,
                    scope: file.deletingPathExtension().lastPathComponent,
                    projectName: name, kind: .instructions)
            }
        }

        // Project-root memory (convention files under each repo root): CLAUDE.md→Claude,
        // GEMINI.md→Gemini, AGENTS.md shared by Codex/opencode/Kimi (attributed to Codex once to
        // avoid duplicates); .kimi-code/AGENTS.md is Kimi's own project-level override, attributed
        // to Kimi separately
        for (root, name) in projectRoots {
            add(root.appendingPathComponent("CLAUDE.md"), source: .claude,
                scope: name, projectName: name, kind: .instructions)
            // Claude project rules <repo>/.claude/rules/**/*.md (same as user-level; officially a
            // shared rules directory can be mounted into a project via symlink, so enumeration
            // follows links and guards against cycles)
            for rule in enumerateRules(root.appendingPathComponent(".claude/rules", isDirectory: true)) {
                add(rule.url, source: .claude, scope: rule.scope,
                    projectName: name, kind: .instructions)
            }
            add(root.appendingPathComponent("GEMINI.md"), source: .gemini,
                scope: name, projectName: name, kind: .instructions)
            add(root.appendingPathComponent("QWEN.md"), source: .qwen,
                scope: name, projectName: name, kind: .instructions)
            add(root.appendingPathComponent(".kimi-code/AGENTS.md"),
                source: .kimi, scope: name, projectName: name, kind: .instructions)
        }

        // Codex project instructions are discovered only along the root → cwd chain of actual
        // recent cwds; project roots are always included.
        var codexScopes = codexInstructionScopes
        codexScopes.append(contentsOf: projectRoots.map {
            (directory: $0.root, projectName: $0.name, scope: $0.name)
        })
        var seenInstructionDirs = Set<String>()
        for item in codexScopes where seenInstructionDirs.insert(item.directory.path).inserted {
            addEffectiveCodexInstruction(
                directory: item.directory, scope: item.scope, projectName: item.projectName)
        }

        // Keep one entry per path: MemoryEntry.id = path, and duplicate ids likewise misalign
        // SwiftUI lists/grids.
        var seenPaths = Set<String>()
        result = result.filter { seenPaths.insert($0.path).inserted }
        return result.sorted {
            ($0.source.rawValue, $0.scope, $0.path) < ($1.source.rawValue, $1.scope, $1.path)
        }
    }

    /// Enumerates by extension (Cursor rules are `.mdc`, a markdown variant with YAML frontmatter;
    /// `enumerateMarkdown` only recognizes `.md` and would miss them entirely)
    static func enumerateFiles(_ dir: URL, extensions: [String]) -> [URL] {
        let fm = FileManager.default
        let wanted = Set(extensions.map { $0.lowercased() })
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator
        where wanted.contains(url.pathExtension.lowercased()) {
            files.append(url)
        }
        return files
    }

    /// Markdown files that are **direct children only** (no descent into subdirectories).
    /// Used for Codex's memories directory: it is a git repo mixing memories/session
    /// summaries/extensions/skills, so recursing picks up the wrong files.
    /// Direct subdirectories (sorted by name so a single scan's result is stable)
    static func subdirectories(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Project name for a Trae memory library. Directory names are `<forward-encoded
    /// path>--p<N>-<hash>`, one suffix more than Claude's, so strip the suffix first, then use the
    /// same "forward-encode known roots and compare" logic (`-` can't be reversed, see CLAUDE.md).
    static func resolveTraeProjectName(
        projectDir: URL, knownRoots: [(root: URL, name: String)]
    ) -> String {
        let encoded = projectDir.lastPathComponent
        let stripped = TraeSessionIndexer.stripProjectSuffix(encoded)
        for (root, name) in knownRoots {
            let candidate = encodeProjectDirName(root.standardizedFileURL.path)
            if candidate == stripped || candidate == encoded { return name }
        }
        // No match: fall back to the lossy last-segment heuristic -- but on the string **after the
        // suffix is stripped**, otherwise the last segment would be the hash (`friendlyProject`
        // takes only the last segment).
        return friendlyProject(fromEncoded: stripped)
    }

    static func enumerateMarkdownShallow(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func enumerateMarkdown(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            files.append(url)
        }
        return files
    }

    /// Claude rules directory enumeration (official `.claude/rules/`: .md discovered recursively;
    /// directories may be symlinks, used to mount one shared rule set into several projects; cycles
    /// must be handled). `enumerateMarkdown`'s FileManager.enumerator doesn't descend into
    /// symlinked directories, so recursion is hand-written here: follow links, block cycles with a
    /// set of visited **real paths**, skip broken links.
    /// Listing must use the path-based `contentsOfDirectory(atPath:)` with the real path -- the URL
    /// version returns nothing for a "symlink pointing at a directory" (measured), while the path
    /// version goes through opendir and follows it. Child URLs are still built on the **logical**
    /// path: entry path and scope both use the name the user sees in the project
    /// (`shared/security`), never exposing the link target.
    static func enumerateRules(_ dir: URL) -> [(url: URL, scope: String)] {
        let fm = FileManager.default
        var visited = Set<String>()
        var result: [(url: URL, scope: String)] = []
        func walk(_ directory: URL, prefix: String) {
            let real = directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard !visited.contains(real) else { return }
            visited.insert(real)
            let names = ((try? fm.contentsOfDirectory(atPath: real)) ?? [])
                .filter { !$0.hasPrefix(".") }
                .sorted()
            for name in names {
                let child = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                // fileExists follows symlinks: linked directories are walked as directories, broken
                // links are skipped
                guard fm.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    walk(child, prefix: prefix + name + "/")
                } else if child.pathExtension.lowercased() == "md" {
                    result.append((child, prefix + child.deletingPathExtension().lastPathComponent))
                }
            }
        }
        walk(dir, prefix: "")
        return result
    }

    /// Display scope of a qoder memory: path relative to the memories root, without extension;
    /// strips the <user-hash>/global/ prefix, leaving <category>/<name> (returned as-is without
    /// that prefix)
    static func qoderMemoryScope(file: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        var rel = file.deletingPathExtension().standardizedFileURL.path
        if rel.hasPrefix(rootPath + "/") {
            rel = String(rel.dropFirst(rootPath.count + 1))
        }
        if rel.hasPrefix("global/") {
            rel = String(rel.dropFirst("global/".count))
        } else if let range = rel.range(of: "/global/") {
            rel = String(rel[range.upperBound...])
        }
        return rel
    }

    /// Claude encodes the cwd's "/" as "-"; take the last segment as the project name.
    /// **Lossy**: `aftership-semantic-layer` gets cut down to `layer` -- only a fallback when
    /// reverse lookup fails entirely.
    static func friendlyProject(fromEncoded encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        return parts.last.map(String.init) ?? encoded
    }

    /// Claude / Qwen project directory name encoding (verified against all 11 local dirs): `/`,
    /// `.`, and `_` **all** become `-`.
    /// Many-to-one and irreversible -- so project names can only be matched by forward-encoding
    /// known paths, never by splitting the string backwards.
    public static func encodeProjectDirName(_ path: String) -> String {
        var encoded = ""
        for character in path {
            encoded.append(character == "/" || character == "." || character == "_" ? "-" : character)
        }
        return encoded
    }

    /// Project name of a memory library:
    ///  1. Forward-encode each known repo root and compare it for exact equality with the
    ///     directory name (on a match, use that root's name);
    ///  2. otherwise read the head of the newest `*.jsonl` in that directory for the real cwd and
    ///     take its last path component;
    ///  3. only if both fail, fall back to the lossy last-segment heuristic.
    /// The encoding is many-to-one, so in theory several roots could match one directory name --
    /// take the first in `knownRoots` (the caller sorts by recent activity), keeping a single
    /// scan's result stable.
    static func resolveProjectName(
        projectDir: URL, knownRoots: [(root: URL, name: String)]
    ) -> String {
        let encoded = projectDir.lastPathComponent
        for (root, name) in knownRoots
        where encodeProjectDirName(root.standardizedFileURL.path) == encoded {
            return name
        }
        if let cwd = newestSessionCwd(in: projectDir), !cwd.isEmpty {
            let last = URL(fileURLWithPath: cwd).standardizedFileURL.lastPathComponent
            if !last.isEmpty { return last }
        }
        return friendlyProject(fromEncoded: encoded)
    }

    /// cwd recorded in the head of the most recently modified transcript in the directory
    /// (`ClaudeSessionIndexer.headInfo` is available in the same module).
    /// Reads only one file: this is the fallback for project-name lookup and not worth another full
    /// session scan.
    static func newestSessionCwd(in projectDir: URL) -> String? {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        let newest = files.max {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return lhs < rhs
        }
        guard let newest else { return nil }
        return ClaudeSessionIndexer.headInfo(fileURL: newest).cwd
    }

    // MARK: - Memory document parsing (frontmatter + wiki links in the body)

    /// Reads the file once (capped at 64KB) to get frontmatter key/values and body `[[links]]`.
    /// The cap can't reuse `readHead`'s 8KB: the memory library index MEMORY.md measured 11.8KB
    /// with all links in the body, and 8KB would swallow the entire second half of the links.
    static func parseMemoryDocument(
        _ url: URL, bytes: Int = 65536, markdownLinks: Bool = false
    ) -> (fields: [String: String], links: [String], indexedTargets: [String]) {
        guard let text = readHead(url, bytes: bytes) else { return ([:], [], []) }
        return (
            parseFrontmatterFields(text),
            extractWikiLinks(text),
            markdownLinks ? extractMarkdownLinks(text) : [])
    }

    /// Session references in the body of Codex's `MEMORY.md`.
    ///
    /// It has no frontmatter; project and session ownership is written in the body's
    /// `### rollout_summary_files` section, one line each, shaped like:
    /// ```
    /// - rollout_summaries/2026-07-27T…-xxx.md (cwd=…, rollout_path=/Users/…/rollout-….jsonl,
    ///   updated_at=…, thread_id=019fa2f0-c124-7c03-a2d1-c6debaf69293, <status description>)
    /// ```
    /// `thread_id=` is the session id and `rollout_path=` tells whether the record still exists
    /// (all 15 observed locally are reachable, far more reliable than Claude's `originSessionId`
    /// at 37/84).
    ///
    /// **Don't attribute projects by `cwd=`**: one observed entry points at
    /// `~/.slock/agents/<uuid>` (a sandbox working directory rather than a repo root); attributing
    /// by it would invent a nonexistent project.
    public static func extractCodexSessionRefs(_ text: String) -> [MemorySessionRef] {
        let fm = FileManager.default
        var refs: [MemorySessionRef] = []
        var seen = Set<String>()
        for rawLine in text.components(separatedBy: "\n") {
            guard let idValue = value(of: "thread_id=", in: rawLine), !idValue.isEmpty,
                  seen.insert(idValue).inserted
            else { continue }
            let path = value(of: "rollout_path=", in: rawLine)
            let existing = path.flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
            refs.append(MemorySessionRef(sessionId: idValue, path: existing))
        }
        return refs
    }

    /// Value of `key=value`, ending at a comma / closing paren / whitespace
    private static func value(of key: String, in line: String) -> String? {
        guard let start = line.range(of: key) else { return nil }
        let rest = line[start.upperBound...]
        let end = rest.firstIndex { $0 == "," || $0 == ")" || $0 == " " } ?? rest.endIndex
        let value = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Target of a markdown link (`[title](feedback_push.md)` → `feedback_push.md`).
    ///
    /// Only for the **memory library index** (MEMORY.md): Claude's index body is "one markdown link
    /// per line", which is the only way to find "memory files the index never includes" -- the
    /// agent can't read those entries at all (observed in 2 of 72 in the semantic-layer library).
    /// Only `.md` targets are collected; external links and images are skipped.
    public static func extractMarkdownLinks(_ text: String) -> [String] {
        let characters = Array(text)
        var targets: [String] = []
        var seen = Set<String>()
        var index = 0
        while index + 1 < characters.count {
            // Find "](" -- the boundary between link text and target
            guard characters[index] == "]", characters[index + 1] == "(" else {
                index += 1
                continue
            }
            var cursor = index + 2
            var buffer = ""
            var closed = false
            while cursor < characters.count {
                if characters[cursor] == ")" { closed = true; break }
                if characters[cursor] == "\n" || buffer.count > 300 { break }
                buffer.append(characters[cursor])
                cursor += 1
            }
            index = closed ? cursor + 1 : index + 1
            guard closed else { continue }
            // Drop the anchor/query string; .md only
            let target = buffer.trimmingCharacters(in: .whitespaces)
                .split(separator: "#").first.map(String.init) ?? ""
            guard target.lowercased().hasSuffix(".md"),
                  !target.contains("://"),
                  seen.insert(target.lowercased()).inserted
            else { continue }
            targets.append(target)
        }
        return targets
    }

    /// `[[target]]` in the body. Anything spanning lines or overlong (>120 chars) doesn't count --
    /// that's usually the body using `[[…]]` as emphasis (2 of 115 links observed locally), and
    /// treating it as a link would invent false edges.
    public static func extractWikiLinks(_ text: String) -> [String] {
        let characters = Array(text)
        var links: [String] = []
        var seen = Set<String>()
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "[", characters[index + 1] == "[" else {
                index += 1
                continue
            }
            var cursor = index + 2
            var buffer = ""
            var closed = false
            while cursor + 1 < characters.count {
                if characters[cursor] == "]", characters[cursor + 1] == "]" {
                    closed = true
                    break
                }
                if characters[cursor] == "\n" || buffer.count > 120 { break }
                buffer.append(characters[cursor])
                cursor += 1
            }
            guard closed else {
                index += 1
                continue
            }
            let value = buffer.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, seen.insert(value.lowercased()).inserted { links.append(value) }
            index = cursor + 2
        }
        return links
    }

    // MARK: - frontmatter parsing (pure functions, unit-test targets)

    /// name / description from the file's leading `---` … `---` YAML block (simple key: value).
    public static func parseFrontmatter(_ text: String) -> (name: String?, description: String?) {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, nil)
        }
        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }  // end of frontmatter
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\"")
                || (value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "name": name = value.isEmpty ? nil : value
            case "description": description = value.isEmpty ? nil : value
            default: break
            }
        }
        return (name, description)
    }

    /// Parses all simple key/values in the frontmatter (reused by agent definitions etc.).
    /// Supports: single-line `key: value` (quotes stripped); block scalars (`key: |` / `key: >`,
    /// absorbing the following more-indented lines).
    /// Nested maps / complex YAML are not parsed -- anything beyond is ignored. Keys are
    /// lowercased.
    ///
    /// **Child keys of a nested map are collected as top-level keys** (`type` / `originSessionId`
    /// under `metadata:` appear directly in the result). Memory indexing **intentionally** relies
    /// on this to get `metadata.*`: don't "fix" it into strict YAML, or MemoryEntry's type and
    /// origin session would all go empty.
    public static func parseFrontmatterFields(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }  // end of frontmatter
            index += 1
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.first == "|" || value.first == ">" {
                // block scalar: absorb following more-indented lines until a 0-indent key or ---
                let fold = value.first == ">"
                var block: [String] = []
                while index < lines.count {
                    let line = lines[index]
                    let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
                    if lineTrimmed == "---" { break }
                    if lineTrimmed.isEmpty { block.append(""); index += 1; continue }
                    let leading = line.prefix { $0 == " " || $0 == "\t" }.count
                    if leading == 0 { break }  // back to a top-level key; block ends
                    block.append(lineTrimmed)
                    index += 1
                }
                value = block.joined(separator: fold ? " " : "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if value.count >= 2,
                      (value.first == "\"" && value.last == "\"")
                        || (value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    static func readHead(_ url: URL, bytes: Int = 8192) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path),
              let data = try? handle.read(upToCount: bytes) else { return nil }
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    }
}
