import Foundation

/// Hermes's built-in skill usage counters: `~/.hermes/skills/.usage.json`.
///
/// Surveyed (2026-08): the top level is `{<slug>: {use_count, last_used_at, view_count, …}}`.
/// Hermes's state.db message stream has no skill invocation events, so this counter file is the
/// **only** local source of per-skill data — reading it fills the "hit count / last used" gap
/// on the skills page for hermes.
public enum HermesSkillUsage {
    public struct Stat: Equatable, Sendable {
        public var slug: String
        public var useCount: Int
        public var lastUsedAt: Date?

        public init(slug: String, useCount: Int, lastUsedAt: Date?) {
            self.slug = slug
            self.useCount = useCount
            self.lastUsedAt = lastUsedAt
        }
    }

    /// Reads the counter file; a missing file / bad JSON returns empty (this is an optional
    /// enhancement and shouldn't error). Rows with `use_count == 0` are omitted (never used ≠ has
    /// stats).
    public static func read(url: URL) -> [Stat] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        var stats: [Stat] = []
        for (slug, value) in root {
            guard let info = value as? [String: Any] else { continue }
            let count = (info["use_count"] as? NSNumber)?.intValue ?? 0
            guard count > 0 else { continue }
            stats.append(Stat(
                slug: slug,
                useCount: count,
                lastUsedAt: (info["last_used_at"] as? String).flatMap(parseDate)))
        }
        return stats.sorted { $0.slug < $1.slug }
    }

    private static let isoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /// Hermes writes **6-digit microseconds** (`2026-07-25T03:00:53.141994+00:00`), beyond the
    /// 3 fractional digits ISO8601DateFormatter expects → truncate to milliseconds, then parse.
    static func parseDate(_ raw: String) -> Date? {
        if let date = isoFraction.date(from: raw) { return date }
        if let dot = raw.firstIndex(of: ".") {
            let tail = raw[raw.index(after: dot)...]
            let digits = tail.prefix(while: \.isNumber)
            let zone = tail.dropFirst(digits.count)
            let trimmed = "\(raw[..<dot]).\(digits.prefix(3))\(zone)"
            if let date = isoFraction.date(from: trimmed) { return date }
        }
        return isoPlain.date(from: raw)
    }
}
