import Foundation

/// ~/.codex/sessions 下全部 rollout-*.jsonl 的递归枚举器。
/// 与 EurekaIngest.CodexRolloutFiles 同逻辑：EurekaUsage 不能依赖 EurekaIngest，
/// 自带一份（同 JSONLinesReader / CodexRolloutDecoderProxy 的跨模块惯例）。
/// resume 的旧会话在创建日目录原地追加（mtime 刷新、不新建当天目录），
/// "数最近 N 个日期目录"必然漏掉它们 → 各消费方统一整树遍历。
enum CodexRolloutFiles {
    /// 一个 rollout 文件及其 mtime（读取失败为 nil，由调用方决定取舍）
    struct Entry {
        let url: URL
        let mtime: Date?
    }

    /// 整树枚举 sessionsRoot 下所有 YYYY/MM/DD 数字目录里的 rollout-*.jsonl
    static func enumerate(sessionsRoot: URL) -> [Entry] {
        var results: [Entry] = []
        for year in numericSubdirs(of: sessionsRoot, digits: 4) {
            for month in numericSubdirs(of: year, digits: 2) {
                for day in numericSubdirs(of: month, digits: 2) {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: day, includingPropertiesForKeys: [.contentModificationDateKey]
                    )) ?? []
                    for file in files
                    where file.lastPathComponent.hasPrefix("rollout-")
                        && file.pathExtension == "jsonl" {
                        results.append(Entry(
                            url: file,
                            mtime: (try? file.resourceValues(
                                forKeys: [.contentModificationDateKey]))?
                                .contentModificationDate))
                    }
                }
            }
        }
        return results
    }

    /// 列出 N 位纯数字命名的子目录（YYYY=4 位，MM/DD=2 位），其余条目一律跳过
    private static func numericSubdirs(of dir: URL, digits: Int) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { url in
            let name = url.lastPathComponent
            return name.count == digits && name.allSatisfy(\.isNumber)
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
