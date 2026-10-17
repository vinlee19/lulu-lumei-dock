import Foundation

/// Trae's **two installs**: CN and international are independent apps whose data dirs never
/// share anything, but Eureka merges them into one source `.trae` (one brand, two channels).
///
/// | | dotfile dir | Application Support |
/// |---|---|---|
/// | CN (observed 3.3.84) | `~/.trae-cn` | `~/Library/Application Support/Trae CN` |
/// | International (observed 3.5.35) | `~/.trae` | `~/Library/Application Support/Trae` |
///
/// The names come from each `product.json`'s `dataFolderName` / `nameShort`, not guesswork.
///
/// **Capability differences** (observed on this machine; don't assume the two are symmetric):
/// - hooks: **CN only** - only CN's `libai_agent.dylib` contains
///   `src/domain/hooks/{config/parser,executor/*,instance/trigger}.rs`;
/// - memory library: **CN only** (`~/.trae-cn/memory`);
/// - skills / rules / plans: both.
///
/// ⚠️ **Session bodies, tokens and rate limits are never available.** Every session lives in
/// a single database `<appSupport>/ModularData/ai-agent/database.db`, which is SQLCipher
/// encrypted (the first 16 bytes are a random salt; `sqlite3` reports "file is not a
/// database"), and there is no plaintext transcript anywhere on the machine. Session
/// titles/times can only be inferred from the plaintext memory library (see
/// `TraeSessionIndexer`); live activity comes only from hooks (see `TraeHooksInstaller`).
///
/// ⚠️ **Credential red line.** `<dataFolder>/trae-jwt-token` is a JWT, `<dataFolder>/mcp.json`
/// may carry API keys, and `<appSupport>/{Cookies,ModularData/ai-agent/database.db}` hold auth
/// and session content. **Any walk may only enter the sub-roots this file spells out; never
/// walk `dataFolder` or `appSupport` itself** (same nature as the Cursor `state.vscdb` rule
/// in CLAUDE.md).
public enum TraePaths {
    /// The two release channels. CN comes first: it is the more capable one (hooks and the
    /// memory library exist only there).
    public enum Channel: String, CaseIterable, Sendable {
        case cn
        case intl

        /// Dotfile dir name under home (= product.json's `dataFolderName`)
        var dotDirName: String {
            switch self {
            case .cn: return ".trae-cn"
            case .intl: return ".trae"
            }
        }

        /// Dir name under Application Support (= product.json's `nameShort`)
        var appSupportDirName: String {
            switch self {
            case .cn: return "Trae CN"
            case .intl: return "Trae"
            }
        }

        /// Command-line launcher (both live in `/usr/local/bin`, installed by the client itself)
        public var cliCommand: String {
            switch self {
            case .cn: return "trae-cn"
            case .intl: return "trae"
            }
        }

        var homeEnvKey: String {
            switch self {
            case .cn: return "EUREKA_TRAE_HOME"
            case .intl: return "EUREKA_TRAE_INTL_HOME"
            }
        }

        var appSupportEnvKey: String {
            switch self {
            case .cn: return "EUREKA_TRAE_APP_SUPPORT"
            case .intl: return "EUREKA_TRAE_INTL_APP_SUPPORT"
            }
        }
    }

    // MARK: - The two roots

    /// Dotfile home (env `EUREKA_TRAE_HOME` / `EUREKA_TRAE_INTL_HOME` > `~/.trae-cn` / `~/.trae`)
    public static func configHome(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment[channel.homeEnvKey], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(channel.dotDirName, isDirectory: true)
    }

    /// Application Support home (IDE state and the encrypted session DB live under it)
    public static func appSupportHome(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment[channel.appSupportEnvKey], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/\(channel.appSupportDirName)", isDirectory: true)
    }

    /// Which channels are actually installed. The test is that the dotfile dir exists; a
    /// channel overridden via env **always counts as installed** (tests run entirely in temp
    /// dirs and must not be filtered out because the dir name looks wrong).
    public static func installedChannels(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [Channel] {
        Channel.allCases.filter { channel in
            if let custom = environment[channel.homeEnvKey], !custom.isEmpty { return true }
            return fileManager.fileExists(
                atPath: configHome(channel, environment: environment).path)
        }
    }

    // MARK: - hooks (CN only)

    /// Global hooks config `~/.trae-cn/hooks.json`. Path source: Trae's frontend asset table
    /// `{assetType:"hook",projectRelPath:".trae/hooks.json", globalRelPath:"hooks.json"}`, where
    /// the global root = `pathService.userHome` + `productService.dataFolderName` (= `.trae-cn`).
    public static func hooksConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(.cn, environment: environment)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    /// Project-level hooks config `<repo>/.trae/hooks.json` (this app only reads it for
    /// diagnostics, never edits it)
    public static func projectHooksConfig(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/hooks.json", isDirectory: false)
    }

    // MARK: - Skills

    /// User skills root `<dataFolder>/skills/<name>/SKILL.md` (standard Claude-style layout:
    /// YAML frontmatter `name` / `description` + body)
    public static func skillsRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Built-in skills root `<dataFolder>/builtin_skills` (`TRAE-code-review` etc., shipped with
    /// the client → read-only)
    public static func builtinSkillsRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("builtin_skills", isDirectory: true)
    }

    /// A second built-in skills root `<dataFolder>/builtin/global/skills` (`TRAE-computer-use`
    /// etc.; coexists with `builtin_skills` with different contents - scan both, scanning only
    /// one misses half)
    public static func builtinGlobalSkillsRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("builtin/global/skills", isDirectory: true)
    }

