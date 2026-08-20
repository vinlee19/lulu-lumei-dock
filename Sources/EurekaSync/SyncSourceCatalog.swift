import Foundation

/// 一个待同步候选文件（本地指纹 + 目标对象键）
public struct SyncCandidate: Equatable {
    public var localPath: String
    public var remoteKey: String
    public var size: Int64
    public var mtime: Double
    /// 0 = memory/skills（小而贵，先传）；1 = 会话 transcript
    public var priority: Int
    /// 来源类目（如 "claude/skills"、"custom/notes"）；首段即来源，历史记录按来源分组用
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

/// 备份范围的全部根路径（由 app 侧用现成 resolver 注入，模块本身不解析 env → 便于测试）
public struct SyncRoots {
    public var claudeHome: URL       // ~/.claude（CLAUDE.md + memories/)
    public var claudeProjects: URL   // ~/.claude/projects（transcripts + 项目 memory）
    public var claudeSkills: URL     // ~/.claude/skills
    public var codexHome: URL        // ~/.codex（AGENTS.md + memories/）
    public var codexSessions: URL    // ~/.codex/sessions
    public var codexSkills: URL      // ~/.codex/skills
    public var opencodeSkills: URL   // ~/.config/opencode/skills
    public var opencodeDB: URL       // ~/.local/share/opencode/opencode.db
    public var grokSkills: URL       // ~/.grok/skills
    public var grokMemory: URL       // ~/.grok/memory（跨会话记忆，实验特性）
    public var grokSessions: URL     // ~/.grok/sessions（events/chat_history *.jsonl）
    public var kimiSkills: URL       // ~/.kimi-code/skills
    public var kimiSessions: URL     // ~/.kimi-code/sessions（wire.jsonl + state.json）
    public var geminiHome: URL       // ~/.gemini（GEMINI.md + projects.json）
    public var geminiSessions: URL   // ~/.gemini/tmp（chats/session-*.jsonl）
    public var geminiSkills: URL     // ~/.gemini/skills
    public var qwenProjects: URL     // ~/.qwen/projects（chats/*.jsonl + runtime.json + memory）
    public var qwenMemories: URL     // ~/.qwen/memories
    public var qwenSkills: URL       // ~/.qwen/skills（⚠️ settings.json 含密钥，绝不纳入）
    public var hermesSkills: URL     // ~/.hermes/skills（分类目录树）
    public var hermesMemories: URL   // ~/.hermes/memories（MEMORY.md / USER.md）
    public var hermesHome: URL       // ~/.hermes（只取 SOUL.md 单文件，见 enumerate）
    public var hermesPlans: URL      // ~/.hermes/plans（profile 级，常不存在）
    public var claudePlans: URL      // ~/.claude/plans（Claude 计划，本就是 .md）
    public var plansStaging: URL     // ~/…/Eureka/plans（Codex/opencode 计划物化暂存，含 codex/ 与 opencode/）
    /// ~/.codebuddy/projects（会话 *.jsonl + <sessionId>/subagents/）。
    /// ⚠️ 同级 settings.json / mcp.json 可能含 API key/token —— 只 walk 这个根，绝不碰 home。
    public var codeBuddyProjects: URL?
    /// ~/.codebuddy/memery（全局记忆；官方拼写就是 memery）
    public var codeBuddyMemory: URL?
    /// ~/.qoder-cn/projects（会话 *.jsonl）。
    /// ⚠️ 同级 .auth/ 是凭据、settings.json 含 API key —— 只 walk 这个根，绝不碰 home。
    public var qoderProjects: URL?
    /// ~/.qoder-cn/memories（<user-hash>/global/<category>/）
    public var qoderMemories: URL?
    /// ~/.gemini/antigravity/skills（Antigravity 自己的技能，**不是** ~/.gemini/skills）。
    /// 会话是 protobuf（conversations/*.pb），二进制无从增量比对 → 不纳入备份。
    public var antigravitySkills: URL?
    /// ~/.cursor/skills（SKILL.md，与 Claude 同构）。
    /// ⚠️ Cursor 的会话与消息全在 `state.vscdb` 里，而**同一个库**的 ItemTable 还存着
    ///    `cursorAuth/accessToken` 与 `cursorAuth/refreshToken` —— 那个库永远不进备份，
    ///    Cursor 能同步的只有这一个技能目录。别加会话根。
    public var cursorSkills: URL?
    /// ~/.cursor/agents（子代理定义 <name>.md）
    public var cursorAgents: URL?
    /// trae 可备份的根：(本地根, 远端类目)。Trae 有**两个渠道**（CN `~/.trae-cn` 与
    /// 国际版 `~/.trae`），技能与用户规则各自一套，所以用数组而不是固定字段。
    /// 由 app 侧按已装渠道注入（见 `SyncService.traeRoots`）。
    ///
    /// ⚠️ **白名单，且只能是白名单。** 绝不加 `~/.trae-cn` 本身，也绝不加
    /// `~/Library/Application Support/Trae CN`：
    ///   - `<dataFolder>/trae-jwt-token` 是 JWT；
    ///   - `<dataFolder>/mcp.json` 可能含 API key；
    ///   - `<appSupport>/Cookies`、`<appSupport>/ModularData/ai-agent/database.db`
    ///     （SQLCipher 加密的全部会话）含鉴权与会话正文。
    /// 与 `cursorSkills` 上那条注释同性质：会话库跟凭据同处一地，一律不纳入。
    public var traeRoots: [(root: URL, category: String)] = []
    /// ZCode 可备份的根。⚠️ **白名单，且只能是白名单**：
    ///   - `~/.zcode/v2` 含 credentials.json（鉴权）—— 绝不纳入；
    ///   - `~/.zcode/cli/db` 是会话库本体（WAL 活跃，且与本备份的 rollout/agents 冗余）—— 不纳入；
    ///   - `~/.zcode/cli/rollout`（model-io-*.jsonl 用量流水）与
    ///     `~/.zcode/cli/agents`（子代理 metadata/transcript）只收文本工件；
    ///   - `~/.agents/skills`（共享技能根，与桌面版共用）。
    public var zcodeRollout: URL?
    public var zcodeAgents: URL?
    public var zcodeSkills: URL?
    /// 用户自定义同步目录：(本地根, 远端类目如 "custom/notes")。默认空 → 既有构造点不受影响
    public var customDirs: [(root: URL, category: String)] = []
    /// eureka 自身的分析快照（EurekaDBSnapshot 产出的三事实表 SQLite）。
    /// 默认 nil → 既有构造点不受影响；由 app 侧在每轮同步前物化后注入。
    public var eurekaSnapshot: URL?
    /// 项目级 skill 根：(本地根 <repo>/<agentDir>/skills, 远端类目 "<source>/skills/project/<项目名>")。
    /// 默认空；由 app 侧从 ProjectScopeDiscovery 注入，与全局 skill 并列备份。
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

/// 枚举备份范围 → [SyncCandidate]。纯文件 IO、无网络。
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

