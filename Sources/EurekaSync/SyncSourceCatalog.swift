import Foundation

/// One file to sync (local fingerprint + target object key)
public struct SyncCandidate: Equatable {
    public var localPath: String
    public var remoteKey: String
    public var size: Int64
    public var mtime: Double
    /// 0 = memory/skills (small and valuable, upload first); 1 = session transcript
    public var priority: Int
    /// Source category (e.g. "claude/skills", "custom/notes"); the first segment is the source,
    /// used to group the history by source
    public var category: String

    public init(
        localPath: String, remoteKey: String, size: Int64, mtime: Double,
        priority: Int, category: String = ""
    ) {
        self.localPath = localPath
        self.remoteKey = remoteKey
        self.size = size
        self.mtime = mtime
        self.priority = priority
        self.category = category
    }
}

/// Every root path in backup scope (injected by the app via the existing resolvers; the module
/// itself never reads env → easy to test)
public struct SyncRoots {
    public var claudeHome: URL       // ~/.claude (CLAUDE.md + memories/)
    public var claudeProjects: URL   // ~/.claude/projects (transcripts + project memory)
    public var claudeSkills: URL     // ~/.claude/skills
    public var codexHome: URL        // ~/.codex (AGENTS.md + memories/)
    public var codexSessions: URL    // ~/.codex/sessions
    public var codexSkills: URL      // ~/.codex/skills
    public var opencodeSkills: URL   // ~/.config/opencode/skills
    public var opencodeDB: URL       // ~/.local/share/opencode/opencode.db
    public var grokSkills: URL       // ~/.grok/skills
    public var grokMemory: URL       // ~/.grok/memory (cross-session memory, experimental feature)
    public var grokSessions: URL     // ~/.grok/sessions (events/chat_history *.jsonl)
    public var kimiSkills: URL       // ~/.kimi-code/skills
    public var kimiSessions: URL     // ~/.kimi-code/sessions (wire.jsonl + state.json)
    public var geminiHome: URL       // ~/.gemini (GEMINI.md + projects.json)
    public var geminiSessions: URL   // ~/.gemini/tmp (chats/session-*.jsonl)
    public var geminiSkills: URL     // ~/.gemini/skills
    public var qwenProjects: URL     // ~/.qwen/projects (chats/*.jsonl + runtime.json + memory)
    public var qwenMemories: URL     // ~/.qwen/memories
    public var qwenSkills: URL       // ~/.qwen/skills (⚠️ settings.json holds secrets, never include it)
    public var hermesSkills: URL     // ~/.hermes/skills (category directory tree)
    public var hermesMemories: URL   // ~/.hermes/memories (MEMORY.md / USER.md)
    public var hermesHome: URL       // ~/.hermes (only the single SOUL.md file, see enumerate)
    public var hermesPlans: URL      // ~/.hermes/plans (profile-level, often absent)
    public var claudePlans: URL      // ~/.claude/plans (Claude plans, already .md)
    public var plansStaging: URL     // ~/…/Eureka/plans (staging for materialized Codex/opencode plans, holds codex/ and opencode/)
    /// ~/.codebuddy/projects (session *.jsonl + <sessionId>/subagents/).
    /// ⚠️ The sibling settings.json / mcp.json may hold API keys/tokens: walk only this root,
    /// never touch home.
    public var codeBuddyProjects: URL?
    /// ~/.codebuddy/memery (global memory; `memery` is the official spelling)
    public var codeBuddyMemory: URL?
    /// ~/.qoder-cn/projects (session *.jsonl).
    /// ⚠️ The sibling .auth/ holds credentials and settings.json holds API keys: walk only this
    /// root, never touch home.
    public var qoderProjects: URL?
    /// ~/.qoder-cn/memories (<user-hash>/global/<category>/)
    public var qoderMemories: URL?
    /// ~/.gemini/antigravity/skills (Antigravity's own skills, **not** ~/.gemini/skills).
    /// Sessions are protobuf (conversations/*.pb); binary can't be diffed incrementally → not
    /// backed up.
    public var antigravitySkills: URL?
    /// ~/.cursor/skills (SKILL.md, same layout as Claude).
    /// ⚠️ Cursor's sessions and messages all live in `state.vscdb`, and the ItemTable of **that
    ///    same database** also stores `cursorAuth/accessToken` and `cursorAuth/refreshToken`:
    ///    that database never enters a backup, and this skills directory is the only thing
    ///    Cursor can sync. Don't add a session root.
    public var cursorSkills: URL?
    /// ~/.cursor/agents (subagent definitions <name>.md)
    public var cursorAgents: URL?
    /// Trae roots that may be backed up: (local root, remote category). Trae has **two channels**
    /// (CN `~/.trae-cn` and
    /// international `~/.trae`), each with its own skills and user rules, hence an array rather
    /// than fixed fields.
    /// Injected by the app per installed channel (see `SyncService.traeRoots`).
    ///
    /// ⚠️ **A whitelist, and only ever a whitelist.** Never add `~/.trae-cn` itself, nor
    /// `~/Library/Application Support/Trae CN`:
    ///   - `<dataFolder>/trae-jwt-token` is a JWT;
    ///   - `<dataFolder>/mcp.json` may hold API keys;
    ///   - `<appSupport>/Cookies` and `<appSupport>/ModularData/ai-agent/database.db`
    ///     (every session, SQLCipher-encrypted) hold auth data and session bodies.
    /// Same reasoning as the comment on `cursorSkills`: the session store sits next to the
    /// credentials, so none of it is included.
    public var traeRoots: [(root: URL, category: String)] = []
    /// ZCode roots that may be backed up. ⚠️ **A whitelist, and only ever a whitelist**:
    ///   - `~/.zcode/v2` holds credentials.json (auth): never included;
    ///   - `~/.zcode/cli/db` is the session database itself (WAL-active, and redundant with the
    ///     rollout/agents backed up here): not included;
    ///   - `~/.zcode/cli/rollout` (model-io-*.jsonl usage log) and
    ///     `~/.zcode/cli/agents` (subagent metadata/transcript): text artifacts only;
    ///   - `~/.agents/skills` (shared skills root, also used by the desktop app).
    public var zcodeRollout: URL?
    public var zcodeAgents: URL?
    public var zcodeSkills: URL?
    /// User-defined sync directories: (local root, remote category such as "custom/notes").
    /// Empty by default → existing call sites are unaffected
    public var customDirs: [(root: URL, category: String)] = []
    /// Eureka's own analytics snapshot (the three-fact-table SQLite produced by EurekaDBSnapshot).
    /// nil by default → existing call sites are unaffected; the app materializes and injects it
    /// before each sync round.
    public var eurekaSnapshot: URL?
    /// Audit archive directory (dt=YYYY-MM-DD/audit-events-*.parquet produced by AuditArchive,
    /// already redacted).
    /// nil by default; the app injects it only when the user turns on audit archiving.
    public var auditArchiveDir: URL?
    /// Project-level skill roots: (local root <repo>/<agentDir>/skills, remote category
    /// "<source>/skills/project/<project name>").
    /// Empty by default; injected by the app from ProjectScopeDiscovery and backed up alongside
    /// the global skills.
    public var projectSkills: [(root: URL, category: String)] = []

