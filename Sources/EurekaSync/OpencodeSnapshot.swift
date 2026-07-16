import EurekaStore
import Foundation

/// opencode 会话只存在于一个 live WAL SQLite 库里，naive 文件拷贝可能拿到
/// 不一致快照 → 用 VACUUM INTO 产出事务一致的快照文件再上传。
/// （VACUUM INTO 自 SQLite 3.27 起支持从只读连接执行，macOS 14 系统库远高于此。）
public enum OpencodeSnapshot {
    /// 变更指纹：size = db + db-wal 字节合计，mtime = 两者较大值。
    /// 与 sync_state(path = dbPath) 对比，未变则整步跳过（不做 VACUUM）。
    public static func fingerprint(dbPath: URL) -> (size: Int64, mtime: Double)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dbPath.path) else { return nil }
        var totalSize: Int64 = 0
        var latestMtime: Double = 0
        for url in [dbPath, URL(fileURLWithPath: dbPath.path + "-wal")] {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            totalSize += (attrs[.size] as? Int64) ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            latestMtime = max(latestMtime, mtime)
        }
        return (totalSize, latestMtime)
    }

    /// 只读打开 → VACUUM INTO 临时快照；返回快照 URL，调用方上传后负责删除
    public static func snapshot(dbPath: URL, to tempDir: URL) throws -> URL {
        let target = tempDir.appendingPathComponent(
            "opencode-snapshot-\(Int(Date().timeIntervalSince1970)).db")
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dbPath.path, readOnly: true)
        // 路径由我们生成（temp 目录 + 时间戳），单引号转义防御性处理
        let escaped = target.path.replacingOccurrences(of: "'", with: "''")
        try db.execute("VACUUM INTO '\(escaped)'")
        return target
    }
}
