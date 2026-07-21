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
    public var scope: String  // "全局" / 项目名 / 文件名（展示用）
    public var path: String
    public var kind: MemoryEntryKind
    /// 归属项目名；nil = 系统级记忆（全局 / 用户自建），非 nil = 该项目的记忆
    public var projectName: String?
    public var sizeBytes: UInt64
    public var modifiedAt: Date
    public var isEditable: Bool { kind != .generated }
    public var isDeletable: Bool { kind != .generated }

    public init(
        source: AgentSource, scope: String, path: String,
        projectName: String? = nil,
        kind: MemoryEntryKind = .userManaged,
        sizeBytes: UInt64, modifiedAt: Date
    ) {
        self.source = source
        self.scope = scope
        self.path = path
        self.kind = kind
        self.projectName = projectName
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
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
        opencodeSkillsRoot: URL? = nil,
        grokSkillsRoot: URL? = nil,
        kimiSkillsRoot: URL? = nil,
        geminiSkillsRoot: URL? = nil,
        qwenSkillsRoot: URL? = nil,
        antigravitySkillsRoots: [URL] = [],
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
        // antigravity：内置 builtin/skills（用户级 ~/.gemini/skills 已归 gemini）
        for root in antigravitySkillsRoots {
            result += scanSkillRoot(root, source: .antigravity, enabled: true, scope: .system)
            result += scanSkillRoot(
                disabledRoot(for: root), source: .antigravity, enabled: false, scope: .system)
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

    // MARK: - 记忆

    public static func indexMemory(
        claudeHome: URL, codexHome: URL, opencodeHome: URL,
        claudeProjectsRoot: URL,
        grokMemoryRoot: URL? = nil,
        kimiHome: URL? = nil,
        geminiHome: URL? = nil,
        qwenHome: URL? = nil,
        projectRoots: [(root: URL, name: String)] = [],
        codexInstructionScopes: [(directory: URL, projectName: String, scope: String)] = []
    ) -> [MemoryEntry] {
        let fm = FileManager.default
        var result: [MemoryEntry] = []

        func add(
            _ url: URL, source: AgentSource, scope: String,
            projectName: String? = nil, kind: MemoryEntryKind = .userManaged
        ) {
            guard fm.fileExists(atPath: url.path),
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return }
            result.append(MemoryEntry(
                source: source, scope: scope, path: url.path,
                projectName: projectName,
                kind: kind,
                sizeBytes: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast))
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
        // Claude 项目记忆：projects/<encoded>/memory/**/*.md（含 MEMORY.md）
        let projectDirs = (try? fm.contentsOfDirectory(
            at: claudeProjectsRoot, includingPropertiesForKeys: nil)) ?? []
        for proj in projectDirs {
            let memDir = proj.appendingPathComponent("memory", isDirectory: true)
            guard fm.fileExists(atPath: memDir.path) else { continue }
            let projName = friendlyProject(fromEncoded: proj.lastPathComponent)
            for file in enumerateMarkdown(memDir) {
                add(file, source: .claude, scope: projName, projectName: projName)
            }
        }

        // Codex 全局持久指令：AGENTS.override.md 优先于 AGENTS.md。
        addEffectiveCodexInstruction(directory: codexHome, scope: "全局")
        // Codex memories/**/*.md 是后台生成状态，仅供查看。
        for file in enumerateMarkdown(codexHome.appendingPathComponent("memories", isDirectory: true)) {
            add(file, source: .codex,
                scope: file.deletingPathExtension().lastPathComponent, kind: .generated)
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
            let qwenProjects = (try? fm.contentsOfDirectory(
                at: qwenHome.appendingPathComponent("projects", isDirectory: true),
                includingPropertiesForKeys: nil)) ?? []
            for proj in qwenProjects {
                let memDir = proj.appendingPathComponent("memory", isDirectory: true)
                guard fm.fileExists(atPath: memDir.path) else { continue }
                let projName = friendlyProject(fromEncoded: proj.lastPathComponent)
                for file in enumerateMarkdown(memDir) {
                    add(file, source: .qwen, scope: projName, projectName: projName)
                }
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

        return result.sorted {
            ($0.source.rawValue, $0.scope, $0.path) < ($1.source.rawValue, $1.scope, $1.path)
        }
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

    /// Claude 把 cwd 的 "/" 编码成 "-"；取末段作为项目名（含点的目录名会有损，但末段通常准确）
    static func friendlyProject(fromEncoded encoded: String) -> String {
        let trimmed = encoded.hasPrefix("-") ? String(encoded.dropFirst()) : encoded
        let parts = trimmed.split(separator: "-")
        return parts.last.map(String.init) ?? encoded
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
