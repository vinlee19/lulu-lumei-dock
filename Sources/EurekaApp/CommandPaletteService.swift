import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// ⌘K global search: in-memory metadata matching (instant) + FTS body hits (knowledge_fts /
/// transcript_fts), 250ms debounce, searching from ≥2 characters (following the session full-text
/// search convention). Silently degrades to metadata-only when FTS can't open. Threading matches
/// the other services: read published data on main, run FTS on a private queue, publish back on
/// main (no @MainActor).
///
/// `Kind`/`Hit` and the two pure functions `merge`/`snippet` are actually defined in `EurekaKit.CommandPalette`
/// (see that file's header comment): eureka-tests can't link this app-shell target's object code, so pure logic must live one layer down
/// to be testable — typealiases forward them here so call sites stay unchanged.
final class CommandPaletteService: ObservableObject {
    typealias Kind = CommandPalette.Kind
    typealias Hit = CommandPalette.Hit

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var searching = false

    private let sessionBrowser: SessionBrowserService
    private let skillMemory: SkillMemoryService
    private let plans: PlansService
    private let prompts: PromptsService
    private let settings: AppSettings
    private let queue = DispatchQueue(label: "com.vinlee.eureka.palette", qos: .userInitiated)
    private var store: EurekaStore?
    private var pending: DispatchWorkItem?

    init(
        sessionBrowser: SessionBrowserService,
        skillMemory: SkillMemoryService,
        plans: PlansService,
        prompts: PromptsService,
        settings: AppSettings
    ) {
        self.sessionBrowser = sessionBrowser
        self.skillMemory = skillMemory
        self.plans = plans
        self.prompts = prompts
        self.settings = settings
    }

    func reset() {
        query = ""
        hits = []
    }

    private func schedule() {
        pending?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            hits = []
            searching = false
            return
        }
        searching = true
        let item = DispatchWorkItem { [weak self] in self?.perform(trimmed) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func perform(_ query: String) {
        // 1) Collect metadata hits on main (services' published data can only be read on main)
        let lowered = query.lowercased()
        var metadata: [Hit] = []
        // sessionsById iterates in dictionary order (unordered); merge cuts perKindCap per group in
        // arrival order, so without sorting first which sessions land in the top 6 slots is random,
        // which can starve FTS body hits carrying messageIdx. Sorting by lastActiveAt descending
        // keeps the most recent sessions after truncation and makes results stable and reproducible
        // for the same data. id matching is tightened to hasPrefix (keeps the "paste an id prefix"
        // case, removes the noise of two-character substrings matching piles of UUIDs); displayName
        // is a human-readable title, where contains is more intuitive, so it stays unchanged.
        let sortedSessions = sessionBrowser.sessionsById.values.sorted { $0.lastActiveAt > $1.lastActiveAt }
        for session in sortedSessions
        where session.displayName.lowercased().contains(lowered)
            || session.id.lowercased().hasPrefix(lowered) {
            metadata.append(Hit(
                kind: .session, key: session.id, title: session.displayName,
                subtitle: session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                snippet: nil, sessionId: session.id, messageIdx: nil))
        }
        let snapshot = skillMemory.knowledgeSnapshot()
        for skill in snapshot.skills
        where skill.name.lowercased().contains(lowered)
            || (skill.description ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .skill, key: skill.path, title: skill.name,
                subtitle: skill.source.rawValue, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        for memory in snapshot.memories
        where memory.title.lowercased().contains(lowered)
            || (memory.summary ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: memory.kind == .instructions ? .instruction : .memory,
                key: memory.path, title: memory.title,
                subtitle: memory.projectName ?? memory.scope,
                snippet: nil, sessionId: nil, messageIdx: nil))
        }
        for plan in plans.knowledgeSnapshot()
        where plan.title.lowercased().contains(lowered)
            || (plan.summary ?? "").lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .plan, key: plan.path, title: plan.title,
                subtitle: plan.project, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        // Prompt metadata matches titles only (same rule as skills by name and memory by title) — a
        // full-text contains that lowercases tens of thousands of prompts one by one on main would
        // stall typing; body hits go to the FTS channel below (background queue, kind = "prompt"
        // already mapped)
        for prompt in prompts.knowledgeSnapshot()
        where prompt.title.lowercased().contains(lowered) {
            metadata.append(Hit(
                kind: .prompt, key: prompt.id, title: prompt.title,
                subtitle: prompt.source.displayName, snippet: nil, sessionId: nil, messageIdx: nil))
        }
        // 2) FTS goes to the queue (body hits) and merges back on main. transcript FTS is gated by
        //    the Settings "cross-session full-text search index"
        // toggle (session-side indexing convention); knowledge FTS is the companion index of the
        // knowledge-surface scan and isn't governed by that toggle. AppSettings is @MainActor as a
        // whole; perform relies on the caller to run on main (same as WellnessMonitor's
        // MainActor.assumeIsolated usage), so read the values before hopping to the queue to avoid
        // carrying MainActor values into the private-queue closure.
        let transcriptSearchEnabled = MainActor.assumeIsolated { settings.fullTextSearchEnabled }
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            var content: [Hit] = []
            if let store = self.store {
                for hit in (try? store.knowledge.search(query, limit: 20)) ?? [] {
                    let kind: Kind = switch hit.kind {
                    case "skill": .skill
                    case "instruction": .instruction
                    case "plan": .plan
                    case "prompt": .prompt
                    default: .memory
                    }
                    content.append(Hit(
                        kind: kind, key: hit.path, title: hit.title,
                        subtitle: hit.project ?? hit.source,
                        snippet: CommandPalette.snippet(hit.text, query: query),
                        sessionId: nil, messageIdx: nil))
                }
                if transcriptSearchEnabled {
                    for hit in (try? store.search.search(query, limit: 20)) ?? [] {
                        content.append(Hit(
                            kind: .session, key: hit.sessionId,
                            title: L10n.format("Session %@", zhHans: "会话 %@", String(hit.sessionId.prefix(8))),
                            subtitle: hit.role,
                            snippet: CommandPalette.snippet(hit.text, query: query),
                            sessionId: hit.sessionId, messageIdx: hit.messageIdx))
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == query
                else { return }  // query has changed; drop stale results
                // Harness background calls (memory compaction etc.) match almost any body query;
                // move them behind real sessions before the per-kind cap so they cannot crowd the
                // six session slots. Order is otherwise kept.
                let ranked = (metadata + content).enumerated().sorted { lhs, rhs in
                    let left = self.isHarnessSession(lhs.element)
                    let right = self.isHarnessSession(rhs.element)
                    return left != right ? !left : lhs.offset < rhs.offset
                }.map(\.element)
                var merged = CommandPalette.merge(ranked, perKindCap: 6)
                // fill in real names for session hits
                merged = merged.map { hit in
                    var hit = hit
                    if hit.kind == .session, let id = hit.sessionId,
                       let info = self.sessionBrowser.sessionsById[id] {
                        hit.title = info.displayName
                    }
                    return hit
                }
                self.hits = merged
                self.searching = false
            }
        }
    }

    private func isHarnessSession(_ hit: Hit) -> Bool {
        guard hit.kind == .session, let id = hit.sessionId,
              let info = sessionBrowser.sessionsById[id] else { return false }
        return PromptClassifier.isHarnessUtility(info.displayName)
    }
}
