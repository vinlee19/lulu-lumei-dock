import EurekaKit
import Foundation

/// 跨源配置一致性检查：12 个 CLI 的技能 / 指令 / 记忆横向对账。
///
/// 纯函数放 EurekaIngest（输入全是已扫好的值类型），所以**阈值口径能被单测钉住** ——
/// 这块最大的风险不是算错，而是**报得太多**：一张全是噪声的卡，用户看两次就再也不看了。
/// 三条口径都是"自适应"的：拿用户自己已有的约定去对账，不照理想清单挑刺。
public enum ConsistencyChecker {
    /// 某种指令文件出现在 ≥ 这么多仓库 ⇒ 认定它是用户的习惯，别的仓库缺就可能是遗漏。
    /// 本机实测这样只报 3 个仓库（一个完全没配、两个各缺一种），另外 7 个齐全的不打扰。
    public static let instructionConventionMinRepos = 2
    /// 参与技能对账的源门槛。本机分布 claude=48，cursor/gemini/opencode/codebuddy=23，
    /// grok=8，codex=5，kimi=1 —— 门槛太低会把"只随手配过几个技能"的源也拉进来，
    /// 于是 8 个源全上榜，等于没信息。
    public static let skillComparableMinCount = 10
    /// 一个源缺这么多才值得报（零星差异通常是故意的）
    public static let skillGapMinCount = 3

    public struct Report: Equatable {
        public struct InstructionGap: Equatable, Identifiable {
            public var id: String { project }
            public var project: String
            public var present: [String]
            public var missing: [String]
        }
        public struct SkillSourceGap: Equatable, Identifiable {
            public var id: String { source.rawValue }
            public var source: AgentSource
            public var missing: [String]
        }
        public struct LibraryDrift: Equatable, Identifiable {
            public var id: String { key }
            public var key: String
            public var projectName: String
            public var unindexed: Int
            public var dangling: Int
        }
        public var instructionGaps: [InstructionGap] = []
        public var skillGaps: [SkillSourceGap] = []
        public var libraryDrifts: [LibraryDrift] = []

        public init() {}

        public var isClean: Bool {
            instructionGaps.isEmpty && skillGaps.isEmpty && libraryDrifts.isEmpty
        }
        public var issueCount: Int {
            instructionGaps.count + skillGaps.count + libraryDrifts.count
        }
    }

    /// MCP 同名异义：同一个 server 名在多个源里配置，但定义互相冲突
    /// （实勘案例：notion 在 codex 是远程 mcp.notion.com、在 grok 是本地 npx——
    /// 矩阵里都亮"已配置"，实则是两个实现）。只报**定义确实不同**的，纯展示不误伤。
    public struct MCPDrift: Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        /// 各处定义的归一化摘要（去重排序，如 ["npx …", "https://…"]）
        public var variants: [String]
    }

    /// 与 report 解耦的独立检查（MCP 条目在 MCPService 手里，调用点不同）
    public static func mcpDrifts(_ servers: [MCPServerEntry]) -> [MCPDrift] {
        var byName: [String: [MCPServerEntry]] = [:]
        for entry in servers {
            byName[entry.name.lowercased(), default: []].append(entry)
        }
        var drifts: [MCPDrift] = []
        for (_, entries) in byName where entries.count >= 2 {
            let variants = Set(entries.compactMap { entry -> String? in
                let summary = entry.commandSummary ?? entry.urlSummary
                guard let summary, !summary.isEmpty else { return nil }
                return summary
            })
            guard variants.count >= 2 else { continue }
            drifts.append(MCPDrift(
                name: entries[0].name, variants: variants.sorted()))
        }
        return drifts.sorted { $0.name < $1.name }
    }

    /// `repoNames` = 本轮发现的全部仓库名（用来找出「完全没配指令」的那些）
    public static func report(
        skills: [SkillEntry], memories: [MemoryEntry],
        libraries: [MemoryLibrary], repoNames: [String]
    ) -> Report {
        var report = Report()

        // MARK: ① 项目指令缺口
        var filesByProject: [String: Set<String>] = [:]
        for entry in memories where entry.kind == .instructions {
            guard let project = entry.projectName else { continue }
            filesByProject[project, default: []]
                .insert(URL(fileURLWithPath: entry.path).lastPathComponent)
        }
        // 完全没配指令的仓库只有「活跃」的才参与 —— 活跃 = 它有记忆库。
        // 否则 ProjectResolver 顺着近期 cwd 认出来的 sandbox 工作目录
        // （`~/.slock/agents/<uuid>` 这类，本机 17 个"仓库"里有 5 个如此）会各刷一条
        // "缺 CLAUDE.md"，而用户压根没打算在那儿用 agent。
        let libraryProjects = Set(libraries.map(\.projectName))
        for name in repoNames
        where filesByProject[name] == nil && libraryProjects.contains(name) {
            filesByProject[name] = []
        }
        var conventionCount: [String: Int] = [:]
        for files in filesByProject.values {
            for file in files { conventionCount[file, default: 0] += 1 }
        }
        let conventions = conventionCount
            .filter { $0.value >= instructionConventionMinRepos }
            .keys.sorted()
        if !conventions.isEmpty {
            for (project, files) in filesByProject {
                let missing = conventions.filter { !files.contains($0) }
                guard !missing.isEmpty else { continue }
                report.instructionGaps.append(.init(
                    project: project, present: files.sorted(), missing: missing))
            }
            report.instructionGaps.sort {
                $0.missing.count == $1.missing.count
                    ? $0.project < $1.project : $0.missing.count > $1.missing.count
            }
        }

        // MARK: ② 技能跨源缺口（只看用户自建/安装的）
        var sourcesByName: [String: Set<AgentSource>] = [:]
        var countBySource: [AgentSource: Int] = [:]
        for skill in skills where skill.origin == .user {
            sourcesByName[
                SkillMemoryIndexer.normalizeSkillName(skill.name), default: []
            ].insert(skill.source)
            countBySource[skill.source, default: 0] += 1
        }
        let comparable = Set(countBySource.filter { $0.value >= skillComparableMinCount }.keys)
        // **只报「只差这一个源」的技能**：一个技能在其它所有可比源都装了、独独缺一个，
        // 大概率是漏了。而"claude 有 48 个、cursor 只有 23 个"这种差异多半是故意的
        // （用户主要用某个源），报出来既多又没有可执行动作 —— eureka 也没有跨源同步技能的能力。
        var missingBySource: [AgentSource: [String]] = [:]
        for (name, owners) in sourcesByName {
            let missing = comparable.subtracting(owners)
            guard missing.count == 1, let target = missing.first,
                  owners.intersection(comparable).count >= 2
            else { continue }
            missingBySource[target, default: []].append(name)
        }
        report.skillGaps = missingBySource
            .filter { $0.value.count >= skillGapMinCount }
            .map { .init(source: $0.key, missing: $0.value.sorted()) }
            .sorted { $0.missing.count > $1.missing.count }

        // MARK: ③ 记忆库索引漂移
        report.libraryDrifts = libraries.filter(\.hasDrift).map {
            .init(key: $0.key, projectName: $0.projectName,
                  unindexed: $0.unindexedEntries.count, dangling: $0.danglingIndexRefs.count)
        }
        return report
    }
}
