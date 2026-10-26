import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// Prompt library service: incrementally extracts user prompts from session transcripts for
/// one place to browse, search and reuse them.
///
/// Incremental strategy mirrors transcript_fts (fingerprint skip): `prompt_sessions` records
/// each session's last extraction time, and sessions whose `lastActiveAt` hasn't changed are
/// skipped (a full TranscriptReader re-parse is the main cost; one full scan can take seconds).
/// The extraction upsert refreshes only the body columns; favorites / tags / use counts are
/// user-written facts and are never overwritten by extraction (see PromptsRepo.upsertExtracted).
///
/// The session list comes from SessionBrowserService (injected, no duplicate discovery);
/// AppDelegate subscribes to sessionBrowser's scan-completed event and calls refresh().
final class PromptsService: ObservableObject {
    @Published private(set) var prompts: [PromptEntry] = []
    /// Frequently repeated groups (clustered by fingerprint after dropping noise and trivia;
    /// computed and cached on the refresh queue, never recomputed in body)
    @Published private(set) var groups: [PromptGroup] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanPhase: String?
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var totalCount = 0
    @Published private(set) var favoriteCount = 0
    /// Count of entries folded by default (noise / trivial / long paste, not favorited), for the
    /// stats card hint
    @Published private(set) var foldedCount = 0
    /// Evaluation cache (prompt_id → aggregated four-layer signals; the extraction pipeline
    /// computes and persists them, this only reads them back).
    /// A missing row = the source isn't evaluable or the library hasn't been rescanned yet —
    /// the UI must stay silent with no dot, never show "clean"
    @Published private(set) var evalById: [String: PromptEval] = [:]
    /// Cross-page jump target (from the command palette / session detail)
    var focusId: String?
    var searchText: String = "" { didSet { scheduleRebuild(debounce: true) } }
    var favoritesOnly = false { didSet { scheduleRebuild(debounce: false) } }
    /// Show everything (including trivial / long paste / legacy noise); ignored while searching,
    /// which hides nothing (the search intent is explicit)
    var showAll = false { didSet { scheduleRebuild(debounce: false) } }

    /// Extraction is background enrichment (the user isn't waiting on it); utility avoids
    /// competing for cores with the UI critical path — the first full extraction re-parses every
    /// session, and userInitiated would starve the main UI during launch warm-up
    private let queue = DispatchQueue(label: "com.vinlee.eureka.prompts", qos: .utility)
    /// Filter generation: a slow result arriving on the main thread is dropped if newer input
    /// has superseded it
    private var rebuildGeneration = 0
    private let sessionBrowser: SessionBrowserService
    private var store: EurekaStore?
    private var all: [PromptEntry] = []
    /// id → entry index (kept in sync with all): detail jumps, group member expansion and
    /// annotation write-back all look up by id; a linear scan of all on a 10k-entry library
    /// would scan the whole library N times for every expanded group
    private var byId: [String: PromptEntry] = [:]
    /// Reuse-value classification cache (computed on the refresh queue; read/written on main).
    /// Derived in memory, not persisted: iterating on thresholds needs no DB refresh or schema
    /// migration
    private var kindById: [String: PromptKind] = [:]
    /// Session metadata snapshot (taken on the queue during extraction so row rendering doesn't
    /// go back to the main thread to read the service)
    private var sessionsById: [String: AgentSessionInfo] = [:]

