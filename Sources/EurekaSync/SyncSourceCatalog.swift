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
    public var claudePlans: URL      // ~/.claude/plans（Claude 计划，本就是 .md）
    public var plansStaging: URL     // ~/…/Eureka/plans（Codex/opencode 计划物化暂存，含 codex/ 与 opencode/）
    /// 用户自定义同步目录：(本地根, 远端类目如 "custom/notes")。默认空 → 既有构造点不受影响
    public var customDirs: [(root: URL, category: String)] = []

    public init(
        claudeHome: URL, claudeProjects: URL, claudeSkills: URL,
        codexHome: URL, codexSessions: URL, codexSkills: URL,
        opencodeSkills: URL, opencodeDB: URL,
        grokSkills: URL, grokMemory: URL, grokSessions: URL,
        kimiSkills: URL, kimiSessions: URL,
        geminiHome: URL, geminiSessions: URL, geminiSkills: URL,
        claudePlans: URL, plansStaging: URL
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
        self.claudePlans = claudePlans
        self.plansStaging = plansStaging
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

        // 计划（.md 首类工件）：Claude 直接文件；Codex/opencode 由 PlanMaterializer 物化到暂存
        walk(root: roots.claudePlans, category: "claude/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("codex", isDirectory: true),
             category: "codex/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("opencode", isDirectory: true),
             category: "opencode/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("grok", isDirectory: true),
             category: "grok/plans", priority: 0, include: markdownOnly)
        walk(root: roots.plansStaging.appendingPathComponent("kimi", isDirectory: true),
             category: "kimi/plans", priority: 0, include: markdownOnly)

        // 用户自定义目录：远端类目由用户指定（custom/<名>），全部常规文件（隐藏文件仍跳过）
        for dir in roots.customDirs {
            walk(root: dir.root, category: dir.category, priority: 1, include: always)
        }

        return Result(candidates: candidates, skippedOversize: oversize)
    }

    /// 停用区同级目录：<root>.eureka-disabled（与 SkillMemoryIndexer.disabledRoot 同约定）
    static func disabledSibling(of root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }
}