    public init(
        claudeHome: URL, claudeProjects: URL, claudeSkills: URL,
        codexHome: URL, codexSessions: URL, codexSkills: URL,
        opencodeSkills: URL, opencodeDB: URL,
        grokSkills: URL, grokMemory: URL, grokSessions: URL,
        kimiSkills: URL, kimiSessions: URL,
        geminiHome: URL, geminiSessions: URL, geminiSkills: URL,
        qwenProjects: URL, qwenMemories: URL, qwenSkills: URL,
        hermesSkills: URL, hermesMemories: URL, hermesHome: URL, hermesPlans: URL,
        claudePlans: URL, plansStaging: URL,
        codeBuddyProjects: URL? = nil, codeBuddyMemory: URL? = nil,
        qoderProjects: URL? = nil, qoderMemories: URL? = nil,
        cursorSkills: URL? = nil,
        cursorAgents: URL? = nil,
        zcodeRollout: URL? = nil, zcodeAgents: URL? = nil, zcodeSkills: URL? = nil,
        antigravitySkills: URL? = nil
    ) {
        self.claudeHome = claudeHome
        self.claudeProjects = claudeProjects
        self.claudeSkills = claudeSkills
        self.codexHome = codexHome
        self.codexSessions = codexSessions
        self.codexSkills = codexSkills
        self.opencodeSkills = opencodeSkills
        self.opencodeDB = opencodeDB
        self.grokSkills = grokSkills
        self.grokMemory = grokMemory
        self.grokSessions = grokSessions
        self.kimiSkills = kimiSkills
        self.kimiSessions = kimiSessions
        self.geminiHome = geminiHome
        self.geminiSessions = geminiSessions
        self.geminiSkills = geminiSkills
        self.qwenProjects = qwenProjects
        self.qwenMemories = qwenMemories
        self.qwenSkills = qwenSkills
        self.hermesSkills = hermesSkills
        self.hermesMemories = hermesMemories
        self.hermesHome = hermesHome
        self.hermesPlans = hermesPlans
        self.claudePlans = claudePlans
        self.plansStaging = plansStaging
        self.codeBuddyProjects = codeBuddyProjects
        self.codeBuddyMemory = codeBuddyMemory
        self.qoderProjects = qoderProjects
        self.qoderMemories = qoderMemories
        self.cursorSkills = cursorSkills
        self.cursorAgents = cursorAgents
        self.antigravitySkills = antigravitySkills
        self.zcodeRollout = zcodeRollout
        self.zcodeAgents = zcodeAgents
        self.zcodeSkills = zcodeSkills
    }
}