    init(sessionBrowser: SessionBrowserService) {
        self.sessionBrowser = sessionBrowser
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Incremental extraction: re-parse only sessions whose `lastActiveAt` is later than the last
    /// extraction fingerprint.
    /// Silently skips when there is no session data (sessionBrowser hasn't finished scanning; the
    /// next scan completion triggers it again).
    /// Sessions one pass parses, newest first. A first install has every session pending, each
    /// parsed in full (transcript + turn graphs); one unbounded pass held a core for minutes and
    /// was behind a measured 5.5 GB peak. The rest follow in chained passes a few seconds apart,
    /// each publishing what is done so far.
    static let extractionBatch = 60

    func refresh() {
        guard !scanning else { return }
        let sessions = Array(sessionBrowser.sessionsById.values)
        guard !sessions.isEmpty else { return }
        scanning = true
        publishPhase(L10n.text("Extracting user prompts…", zhHans: "正在提取用户提问…"))
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.store else {
                DispatchQueue.main.async {
                    self.scanning = false
                    self.scanPhase = nil
                }
                return
            }
            let now = Date()
            let fingerprints = (try? store.prompts.extractionFingerprints()) ?? [:]
            let allPending = sessions.filter { session in
                guard let last = fingerprints[session.id] else { return true }
                return session.lastActiveAt > last
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            let pending = Array(allPending.prefix(Self.extractionBatch))
            let remaining = allPending.count - pending.count
            var sessionMeta: [String: AgentSessionInfo] = [:]
            for session in sessions { sessionMeta[session.id] = session }
            if !pending.isEmpty {
                self.publishPhase(L10n.format("Parsing %@ sessions…", zhHans: "正在解析 %@ 个会话…", String(pending.count)))
                for (index, session) in pending.enumerated() {
                    // One pool per session: transient messages / turn graphs are released
                    // between sessions, so a full rescan (fingerprints cleared after a migration)
                    // doesn't accumulate hundreds of sessions' parse output until the queue block
                    // ends (one of the main causes of a measured 5.5GB peak)
                    autoreleasepool {
                        // Load once and share between extraction and evaluation (a full
                        // re-parse is the main cost; never call it twice)
                        let messages = TranscriptReader.load(session: session).messages
                        let entries = PromptExtractor.extract(
                            messages: messages, session: session, at: now)
                        try? store.prompts.upsertExtracted(entries, at: now)
                        let evals = Self.evaluate(
                            messages: messages, session: session,
                            extractedIds: Set(entries.map(\.id)))
                        try? store.prompts.upsertEval(evals)
                        try? store.prompts.markExtracted(
                            sessionId: session.id, source: session.source, at: now)
                    }
                    if index % 25 == 0 {
                        self.publishPhase(
                            L10n.format("Parsing session %@/%@…", zhHans: "正在解析会话 %@/%@…", String(index + 1), String(pending.count)))
                    }
                }
            }
            let entries = (try? store.prompts.all()) ?? []
            let favorites = (try? store.prompts.favoriteCount()) ?? 0
            let evals = (try? store.prompts.evalMap()) ?? [:]
            // Classification + clustering are computed and cached once on this queue (a few
            // thousand entries, O(n), kept off the UI render path)
            var kinds: [String: PromptKind] = [:]
            kinds.reserveCapacity(entries.count)
            var folded = 0
            for entry in entries {
                let kind = PromptClassifier.classify(entry.text)
                kinds[entry.id] = kind
                if !entry.favorite, Self.isFoldable(kind) {
                    folded += 1
                }
            }
            let groups = PromptGrouping.groups(from: entries, minCount: 3) { entry in
                let kind = kinds[entry.id] ?? .instruction
                return kind != .noise && kind != .trivial
            }
            let index = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            DispatchQueue.main.async {
                self.all = entries
                self.byId = index
                self.kindById = kinds
                self.groups = groups
                self.evalById = evals
                self.foldedCount = folded
                self.sessionsById = sessionMeta
                self.totalCount = entries.count
                self.favoriteCount = favorites
                self.lastScanAt = now
                self.scheduleRebuild(debounce: false)
                self.scanning = false
                self.scanPhase = nil
                if remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
                }
            }
        }
    }

    private func publishPhase(_ phase: String) {
        DispatchQueue.main.async { self.scanPhase = phase }
    }

