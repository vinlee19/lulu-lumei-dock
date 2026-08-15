import EurekaKit
import Foundation

/// 技能 / agent 的归属范围：系统级（用户 home 根）或项目级（某项目 cwd 下）
public enum SkillScope: Equatable, Sendable {
    case system
    case project(String)  // 关联项目名

    /// 项目名（系统级为 nil）
    public var projectName: String? {
        if case .project(let name) = self { return name }
        return nil
    }
    public var isProject: Bool { projectName != nil }
}

/// 项目级根：某项目 cwd 下的 skills / agents 目录（技能与 agent 复用）
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

/// 技能来源归属：用户自建/安装 or 工具内置携带（插件 / .system / bundled / builtin）
public enum SkillOrigin: String, Equatable, Sendable {
    case user      // 用户自建或安装（可增删改、可启停）
    case bundled   // 工具内置/携带（只读，仅用于详情矩阵与跨源存在判定）
}

/// 一个技能（Claude/Codex 的 SKILL.md）
public struct SkillEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var source: AgentSource
    public var name: String
    public var description: String?
    public var path: String       // SKILL.md 绝对路径
    public var directory: String  // 技能目录绝对路径
    public var enabled: Bool      // 在启用区 = true；在 *.eureka-disabled 区 = false
    public var scope: SkillScope  // 系统级 or 项目级
    public var origin: SkillOrigin  // 用户自建 or 工具内置携带
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

/// 一条记忆指向的会话。
///
/// Claude 的记忆一条对一个会话（frontmatter `metadata.originSessionId`）；
/// Codex 的 `MEMORY.md` 是**一个文件聚合多次会话**（正文 `### rollout_summary_files` 段落里
/// 每行一个 `thread_id=`，实勘 15 个），所以这里必须是多值。
public struct MemorySessionRef: Equatable, Sendable, Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    /// transcript 的实际路径；nil = 记录文件已不在（UI 置灰、不可跳转）
    public var path: String?
    public var exists: Bool { path != nil }

    public init(sessionId: String, path: String?) {
        self.sessionId = sessionId
        self.path = path
    }
}

public enum MemoryEntryKind: String, Equatable, Sendable {
    /// CLAUDE.md / AGENTS.md 等用户维护的持久指令。
    case instructions
    /// 用户自行创建、可正常增删改的记忆文档。
    case userManaged
    /// Codex 后台生成的本地 memory state，只允许查看。
    case generated
}

/// 一份记忆/指令文件（CLAUDE.md / AGENTS.md / memory 目录下的 markdown）
public struct MemoryEntry: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var source: AgentSource
    /// 分组用的展示范围："全局" / 项目名 / 文件名。**不是标题** —— 同一项目的几十条记忆
    /// 这里全是同一个项目名，拿它当标题会让整列重名（见 `title`）。
    public var scope: String
    public var path: String
    public var kind: MemoryEntryKind
    /// 归属项目名；nil = 系统级记忆（全局 / 用户自建），非 nil = 该项目的记忆
    public var projectName: String?
    public var sizeBytes: UInt64
    public var modifiedAt: Date
    /// 条目标题：frontmatter `name` 优先，否则文件名（去扩展名）
    public var title: String
    /// frontmatter `description`
    public var summary: String?
    /// frontmatter `metadata.type`；没写就是 `.other`
    public var memoryType: MemoryType
    /// frontmatter `metadata.originSessionId`：这条记忆诞生于哪次会话
    public var originSessionId: String?
    /// 来源会话 transcript 的实际路径；nil = 会话已被删除（图谱里置灰、不可跳转）
    public var originSessionPath: String?
    /// 这条记忆指向的**全部**会话。Claude 是 0/1 个（等于 originSessionId）；
    /// Codex 的 MEMORY.md 聚合多次会话，实勘 15 个。UI 据此给单按钮或下拉列表。
    public var relatedSessions: [MemorySessionRef]
    /// 正文里的 `[[wiki 链接]]` 原文（解析成边在 EurekaKit 做，索引层只采集）
    public var links: [String]
    /// **仅索引文件**（MEMORY.md）有值：正文里以 markdown 链接列出的条目文件名。
    /// 与目录里的实际文件对账，就能算出「未被收录的死记忆」与「指向空气的条目」。
    /// 不并进 `links`：那会让索引在图谱里连出几十条 contains 边，把真正要看的引用边盖掉。
    public var indexedTargets: [String]
    /// 记忆库的索引文件（`<library>/MEMORY.md`）
    public var isIndex: Bool
    /// 所属记忆库：`"<source>:<encoded-project-dir>"`；nil = 不属于任何记忆库
    public var libraryKey: String?
    public var isEditable: Bool { kind != .generated }
    public var isDeletable: Bool { kind != .generated }

    /// `[[link]]` 的可匹配别名：文件 basename + frontmatter name
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
        // Claude 那条单值来源也并进多值列表，UI 只认一个字段
        self.relatedSessions = relatedSessions.isEmpty
            ? (originSessionId.map { [MemorySessionRef(sessionId: $0, path: originSessionPath)] } ?? [])
            : relatedSessions
        self.links = links
        self.indexedTargets = indexedTargets
        self.isIndex = isIndex
        self.libraryKey = libraryKey
    }
}

