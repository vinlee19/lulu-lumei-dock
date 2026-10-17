import EurekaKit
import EurekaStore
import Foundation

/// Full-text indexer for the knowledge surfaces: hooked to the scan-completion points of
/// SkillMemoryService / PlansService (event-driven, not timed), rebuilt incrementally by
/// fingerprint (size+mtime) diff. Indexing failures are silent — the panel degrades to metadata
/// search instead of breaking.
///
/// Lives in `EurekaIngest` (not `EurekaApp` as the plan draft said): it depends only on
/// `EurekaStore`/`Foundation` and is a natural neighbor of `SkillMemoryIndexer`/`PlanMaterializer`
/// in the same layer; `eureka-tests` also reaches only this layer — dependencies between SwiftPM
/// `.executableTarget`s are visible only to type checking, and the linker can't get the other
/// target's object code (`swift run eureka-tests` reliably fails to link, verified), so pure
/// functions couldn't be tested and it cannot live in the app layer.
public final class KnowledgeSearchIndexer {
    /// Per-file body index truncation cap (plan documents can be large; head hits are enough for
    /// knowledge search)
    static let bodyCap = 256 * 1024

    public struct Doc: Equatable {
        public var kind: String
        public var path: String
        public var source: String
        public var title: String
        public var project: String?
        public var size: Int64
        public var mtime: Double
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.knowledge-index", qos: .utility)
    private var store: EurekaStore?

    public init() {}

    /// Pure entry → doc mapping (testable); body reading is deferred to the index queue
    public static func docs(
        skills: [SkillEntry], memories: [MemoryEntry], plans: [PlanMaterializer.PlanEntry]
    ) -> [Doc] {
        var result: [Doc] = []
        for skill in skills {
            result.append(Doc(
                kind: "skill", path: skill.path, source: skill.source.rawValue,
                title: skill.name, project: nil,
                size: Int64(skill.sizeBytes), mtime: skill.modifiedAt.timeIntervalSince1970))
        }
        for memory in memories {
            result.append(Doc(
                kind: memory.kind == .instructions ? "instruction" : "memory",
                path: memory.path, source: memory.source.rawValue,
                title: memory.title, project: memory.projectName,
                size: Int64(memory.sizeBytes), mtime: memory.modifiedAt.timeIntervalSince1970))
        }
        for plan in plans {
            result.append(Doc(
                kind: "plan", path: plan.path, source: plan.source.rawValue,
                title: plan.title, project: plan.project,
                size: Int64(plan.sizeBytes), mtime: plan.modifiedAt.timeIntervalSince1970))
        }
        return result
    }

    public func index(
        skills: [SkillEntry], memories: [MemoryEntry], plans: [PlanMaterializer.PlanEntry]
    ) {
        let docs = Self.docs(skills: skills, memories: memories, plans: plans)
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.store else { return }
            let fingerprints = (try? store.knowledge.fileFingerprints()) ?? [:]
            var failures = 0
            for doc in docs {
                if let old = fingerprints[doc.path],
                   old.size == doc.size, old.mtime == doc.mtime { continue }
                guard var body = try? String(contentsOfFile: doc.path, encoding: .utf8)
                else { failures += 1; continue }
                if body.utf8.count > Self.bodyCap {
                    // Truncate by bytes (prefix counts Characters, so pure CJK text would exceed
                    // the cap ~3x); a trailing U+FFFD may appear, harmless to the index
                    body = String(decoding: body.utf8.prefix(Self.bodyCap), as: UTF8.self)
                }
                do {
                    try store.knowledge.replaceDoc(
                        path: doc.path, kind: doc.kind, source: doc.source, title: doc.title,
                        project: doc.project, size: doc.size, mtime: doc.mtime, body: body)
                } catch { failures += 1 }
            }
            try? store.knowledge.prune(keeping: Set(docs.map(\.path)))
            // Degrade silently (the panel falls back to metadata search), but failures must be
            // diagnosable (disk full / corrupt db / non-UTF-8)
            if failures > 0 {
                NSLog("%@", L10n.format("KnowledgeSearchIndexer: failed to index %@/%@ documents", zhHans: "KnowledgeSearchIndexer: %@/%@ 篇正文索引失败", String(failures), String(docs.count)))
            }
        }
    }

    /// Prompt library index: bodies live in memory (the SQLite prompts table) rather than disk
    /// files, so it is a separate channel from the file-based knowledge surfaces; the fingerprint
    /// is approximated by (text byte count, timestamp) — unchanged timestamp/byte count after the
    /// extraction upsert means unchanged. Pruned independently (by kind), never deleting file-based
    /// docs or vice versa.
    public func indexPrompts(_ prompts: [PromptEntry]) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.store == nil {
                self.store = try? EurekaStore(path: EurekaStore.defaultURL())
            }
            guard let store = self.store else { return }
            let fingerprints = (try? store.knowledge.fileFingerprints()) ?? [:]
            let ids = Set(prompts.map(\.id))
            for prompt in prompts {
                let size = Int64(prompt.text.utf8.count)
                let mtime = prompt.timestamp?.timeIntervalSince1970
                    ?? prompt.firstSeen.timeIntervalSince1970
                if let old = fingerprints[prompt.id],
                   old.size == size, old.mtime == mtime { continue }
                let body = prompt.text.utf8.count > Self.bodyCap
                    ? String(decoding: prompt.text.utf8.prefix(Self.bodyCap), as: UTF8.self)
                    : prompt.text
                try? store.knowledge.replaceDoc(
                    path: prompt.id, kind: "prompt", source: prompt.source.rawValue,
                    title: prompt.title, project: prompt.projectName,
                    size: size, mtime: mtime, body: body)
            }
            try? store.knowledge.prunePrompts(keeping: ids)
        }
    }
}