    /// Evaluates every prompt in one session: slice turns → (full tier only) build the graph and
    /// run in-turn diagnostics → aggregate four-layer signals.
    /// Only evaluates prompts that were actually stored (noise filtered out by extract is not
    /// evaluated); excluded sources return empty.
    /// Pure computation, runs on the extraction queue.
    static func evaluate(
        messages: [TranscriptMessage], session: AgentSessionInfo,
        extractedIds: Set<String>
    ) -> [PromptEval] {
        let capability = PromptEvalCapability.level(for: session.source)
        guard capability != .excluded, !extractedIds.isEmpty else { return [] }
        let turns = TurnSlicer.slice(messages)
        var evals: [PromptEval] = []
        for (index, turn) in turns.enumerated() {
            guard let messageId = turn.promptMessageId else { continue }
            let promptId = PromptEntry.makeId(
                source: session.source, sessionId: session.id, messageIdx: messageId)
            guard extractedIds.contains(promptId) else { continue }
            // Build the graph only for the full tier (toolNote sources' graphs degrade to all
            // zeros, so building them would be wasted cost)
            let diagnostics = capability == .full
                ? TurnDiagnostics.evaluate(
                    TurnGraphBuilder.build(turn), promptChars: turn.promptText.count)
                : nil
            // Next real prompt (skips continuation turns with no prompt)
            let next = turns[(index + 1)...]
                .first { $0.promptMessageId != nil }?.promptText
            if let eval = PromptEvaluator.evaluate(
                promptId: promptId, turn: turn, diagnostics: diagnostics,
                nextPromptText: next, capability: capability) {
                evals.append(eval)
            }
        }
        return evals
    }

