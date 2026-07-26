import Foundation
import EurekaKit

/// Codex 限额：零网络请求——最新 rollout 文件（整树枚举，按 mtime 取新）
/// 尾部的最后一条 token_count.rate_limits 快照（带"截至"时间）。
public struct CodexRateLimitProvider: RateLimitProvider {
    public let source = AgentSource.codex
    private let sessionsRoot: URL
    /// 快照多旧仍可用（默认 7 天；再旧视为无数据）
    private let maxAge: TimeInterval

    public init(sessionsRoot: URL, maxAge: TimeInterval = 7 * 86400) {
        self.sessionsRoot = sessionsRoot
        self.maxAge = maxAge
    }

    public func snapshot() async -> RateLimitSnapshot? {
        guard let file = newestRollout() else { return nil }
        guard let snapshot = Self.lastRateLimits(in: file) else { return nil }
        guard Date().timeIntervalSince(snapshot.asOf) < maxAge else { return nil }
        var result = snapshot
        // 超过 10 分钟的快照标 stale（UI 显示"截至 HH:mm"）
        result.isStale = Date().timeIntervalSince(snapshot.asOf) > 600
        return result
    }

    /// 整树枚举全部日期目录（YYYY/MM/DD），返回 mtime 最新的 rollout。
    /// resume 的旧会话在创建日目录原地追加（mtime 刷新），只数最近日期目录会漏；
    /// 不按回看天数过滤——"最新 mtime"本身已界定新鲜度，快照新旧再由 maxAge 把关。
    public func newestRollout() -> URL? {
        var newest: (url: URL, mtime: Date)?
        for entry in CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot) {
            let mtime = entry.mtime ?? .distantPast
            if newest == nil || mtime > newest!.mtime {
                newest = (entry.url, mtime)
            }
        }
        return newest?.url
    }

    /// 文件尾部 64KB 中最后一条 rate_limits
    public static func lastRateLimits(in url: URL) -> RateLimitSnapshot? {
        guard
            let handle = FileHandle(forReadingAtPath: url.path),
            let size = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, 65536)
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        var latest: RateLimitSnapshot?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            for case .rateLimits(let snapshot) in CodexRolloutDecoderProxy.decode(Data(line)) {
                latest = snapshot
            }
        }
        return latest
    }
}

/// EurekaUsage 不依赖 EurekaIngest，自带一个只解 rate_limits 的精简解码
enum CodexRolloutDecoderProxy {
    enum Decoded {
        case rateLimits(RateLimitSnapshot)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func decode(_ line: Data) -> [Decoded] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            root["type"] as? String == "event_msg",
            let payload = root["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let limits = payload["rate_limits"] as? [String: Any]
        else { return [] }

        let asOf = (root["timestamp"] as? String).flatMap { isoFormatter.date(from: $0) } ?? Date()

        func window(_ key: String) -> RateLimitWindow? {
            guard let dict = limits[key] as? [String: Any],
                  let usedPercent = dict["used_percent"] as? Double
            else { return nil }
            return RateLimitWindow(
                usedPercent: usedPercent,
                windowMinutes: dict["window_minutes"] as? Int ?? 0,
                resetsAt: (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }

        return [.rateLimits(RateLimitSnapshot(
            source: .codex,
            asOf: asOf,
            planType: limits["plan_type"] as? String,
            primary: window("primary"),
            secondary: window("secondary")
        ))]
    }
}