        /// 递归枚举 root 下常规文件。用 path-based enumerator 直接拿相对路径 ——
        /// URL 版会把 /var 解析成 /private/var 导致前缀比对失配（symlink 根同理）。
        func walk(
            root: URL, category: String, priority: Int,
            include: (String) -> Bool
        ) {
            guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return }
            for case let rel as String in enumerator {
                // 跳隐藏文件/目录（任一路径段以 . 开头）
                if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                guard include(rel) else { continue }
                add(root.appendingPathComponent(rel), category: category,
                    relativePath: rel, priority: priority)
            }
        }

        let always: (String) -> Bool = { _ in true }
        let markdownOnly: (String) -> Bool = { $0.lowercased().hasSuffix(".md") }
        let jsonlOnly: (String) -> Bool = { $0.lowercased().hasSuffix(".jsonl") }

        // Claude：全局 CLAUDE.md + memories/**.md
        add(roots.claudeHome.appendingPathComponent("CLAUDE.md"),
            category: "claude", relativePath: "CLAUDE.md", priority: 0)
        walk(root: roots.claudeHome.appendingPathComponent("memories", isDirectory: true),
             category: "claude/memories", priority: 0, include: markdownOnly)
        // Claude projects：transcripts（*.jsonl 完全递归，覆盖 <session>/subagents/ 深层）
        // + 项目 memory/**.md（projects 根下非 jsonl，单独按 .md 收）
        walk(root: roots.claudeProjects, category: "claude/projects", priority: 1,
             include: jsonlOnly)
        walk(root: roots.claudeProjects, category: "claude/projects", priority: 0) { rel in
            rel.lowercased().hasSuffix(".md") && rel.contains("/memory/")
        }
        // Claude skills（含停用区）
        walk(root: roots.claudeSkills, category: "claude/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.claudeSkills),
             category: "claude/skills.eureka-disabled", priority: 0, include: always)