/// Enumerates the backup scope → [SyncCandidate]. Pure file IO, no network.
public enum SyncSourceCatalog {
    public struct Result {
        public var candidates: [SyncCandidate]
        public var skippedOversize: Int
    }

    public static func enumerate(
        roots: SyncRoots, prefix: String, host: String, maxFileSize: Int64
    ) -> Result {
        var candidates: [SyncCandidate] = []
        var oversize = 0

        func add(_ url: URL, category: String, relativePath: String, priority: Int) {
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                values.isRegularFile == true
            else { return }
            let size = Int64(values.fileSize ?? 0)
            guard size <= maxFileSize else {
                oversize += 1
                return
            }
            candidates.append(SyncCandidate(
                localPath: url.path,
                remoteKey: SyncKeyMapper.key(
                    prefix: prefix, host: host, category: category, relativePath: relativePath),
                size: size,
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                priority: priority,
                category: category))
        }

        /// Recursively enumerates regular files under root. Uses the path-based enumerator to get
        /// relative paths directly:
        /// the URL version resolves /var to /private/var and breaks the prefix comparison (same
        /// for symlinked roots).
        func walk(
            root: URL, category: String, priority: Int,
            include: (String) -> Bool
        ) {
            guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return }
            for case let rel as String in enumerator {
                // Skip hidden files/directories (any path segment starting with .)
                if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                guard include(rel) else { continue }
                add(root.appendingPathComponent(rel), category: category,
                    relativePath: rel, priority: priority)
            }
        }

        let always: (String) -> Bool = { _ in true }
        let markdownOnly: (String) -> Bool = { $0.lowercased().hasSuffix(".md") }
        let jsonlOnly: (String) -> Bool = { $0.lowercased().hasSuffix(".jsonl") }