/// 扫描 Claude / Codex 的技能与记忆文件。纯文件 IO，无状态，便于单测（env 覆盖路径根）。
public enum SkillMemoryIndexer {
    private static func home() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - 路径根（EUREKA_* 覆盖，沿用其它扫描器约定）

    public static func claudeSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// 项目级技能根：各仓库根下 `<root>/<agentDir>/skills`（技能页与云备份共用同一发现口径）。
    /// 抽自 SkillMemoryService.refresh 的原内联逻辑，供 SyncSourceCatalog 复用、避免漂移。
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

    /// 停用区（Eureka 自管的同级目录，非破坏、可逆）：~/.claude/skills → ~/.claude/skills.eureka-disabled
    public static func disabledRoot(for skillsRoot: URL) -> URL {
        skillsRoot.deletingLastPathComponent()
            .appendingPathComponent(skillsRoot.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }

    /// Claude 插件技能根（内置/携带）：`~/.claude/plugins/cache/<marketplace>/<plugin>/[<version>/]skills`。
    /// 层级可能带或不带 version 段，两级都探；返回所有存在的 skills 目录。
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
                collect(plugin)                       // plugin/skills（无版本）
                for version in subdirs(plugin) { collect(version) }  // plugin/version/skills
            }
        }
        return roots
    }

    /// 归一化技能名用于跨源/统计匹配：小写；`plugin:skill` 取冒号后段。
    public static func normalizeSkillName(_ name: String) -> String {
        let lower = name.lowercased()
        if let colon = lower.lastIndex(of: ":") {
            return String(lower[lower.index(after: colon)...])
        }
        return lower
    }

    // MARK: - 技能

    public static func indexSkills(
        claudeSkillsRoot: URL, codexSkillsRoot: URL,
        /// `~/.codex/memories/skills`：Codex 把技能也放进了那个 memories git 仓库
        /// （实勘 `publish-draft-pr`）。不收这里，它就会被记忆扫描当成一条"记忆"。
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
        /// zcode：技能装在共享的 `~/.agents/skills`（SKILL.md 与 Claude 同构）
        zcodeSkillsRoot: URL? = nil,
        /// trae 的**可写**技能根，两个渠道各一个（`~/.trae-cn/skills`、`~/.trae/skills`）。
        /// 只读的 `builtin_skills` / `builtin/global/skills` 走 `bundledRoots`。
        traeSkillsRoots: [URL] = [],
        projectSkillRoots: [ProjectScopedRoot] = [],
        bundledRoots: [(root: URL, source: AgentSource)] = []
    ) -> [SkillEntry] {
        var result: [SkillEntry] = []
        // 系统级（用户 home 根 + 停用区）
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
        // cursor：~/.cursor/skills（SKILL.md 与 Claude 同构）。
        // 同级的 ~/.cursor/skills-cursor 是官方内置技能，随客户端分发、用户改不了，不列。
        if let cursorSkillsRoot {
            result += scanSkillRoot(
                cursorSkillsRoot, source: .cursor, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: cursorSkillsRoot), source: .cursor, enabled: false,
                scope: .system)
        }
        // gemini：~/.gemini/skills（SKILL.md 与 Claude 同构；该目录同时被 Antigravity 共用，
        // 归 Gemini 一次避免双源重复列出）
        if let geminiSkillsRoot {
            result += scanSkillRoot(
                geminiSkillsRoot, source: .gemini, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: geminiSkillsRoot), source: .gemini, enabled: false, scope: .system)
        }
        // qwen：~/.qwen/skills（SKILL.md 与 Claude 同构）
        if let qwenSkillsRoot {
            result += scanSkillRoot(
                qwenSkillsRoot, source: .qwen, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: qwenSkillsRoot), source: .qwen, enabled: false, scope: .system)
        }
        // antigravity 用户级技能 ~/.gemini/antigravity/skills（**不是** ~/.gemini/skills，
        // 那是 Gemini 的、已归 gemini 一次）；内置 builtin/skills 走 bundledRoots
        for root in antigravitySkillsRoots {
            result += scanSkillRoot(root, source: .antigravity, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: root), source: .antigravity, enabled: false, scope: .system)
        }
        // codebuddy：~/.codebuddy/skills（SKILL.md 与 Claude 同构，实勘 23 个）
        if let codeBuddySkillsRoot {
            result += scanSkillRoot(
                codeBuddySkillsRoot, source: .codebuddy, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: codeBuddySkillsRoot), source: .codebuddy, enabled: false,
                scope: .system)
        }
        // qoder：~/.qoder-cn/skills（与 codebuddy 同构；⚠️ 本机未装 Qoder，未实勘）
        if let qoderSkillsRoot {
            result += scanSkillRoot(
                qoderSkillsRoot, source: .qoder, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: qoderSkillsRoot), source: .qoder, enabled: false, scope: .system)
        }
        // zcode：~/.agents/skills（共享技能根，ZCode CLI 桌面版装技能的默认位置）
        if let zcodeSkillsRoot {
            result += scanSkillRoot(
                zcodeSkillsRoot, source: .zcode, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: zcodeSkillsRoot), source: .zcode, enabled: false, scope: .system)
        }
        // trae：`<dataFolder>/skills`（SKILL.md 与 Claude 同构：frontmatter 的 name/description）。
        // 两个渠道（CN / 国际版）可能同时装着，各扫一遍；同名技能在两边是两条，
        // 因为它们确实是两个应用各自的配置，不该合并计数。
        for root in traeSkillsRoots {
            result += scanSkillRoot(root, source: .trae, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: root), source: .trae, enabled: false, scope: .system)
        }
        // hermes：分类目录树，启停看 config.yaml 而非目录位置（详见 scanHermesSkillTree）
        if let hermesSkillsRoot {
            result += scanHermesSkillTree(
                hermesSkillsRoot, disabledNames: hermesDisabledSkills)
        }
        // 项目级（各项目 cwd 下的 skills 根 + 停用区）
        for project in projectSkillRoots {
            let scope = SkillScope.project(project.projectName)
            result += scanSkillRoot(
                project.root, source: project.source, enabled: true, scope: scope)
            result += scanSkillRoot(
                disabledRoot(for: project.root), source: project.source, enabled: false, scope: scope)
        }
        // 内置/携带根（插件 / .system / bundled / builtin）：只读，标 origin=.bundled，无停用区
        for bundled in bundledRoots {
            result += scanSkillRoot(
                bundled.root, source: bundled.source, enabled: true,
                scope: .system, origin: .bundled)
        }
        // 同一 path 只留一条（系统级先扫 → 优先保留）：项目根与系统根重合时（例如会话在 ~ 里
        // 跑过，仓库根回退成 home）同一 SKILL.md 会被扫两次，而 SkillEntry.id = path，
        // 重复 id 会让 SwiftUI 的 ForEach/LazyVGrid 出现空洞格子。
        var seenPaths = Set<String>()
        result = result.filter { seenPaths.insert($0.path).inserted }
        // 启用在前，再按名字
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
            if dirName.hasPrefix(".") { continue }  // 跳过 .system 等系统目录
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

    /// Hermes 技能树扫描：`skills/<分类>/<名>/SKILL.md`，另有 `<分类>/<子类>/<名>/` 与
    /// 顶层无分类两种深度 —— 故必须**递归**找 SKILL.md（`scanSkillRoot` 只看直属子级，撑不住）。
    ///
    /// 启停不看目录：Hermes 用 `config.yaml` 的 `skills.disabled`（按 frontmatter `name` 匹配），
    /// 目录一动就会破坏它的 `.bundled_manifest` md5 记账 → `disabledNames` 由调用方
    /// （app 层，能同时用到 EurekaInstall 的 HermesConfigEditor）读出后传进来。
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
            // 支持目录（技能自带素材）与工具/缓存目录里不会有独立技能，整棵剪掉
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
                scope: .system,     // Hermes 没有项目级技能（只有 skills.external_dirs）
                origin: .user,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return result.sorted {
            ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    /// 递归时整棵跳过的目录：技能自带素材目录 + 归档/缓存/依赖目录
    private static let hermesPrunedDirs: Set<String> = [
        "references", "templates", "assets", "scripts",
        ".hub", ".archive", ".curator_backups", ".git", ".github",
        "venv", ".venv", "node_modules", "site-packages",
        "__pycache__", ".tox", ".nox", ".pytest_cache", ".mypy_cache", ".ruff_cache",
    ]

    // MARK: - 记忆

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
        /// `~/.trae-cn/memory`（只有 CN 版有记忆库）
        traeMemoryRoot: URL? = nil,
        /// trae 各渠道的 dotfile 根（`~/.trae-cn`、`~/.trae`）。用户手写规则有两种形态并存：
        /// `<root>/user_rules.md` 单文件（Trae 前端叫 legacy）与 `<root>/user_rules/*.md` 目录。
        traeRulesHomes: [URL] = [],
        projectRoots: [(root: URL, name: String)] = [],
        codexInstructionScopes: [(directory: URL, projectName: String, scope: String)] = []
    ) -> [MemoryEntry] {
        let fm = FileManager.default
        var result: [MemoryEntry] = []

        /// `libraryKey` 非 nil = 这条属于某个记忆库；`sessionRoot` = 该库同级的会话目录
        /// （`~/.claude/projects/<encoded>/`），用来判断来源会话的 transcript 还在不在。
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
                // 只有索引文件才解析 markdown 链接（普通记忆正文里的 md 链接是引用外部文档，
                // 不是"收录"语义）
                indexedTargets: isLibraryIndex ? document.indexedTargets : [],
                // 只有记忆库里的 MEMORY.md 才是索引。Hermes 的 memories/MEMORY.md 是它
                // 自己写的记忆正文（不是任何库的目录），所以判据里必须带上 libraryKey。
                isIndex: isLibraryIndex,
                libraryKey: libraryKey))
        }

        /// Codex 每一级目录只加载 override/AGENTS 中第一个存在的文件。
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

        // Claude 全局 CLAUDE.md
        add(claudeHome.appendingPathComponent("CLAUDE.md"), source: .claude,
            scope: "全局", kind: .instructions)
        // Claude ~/.claude/memories/**/*.md（用户自建记忆）
        for file in enumerateMarkdown(claudeHome.appendingPathComponent("memories", isDirectory: true)) {
            add(file, source: .claude, scope: file.deletingPathExtension().lastPathComponent)
        }
        // Claude 项目记忆库：projects/<encoded>/memory/**/*.md（MEMORY.md = 该库的索引）
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

        // Codex 全局持久指令：AGENTS.override.md 优先于 AGENTS.md。
        addEffectiveCodexInstruction(directory: codexHome, scope: "全局")
        // Codex 记忆 = `~/.codex/memories/` **顶层**的 md（实勘为三层管道：
        // raw_memories.md → MEMORY.md → memory_summary.md），后台生成、仅供查看。
        //
        // ⚠️ **只收顶层，绝不递归**：这个目录是 Codex 自建的 git 仓库，混装着三类非记忆内容 ——
        // `rollout_summaries/`（每次会话的摘要，是 MEMORY.md 的证据附件）、
        // `extensions/`（教 Codex 怎么维护记忆的元指令）、
        // `skills/`（**技能**，见 indexSkills 的 codexMemorySkillsRoot）。
        // 递归收一遍会把 20 个文件全算成记忆，其中 17 个不是。
        for file in enumerateMarkdownShallow(
            codexHome.appendingPathComponent("memories", isDirectory: true)) {
            // Codex 没有 frontmatter，会话归属写在正文的 rollout_summary_files 段落里
            let refs = readHead(file, bytes: 262_144).map(extractCodexSessionRefs) ?? []
            add(file, source: .codex,
                scope: file.deletingPathExtension().lastPathComponent, kind: .generated,
                relatedSessions: refs)
        }

        // opencode 全局 AGENTS.md（~/.config/opencode/AGENTS.md，遵循 AGENTS.md 标准）
        add(opencodeHome.appendingPathComponent("AGENTS.md"), source: .opencode,
            scope: "全局", kind: .instructions)
        // opencode memories/**/*.md（createMemory 写这里，索引须对齐避免死路径）
        for file in enumerateMarkdown(opencodeHome.appendingPathComponent("memories", isDirectory: true)) {
            add(file, source: .opencode, scope: file.deletingPathExtension().lastPathComponent)
        }

        // grok 跨会话记忆 ~/.grok/memory/**/*.md（实验特性，目录可能不存在）
        if let grokMemoryRoot {
            for file in enumerateMarkdown(grokMemoryRoot) {
                add(file, source: .grok, scope: file.deletingPathExtension().lastPathComponent)
            }
        }

        // kimi 全局记忆 ~/.kimi-code/AGENTS.md（Kimi 唯一全局记忆文件，AGENTS.md-first）
        if let kimiHome {
            add(kimiHome.appendingPathComponent("AGENTS.md"), source: .kimi,
                scope: "全局", kind: .instructions)
        }

        // gemini 全局记忆 ~/.gemini/GEMINI.md（GEMINI.md-first）
        if let geminiHome {
            add(geminiHome.appendingPathComponent("GEMINI.md"), source: .gemini,
                scope: "全局", kind: .instructions)
        }

        // qwen：全局 memories/*.md + 项目级 projects/<encoded>/memory/**/*.md（Claude 式布局）
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

        // hermes：三份 profile 级指令文件，**无项目级记忆概念**。
        //   memories/MEMORY.md = agent 自记、memories/USER.md = 用户画像、SOUL.md = 人格身份。
        // ⚠ MEMORY/USER 正文是「条目以 \n§\n 相连」的扁平格式且有字数上限（2200 / 1375），
        //   外部改坏格式或超限会触发 Hermes 的漂移保护：它存一份 .bak 后**拒绝后续写入**。
        if let hermesHome {
            let memories = hermesHome.appendingPathComponent("memories", isDirectory: true)
            // MEMORY / USER 是 **agent 自己写的记忆**（不是用户维护的指令）→ 归记忆；
            // SOUL 是人格身份设定，等价于系统提示 → 归指令。
            add(memories.appendingPathComponent("MEMORY.md"), source: .hermes,
                scope: "MEMORY", kind: .userManaged)
            add(memories.appendingPathComponent("USER.md"), source: .hermes,
                scope: "USER", kind: .userManaged)
            add(hermesHome.appendingPathComponent("SOUL.md"), source: .hermes,
                scope: "SOUL", kind: .instructions)
        }

        // codebuddy 全局记忆 ~/.codebuddy/memery/**/*.md（官方拼写就是 memery，勿"修正"）
        if let codeBuddyMemoryRoot {
            for file in enumerateMarkdown(codeBuddyMemoryRoot) {
                add(file, source: .codebuddy,
                    scope: file.deletingPathExtension().lastPathComponent)
            }
        }

        // qoder 全局记忆 memories/<user-hash>/global/<category>/**/*.md：
        // scope 取相对 global/ 的类别路径（拿不到类别就退回文件名）
        if let qoderMemoriesRoot {
            for file in enumerateMarkdown(qoderMemoriesRoot) {
                add(file, source: .qoder,
                    scope: qoderMemoryScope(file: file, root: qoderMemoriesRoot))
            }
        }

        // trae 记忆库（**只有 CN 版有**）：
        //   memory/user_profile.md                        ← 全局用户画像
        //   memory/projects/<encoded>/project_memory.md   ← 项目记忆
        //   memory/projects/<encoded>/<YYYYMMDD>/topics.md ← 每日会话话题摘要（只读流水）
        // 三者都是 Trae 自己写的 → 归**记忆**；用户手写规则在下面单独归**指令**。
        // 不收 `session_memory_<id>.jsonl`：那是逐回合流水且不是 markdown。
        if let traeMemoryRoot {
            add(traeMemoryRoot.appendingPathComponent("user_profile.md"),
                source: .trae, scope: "全局", kind: .userManaged)
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
                    // 这份摘要覆盖了哪些会话。path 一律 nil —— Trae 没有可跳转的转录文件，
                    // UI 会据此置灰（同 CLAUDE.md 里「originSessionPath == nil 就置灰」那条）。
                    let refs = TraeSessionIndexer.parseTopics(fileURL: topics)
                        .map { MemorySessionRef(sessionId: $0.sessionId, path: nil) }
                    add(topics, source: .trae,
                        scope: "\(projectName) · \(dayDir.lastPathComponent)",
                        projectName: projectName, kind: .generated,
                        libraryKey: libraryKey, relatedSessions: refs)
                }
            }
        }

        // trae 用户手写规则 → **指令**（两个渠道各自一套，scope 用 dotfile 目录名区分）
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

        // trae 项目规则 <repo>/.trae/rules/*.md（含旧的单文件名 project_rules.md）→ 指令
        for (root, name) in projectRoots {
            for file in enumerateMarkdown(TraePaths.projectRulesRoot(repoRoot: root)) {
                add(file, source: .trae,
                    scope: file.deletingPathExtension().lastPathComponent,
                    projectName: name, kind: .instructions)
            }
        }

        // cursor 项目规则 <repo>/.cursor/rules/*.mdc（官方 create-rule 技能里的约定）：
        // 这是 Cursor 唯一的本地"记忆"形态——它没有全局记忆目录，`cursor/memoriesEnabled`
        // 指的是服务端记忆。.mdc 就是带 YAML frontmatter 的 markdown，按扩展名单独收。
        for (root, name) in projectRoots {
            let rulesDir = root.appendingPathComponent(".cursor/rules", isDirectory: true)
            for file in enumerateFiles(rulesDir, extensions: ["mdc", "md"]) {
                add(file, source: .cursor,
                    scope: file.deletingPathExtension().lastPathComponent,
                    projectName: name, kind: .instructions)
            }
        }

        // 项目根记忆（各仓库根下的约定文件）：CLAUDE.md→Claude、GEMINI.md→Gemini、
        // AGENTS.md→Codex/opencode/Kimi 共用（归 Codex 一次避免重复）；
        // .kimi-code/AGENTS.md 是 Kimi 专属的项目级覆盖，单独归 Kimi
        for (root, name) in projectRoots {
            add(root.appendingPathComponent("CLAUDE.md"), source: .claude,
                scope: name, projectName: name, kind: .instructions)
            add(root.appendingPathComponent("GEMINI.md"), source: .gemini,
                scope: name, projectName: name, kind: .instructions)
            add(root.appendingPathComponent("QWEN.md"), source: .qwen,
                scope: name, projectName: name, kind: .instructions)
            add(root.appendingPathComponent(".kimi-code/AGENTS.md"),
                source: .kimi, scope: name, projectName: name, kind: .instructions)
        }

        // Codex 项目指令只沿实际近期 cwd 的 root → cwd 链发现；项目根始终纳入。
        var codexScopes = codexInstructionScopes
        codexScopes.append(contentsOf: projectRoots.map {
            (directory: $0.root, projectName: $0.name, scope: $0.name)
        })
        var seenInstructionDirs = Set<String>()
        for item in codexScopes where seenInstructionDirs.insert(item.directory.path).inserted {
            addEffectiveCodexInstruction(
                directory: item.directory, scope: item.scope, projectName: item.projectName)
        }

        // 同一 path 只留一条：MemoryEntry.id = path，重复 id 同样会让 SwiftUI 列表/网格错位。
        var seenPaths = Set<String>()
        result = result.filter { seenPaths.insert($0.path).inserted }
        return result.sorted {
            ($0.source.rawValue, $0.scope, $0.path) < ($1.source.rawValue, $1.scope, $1.path)
        }
    }

    /// 按扩展名枚举（Cursor 规则是 `.mdc`：带 YAML frontmatter 的 markdown 变体，
    /// `enumerateMarkdown` 只认 `.md` 会整片漏掉）
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

    /// **只收直属子级**的 markdown（不进子目录）。
    /// Codex 的 memories 目录用它：那是个混装记忆/会话摘要/扩展/技能的 git 仓库，递归即误收。
    /// 直属子目录（按名字排序，保证同一次扫描结果稳定）
    static func subdirectories(of dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Trae 记忆库的项目名。目录名是 `<正向编码路径>--p<N>-<hash>`，比 Claude 多一个后缀，
    /// 所以先剥后缀再走同一套「正向编码已知根再比对」的逻辑（`-` 不可反解，见 CLAUDE.md）。
    static func resolveTraeProjectName(
        projectDir: URL, knownRoots: [(root: URL, name: String)]
    ) -> String {
        let encoded = projectDir.lastPathComponent
        let stripped = TraeSessionIndexer.stripProjectSuffix(encoded)
        for (root, name) in knownRoots {
            let candidate = encodeProjectDirName(root.standardizedFileURL.path)
            if candidate == stripped || candidate == encoded { return name }
        }
        // 比不中就退回有损的末段启发式 —— 但要用**剥掉后缀之后**的串，
        // 否则末段会是那串 hash（`friendlyProject` 只取最后一段）。
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

    /// qoder 记忆的展示 scope：相对 memories 根的去扩展名路径；
    /// 剥掉 <user-hash>/global/ 前缀，留下 <category>/<名>（无此前缀时原样返回）
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

    /// Claude 把 cwd 的 "/" 编码成 "-"；取末段作为项目名。
    /// **有损**：`aftership-semantic-layer` 会被切成 `layer` —— 只在反查全失败时兜底用。
    static func friendlyProject(fromEncoded encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        return parts.last.map(String.init) ?? encoded
    }

    /// Claude / Qwen 的项目目录名编码规则（实勘 11 个目录全对）：`/`、`.`、`_` **都**变 `-`。
    /// 多对一、不可反解 —— 所以项目名只能正向编码已知路径来比对，绝不能反着切字符串。
    public static func encodeProjectDirName(_ path: String) -> String {
        var encoded = ""
        for character in path {
            encoded.append(character == "/" || character == "." || character == "_" ? "-" : character)
        }
        return encoded
    }

    /// 记忆库的项目名：
    ///  1. 把每个已知仓库根正向编码后与目录名全等比对（命中就用该根的名字）；
    ///  2. 没命中就读该目录里最新一个 `*.jsonl` 的头部拿真实 cwd，取末段目录名；
    ///  3. 都不行才退回有损的末段启发式。
    /// 编码是多对一的，理论上可能多根命中同一目录名 —— 取 `knownRoots` 里第一个（调用方按最近活跃排序），
    /// 保证同一次扫描结果稳定。
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

    /// 目录里最近改动的 transcript 头部记录的 cwd（`ClaudeSessionIndexer.headInfo` 同模块可用）。
    /// 只读一个文件：这是「项目名反查」的兜底，不值得为它再全量扫一遍会话。
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

    // MARK: - 记忆文档解析（frontmatter + 正文 wiki 链接）

    /// 读一次文件（上限 64KB）拿到 frontmatter 键值与正文里的 `[[链接]]`。
    /// 上限不能沿用 `readHead` 的 8KB：记忆库索引 MEMORY.md 实测 11.8KB，链接全在正文里，
    /// 8KB 会把后半截链接整片吞掉。
    static func parseMemoryDocument(
        _ url: URL, bytes: Int = 65536, markdownLinks: Bool = false
    ) -> (fields: [String: String], links: [String], indexedTargets: [String]) {
        guard let text = readHead(url, bytes: bytes) else { return ([:], [], []) }
        return (
            parseFrontmatterFields(text),
            extractWikiLinks(text),
            markdownLinks ? extractMarkdownLinks(text) : [])
    }

    /// Codex `MEMORY.md` 正文里的会话引用。
    ///
    /// 它没有 frontmatter，项目与会话归属写在正文的 `### rollout_summary_files` 段落里，
    /// 每行形如：
    /// ```
    /// - rollout_summaries/2026-07-27T…-xxx.md (cwd=…, rollout_path=/Users/…/rollout-….jsonl,
    ///   updated_at=…, thread_id=019fa2f0-c124-7c03-a2d1-c6debaf69293, 状态描述)
    /// ```
    /// 取 `thread_id=` 作会话 id、`rollout_path=` 判断记录是否还在（实勘 15 条全部可达，
    /// 比 Claude 的 `originSessionId` 37/84 可靠得多）。
    ///
    /// ⚠️ **不要用 `cwd=` 归项目**：实勘有一条指向 `~/.slock/agents/<uuid>`（sandbox 工作目录
    /// 而非仓库根），按它归会造出一个不存在的项目。
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

    /// 取 `key=value` 的 value，止于逗号 / 右括号 / 空白
    private static func value(of key: String, in line: String) -> String? {
        guard let start = line.range(of: key) else { return nil }
        let rest = line[start.upperBound...]
        let end = rest.firstIndex { $0 == "," || $0 == ")" || $0 == " " } ?? rest.endIndex
        let value = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// markdown 链接的目标（`[标题](feedback_push.md)` → `feedback_push.md`）。
    ///
    /// 只给**记忆库索引**（MEMORY.md）用：Claude 的索引正文是「一行一条 markdown 链接」，
    /// 靠它才能算出「哪些记忆文件没被索引收录」—— 那些条目 agent 根本读不到（实勘
    /// semantic-layer 库 72 条里有 2 条如此）。只收 `.md` 目标，外链与图片一律跳过。
    public static func extractMarkdownLinks(_ text: String) -> [String] {
        let characters = Array(text)
        var targets: [String] = []
        var seen = Set<String>()
        var index = 0
        while index + 1 < characters.count {
            // 找 "](" —— 链接文字与目标的交界
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
            // 去掉锚点/查询串；只要 .md
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

    /// 正文里的 `[[目标]]`。跨行、超长（>120 字符）的一律不算 —— 那通常是正文里
    /// 把 `[[…]]` 当强调号用（实勘 115 条链接里有 2 条如此），当成链接会造出假边。
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

    // MARK: - frontmatter 解析（纯函数，单测目标）

    /// 取文件最前的 `---` … `---` YAML 段中的 name / description（简单 key: value）。
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
            if trimmed == "---" { break }  // frontmatter 结束
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

    /// 解析 frontmatter 的全部简单键值（供 agent 定义等复用）。
    /// 支持：单行 `key: value`（去引号）；block scalar（`key: |` / `key: >`，收编后续更深缩进行）。
    /// 不解析嵌套 map / 复杂 YAML——超出即忽略。键统一小写。
    ///
    /// ⚠️ **嵌套 map 的子键会被当顶层键收下**（`metadata:` 下的 `type` / `originSessionId` 直接出现在
    /// 返回值里）。记忆索引**有意**依赖这个行为拿 `metadata.*`：别把它"修正"成严格 YAML，
    /// 那会让 MemoryEntry 的类型与来源会话整片变空。
    public static func parseFrontmatterFields(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        var index = 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }  // frontmatter 结束
            index += 1
            if trimmed.isEmpty { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.first == "|" || value.first == ">" {
                // block scalar：收编后续更深缩进的行，直到回到 0 缩进的 key 或 ---
                let fold = value.first == ">"
                var block: [String] = []
                while index < lines.count {
                    let line = lines[index]
                    let lineTrimmed = line.trimmingCharacters(in: .whitespaces)
                    if lineTrimmed == "---" { break }
                    if lineTrimmed.isEmpty { block.append(""); index += 1; continue }
                    let leading = line.prefix { $0 == " " || $0 == "\t" }.count
                    if leading == 0 { break }  // 回到顶层 key，块结束
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
