import Foundation
import EurekaKit

/// Grok 配额：零网络请求——读 `~/.grok/logs/unified.jsonl` 里最后一条
/// `billing: fetched credits config` 快照（grok CLI 每次拉取账单都会写这行）。
/// 与 CodexRateLimitProvider 同构（本地日志尾读、按"截至"时间判 stale/过期）。
/// Grok 是单一统一配额池（无 5h/周双窗），故 secondary 恒为 nil。
public struct GrokRateLimitProvider: RateLimitProvider {
    public let source = AgentSource.grok
    private let logURL: URL
    /// 快照多旧仍可用（默认 7 天；再旧视为无数据）
    private let maxAge: TimeInterval

    public init(logURL: URL, maxAge: TimeInterval = 7 * 86400) {
        self.logURL = logURL
        self.maxAge = maxAge
    }

    public func snapshot() async -> RateLimitSnapshot? {
        guard let snapshot = Self.lastBilling(in: logURL) else { return nil }
        guard Date().timeIntervalSince(snapshot.asOf) < maxAge else { return nil }
        var result = snapshot
        // 超过 10 分钟的快照标 stale（UI 显示"截至 HH:mm"）
        result.isStale = Date().timeIntervalSince(snapshot.asOf) > 600
        return result
    }

    /// 文件尾部 256KB 中最后一条 billing 快照（billing 行相对稀疏，取大些的窗口）
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

    /// 解析一行 unified.jsonl；非 billing 行返回 nil。
    public static func parse(_ line: Data) -> RateLimitSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            (root["msg"] as? String) == "billing: fetched credits config",
            let ctx = root["ctx"] as? [String: Any],
            let config = ctx["config"] as? [String: Any]
        else { return nil }

        // proto3 省略零值：0% 那周 creditUsagePercent 缺省 → 记 0
        let usedPercent = (config["creditUsagePercent"] as? NSNumber)?.doubleValue ?? 0
        let asOf = parseDate(root["ts"] as? String) ?? Date()

        var windowMinutes = 10080  // 默认按周
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

    // ts 带小数秒（…Z），currentPeriod.end 不带 → 两种都试
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