        // Claude: global CLAUDE.md + memories/**.md
        add(roots.claudeHome.appendingPathComponent("CLAUDE.md"),
            category: "claude", relativePath: "CLAUDE.md", priority: 0)
        walk(root: roots.claudeHome.appendingPathComponent("memories", isDirectory: true),
             category: "claude/memories", priority: 0, include: markdownOnly)
        // Claude projects: transcripts (*.jsonl fully recursive, covers deep <session>/subagents/)
        // + project memory/**.md (non-jsonl under the projects root, collected separately by .md)
        walk(root: roots.claudeProjects, category: "claude/projects", priority: 1,
             include: jsonlOnly)
        walk(root: roots.claudeProjects, category: "claude/projects", priority: 0) { rel in
            rel.lowercased().hasSuffix(".md") && rel.contains("/memory/")
        }
        // Claude skills (including the disabled area)
        walk(root: roots.claudeSkills, category: "claude/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.claudeSkills),
             category: "claude/skills.eureka-disabled", priority: 0, include: always)

        // Codex: persistent instructions (Codex decides the override precedence; back up both)
        // + memories + sessions + skills
        add(roots.codexHome.appendingPathComponent("AGENTS.md"),
            category: "codex", relativePath: "AGENTS.md", priority: 0)
        add(roots.codexHome.appendingPathComponent("AGENTS.override.md"),
            category: "codex", relativePath: "AGENTS.override.md", priority: 0)
        walk(root: roots.codexHome.appendingPathComponent("memories", isDirectory: true),
             category: "codex/memories", priority: 0, include: markdownOnly)
        walk(root: roots.codexSessions, category: "codex/sessions", priority: 1,
             include: jsonlOnly)
        walk(root: roots.codexSkills, category: "codex/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.codexSkills),
             category: "codex/skills.eureka-disabled", priority: 0, include: always)

        // opencode skills (opencode.db is handled separately by OpencodeSnapshot)
        walk(root: roots.opencodeSkills, category: "opencode/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.opencodeSkills),
             category: "opencode/skills.eureka-disabled", priority: 0, include: always)

        // grok: memory/**.md + sessions/**/*.jsonl + skills (including the disabled area)
        walk(root: roots.grokMemory, category: "grok/memories", priority: 0, include: markdownOnly)
        walk(root: roots.grokSessions, category: "grok/sessions", priority: 1, include: jsonlOnly)
        walk(root: roots.grokSkills, category: "grok/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.grokSkills),
             category: "grok/skills.eureka-disabled", priority: 0, include: always)

        // kimi: sessions (wire.jsonl + state.json, restoring a session needs both) + skills
        // (including the disabled area)
        walk(root: roots.kimiSessions, category: "kimi/sessions", priority: 1) { rel in
            rel.lowercased().hasSuffix(".jsonl") || rel.hasSuffix("state.json")
        }
        walk(root: roots.kimiSkills, category: "kimi/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.kimiSkills),
             category: "kimi/skills.eureka-disabled", priority: 0, include: always)

        // gemini: global GEMINI.md + projects.json + session chats + skills (including the
        // disabled area)
        add(roots.geminiHome.appendingPathComponent("GEMINI.md"),
            category: "gemini", relativePath: "GEMINI.md", priority: 0)
        add(roots.geminiHome.appendingPathComponent("projects.json"),
            category: "gemini", relativePath: "projects.json", priority: 0)
        walk(root: roots.geminiSessions, category: "gemini/sessions", priority: 1, include: jsonlOnly)
        walk(root: roots.geminiSkills, category: "gemini/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.geminiSkills),
             category: "gemini/skills.eureka-disabled", priority: 0, include: always)

