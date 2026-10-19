import Foundation

/// Spool directory layout (a contract shared with eureka-relay):
/// `<root>/tmp/` (relay writes temp files) → rename → `<root>/events/` (pending)
/// → rename on consumption → `<root>/processing/` (replayable after a crash) → delete
public enum SpoolPaths {
    /// Defaults to ~/Library/Application Support/Eureka; override with EUREKA_SPOOL_DIR (for
    /// tests/demos)
    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_SPOOL_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return appSupport.appendingPathComponent("Eureka", isDirectory: true)
    }

    public static func eventsDir(root: URL) -> URL {
        root.appendingPathComponent("events", isDirectory: true)
    }

    public static func processingDir(root: URL) -> URL {
        root.appendingPathComponent("processing", isDirectory: true)
    }
}
