import EurekaKit
import Foundation

/// 一个**记忆库**：某个项目的 `memory/` 目录 —— 一份索引（MEMORY.md）+ 若干条目。
///
/// 这是 Claude（以及同构的 Qwen）真正的记忆形态：条目由 agent 自己增删，索引里一行一条钩子。
/// 记忆页把整库折叠成一行、点进去看条目，就是照这个结构来的 —— 否则单个项目 73 条
/// 会把「全局记忆」那几条彻底冲掉。
public struct MemoryLibrary: Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// `"<source>:<encoded-project-dir>"`，与 `MemoryEntry.libraryKey` 同源
    public var key: String
    public var source: AgentSource
    public var projectName: String
    /// 库目录（`~/.claude/projects/<encoded>/memory`）
    public var directory: String
    /// 索引文件；nil = 这个库还没有 MEMORY.md
    public var index: MemoryEntry?
    /// 条目（索引除外），最近修改在前
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

    /// 条目数（**不含**索引：索引是目录不是记忆）
    public var count: Int { entries.count }

    /// 体积含索引：用户在「记忆占了多少盘」这个问题上不会把索引排除在外
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

    /// 有来源会话且 transcript 还在的条目数（图谱里可跳转的那些）
    public var linkedSessionCount: Int {
        Set(entries.compactMap { $0.originSessionPath == nil ? nil : $0.originSessionId }).count
    }

    // MARK: - 索引漂移（`MEMORY.md` 与目录实际内容对账）

    /// 索引正文收录的条目键（归一化后，用于与实际文件比对）
    private var indexedKeys: Set<String> {
        Set((index?.indexedTargets ?? []).map {
            MemoryGraphBuilder.normalizeKey(
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
        })
    }

    /// **未被 `MEMORY.md` 收录的条目**。agent 是读索引决定加载什么的 ——
    /// 文件躺在目录里但索引没列，等于**死记忆**（实勘 semantic-layer 库 72 条里有 2 条如此）。
    /// 没有索引文件时返回空：那种库压根没有"收录"这回事，不该把全部条目报成异常。
    public var unindexedEntries: [MemoryEntry] {
        guard index != nil else { return [] }
        let keys = indexedKeys
        return entries.filter { entry in
            let basename = URL(fileURLWithPath: entry.path)
                .deletingPathExtension().lastPathComponent
            // 文件名或 frontmatter name 任一被收录即算收录
            return !keys.contains(MemoryGraphBuilder.normalizeKey(basename))
                && !keys.contains(MemoryGraphBuilder.normalizeKey(entry.title))
        }
    }

    /// 索引里列了、目录里却没有的条目（指向空气的引用）
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

    /// 这个库有没有需要提醒的健康问题
    public var hasDrift: Bool { !unindexedEntries.isEmpty || !danglingIndexRefs.isEmpty }

    public var allFiles: [MemoryEntry] { (index.map { [$0] } ?? []) + entries }

    /// 按 `libraryKey` 归组。纯函数，输入次序无关（内部自排），便于单测。
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
        // 条目多的在前、同数按项目名：库行顺序不能随字典遍历漂移
        return libraries.sorted {
            $0.count == $1.count
                ? $0.projectName.lowercased() < $1.projectName.lowercased()
                : $0.count > $1.count
        }
    }

    /// 映射成 EurekaKit 的图谱输入（模块方向要求：EurekaKit 不能反向依赖 EurekaIngest）
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