        // qwen: session jsonl + runtime.json + project memory md under projects, global
        // memories, skills.
        // ⚠️ ~/.qwen/settings.json holds API keys and is never in backup scope.
        walk(root: roots.qwenProjects, category: "qwen/projects", priority: 1) { rel in
            rel.lowercased().hasSuffix(".jsonl") || rel.hasSuffix("runtime.json")
                || rel.lowercased().hasSuffix(".md")
        }
        walk(root: roots.qwenMemories, category: "qwen/memories", priority: 0, include: markdownOnly)
        walk(root: roots.qwenSkills, category: "qwen/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.qwenSkills),
             category: "qwen/skills.eureka-disabled", priority: 0, include: always)

        // Plans (.md first-class artifacts): Claude's files directly; Codex/opencode plans are
        // materialized into staging by PlanMaterializer
        // hermes: skill tree + the two global memories + SOUL.md + profile-level plans.
        // ⚠️ Never include ~/.hermes/{.env,auth.json} (credentials), config.yaml (holds provider
        //    base_url),
        //    or state.db (session/usage database, large and full of full text), so only these
        //    four roots are listed here.
        // SOUL.md is added as a single file: ~/.hermes also holds a 2GB hermes-agent source
        // checkout,
        // so the whole home must never be walked recursively
        add(roots.hermesHome.appendingPathComponent("SOUL.md"),
            category: "hermes", relativePath: "SOUL.md", priority: 0)
        walk(root: roots.hermesSkills, category: "hermes/skills", priority: 0, include: always)
        walk(root: roots.hermesMemories, category: "hermes/memories", priority: 0,
             include: markdownOnly)
        walk(root: roots.hermesPlans, category: "hermes/plans", priority: 0, include: markdownOnly)
        walk(root: roots.claudePlans, category: "claude/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("codex", isDirectory: true),
             category: "codex/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("opencode", isDirectory: true),
             category: "opencode/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("grok", isDirectory: true),
             category: "grok/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("kimi", isDirectory: true),
             category: "kimi/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("gemini", isDirectory: true),
             category: "gemini/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("qwen", isDirectory: true),
             category: "qwen/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("qoder", isDirectory: true),
             category: "qoder/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("cursor", isDirectory: true),
             category: "cursor/plans", priority: 0, include: markdownOnly)

        // codebuddy: session jsonl (including deep <sessionId>/subagents/) + global memery
        // (official spelling).
        // ⚠️ ~/.codebuddy/{settings.json,mcp.json} may hold API keys/tokens → list only these two
        //    roots,
        //    never walk home (walk already skips hidden segments; belt and braces).
        if let codeBuddyProjects = roots.codeBuddyProjects {
            walk(root: codeBuddyProjects, category: "codebuddy/projects", priority: 1,
                 include: jsonlOnly)
        }
        if let codeBuddyMemory = roots.codeBuddyMemory {
            walk(root: codeBuddyMemory, category: "codebuddy/memery", priority: 0,
                 include: markdownOnly)
        }

        // qoder: session jsonl + global memories (<user-hash>/global/<category>/).
        // ⚠️ ~/.qoder-cn/{.auth/,settings.json} are credentials → list only these two roots,
        //    never walk home.
        if let qoderProjects = roots.qoderProjects {
            walk(root: qoderProjects, category: "qoder/projects", priority: 1,
                 include: jsonlOnly)
        }
        if let qoderMemories = roots.qoderMemories {
            walk(root: qoderMemories, category: "qoder/memories", priority: 0,
                 include: markdownOnly)
        }

        // cursor: only the skills and subagent-definition directories. Sessions live in
        // state.vscdb,
        // the same database as the cursorAuth/* tokens → that database is never included.
        if let cursorSkills = roots.cursorSkills {
            walk(root: cursorSkills, category: "cursor/skills", priority: 0,
                 include: markdownOnly)
        }
        if let cursorAgents = roots.cursorAgents {
            walk(root: cursorAgents, category: "cursor/agents", priority: 0,
                 include: markdownOnly)
        }

