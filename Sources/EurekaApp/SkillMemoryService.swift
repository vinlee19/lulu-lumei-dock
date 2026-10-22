import AppKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaUsage
import Foundation

/// Browsing and full management of skills & memories across every agent source (including
/// project-level dirs; discovery rules in ProjectRoots.recentCwds /
/// SkillMemoryIndexer.projectSkillRoots). Owns a background scan queue; edits back up before
/// writing, deletes go to the Trash, and disabling = moving to a sibling *.eureka-disabled dir (all
/// reversible).
final class SkillMemoryService: ObservableObject {
    @Published private(set) var skills: [SkillEntry] = []
    /// **Standalone memory entries** in the memory list (each CLI's global memory dir). Two things
    /// are not here: project memory-library entries fold into `libraries` (one project's 70+
    /// entries would drown out the global memories); **user-maintained persistent instructions**
    /// such as CLAUDE.md / AGENTS.md belong to `instructions` - they aren't memories.
    @Published private(set) var memories: [MemoryEntry] = []
    /// Persistent instruction files: CLAUDE.md / AGENTS.md / GEMINI.md / QWEN.md / `.cursor/rules`
    /// / Hermes SOUL. They get their own Instructions tab: they are rules the user writes for the
    /// agent, not memories the agent accumulated, and counting them together would make the "how
    /// many memories" number meaningless.
    @Published private(set) var instructions: [MemoryEntry] = []
    /// Memory libraries (Claude / Qwen `projects/<encoded>/memory`); empty while searching
    /// (matching entries are expanded flat instead)
    @Published private(set) var libraries: [MemoryLibrary] = []
    /// **The single counting basis**: standalone entries + every library file (= the hit set while
    /// searching). The stats card, source chips and search result count all read it - they used to
    /// read the filtered list arrays, so none of the 97 project memories were counted.
    @Published private(set) var memoryEntries: [MemoryEntry] = []
    @Published private(set) var scanning = false
    /// Phase copy while scanning (once the list has data, the small spinner in the search box
    /// alone doesn't show a scan is running); set to nil when done
    @Published private(set) var scanPhase: String?
    /// When the last scan finished. nil = never scanned (refresh's criterion); the UI uses it
    /// to show "last scanned X ago"
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    /// Cross-page deep link: file path of the entry to focus (written by PopoverRootView,
    /// cleared once the matching tab consumes it)
    @Published var focusPath: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    /// .utility: repo discovery plus a walk of every skill / memory / instruction file; it must
    /// not compete with the UI on the performance cores
    private let queue = DispatchQueue(label: "com.vinlee.eureka.skillmemory", qos: .utility)
    private let resolver = ProjectResolver()
    private var allSkills: [SkillEntry] = []
    private var allMemories: [MemoryEntry] = []
    private var allLibraries: [MemoryLibrary] = []
    /// Every repo root found by this scan. The consistency check needs it to find repos with
    /// **no** instruction files at all -
    /// such repos never appear in allMemories (observed: starrocks is one).
    private var allRepoRoots: [(root: URL, name: String)] = []
    /// Memory library → relationship graph. Building it is a pure function but not cheap
    /// (semantic-layer has 126 nodes),
    /// and SwiftUI re-evaluates body repeatedly → cache per library, cleared on every rescan.
    private var graphCache: [String: MemoryGraph.Graph] = [:]
    /// `"<library key>|<canvas width>"` → layout result (see layout(for:width:))
    private var layoutCache: [String: MemoryGraphLayout.Result] = [:]

    // MARK: - Scanning

