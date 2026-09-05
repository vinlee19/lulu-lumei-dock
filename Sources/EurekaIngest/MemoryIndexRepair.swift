import EurekaKit
import Foundation

/// 记忆库索引（`MEMORY.md`）漂移的确定性修复：
/// - **悬空引用** → 删除指向已不存在文件的列表行（agent 按行加载会扑空）；
/// - **未收录条目** → 在文末追加 `- [标题](文件名.md) — 摘要` 行（agent 读索引决定
///   加载什么，没被收录的条目等于死记忆）。
///
/// 纯文本进出、可单测。检测口径与 `MemoryLibrary.unindexedEntries` /
/// `danglingIndexRefs` 同源（normalizeKey 一致），但基于**全文**重算 ——
/// 索引器解析带 64KB 头部上限，重写必须以完整文件为准，否则会把没读到的尾部
/// 误判成漂移、修复时整段截掉。
public enum MemoryIndexRepair {
    public struct Outcome: Equatable, Sendable {
        public var text: String
        public var addedCount: Int
        public var removedCount: Int
    }

    /// 生成修复后的索引全文；无漂移（无行可删、无条目可补）时返回 nil。
    /// `entries` 传库里的真实条目（不含索引自身）。
    public static func repair(indexText: String, entries: [MemoryEntry]) -> Outcome? {
        var actualKeys = Set<String>()
        for entry in entries {
            actualKeys.insert(key(forPath: entry.path))
            actualKeys.insert(MemoryGraphBuilder.normalizeKey(entry.title))
        }

        // 1) 删悬空行：只动列表项，且该行**所有** .md 链接目标都不在目录里才删 ——
        //    标题/正文行、含仍有效链接的行一律保留（保守优先，索引是 agent 的入口文件）
        var removedCount = 0
        var lines = indexText.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return false }
            let targets = SkillMemoryIndexer.extractMarkdownLinks(line)
            guard !targets.isEmpty else { return false }
            let allDangling = targets.allSatisfy { !actualKeys.contains(key(forPath: $0)) }
            if allDangling { removedCount += 1 }
            return allDangling
        }

        // 2) 补未收录：以清理后的全文重算收录键；文件名或 frontmatter 标题任一命中即算收录
        //    （与 MemoryLibrary.unindexedEntries 的判据一致）
        let indexedKeys = Set(
            SkillMemoryIndexer.extractMarkdownLinks(lines.joined(separator: "\n"))
                .map { key(forPath: $0) })
        let missing = entries.filter { entry in
            !indexedKeys.contains(key(forPath: entry.path))
                && !indexedKeys.contains(MemoryGraphBuilder.normalizeKey(entry.title))
        }

        guard removedCount > 0 || !missing.isEmpty else { return nil }

        if !missing.isEmpty {
            // 尾部空行收干净再追加，最后补一个换行结尾
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            for entry in missing {
                lines.append(indexLine(for: entry))
            }
            lines.append("")
        }
        return Outcome(
            text: lines.joined(separator: "\n"),
            addedCount: missing.count,
            removedCount: removedCount)
    }

    /// 一条补录行：`- [标题](文件名) — 摘要`（无摘要时省略破折号段）。
    /// 与 Claude 自己维护的索引行格式一致，写进去它就能继续接手。
    static func indexLine(for entry: MemoryEntry) -> String {
        let file = URL(fileURLWithPath: entry.path).lastPathComponent
        let hook = (entry.summary ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hook.isEmpty
            ? "- [\(entry.title)](\(file))"
            : "- [\(entry.title)](\(file)) — \(hook)"
    }

    /// 路径/链接目标 → 归一化键（去扩展名的文件名，normalizeKey 同源）
    private static func key(forPath path: String) -> String {
        MemoryGraphBuilder.normalizeKey(
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }
}
