import EurekaKit
import Foundation

/// A **memory library**: one project's `memory/` directory — an index (MEMORY.md) + some entries.
///
/// This is the real shape of Claude's (and the identically structured Qwen's) memory: the agent
/// adds and removes entries itself, one hook line per entry in the index. The Memory tab folds a
/// whole library into one row that opens to its entries, following this structure — otherwise a
/// single project's 73 entries would completely drown out the few global-memory entries.
public struct MemoryLibrary: Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// `"<source>:<encoded-project-dir>"`, same origin as `MemoryEntry.libraryKey`
    public var key: String
    public var source: AgentSource
    public var projectName: String
    /// Library directory (`~/.claude/projects/<encoded>/memory`)
    public var directory: String
    /// Index file; nil = this library has no MEMORY.md yet
    public var index: MemoryEntry?
    /// Entries (excluding the index), most recently modified first
    public var entries: [MemoryEntry]

    public init(
        key: String, source: AgentSource, projectName: String, directory: String,
        index: MemoryEntry?, entries: [MemoryEntry]
    ) {
        self.key = key
        self.source = source
        self.projectName = projectName
        self.directory = directory
        self.index = index
        self.entries = entries
    }

    /// Entry count (**excluding** the index: the index is a directory, not a memory)
    public var count: Int { entries.count }

    /// Size includes the index: users asking "how much disk does memory take" wouldn't exclude it
    public var sizeBytes: UInt64 {
        entries.reduce(index?.sizeBytes ?? 0) { $0 + $1.sizeBytes }
    }

    public var latestModifiedAt: Date {
        entries.map(\.modifiedAt).max() ?? index?.modifiedAt ?? .distantPast
    }

    public var typeBreakdown: [MemoryType: Int] {
        var counts: [MemoryType: Int] = [:]
        for entry in entries { counts[entry.memoryType, default: 0] += 1 }
        return counts
    }

    /// Number of entries with an origin session whose transcript still exists (the navigable ones
    /// in the graph)
    public var linkedSessionCount: Int {
        Set(entries.compactMap { $0.originSessionPath == nil ? nil : $0.originSessionId }).count
    }

    // MARK: - Index drift (reconciling `MEMORY.md` with the directory's actual contents)

    /// Entry keys listed in the index body (normalized, for comparison with actual files)
    private var indexedKeys: Set<String> {
        Set((index?.indexedTargets ?? []).map {
            MemoryGraphBuilder.normalizeKey(
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
        })
    }

    /// **Entries not listed in `MEMORY.md`**. The agent reads the index to decide what to load —
    /// a file sitting in the directory but missing from the index is **dead memory** (2 of the 72
    /// entries in the surveyed semantic-layer library were like this).
    /// Returns empty when there is no index file: such a library has no notion of "listed" at all,
    /// so reporting every entry as an anomaly would be wrong.
    public var unindexedEntries: [MemoryEntry] {
        guard index != nil else { return [] }
        let keys = indexedKeys
        return entries.filter { entry in
            let basename = URL(fileURLWithPath: entry.path)
                .deletingPathExtension().lastPathComponent
            // Listed if either the file name or the frontmatter name is listed
            return !keys.contains(MemoryGraphBuilder.normalizeKey(basename))
                && !keys.contains(MemoryGraphBuilder.normalizeKey(entry.title))
        }
    }

    /// Entries listed in the index but missing from the directory (references pointing at nothing)
    public var danglingIndexRefs: [String] {
        guard let index else { return [] }
        var actual = Set<String>()
        for entry in entries {
            let basename = URL(fileURLWithPath: entry.path)
                .deletingPathExtension().lastPathComponent
            actual.insert(MemoryGraphBuilder.normalizeKey(basename))
            actual.insert(MemoryGraphBuilder.normalizeKey(entry.title))
        }
        return index.indexedTargets.filter {
            let key = MemoryGraphBuilder.normalizeKey(
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
            return !actual.contains(key)
        }
    }

    /// Whether this library has a health issue worth flagging
    public var hasDrift: Bool { !unindexedEntries.isEmpty || !danglingIndexRefs.isEmpty }

    public var allFiles: [MemoryEntry] { (index.map { [$0] } ?? []) + entries }

    /// Groups by `libraryKey`. Pure function, independent of input order (sorts internally), easy
    /// to unit test.
    public static func group(_ all: [MemoryEntry]) -> [MemoryLibrary] {
        var buckets: [String: [MemoryEntry]] = [:]
        for entry in all {
            guard let key = entry.libraryKey else { continue }
            buckets[key, default: []].append(entry)
        }
        var libraries: [MemoryLibrary] = []
        for (key, members) in buckets {
            guard let sample = members.first else { continue }
            let index = members.first(where: \.isIndex)
            let entries = members.filter { !$0.isIndex }
                .sorted { lhs, rhs in
                    lhs.modifiedAt == rhs.modifiedAt
                        ? lhs.title.lowercased() < rhs.title.lowercased()
                        : lhs.modifiedAt > rhs.modifiedAt
                }
            libraries.append(MemoryLibrary(
                key: key, source: sample.source,
                projectName: sample.projectName ?? sample.scope,
                directory: URL(fileURLWithPath: sample.path)
                    .deletingLastPathComponent().path,
                index: index, entries: entries))
        }
        // Larger libraries first, ties by project name: library row order must not drift with
        // dictionary iteration
        return libraries.sorted {
            $0.count == $1.count
                ? $0.projectName.lowercased() < $1.projectName.lowercased()
                : $0.count > $1.count
        }
    }

    /// Maps to EurekaKit's graph input (module direction: EurekaKit must not depend back on
    /// EurekaIngest)
    public func graphInput() -> MemoryGraphInput {
        let unindexed = Set(unindexedEntries.map(\.path))
        return MemoryGraphInput(
            title: projectName,
            items: allFiles.map { entry in
                MemoryGraphInput.Item(
                    id: entry.path,
                    title: entry.title,
                    subtitle: entry.summary ?? "",
                    type: entry.memoryType,
                    aliases: entry.linkAliases,
                    links: entry.links,
                    originSessionId: entry.originSessionId,
                    originSessionExists: entry.originSessionPath != nil,
                    modifiedAt: entry.modifiedAt,
                    isIndex: entry.isIndex,
                    isUnindexed: unindexed.contains(entry.path))
            })
    }
}
