import CryptoKit
import EurekaIngest
import Foundation

/// 把随 app 分发的 eureka-relay 同步到稳定路径
/// `~/Library/Application Support/Eureka/bin/eureka-relay`。
/// hooks/notify 配置永远只引用稳定路径 → 升级/移动 app 不断链。
enum RelaySyncer {
    static var stableRelayURL: URL {
        SpoolPaths.root()
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("eureka-relay")
    }

    /// 与当前可执行文件同目录的 relay（.build/debug/ 与 lulu-lumei-dock.app/Contents/MacOS/ 都成立）
    static var bundledRelayURL: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return nil
        }
        let candidate = executable.deletingLastPathComponent()
            .appendingPathComponent("eureka-relay")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// 同步（内容不同才覆盖），返回稳定路径；找不到源时返回 nil
    @discardableResult
    static func sync() -> URL? {
        guard let source = bundledRelayURL else { return nil }
        let target = stableRelayURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing = try? Data(contentsOf: target),
               let fresh = try? Data(contentsOf: source),
               SHA256.hash(data: existing) == SHA256.hash(data: fresh) {
                return target  // 已是最新
            }
            // 先落临时文件再替换，避免覆盖正在执行的二进制
            let tmp = target.deletingLastPathComponent()
                .appendingPathComponent(".eureka-relay.tmp")
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: source, to: tmp)
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: target)
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            return target
        } catch {
            fputs("[eureka] relay 同步失败: \(error)\n", stderr)
            return fm.fileExists(atPath: target.path) ? target : nil
        }
    }
}