        // antigravity: only the skills directory can be backed up (sessions are protobuf, excluded)
        if let antigravitySkills = roots.antigravitySkills {
            walk(root: antigravitySkills, category: "antigravity/skills", priority: 0,
                 include: markdownOnly)
        }

        // zcode: usage-log jsonl + subagent metadata/transcript text + shared skills root.
        // ⚠️ ~/.zcode/v2 (credentials.json) and cli/db (the session database itself) are never
        //    included; see the SyncRoots comment.
        if let zcodeRollout = roots.zcodeRollout {
            walk(root: zcodeRollout, category: "zcode/rollout", priority: 1,
                 include: jsonlOnly)
        }
        if let zcodeAgents = roots.zcodeAgents {
            walk(root: zcodeAgents, category: "zcode/agents", priority: 1) { rel in
                rel.lowercased().hasSuffix(".jsonl")
                    || rel.lowercased().hasSuffix(".json")
                    || rel.lowercased().hasSuffix(".md")
                    || rel.lowercased().hasSuffix(".txt")
            }
        }
        if let zcodeSkills = roots.zcodeSkills {
            walk(root: zcodeSkills, category: "zcode/skills", priority: 0, include: always)
            walk(root: disabledSibling(of: zcodeSkills),
                 category: "zcode/skills.eureka-disabled", priority: 0, include: always)
        }

        // trae: only three kinds of plaintext markdown can be backed up (skills / memory / user
        // rules), all from explicit whitelisted roots.
        // Sessions live in the SQLCipher-encrypted database, next to trae-jwt-token / mcp.json
        // → none of it is included.
        // Plans (`<repo>/.trae/documents/plan_*.md`) live in the user's repo and, like Hermes,
        // are not managed here.
        //
        // An entry may be a directory (skills / user_rules / memory) or a single file
        // (`<dataFolder>/user_rules.md`: it sits at the root of dataFolder, and that directory
        // also holds
        // trae-jwt-token, so it can only be added as a single file like hermes' SOUL.md; never
        // walk its parent).
        for (root, category) in roots.traeRoots {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: root.path, isDirectory: &isDirectory)
            if exists, !isDirectory.boolValue {
                add(root, category: category, relativePath: root.lastPathComponent, priority: 0)
            } else {
                walk(root: root, category: category, priority: 0, include: markdownOnly)
            }
        }

        // Eureka analytics snapshot (standalone SQLite of the three fact tables, produced by
        // EurekaDBSnapshot): added as a single file.
        // The *.fingerprint sidecar sits in the same directory, but only the snapshot itself is
        // added here; the directory is not walked.
        if let snapshot = roots.eurekaSnapshot {
            add(snapshot, category: "eureka/db",
                relativePath: snapshot.lastPathComponent, priority: 1)
        }

        // Audit archive: keep the dt=… directory levels → remote Hive partitions; temp files start
        // with . and walk skips them automatically
        if let archive = roots.auditArchiveDir {
            walk(root: archive, category: "eureka/audit", priority: 1) {
                $0.hasPrefix("dt=") && $0.hasSuffix(".parquet")
            }
        }

        // User-defined directories: remote category chosen by the user (custom/<name>), every
        // regular file (hidden files still skipped)
        for dir in roots.customDirs {
            walk(root: dir.root, category: dir.category, priority: 1, include: always)
        }

        // Project-level skills: the remote category is already computed by the app
        // (<source>/skills/project/<project name>).
        // The roots passed in are already resolved (<repo>/.claude/skills etc.); walk's
        // hidden-segment check uses the relative path → no false skips.
        for skill in roots.projectSkills {
            walk(root: skill.root, category: skill.category, priority: 0, include: always)
        }

        return Result(candidates: candidates, skippedOversize: oversize)
    }

    /// Disabled-area sibling directory: <root>.eureka-disabled (same convention as
    /// SkillMemoryIndexer.disabledRoot)
    static func disabledSibling(of root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }
}