    /// force = false: scan only if never scanned - startup warm-up and page onAppear both take
    /// this path, so it's naturally idempotent
    /// and entering the page doesn't blindly rescan (the data is already ready from warm-up).
    /// force = true: unconditional full rescan, used only by the refresh button.
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
        // A user hitting refresh wants the latest: drop the cwd discovery cache, otherwise
        // within 60s they'd get the previous result
        if force { ProjectScopeDiscovery.invalidateCache() }
        scanning = true
        scanPhase = L10n.text("Scanning skills and memories…", zhHans: "正在扫描技能与记忆…")
        queue.async { [weak self] in
            guard let self else { return }
            // Repo root of each project (skills and memories share one discovery)
            let repoRoots = ProjectScopeDiscovery.repoRoots(resolver: self.resolver)
            let codexInstructionScopes = ProjectScopeDiscovery.codexInstructionScopes(
                resolver: self.resolver)
            // Project-level skill roots: same discovery rules as cloud backup (see
            // SkillMemoryIndexer.projectSkillRoots)
            let projectRoots = SkillMemoryIndexer.projectSkillRoots(repoRoots: repoRoots)
            // Built-in / bundled skill roots (read-only, for the detail matrix and cross-source
            // checks; not listed)
            var bundledRoots: [(root: URL, source: AgentSource)] = []
            for root in SkillMemoryIndexer.claudePluginSkillsRoots() {
                bundledRoots.append((root, .claude))
            }
            bundledRoots.append((
                SkillMemoryIndexer.codexSkillsRoot()
                    .appendingPathComponent(".system", isDirectory: true), .codex))
            bundledRoots.append((GrokPaths.bundledSkillsRoot(), .grok))
            // antigravity: the first of skillsRoots is user-level, the rest are builtin
            for root in AntigravityPaths.skillsRoots().dropFirst() {
                bundledRoots.append((root, .antigravity))
            }
            // cursor's built-in skills in ~/.cursor/skills-cursor (officially distributed, updated
            // with the client,
            // and its own create-skill skill explicitly says "never write here" → read-only,
            // treated as bundled)
            bundledRoots.append((CursorPaths.bundledSkillsRoot(), .cursor))
            // trae has built-in skills in **two** places with different contents: `builtin_skills`
            // (TRAE-code-review...) and
            // `builtin/global/skills` (TRAE-computer-use...). Scanning only one misses half.
            for root in TraePaths.bundledSkillsRoots() {
                bundledRoots.append((root, .trae))
            }
            let skills = SkillMemoryIndexer.indexSkills(
                claudeSkillsRoot: SkillMemoryIndexer.claudeSkillsRoot(),
                codexSkillsRoot: SkillMemoryIndexer.codexSkillsRoot(),
                // Codex also stuffs skills into the memories git repo; if not collected here, the
                // memory page shows a fake memory
                codexMemorySkillsRoot: SkillMemoryIndexer.codexHome()
                    .appendingPathComponent("memories/skills", isDirectory: true),
                opencodeSkillsRoot: OpencodePaths.skillsRoot(),
                grokSkillsRoot: GrokPaths.skillsRoot(),
                kimiSkillsRoot: KimiPaths.skillsRoot(),
                geminiSkillsRoot: GeminiPaths.skillsRoot(),
                qwenSkillsRoot: QwenPaths.skillsRoot(),
                // user-level ~/.gemini/antigravity/skills; builtin ones go through bundledRoots
                antigravitySkillsRoots: [AntigravityPaths.userSkillsRoot()],
                hermesSkillsRoot: HermesPaths.skillsRoot(),
                // Hermes keeps its enable/disable list in config.yaml (not in dir placement);
                // EurekaIngest doesn't depend on
                // EurekaInstall, so the app layer reads it and passes it in
                hermesDisabledSkills: HermesConfigEditor.disabledSkills(
                    from: ConfigFile.read(HermesPaths.configFile())),
                cursorSkillsRoot: CursorPaths.skillsRoot(),
                codeBuddySkillsRoot: CodeBuddyPaths.skillsRoot(),
                qoderSkillsRoot: QoderPaths.skillsRoot(),
                // zcode skills live in the shared ~/.agents/skills (shared with the desktop app)
                zcodeSkillsRoot: ZcodePaths.skillsRoot(),
                // CN and international may both be installed → one writable root per installed
                // channel
                traeSkillsRoots: TraePaths.userSkillsRoots(),
                projectSkillRoots: projectRoots,
                bundledRoots: bundledRoots)
            let memories = SkillMemoryIndexer.indexMemory(
                claudeHome: SkillMemoryIndexer.claudeHome(),
                codexHome: SkillMemoryIndexer.codexHome(),
                opencodeHome: OpencodePaths.configHome(),
                claudeProjectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(),
                grokMemoryRoot: GrokPaths.memoryRoot(),
                kimiHome: KimiPaths.configHome(),
                geminiHome: GeminiPaths.configHome(),
                qwenHome: QwenPaths.configHome(),
                hermesHome: HermesPaths.configHome(),
                codeBuddyMemoryRoot: CodeBuddyPaths.memoryRoot(),
                qoderMemoriesRoot: QoderPaths.memoriesRoot(),
                // Only CN has a memory library; user-written rules exist in both channels
                traeMemoryRoot: TraePaths.memoryRoot(),
                traeRulesHomes: TraePaths.installedChannels().map { TraePaths.configHome($0) },
                projectRoots: repoRoots,
                codexInstructionScopes: codexInstructionScopes)
            let libraries = MemoryLibrary.group(memories)
            DispatchQueue.main.async {
                self.allSkills = skills
                self.allMemories = memories
                self.allLibraries = libraries
                self.allRepoRoots = repoRoots
                self.graphCache.removeAll()
                self.layoutCache.removeAll()
                self.scanning = false
                self.scanPhase = nil
                self.lastScanAt = Date()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        // The list shows only user-created / installed skills; bundled ones are only for the
        // detail matrix and cross-source checks
        let userSkills = allSkills.filter { $0.origin == .user }
        // Memories split three ways (**no entry is dropped**):
        //  1. Instruction files → instructions (own tab)
        //  2. Standalone memories outside any library → memories
        //  3. Library entries → folded into libraries, one row per library, but still counted
        //     in the counting basis memoryEntries
        let standalone = allMemories.filter { $0.libraryKey == nil }
        let standaloneMemories = standalone.filter { $0.kind != .instructions }
        let instructionFiles = standalone.filter { $0.kind == .instructions }
        let libraryFiles = allMemories.filter { $0.libraryKey != nil }
        guard !query.isEmpty else {
            skills = userSkills
            memories = standaloneMemories
            instructions = instructionFiles
            libraries = allLibraries
            memoryEntries = standaloneMemories + libraryFiles
            return
        }
        skills = userSkills.filter {
            [$0.name, $0.description, $0.path]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
        // While searching, **libraries expand**: matching library entries merge flat into the
        // results, otherwise searching for a memory would find nothing
        let matched = (standaloneMemories + libraryFiles).filter { Self.matches($0, query: query) }
        memories = matched
        instructions = instructionFiles.filter { Self.matches($0, query: query) }
        libraries = []
        memoryEntries = matched
    }

    private static func matches(_ entry: MemoryEntry, query: String) -> Bool {
        [entry.title, entry.scope, entry.path, entry.summary ?? "", entry.projectName ?? ""]
            .joined(separator: " ").lowercased().contains(query)
    }

    // MARK: - Cross-source configuration matrix / name normalization

    /// How a skill name is configured in each source (detail page logo matrix):
    /// source → .user/.bundled (missing = not configured).
    /// Best-effort: matches name or dir name by normalized name (strip `plugin:` prefix,
    /// lowercase); within a source, user wins over bundled.
    func configurations(forName name: String) -> [AgentSource: SkillOrigin] {
        let key = Self.normalizeSkillName(name)
        var result: [AgentSource: SkillOrigin] = [:]
        for entry in allSkills {
            let dirName = URL(fileURLWithPath: entry.directory).lastPathComponent
            guard Self.normalizeSkillName(entry.name) == key
                || Self.normalizeSkillName(dirName) == key else { continue }
            if result[entry.source] == .user { continue }
            result[entry.source] = entry.origin
        }
        return result
    }

    /// Normalizes a skill name for cross-source / stats matching (delegates to
    /// SkillMemoryIndexer, a pure function for easy unit testing)
    static func normalizeSkillName(_ name: String) -> String {
        SkillMemoryIndexer.normalizeSkillName(name)
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func skills(for source: AgentSource) -> [SkillEntry] { skills.filter { $0.source == source } }
    func memories(for source: AgentSource) -> [MemoryEntry] { memories.filter { $0.source == source } }

    // MARK: - Memory stats (single basis: memoryEntries, including library entries)

    /// Total memory count (standalone entries + library files; = hit count while searching)
    var memoryTotal: Int { memoryEntries.count }

    func memoryCount(for source: AgentSource) -> Int {
        memoryEntries.filter { $0.source == source }.count
    }

    var memoryTotalBytes: UInt64 {
        memoryEntries.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    }

    /// Memory scope breakdown: global memories / project memory libraries (instruction files
    /// are no longer counted as memory)
    var memoryScopeBreakdown: (global: Int, library: Int) {
        var global = 0
        var library = 0
        for entry in memoryEntries {
            if entry.libraryKey != nil { library += 1 } else { global += 1 }
        }
        return (global, library)
    }

    var memorySourceCount: Int { Set(memoryEntries.map(\.source)).count }

    // MARK: - Instruction stats (a set entirely separate from memory)

    var instructionTotal: Int { instructions.count }

    func instructionCount(for source: AgentSource) -> Int {
        instructions.filter { $0.source == source }.count
    }

    var instructionTotalBytes: UInt64 {
        instructions.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    }

    /// Instruction scope breakdown: global (`~/.claude/CLAUDE.md` and the like) / project root
    var instructionScopeBreakdown: (global: Int, project: Int) {
        let project = instructions.filter { $0.projectName != nil }.count
        return (instructions.count - project, project)
    }

    var instructionSourceCount: Int { Set(instructions.map(\.source)).count }

    func instructions(for source: AgentSource) -> [MemoryEntry] {
        instructions.filter { $0.source == source }
    }

    func libraries(for source: AgentSource?) -> [MemoryLibrary] {
        guard let source else { return libraries }
        return libraries.filter { $0.source == source }
    }

    /// The memory library an entry belongs to (the detail page's related mini-graph takes the
    /// whole library's graph and then one hop from it)
    func library(containing entry: MemoryEntry) -> MemoryLibrary? {
        guard let key = entry.libraryKey else { return nil }
        return allLibraries.first { $0.key == key }
    }

    // MARK: - Cross-source configuration consistency

    /// Computed in `ConsistencyChecker` (a pure function in EurekaIngest; thresholds pinned
    /// by unit tests).
    /// This only hands it the four data sets we hold.
    var consistencyReport: ConsistencyChecker.Report {
        ConsistencyChecker.report(
            skills: allSkills, memories: allMemories, libraries: allLibraries,
            repoNames: allRepoRoots.map(\.name))
    }

    /// Relationship graph of a memory library (cached per library; cleared on rescan)
    func graph(for library: MemoryLibrary) -> MemoryGraph.Graph {
        if let cached = graphCache[library.key] { return cached }
        let graph = MemoryGraphBuilder.build(library.graphInput())
        graphCache[library.key] = graph
        return graph
    }

    /// **Layout result** of a memory library graph (cached per library + canvas width).
    /// Layout is a pure function but not cheap (semantic-layer: 126 nodes / 53 rows), and it
    /// runs inside a `GeometryReader`
    /// body - without a cache it re-lays out every frame. Width is quantized to whole points
    /// so float jitter can't keep the cache from ever hitting.
    func layout(for library: MemoryLibrary, width: CGFloat) -> MemoryGraphLayout.Result {
        let key = "\(library.key)|\(Int(width.rounded()))"
        if let cached = layoutCache[key] { return cached }
        let result = MemoryGraphLayout.layout(
            graph(for: library), metrics: .standard(width: width))
        layoutCache[key] = result
        return result
    }

    // MARK: - Reading

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Writing (runs on the queue, refreshes back on the main thread when done)

    /// Atomic write: leaves a .bak.eureka.<ts> backup before writing
    func save(path: String, content: String, completion: ((Bool) -> Void)? = nil) {
        guard !Self.isCodexGeneratedMemory(path) else {
            completion?(false)
            return
        }
        queue.async { [weak self] in
            var ok = false
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: path) {
                    let backup = path + ".bak.eureka.\(Self.timestamp())"
                    try? fm.removeItem(atPath: backup)
                    try? fm.copyItem(atPath: path, toPath: backup)
                }
                try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// One-click fix for memory-library index drift: remove dangling lines + add missing ones.
    /// Reads the **whole** index file (the indexer's parser caps at a 64KB head; a rewrite
    /// must be complete),
    /// and writes through save() (backup + atomic write + forced rescan afterwards, so the
    /// drift warning goes away).
    func repairLibraryIndex(_ library: MemoryLibrary, completion: ((Bool) -> Void)? = nil) {
        guard let index = library.index,
              let text = try? String(contentsOfFile: index.path, encoding: .utf8),
              let outcome = MemoryIndexRepair.repair(indexText: text, entries: library.entries)
        else {
            completion?(false)
            return
        }
        save(path: index.path, content: outcome.text, completion: completion)
    }

    /// **Writable** skill root of each source (shared by create and cross-source install). Hermes
    /// uses the top level with no category depth (observed to exist, and the scanner accepts it);
    /// Trae prefers installed channels (CN first); zcode is the shared ~/.agents/skills - other
    /// compatible CLIs will read what's installed there too.
    static func writableSkillRoot(for source: AgentSource) -> URL {
        switch source {
        case .claude: return SkillMemoryIndexer.claudeSkillsRoot()
        case .codex: return SkillMemoryIndexer.codexSkillsRoot()
        case .opencode: return OpencodePaths.skillsRoot()
        case .grok: return GrokPaths.skillsRoot()
        case .antigravity: return AntigravityPaths.userSkillsRoot()
        case .kimi: return KimiPaths.skillsRoot()
        case .gemini: return GeminiPaths.skillsRoot()
        case .qwen: return QwenPaths.skillsRoot()
        case .hermes: return HermesPaths.skillsRoot()
        case .cursor: return CursorPaths.skillsRoot()
        case .codebuddy: return CodeBuddyPaths.skillsRoot()
        case .qoder: return QoderPaths.skillsRoot()
        case .trae:
            // Either channel may be installed: write to the first installed one (CN first); if
            // neither is, create under CN.
            // `builtin_skills` / `builtin/global/skills` ship with the client and are read-only;
            // never create in them.
            return TraePaths.userSkillsRoots().first ?? TraePaths.skillsRoot(.cn)
        case .zcode:
            return ZcodePaths.skillsRoot()
        }
    }

    /// Graduate a prompt to a skill: create the dir and write the complete SKILL.md in one go
    /// (unlike createSkill's empty template,
    /// graduation brings its own content). If the name already exists, fail with nil and
    /// never overwrite. On success returns the created SKILL.md path
    /// (the caller uses it to post .eurekaRevealKnowledge for the jump).
    func createSkillFromPrompt(
        source: AgentSource, name: String, description: String, body: String,
        completion: ((String?) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let root = Self.writableSkillRoot(for: source)
            let slug = Self.slugify(name)
            let dir = root.appendingPathComponent(slug, isDirectory: true)
            let file = dir.appendingPathComponent("SKILL.md")
            var created: String?
            do {
                if !FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.createDirectory(
                        at: dir, withIntermediateDirectories: true)
                    // The body is generated in EurekaInstall (plain text, unit-tested): no
                    // hand-rolled YAML escaping of frontmatter here
                    let content = PromptGraduationDocument.skill(
                        slug: slug, description: description, body: body)
                    try content.write(to: file, atomically: true, encoding: .utf8)
                    created = file.path
                }
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(created); self?.refresh(force: true) }
        }
    }

    /// Graduate a prompt to persistent instructions: append a section to the shared
    /// instruction file the agent **loads in every session**. The destination is decided by
    /// `PromptInstructionDestination` (same source as the UI's target list and reveal's
    /// kind): claude →
    /// `~/.claude/CLAUDE.md` (not `~/.claude/memories/` - Claude Code doesn't read that dir,
    /// see the enum's comment);
    /// codex → `~/.codex/AGENTS.md`, or `AGENTS.override.md` when it exists (Codex loads only
    /// the first of the two).
    /// Read-append-write with a .bak first - a shared file is never overwritten wholesale;
    /// **a failed read aborts**, never replacing
    /// unreadable original text with the default header. Body assembly lives in
    /// EurekaInstall.PromptGraduationDocument (plain text, unit-tested).
    /// On success returns the written file path.
    func graduatePromptToInstructions(
        source: AgentSource, name: String, body: String,
        completion: ((String?) -> Void)? = nil
    ) {
        guard let destination = PromptInstructionDestination.destination(for: source) else {
            DispatchQueue.main.async { completion?(nil) }
            return
        }
        queue.async { [weak self] in
            var created: String?
            let fm = FileManager.default
            do {
                let file: URL
                switch destination {
                case .claudeUserInstructions:
                    file = SkillMemoryIndexer.claudeHome().appendingPathComponent("CLAUDE.md")
                case .codexAgentsFile:
                    let home = SkillMemoryIndexer.codexHome()
                    let overrideExists = fm.fileExists(
                        atPath: home.appendingPathComponent("AGENTS.override.md").path)
                    file = home.appendingPathComponent(
                        PromptGraduationDocument.codexInstructionFileName(
                            overrideExists: overrideExists))
                }
                try fm.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                var existing: String?
                if fm.fileExists(atPath: file.path) {
                    existing = try String(contentsOf: file, encoding: .utf8)
                    let backup = file.path + ".bak.eureka.\(Self.timestamp())"
                    try? fm.removeItem(atPath: backup)
                    try? fm.copyItem(atPath: file.path, toPath: backup)
                }
                try PromptGraduationDocument.appendingInstructionSection(
                    to: existing, title: name, body: body,
                    defaultHeader: destination.defaultHeader)
                    .write(to: file, atomically: true, encoding: .utf8)
                created = file.path
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(created); self?.refresh(force: true) }
        }
    }

    func createSkill(source: AgentSource, name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let root = Self.writableSkillRoot(for: source)
            let slug = Self.slugify(name)
            let dir = root.appendingPathComponent(slug, isDirectory: true)
            let file = dir.appendingPathComponent("SKILL.md")
            let template = "---\nname: \(slug)\ndescription: \n---\n\n"
            var ok = false
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try template.write(to: file, atomically: true, encoding: .utf8)
                }
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Cross-source install: copy an existing skill into another agent's skill root (shared
    /// by the detail matrix's "install/update" and
    /// the consistency card's "fill in"). Writes only each source's skill root (user dir),
    /// never touches any config file.
    /// With `overwrite = false` an existing same-named skill is reported as a failure;
    /// `overwrite = true` does an overwriting update
    /// (the old version goes to the Trash, see SkillPropagator). The callback gives each
    /// target's failure reason
    /// (nil = success), and a forced rescan runs once everything is done.
    func propagate(
        _ skill: SkillEntry, to targets: [AgentSource], overwrite: Bool = false,
        completion: (([AgentSource: String?]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            var results: [AgentSource: String?] = [:]
            let sourceDir = URL(fileURLWithPath: skill.directory)
            let slug = URL(fileURLWithPath: skill.directory).lastPathComponent
            for target in targets {
                do {
                    try SkillPropagator.install(
                        skillDirectory: sourceDir,
                        into: Self.writableSkillRoot(for: target),
                        slug: slug,
                        overwrite: overwrite)
                    results.updateValue(nil, forKey: target)
                } catch {
                    results[target] = error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                completion?(results)
                self?.refresh(force: true)
            }
        }
    }

    /// The consistency card's "fill in": install a set of skills (by normalized name) into one
    /// source. Names are resolved to actual entries on the main thread first (allSkills is read and
    /// written only on the main thread), copies run serially on the queue, and **only one rescan**
    /// happens when all are done (propagating one by one would trigger N full rescans).
    func propagateAll(
        names: [String], to target: AgentSource,
        completion: ((_ succeeded: Int, _ failures: [String]) -> Void)? = nil
    ) {
        var entries: [SkillEntry] = []
        var failures: [String] = []
        for name in names {
            if let entry = skillEntry(named: name) {
                entries.append(entry)
            } else {
                failures.append(L10n.format("%@: no source skill directory found", zhHans: "%@：找不到可作为来源的技能目录", String(name)))
            }
        }
        queue.async { [weak self] in
            var succeeded = 0
            let root = Self.writableSkillRoot(for: target)
            for entry in entries {
                do {
                    try SkillPropagator.install(
                        skillDirectory: URL(fileURLWithPath: entry.directory),
                        into: root,
                        slug: URL(fileURLWithPath: entry.directory).lastPathComponent)
                    succeeded += 1
                } catch {
                    failures.append(L10n.format("%@: %@", zhHans: "%@：%@", String(entry.name), String(error.localizedDescription)))
                }
            }
            DispatchQueue.main.async {
                completion?(succeeded, failures)
                self?.refresh(force: true)
            }
        }
    }

    /// Finds a skill by normalized name to use as the propagation source: user-created,
    /// enabled, system-level preferred.
    /// The consistency card's gap list has only normalized names; this maps them back to the
    /// actual dir.
    func skillEntry(named name: String) -> SkillEntry? {
        let key = Self.normalizeSkillName(name)
        let candidates = allSkills.filter {
            $0.origin == .user && $0.enabled
                && (Self.normalizeSkillName($0.name) == key
                    || Self.normalizeSkillName(
                        URL(fileURLWithPath: $0.directory).lastPathComponent) == key)
        }
        return candidates.first { !$0.scope.isProject } ?? candidates.first
    }

    func createMemory(source: AgentSource, name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let dir: URL
            switch source {
            case .claude:
                dir = SkillMemoryIndexer.claudeHome()
                    .appendingPathComponent("memories", isDirectory: true)
            case .codex:
                // Codex memories/ is background-generated state; user persistent instructions go to
                // AGENTS.md.
                let home = SkillMemoryIndexer.codexHome()
                let file = home.appendingPathComponent("AGENTS.md")
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: home, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try "# AGENTS.md\n\n".write(
                            to: file, atomically: true, encoding: .utf8)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .opencode:
                dir = OpencodePaths.configHome()
                    .appendingPathComponent("memories", isDirectory: true)
            case .grok:
                dir = GrokPaths.memoryRoot()  // grok uses ~/.grok/memory (no memories subdir)
            case .antigravity:
                // antigravity has no memory dir of its own (only skills under
                // ~/.gemini/antigravity/). This used to write ~/.gemini/memories - that's Gemini's,
                // and the file got indexed as a gemini source. Better to offer no entry point than
                // to borrow someone else's dir.
                DispatchQueue.main.async { completion?(false) }
                return
            case .kimi:
                // kimi memory = a single global AGENTS.md (AGENTS.md-first, no memories-dir
                // concept): create ~/.kimi-code/AGENTS.md directly (name ignored), never
                // overwriting an existing one
                let file = KimiPaths.globalAgentsMd()
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try "# AGENTS.md\n\n".write(to: file, atomically: true, encoding: .utf8)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .qwen:
                dir = QwenPaths.memoriesRoot()
            case .cursor:
                // Cursor has no **global** memory dir: of the server-side memories only the toggle
                // lives locally (`cursor/memoriesEnabled`); the local equivalent is the
                // project-level rules `<repo>/.cursor/rules/*.mdc` - they belong to a repo and
                // shouldn't be conjured by this "new global memory" entry point. Indexing still
                // collects them (see SkillMemoryIndexer).
                DispatchQueue.main.async { completion?(false) }
                return
            case .codebuddy:
                dir = CodeBuddyPaths.memoryRoot()  // ~/.codebuddy/memery (official spelling)
            case .qoder:
                // qoder memory layout: memories/<user-hash>/global/<category>/; new entries go to
                // the first <user-hash>/global/ (memories/global/ if there is none)
                let root = QoderPaths.memoriesRoot()
                let subdirs = ((try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    }
                dir = (subdirs.first ?? root)
                    .appendingPathComponent("global", isDirectory: true)
            case .hermes:
                // hermes memory = two fixed global files (memories/MEMORY.md and USER.md); name is
                // ignored. The body is a flat format of "entries joined by \n§\n" with a length
                // cap; an external bad write trips Hermes' drift protection (saves a .bak and
                // refuses further writes) → create an **empty file** here and let Hermes write the
                // first entry.
                let file = HermesPaths.memoriesRoot().appendingPathComponent("MEMORY.md")
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try Data().write(to: file, options: .atomic)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .gemini:
                // gemini memory = the global GEMINI.md (GEMINI.md-first, no memories-dir concept):
                // create ~/.gemini/GEMINI.md directly (name ignored), never overwriting an existing
                // one
                let file = GeminiPaths.globalGeminiMd()
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try "# GEMINI.md\n\n".write(to: file, atomically: true, encoding: .utf8)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .trae:
                // trae has two fixed-name global files, picked by name (same approach as
                // codex/kimi/gemini: the menu passes a fixed name, not a user-typed title):
                //   `user_rules` → `<dataFolder>/user_rules.md` (user-written rules → Instructions tab)
                //   others       → `~/.trae-cn/memory/user_profile.md` (Trae's self-written profile → Memory tab)
                // Project memory `memory/projects/<encoded>/project_memory.md` belongs to a repo
                // and shouldn't be conjured by this "new global" entry point. Always create an
                // **empty file** (same rule as Hermes): both are sectioned flat docs, and stuffing
                // in a fake title would pollute Trae's own section parsing. Only CN has a memory
                // library, so the profile always goes to CN; rules go to the first installed
                // channel.
                let file = Self.slugify(name) == "user-rules" || name == "user_rules"
                    ? (TraePaths.installedChannels().first.map { TraePaths.userRulesFile($0) }
                        ?? TraePaths.userRulesFile(.cn))
                    : TraePaths.userProfileFile()
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try Data().write(to: file, options: .atomic)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .zcode:
                // zcode: no global memory file layout observed (~/.zcode has no AGENTS.md-like
                // file) - no entry point (same rule as antigravity: better to create nothing than a
                // file the CLI doesn't recognize)
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let file = dir.appendingPathComponent(Self.slugify(name) + ".md")
            var ok = false
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try "# \(name)\n\n".write(to: file, atomically: true, encoding: .utf8)
                }
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Deletes a skill (the whole dir) → Trash
    func deleteSkill(_ skill: SkillEntry, completion: ((Bool) -> Void)? = nil) {
        trash(path: skill.directory, completion: completion)
    }

    /// Deletes a memory file → Trash
    func deleteMemory(_ memory: MemoryEntry, completion: ((Bool) -> Void)? = nil) {
        guard memory.isDeletable else { completion?(false); return }
        trash(path: memory.path, completion: completion)
    }

    private func trash(path: String, completion: ((Bool) -> Void)?) {
        queue.async { [weak self] in
            var ok = false
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Enables/disables a skill: moves the whole dir between the active area and
    /// <root>.eureka-disabled (reversible, non-destructive).
    /// The owning skills root (parent dir) is derived from the skill's own dir, so it works
    /// for both system-level and project-level skills.
    func setSkillEnabled(_ skill: SkillEntry, _ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard skill.enabled != enabled else { completion?(true); return }
        // Hermes enable/disable is the skills.disabled list in config.yaml; **never move the
        // dir**:
        // it tracks built-in skills via .bundled_manifest md5 + curator state, and moving a dir
        // gets it flagged as tampered/missing.
        if skill.source == .hermes {
            setHermesSkillEnabled(skill, enabled, completion: completion)
            return
        }
        queue.async { [weak self] in
            let dirURL = URL(fileURLWithPath: skill.directory)
            // Current root = the skill dir's parent; the active root is derived from the disabled
            // one and vice versa
            let currentRoot = dirURL.deletingLastPathComponent()
            let activeRoot = skill.enabled
                ? currentRoot
                : SkillMemoryService.activeRoot(fromDisabled: currentRoot)
            let destRoot = enabled ? activeRoot : SkillMemoryIndexer.disabledRoot(for: activeRoot)
            let dest = destRoot.appendingPathComponent(dirURL.lastPathComponent, isDirectory: true)
            var ok = false
            do {
                try FileManager.default.createDirectory(
                    at: destRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: dirURL, to: dest)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Hermes skill enable/disable: add/remove the frontmatter name in `skills.disabled` of
    /// `~/.hermes/config.yaml`. Goes through ConfigFile.backupThenWrite (leaves *.bak.eureka.<ts>
    /// before writing), the same safety net as Codex config.toml. The editor does line-level
    /// surgery, keeping comments and key order intact; shapes it can't safely rewrite come back
    /// unchanged → treated as failure, nothing written.
    private func setHermesSkillEnabled(
        _ skill: SkillEntry, _ enabled: Bool, completion: ((Bool) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let configURL = HermesPaths.configFile()
            // No config.yaml means no write: ConfigFile.backupThenWrite would mkdir ~/.hermes along
            // with it,
            // conjuring a config holding only skills.disabled, which Hermes would read as
            // "configured".
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                DispatchQueue.main.async {
                    self?.lastError = L10n.format("%@ not found; cannot update the Hermes skill enable/disable list", zhHans: "未找到 %@，无法改写 Hermes 技能启停名单", String(configURL.path))
                    completion?(false)
                }
                return
            }
            let original = ConfigFile.read(configURL)
            let updated = HermesConfigEditor.setSkillDisabled(
                skill.name, disabled: !enabled, in: original)
            var ok = false
            if updated == original {
                // The list is already in the target state, or this config shape can't be rewritten
                // line-by-line - write nothing in either case
                ok = HermesConfigEditor.disabledSkills(from: original).contains(skill.name) != enabled
            } else {
                do {
                    try ConfigFile.backupThenWrite(path: configURL, newContent: updated)
                    ok = true
                } catch {
                    self?.report(error)
                }
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    // MARK: - Cross-page linkage (main thread; same constraint as rebuild)

    /// Knowledge snapshot (for full-text indexing): user skills + all memories (including
    /// library entries and instructions). The full set before search filtering.
    func knowledgeSnapshot() -> (skills: [SkillEntry], memories: [MemoryEntry]) {
        (allSkills.filter { $0.origin == .user }, allMemories)
    }

    /// Memories related to a session (originSessionId or relatedSessions match; for the
    /// session detail's "produced by this session")
    func memories(relatedTo sessionId: String) -> [MemoryEntry] {
        allMemories.filter { entry in
            entry.originSessionId == sessionId
                || entry.relatedSessions.contains { $0.sessionId == sessionId }
        }
    }

    // MARK: - Open externally (main thread)

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Utilities

    private func report(_ error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.lastError = message }
    }

    /// `~/.codex/memories` is maintained by Codex in the background; the service layer also
    /// refuses writes so the UI's read-only state can't be bypassed.
    private static func isCodexGeneratedMemory(_ path: String) -> Bool {
        let root = SkillMemoryIndexer.codexHome()
            .appendingPathComponent("memories", isDirectory: true)
            .standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target.hasPrefix(root + "/")
    }

    /// Disabled root `<x>.eureka-disabled` → its active root `<x>` (reverse mapping)
    static func activeRoot(fromDisabled disabledRoot: URL) -> URL {
        let name = disabledRoot.lastPathComponent
        let suffix = ".eureka-disabled"
        guard name.hasSuffix(suffix) else { return disabledRoot }
        let activeName = String(name.dropLast(suffix.count))
        return disabledRoot.deletingLastPathComponent()
            .appendingPathComponent(activeName, isDirectory: true)
    }

    static func slugify(_ name: String) -> String {
        var slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "untitled" : slug
    }

    static func timestamp() -> Int { Int(Date().timeIntervalSince1970) }
}
