import Foundation
import EurekaKit

/// Codex rate limits: zero network requests - the last token_count.rate_limits snapshot at the
/// tail of the newest rollout file (whole-tree enumeration, newest by mtime)
/// (with an "as of" time).
public struct CodexRateLimitProvider: RateLimitProvider {
    public let source = AgentSource.codex
    private let sessionsRoot: URL
    /// How old a snapshot may be and still be used (default 7 days; older counts as no data)
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
        // Snapshots older than 10 minutes are marked stale (UI shows "as of HH:mm")
        result.isStale = Date().timeIntervalSince(snapshot.asOf) > 600
        return result
    }

    /// Enumerates every date directory (YYYY/MM/DD) in the tree and returns the newest-mtime
    /// rollout. A resumed old session appends in place under its creation-day directory (mtime
    /// refreshes), so counting only recent date directories misses it; there is no lookback-days
    /// filter - "newest mtime" already bounds freshness, and maxAge then gates how old the snapshot
    /// is.
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

    /// Last rate_limits entry in the file's trailing 64KB
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

/// EurekaUsage doesn't depend on EurekaIngest, so it carries a slim decoder that only parses
/// rate_limits
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
