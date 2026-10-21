import EurekaKit
import EurekaStore
import Foundation

/// Cross-session full-text search indexer: discover transcripts → compare size+mtime fingerprints
/// → rebuild all docs of changed files.
/// Only user / assistant text is indexed (tool trails are noisy and can be expanded on the session
/// page). Shared-database sources (opencode / hermes / cursor: every session shares one .db, so
/// fingerprints can't tell them apart) and antigravity (protobuf, no plaintext) aren't indexed yet.
public final class TranscriptSearchIndexer {
    /// Per-message truncation limit (characters) so one huge message can't bloat the index
    static let maxDocChars = 8192

    private let store: EurekaStore
    /// The last pass stopped at `maxRebuilds` with changed sessions left over (a first install
    /// or a post-migration reindex); the caller should come back soon rather than at its usual
    /// cadence
    public private(set) var lastPassTruncated = false

    public init(store: EurekaStore) {
        self.store = store
    }

    /// Discovers every session under the default disk roots and runs one index pass; returns the
    /// number of files rebuilt this pass. Discovery is shared via `AgentSessionDiscovery`
    /// (discovery is the main cost; see the notes there).
    @discardableResult
    public func indexOnce() -> Int {
        indexOnce(sessions: AgentSessionDiscovery.forIndexing())
    }

    /// One index pass over an injected session list (test entry point; production uses
    /// indexOnce())
    /// `maxRebuilds` caps how many changed sessions one pass parses. A first install has every
    /// session changed (thousands, each parsed in full), which used to hold the caller's queue for
    /// minutes in one block; capped passes index the most recent sessions first and spread the
    /// rest over later passes.
    @discardableResult
    public func indexOnce(sessions: [AgentSessionInfo], maxRebuilds: Int = .max) -> Int {
        // Exclude SQLite-backed sources (opencode / hermes / cursor): this index is keyed by
        // transcriptPath (replaceDocs(path:) + prune(keeping:)), but all their sessions share one
        // .db path, so each session would overwrite the previous one's docs wholesale.
        // antigravity has no readable transcript and is excluded too.
        let supported = sessions.filter {
            !$0.source.usesSharedSessionDatabase && $0.source != .antigravity
        }
        guard let fingerprints = try? store.search.fileFingerprints() else { return 0 }
        var rebuilt = 0
        lastPassTruncated = false
        let fm = FileManager.default
        for session in supported.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }) {
            if rebuilt >= maxRebuilds {
                lastPassTruncated = true
                break
            }
            // One pool per session (return = continue): a full reindex (transcript_fts rebuilt
            // after a migration) parses every session back to back in one queue block, so parse
            // transients must be drained per session
            autoreleasepool {
                let path = session.transcriptPath
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value
                else { return }
                let mtime = ((attrs[.modificationDate] as? Date) ?? .distantPast)
                    .timeIntervalSince1970
                if let known = fingerprints[path], known.size == size, known.mtime == mtime {
                    return
                }
                let docs = Self.docs(for: session)
                if (try? store.search.replaceDocs(
                    path: path, source: session.source.rawValue, sessionId: session.id,
                    size: size, mtime: mtime, docs: docs)) != nil {
                    rebuilt += 1
                }
            }
        }
        // Never prune on an empty set: one empty discovery result would delete the whole
        // full-text index and cost another full reindex. Better to keep possibly stale entries
        // (rebuilt as soon as a fingerprint changes) than wipe the index on an empty result.
        if !supported.isEmpty {
            try? store.search.prune(keeping: Set(supported.map(\.transcriptPath)))
        }
        return rebuilt
    }

    /// A session's indexable docs: same TranscriptReader as the session detail page (message.id
    /// lines up naturally, so a hit can jump straight to the message)
    static func docs(for session: AgentSessionInfo) -> [TranscriptSearchDoc] {
        TranscriptReader.load(session: session).messages.compactMap { message in
            guard message.role == .user || message.role == .assistant else { return nil }
            let text = String(message.text.prefix(maxDocChars))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return TranscriptSearchDoc(
                messageIdx: message.id,
                role: message.role == .user ? "user" : "assistant",
                ts: message.timestamp,
                text: text)
        }
    }
}