    /// Project-level skills root `<repo>/.trae/skills`
    public static func projectSkillsRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/skills", isDirectory: true)
    }

    /// **Writable** user skills roots across all installed channels (new skills go here)
    public static func userSkillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        installedChannels(environment: environment, fileManager: fileManager)
            .map { skillsRoot($0, environment: environment) }
    }

    /// **Read-only** built-in skills roots across all installed channels (both builtin
    /// layouts included)
    public static func bundledSkillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        installedChannels(environment: environment, fileManager: fileManager)
            .flatMap {
                [
                    builtinSkillsRoot($0, environment: environment),
                    builtinGlobalSkillsRoot($0, environment: environment),
                ]
            }
    }

    // MARK: - Memory library (CN only)

    /// Memory library root `~/.trae-cn/memory`
    public static func memoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(.cn, environment: environment)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// Global user profile `~/.trae-cn/memory/user_profile.md` (written by Trae itself →
    /// memory, not instructions)
    public static func userProfileFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        memoryRoot(environment: environment)
            .appendingPathComponent("user_profile.md", isDirectory: false)
    }

    /// Project memory root `~/.trae-cn/memory/projects`.
    /// Subdir names look like `-Users-wl-xiao-vinlee-workspace-lerobot--p2-832ae42141a2828b9304`
    /// - slash encoding + a `--p<N>-<hash>` suffix, **lossy just like Claude's** (a `-` may come
    /// from `/`, `.`/`_`, or an original hyphen), so the only way is to encode known repo roots
    /// forward and match.
    public static func memoryProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        memoryRoot(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    // MARK: - Instructions (user-written rules)

    /// Global user rules single file `<dataFolder>/user_rules.md` (Trae's frontend calls it
    /// `legacyUserRuleFilePath`)
    public static func userRulesFile(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("user_rules.md", isDirectory: false)
    }

    /// Global user rules dir `<dataFolder>/user_rules/*.md` (newer layout, coexists with the
    /// single file)
    public static func userRulesDir(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("user_rules", isDirectory: true)
    }

    /// Project rules dir `<repo>/.trae/rules/*.md` (includes the old single-file name
    /// `project_rules.md`)
    public static func projectRulesRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/rules", isDirectory: true)
    }

    // MARK: - Plans

    /// Plan documents dir `<repo>/.trae/documents` (`plan_<yyyyMMdd>_<HHmmss>.md`, already
    /// markdown)
    public static func projectDocumentsRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/documents", isDirectory: true)
    }

    // MARK: - IDE state (only used to resolve cwd, never backed up)

    /// Workspace storage root `<appSupport>/User/workspaceStorage`
    /// (one hash dir per workspace; the `folder` field of `workspace.json` = cwd)
    public static func workspaceStorageRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        appSupportHome(channel, environment: environment)
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }

    /// Workspace storage roots across all installed channels. **Reads only one field of
    /// `workspace.json`** (cwd lookup); the sibling `state.vscdb` is never touched and never
    /// backed up.
    public static func workspaceStorageRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        installedChannels(environment: environment, fileManager: fileManager)
            .map { workspaceStorageRoot($0, environment: environment) }
    }

    // Paths deliberately not provided, so nobody later thinks they were missed:
    // - `<dataFolder>/commands` (slash commands): this app indexes slash commands for **no**
    //   source (Claude's `~/.claude/commands` isn't indexed either); a Trae-only surface would
    //   be inconsistent.
    // - `<dataFolder>/mcp.json`, `<dataFolder>/trae-jwt-token`: credentials, see the red line
    //   in the file header.
    // - `<appSupport>/ModularData/ai-agent/database.db`: encrypted session DB, unreadable and
    //   must not be backed up.
    // - `<appSupport>/logs/*/Modular/ai-agent_*_stdout.log`: internal Rust tracing logs,
    //   100MB/1.5h, dir name changes every launch, format changes between versions -
    //   explicitly not a data source.
}
