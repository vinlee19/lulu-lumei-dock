import Foundation

/// spool 目录布局（与 eureka-relay 共享契约）：
/// `<root>/tmp/`（relay 写临时文件）→ rename → `<root>/events/`（待消费）
/// → 消费时 rename → `<root>/processing/`（崩溃后可重放）→ 删除
public enum SpoolPaths {
    /// 默认 ~/Library/Application Support/Eureka，可用 EUREKA_SPOOL_DIR 覆盖（测试/演示用）
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