        // Codex：持久指令（override 优先语义由 Codex 决定，两份都备份）+ memories + sessions + skills
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

        // opencode skills（opencode.db 由 OpencodeSnapshot 单独处理）
        walk(root: roots.opencodeSkills, category: "opencode/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.opencodeSkills),
             category: "opencode/skills.eureka-disabled", priority: 0, include: always)

        // grok：memory/**.md + sessions/**/*.jsonl + skills（含停用区）
        walk(root: roots.grokMemory, category: "grok/memories", priority: 0, include: markdownOnly)
        walk(root: roots.grokSessions, category: "grok/sessions", priority: 1, include: jsonlOnly)
        walk(root: roots.grokSkills, category: "grok/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.grokSkills),
             category: "grok/skills.eureka-disabled", priority: 0, include: always)

        // kimi：sessions（wire.jsonl + state.json，恢复会话两者都要）+ skills（含停用区）
        walk(root: roots.kimiSessions, category: "kimi/sessions", priority: 1) { rel in
            rel.lowercased().hasSuffix(".jsonl") || rel.hasSuffix("state.json")
        }
        walk(root: roots.kimiSkills, category: "kimi/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.kimiSkills),
             category: "kimi/skills.eureka-disabled", priority: 0, include: always)

        // gemini：全局 GEMINI.md + projects.json + 会话 chats + skills（含停用区）
        add(roots.geminiHome.appendingPathComponent("GEMINI.md"),
            category: "gemini", relativePath: "GEMINI.md", priority: 0)
        add(roots.geminiHome.appendingPathComponent("projects.json"),
            category: "gemini", relativePath: "projects.json", priority: 0)
        walk(root: roots.geminiSessions, category: "gemini/sessions", priority: 1, include: jsonlOnly)
        walk(root: roots.geminiSkills, category: "gemini/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.geminiSkills),
             category: "gemini/skills.eureka-disabled", priority: 0, include: always)

        // qwen：projects 下会话 jsonl + runtime.json + 项目记忆 md、全局 memories、skills。
        // ⚠️ ~/.qwen/settings.json 含 API key，绝不纳入备份范围。
        walk(root: roots.qwenProjects, category: "qwen/projects", priority: 1) { rel in
            rel.lowercased().hasSuffix(".jsonl") || rel.hasSuffix("runtime.json")
                || rel.lowercased().hasSuffix(".md")
        }
        walk(root: roots.qwenMemories, category: "qwen/memories", priority: 0, include: markdownOnly)
        walk(root: roots.qwenSkills, category: "qwen/skills", priority: 0, include: always)
        walk(root: disabledSibling(of: roots.qwenSkills),
             category: "qwen/skills.eureka-disabled", priority: 0, include: always)

        // 计划（.md 首类工件）：Claude 直接文件；Codex/opencode 由 PlanMaterializer 物化到暂存
        // hermes：技能树 + 两份全局记忆 + SOUL.md + profile 级计划。
        // ⚠️ 绝不纳入 ~/.hermes/{.env,auth.json}（凭证）、config.yaml（含 provider base_url）、
        //    state.db（会话/用量库，体积大且含全文），故此处只列这四个根。
        // SOUL.md 用 add 单点加入：~/.hermes 下还有 2GB 的 hermes-agent 源码 checkout，
        // 绝不能对整个 home 做递归 walk
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

