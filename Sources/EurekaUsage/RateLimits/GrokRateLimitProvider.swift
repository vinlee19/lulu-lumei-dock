import Foundation
import EurekaKit

/// Grok quota: zero network requests - reads the last `billing: fetched credits config` snapshot
/// in `~/.grok/logs/unified.jsonl` (the grok CLI writes this line every time it fetches billing).
/// Same design as CodexRateLimitProvider (tail-reads a local log, judges stale/expired by the
/// "as of" time).
/// Grok has a single unified quota pool (no 5h/weekly dual windows), so secondary is always nil.
public struct GrokRateLimitProvider: RateLimitProvider {
    public let source = AgentSource.grok
    private let logURL: URL
    /// How old a snapshot may be and still be used (default 7 days; older counts as no data)
    private let maxAge: TimeInterval

    public init(logURL: URL, maxAge: TimeInterval = 7 * 86400) {
        self.logURL = logURL
        self.maxAge = maxAge
    }

    public func snapshot() async -> RateLimitSnapshot? {
        guard let snapshot = Self.lastBilling(in: logURL) else { return nil }
        guard Date().timeIntervalSince(snapshot.asOf) < maxAge else { return nil }
        var result = snapshot
        // Snapshots older than 10 minutes are marked stale (UI shows "as of HH:mm")
        result.isStale = Date().timeIntervalSince(snapshot.asOf) > 600
        return result
    }

    /// Last billing snapshot in the file's trailing 256KB (billing lines are relatively sparse, so
    /// the window is larger)
    public static func lastBilling(in url: URL) -> RateLimitSnapshot? {
        guard
            let handle = FileHandle(forReadingAtPath: url.path),
            let size = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, 262_144)
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        var latest: RateLimitSnapshot?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let snapshot = parse(Data(line)) { latest = snapshot }
        }
        return latest
    }

    /// Parses one unified.jsonl line; nil for non-billing lines.
    public static func parse(_ line: Data) -> RateLimitSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            (root["msg"] as? String) == "billing: fetched credits config",
            let ctx = root["ctx"] as? [String: Any],
            let config = ctx["config"] as? [String: Any]
        else { return nil }

        // proto3 omits zero values: in a 0% week creditUsagePercent is absent → record 0
        let usedPercent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue ?? 0
        let asOf = parseDate(root["ts"] as? String) ?? Date()

        var windowMinutes = 10080  // Weekly by default
        var resetsAt: Date?
        if let period = config["currentPeriod"] as? [String: Any] {
            let type = (period["type"] as? String) ?? ""
            windowMinutes = type.contains("MONTHLY") ? 43200 : 10080
            resetsAt = parseDate(period["end"] as? String)
        }

        return RateLimitSnapshot(
            source: .grok,
            asOf: asOf,
            planType: ctx["subscriptionTier"] as? String,
            primary: RateLimitWindow(
                usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt),
            secondary: nil)
    }

    // ts has fractional seconds (...Z), currentPeriod.end doesn't → try both
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
