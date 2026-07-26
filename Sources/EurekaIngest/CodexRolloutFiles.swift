import Foundation

/// ~/.codex/sessions 下全部 rollout-*.jsonl 的递归枚举器。
///
/// rollout 按会话**创建日**归档（YYYY/MM/DD）；resume 旧会话是在原文件原地追加
/// （mtime 刷新、文件不挪窝），不会新建当天日期目录。因此"数最近 N 个日期目录"
/// 必然漏掉老创建、新活跃的会话，各消费方（tailer/索引/审计）统一走整树遍历，
/// 再按需用 mtime 过滤。EurekaUsage 不能依赖本模块，那里自带一份小拷贝
/// （同 JSONL 读取的跨模块惯例）。
enum CodexRolloutFiles {
    /// 一个 rollout 文件及其 stat 信息；mtime 读取失败为 nil，由调用方决定取舍
    struct Entry {
        let url: URL
        let mtime: Date?
        let size: UInt64
    }

    /// 整树枚举 sessionsRoot 下所有 YYYY/MM/DD 数字目录里的 rollout-*.jsonl
    static func enumerate(sessionsRoot: URL) -> [Entry] {
        var results: [Entry] = []
        for year in numericSubdirs(of: sessionsRoot, digits: 4) {
            for month in numericSubdirs(of: year, digits: 2) {
                for day in numericSubdirs(of: month, digits: 2) {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: day,
                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                    )) ?? []
                    for file in files
                    where file.lastPathComponent.hasPrefix("rollout-")
                        && file.pathExtension == "jsonl" {
                        let values = try? file.resourceValues(
                            forKeys: [.contentModificationDateKey, .fileSizeKey])
                        results.append(Entry(
                            url: file,
                            mtime: values?.contentModificationDate,
                            size: UInt64(values?.fileSize ?? 0)))
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