        // codebuddy：会话 jsonl（含 <sessionId>/subagents/ 深层）+ 全局 memery（官方拼写）。
        // ⚠️ ~/.codebuddy/{settings.json,mcp.json} 可能含 API key/token → 只列这两个根，
        //    绝不 walk home（隐藏段本就会被 walk 跳过，双保险）。
        if let codeBuddyProjects = roots.codeBuddyProjects {
            walk(root: codeBuddyProjects, category: "codebuddy/projects", priority: 1,
                 include: jsonlOnly)
        }
        if let codeBuddyMemory = roots.codeBuddyMemory {
            walk(root: codeBuddyMemory, category: "codebuddy/memery", priority: 0,
                 include: markdownOnly)
        }

        // qoder：会话 jsonl + 全局 memories（<user-hash>/global/<category>/）。
        // ⚠️ ~/.qoder-cn/{.auth/,settings.json} 是凭据 → 只列这两个根，绝不 walk home。
        if let qoderProjects = roots.qoderProjects {
            walk(root: qoderProjects, category: "qoder/projects", priority: 1,
                 include: jsonlOnly)
        }
        if let qoderMemories = roots.qoderMemories {
            walk(root: qoderMemories, category: "qoder/memories", priority: 0,
                 include: markdownOnly)
        }

        // cursor：只有技能与子代理定义两个目录。会话在 state.vscdb 里，
        // 与 cursorAuth/* token 同库 → 那个库绝不纳入。
        if let cursorSkills = roots.cursorSkills {
            walk(root: cursorSkills, category: "cursor/skills", priority: 0,
                 include: markdownOnly)
        }
        if let cursorAgents = roots.cursorAgents {
            walk(root: cursorAgents, category: "cursor/agents", priority: 0,
                 include: markdownOnly)
        }

        // antigravity：只有技能目录可备份（会话是 protobuf，不纳入）
        if let antigravitySkills = roots.antigravitySkills {
            walk(root: antigravitySkills, category: "antigravity/skills", priority: 0,
                 include: markdownOnly)
        }

        // zcode：用量流水 jsonl + 子代理 metadata/transcript 文本 + 共享技能根。
        // ⚠️ ~/.zcode/v2（credentials.json）与 cli/db（会话库本体）绝不纳入，见 SyncRoots 注释。
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

        // trae：只有技能 / 记忆 / 用户规则三类明文 markdown 可备份，且都是显式白名单根。
        // 会话在 SQLCipher 加密库里，与 trae-jwt-token / mcp.json 同处一地 → 一律不纳入。
        // 计划（`<repo>/.trae/documents/plan_*.md`）在用户仓库里，跟 Hermes 一样不代管。
        //
        // 条目可能是目录（skills / user_rules / memory）也可能是单文件
        // （`<dataFolder>/user_rules.md` —— 它就躺在 dataFolder 根下，而那个目录里还有
        // trae-jwt-token，所以只能像 hermes 的 SOUL.md 一样单点加入，绝不 walk 它的父目录）。
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

        // eureka 分析快照（三张事实表的独立 SQLite，EurekaDBSnapshot 产出）：单文件加入。
        // 指纹侧车 *.fingerprint 在同目录，但这里只加快照本体，不 walk 目录。
        if let snapshot = roots.eurekaSnapshot {
            add(snapshot, category: "eureka/db",
                relativePath: snapshot.lastPathComponent, priority: 1)
        }

        // 用户自定义目录：远端类目由用户指定（custom/<名>），全部常规文件（隐藏文件仍跳过）
        for dir in roots.customDirs {
            walk(root: dir.root, category: dir.category, priority: 1, include: always)
        }

        // 项目级 skill：远端类目已由 app 侧算好（<source>/skills/project/<项目名>）。
        // 传入的是已解析的 <repo>/.claude/skills 等，walk 的隐藏段判定基于相对路径 → 不会误跳。
        for skill in roots.projectSkills {
            walk(root: skill.root, category: skill.category, priority: 0, include: always)
        }

        return Result(candidates: candidates, skippedOversize: oversize)
    }

    /// 停用区同级目录：<root>.eureka-disabled（与 SkillMemoryIndexer.disabledRoot 同约定）
    static func disabledSibling(of root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }
}
