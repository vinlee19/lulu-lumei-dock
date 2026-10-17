import EurekaKit
import Foundation

/// Cross-source config consistency check: reconciles skills / instructions / memory across 12 CLIs.
///
/// Pure functions live in EurekaIngest (the inputs are all already-scanned value types), so **the
/// threshold rules can be pinned by unit tests**. The biggest risk here isn't miscounting but
/// **reporting too much**: a card full of noise gets looked at twice and then never again. All
/// three rules are "adaptive": they reconcile against the user's own existing conventions instead
/// of nitpicking against an ideal checklist.
public enum ConsistencyChecker {
    /// An instruction file kind present in ≥ this many repos ⇒ treat it as the user's habit; a repo
    /// missing it may be an oversight. Measured locally, this reports only 3 repos (one with
    /// nothing configured, two each missing one kind) and leaves the other 7 complete ones alone.
    public static let instructionConventionMinRepos = 2
    /// Minimum skill count for a source to take part in skill reconciliation. Local distribution:
    /// claude=48, cursor/gemini/opencode/codebuddy=23, grok=8, codex=5, kimi=1. Too low a threshold
    /// pulls in sources that "only had a few skills set up casually", and then all 8 sources make
    /// the list, which carries no information.
    public static let skillComparableMinCount = 10
    /// A source must be missing at least this many to be worth reporting (scattered differences are
    /// usually deliberate)
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

    /// MCP same name, different meaning: the same server name is configured in several sources but
    /// the definitions conflict (observed case: notion is the remote mcp.notion.com in codex but a
    /// local npx in grok; both light up as configured in the matrix, yet they are two
    /// implementations). Only **genuinely different definitions** are reported; display-only, no
    /// false positives.
    public struct MCPDrift: Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Normalized summary of each definition (deduplicated and sorted, e.g. ["npx …",
        /// "https://…"])
        public var variants: [String]
    }

    /// Standalone check decoupled from report (MCP entries live in MCPService, called from a
    /// different place)
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

    /// `repoNames` = every repo name discovered this pass (used to find the ones with no
    /// instructions configured at all)
    public static func report(
        skills: [SkillEntry], memories: [MemoryEntry],
        libraries: [MemoryLibrary], repoNames: [String]
    ) -> Report {
        var report = Report()

        // MARK: 1. Project instruction gaps
        var filesByProject: [String: Set<String>] = [:]
        for entry in memories where entry.kind == .instructions {
            guard let project = entry.projectName else { continue }
            filesByProject[project, default: []]
                .insert(URL(fileURLWithPath: entry.path).lastPathComponent)
        }
        // Repos with no instructions at all only count when they are "active", i.e. have a memory
        // library. Otherwise the sandbox working directories ProjectResolver picks up from recent
        // cwds (things like `~/.slock/agents/<uuid>`; 5 of the 17 local "repos" are like that)
        // would each get a "missing CLAUDE.md" entry, though the user never meant to use agents
        // there.
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

        // MARK: 2. Cross-source skill gaps (user-created/installed skills only)
        var sourcesByName: [String: Set<AgentSource>] = [:]
        var countBySource: [AgentSource: Int] = [:]
        for skill in skills where skill.origin == .user {
            sourcesByName[
                SkillMemoryIndexer.normalizeSkillName(skill.name), default: []
            ].insert(skill.source)
            countBySource[skill.source, default: 0] += 1
        }
        let comparable = Set(countBySource.filter { $0.value >= skillComparableMinCount }.keys)
        // **Only report skills missing from exactly one source**: a skill installed in every other
        // comparable source but missing from one is most likely an oversight. A gap like "claude
        // has 48, cursor only 23" is usually deliberate (the user mainly uses one source);
        // reporting it is noisy and offers no actionable step, and eureka can't sync skills across
        // sources anyway.
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

        // MARK: 3. Memory library index drift
        report.libraryDrifts = libraries.filter(\.hasDrift).map {
            .init(key: $0.key, projectName: $0.projectName,
                  unindexed: $0.unindexedEntries.count, dangling: $0.danglingIndexRefs.count)
        }
        return report
    }
}
