import Foundation

/// Safe config-file writes: back up first (keeping the latest N copies), then replace atomically.
public enum ConfigFile {
    public static func read(_ path: URL) -> String {
        (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    public static func backupThenWrite(path: URL, newContent: String, keepBackups: Int = 5) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            let timestamp = Int(Date().timeIntervalSince1970)
            let backup = path.deletingLastPathComponent()
                .appendingPathComponent("\(path.lastPathComponent).bak.eureka.\(timestamp)")
            try? fm.copyItem(at: path, to: backup)
            pruneBackups(for: path, keep: keepBackups)
        } else {
            try fm.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        let tmp = path.deletingLastPathComponent()
            .appendingPathComponent(".\(path.lastPathComponent).eureka-tmp")
        try Data(newContent.utf8).write(to: tmp)
        if fm.fileExists(atPath: path.path) {
            _ = try fm.replaceItemAt(path, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: path)
        }
    }

    public static func backups(for path: URL) -> [URL] {
        let dir = path.deletingLastPathComponent()
        let prefix = "\(path.lastPathComponent).bak.eureka."
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }  // Newest timestamp first
    }

    private static func pruneBackups(for path: URL, keep: Int) {
        for stale in backups(for: path).dropFirst(keep) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}