    /// List filtering: search (body / tags; the title is the body's first line, so it's already
    /// covered) + favorites toggle; first_seen descending (newest prompt first). A full-text
    /// lowercased scan can reach tens of MB per pass as the library grows, so it runs on a global
    /// background queue (not the extraction queue — a full utility extraction run would push
    /// searches to the back); search input is debounced 250ms (same as ⌘K), the favorites toggle
    /// and refresh run immediately.
    private func scheduleRebuild(debounce: Bool) {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + (debounce ? 0.25 : 0)) { [weak self] in
            guard let self, self.rebuildGeneration == generation else { return }
            let lowered = self.searchText
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let onlyFavorites = self.favoritesOnly
            let snapshot = self.all
            let kinds = self.kindById
            // Fold low-value kinds (noise / trivial / long paste) by default; favorites are
            // always kept; nothing is hidden while searching — the user is explicitly looking,
            // so everything should be findable
            let hideFolded = !self.showAll && lowered.isEmpty
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var result = snapshot
                if hideFolded {
                    result = result.filter { entry in
                        if entry.favorite { return true }
                        let kind = kinds[entry.id] ?? .instruction
                        return kind == .instruction || kind == .followup
                    }
                }
                if onlyFavorites {
                    result = result.filter(\.favorite)
                }
                if !lowered.isEmpty {
                    result = result.filter { entry in
                        entry.text.lowercased().contains(lowered)
                            || entry.tags.contains { $0.lowercased().contains(lowered) }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.rebuildGeneration == generation else { return }
                    self.prompts = result
                }
            }
        }
    }

    /// Full unfiltered snapshot for the command palette
    func knowledgeSnapshot() -> [PromptEntry] {
        all
    }

    /// Session display name (list row subtitle; falls back to a short id when not found)
    func sessionName(for entry: PromptEntry) -> String? {
        sessionsById[entry.sessionId]?.displayName
    }

    func entry(id: String) -> PromptEntry? {
        byId[id]
    }

    /// Project names use the display rule (`ProjectResolver.Mode.project`): a worktree counts as
    /// its main repo, and a plain folder inside a workspace repo counts as itself.
    private let projectResolver = ProjectResolver(mode: .project)

    /// The project a prompt was typed in (nil when its session recorded no directory).
    func project(of entry: PromptEntry) -> String? {
        projectResolver.projectName(forCwd: entry.cwd)
    }

    /// Low reuse-value kinds folded by default (noise / trivial / long paste); favorited entries
    /// are never folded
    private static func isFoldable(_ kind: PromptKind?) -> Bool {
        kind == .noise || kind == .trivial || kind == .paste
    }

    // MARK: - User actions (write DB + sync in-memory state)

    func toggleFavorite(_ id: String) {
        guard var entry = mutableEntry(id) else { return }
        entry.favorite.toggle()
        applyMutation(entry)
        try? store?.prompts.setFavorite(id, favorite: entry.favorite)
        favoriteCount = max(0, favoriteCount + (entry.favorite ? 1 : -1))
        // The folded count only covers non-favorited low-value entries: favoriting takes an
        // entry out of the fold, unfavoriting puts it back
        if Self.isFoldable(kindById[id]) {
            foldedCount = max(0, foldedCount + (entry.favorite ? -1 : 1))
        }
    }

    func setTags(_ id: String, tags: [String]) {
        guard var entry = mutableEntry(id) else { return }
        entry.tags = tags.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        applyMutation(entry)
        try? store?.prompts.setTags(id, tags: entry.tags)
    }

    /// Entry's reuse-value kind (refresh cache; unknown is treated conservatively as instruction)
    func kind(of id: String) -> PromptKind {
        kindById[id] ?? .instruction
    }

    /// Entry's evaluation; nil = the source isn't evaluable or hasn't been rescanned (the UI stays
    /// silent, never shows "clean")
    func eval(of id: String) -> PromptEval? {
        evalById[id]
    }

    /// Full command for "start a new session in the terminal with this prompt"; nil when the
    /// source isn't on the allowlist (claude/codex)
    func launchCommand(for id: String) -> String? {
        guard let entry = entry(id: id),
              let cli = PromptLaunchCommand.cliExecutable(for: entry.source)
        else { return nil }
        return PromptLaunchCommand.build(cli: cli, cwd: entry.cwd, prompt: entry.text)
    }

    /// Starts a new session with this prompt in a new Terminal window and counts one reuse
    func launchInTerminal(_ id: String) {
        guard let command = launchCommand(for: id) else { return }
        TerminalRunner.run(command: command)
        recordUse(id)
    }

    /// Copies to the pasteboard and counts one use
    func copyToPasteboard(_ id: String) {
        guard let entry = entry(id: id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        recordUse(id)
    }

    func recordUse(_ id: String) {
        guard var entry = mutableEntry(id) else { return }
        entry.useCount += 1
        entry.lastUsedAt = Date()
        applyMutation(entry)
        try? store?.prompts.recordUse(id)
    }

    /// Removes from the library: the DB does a soft delete (the row stays to block resurrection
    /// by re-extraction, see PromptsRepo.hide), and all in-memory state updates synchronously —
    /// list, index, counts, kind / eval caches, frequent groups — without the async rebuild
    /// (deletion needs immediate feedback) and without waiting for the next refresh (a group's ×N
    /// and the favorite count can't stay wrong until then).
    func delete(_ id: String) {
        guard let entry = byId[id] else { return }
        all.removeAll { $0.id == id }
        prompts.removeAll { $0.id == id }
        byId[id] = nil
        totalCount = all.count
        if entry.favorite {
            favoriteCount = max(0, favoriteCount - 1)
        } else if Self.isFoldable(kindById[id]) {
            foldedCount = max(0, foldedCount - 1)
        }
        kindById[id] = nil
        evalById[id] = nil
        let index = byId
        groups = PromptGrouping.removing(memberId: id, from: groups) { index[$0] }
        try? store?.prompts.hide(id)
    }

    /// Cross-page jump landing: if the entry is found, set focus (consumed by PromptsView
    /// onAppear/onChange)
    func revealPrompt(_ id: String) {
        focusId = id
    }

    private func mutableEntry(_ id: String) -> PromptEntry? {
        byId[id]
    }

    /// Writes a single change back to all + byId + prompts (keeps them consistent when all three
    /// hold the same entry)
    private func applyMutation(_ entry: PromptEntry) {
        byId[entry.id] = entry
        if let index = all.firstIndex(where: { $0.id == entry.id }) {
            all[index] = entry
        }
        if let index = prompts.firstIndex(where: { $0.id == entry.id }) {
            prompts[index] = entry
        }
    }
}
