import Foundation

/// Hermes 自带的技能使用计数：`~/.hermes/skills/.usage.json`。
///
/// 实勘（2026-08）顶层是 `{<slug>: {use_count, last_used_at, view_count, …}}`。
/// Hermes 的 state.db 消息流里没有技能调用事件，这个计数文件是它逐技能数据的
/// **唯一**本地来源 —— 读它补上技能页对 hermes 的"命中次数/最近使用"空白。
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

    /// 读取计数文件；文件缺失/坏 JSON 返回空（这是个可选增强，不该报错）。
    /// `use_count == 0` 的行不出（从未用过 ≠ 有统计）。
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

    /// Hermes 写的是 **6 位微秒**（`2026-07-25T03:00:53.141994+00:00`），
    /// 超出 ISO8601DateFormatter 对 3 位小数的期待 → 截到毫秒再解析。
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
