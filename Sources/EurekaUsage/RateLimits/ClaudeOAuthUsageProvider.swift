import Foundation
import EurekaKit

/// Claude 订阅限额：**非官方接口，默认关闭、设置页 opt-in**。
/// 凭证经 `/usr/bin/security` 子进程读取（弹窗主体是 Apple 签名的 security 工具，
/// "始终允许"一次后静默——避开 ad-hoc 重签后 Keychain ACL 反复弹窗）。
/// 任何失败 → 返回 nil → UI 整块隐藏；绝不自己 refresh token（避免与 Claude Code
/// 竞争使 refresh token 失效），401 时提示用户跑一次 claude。
public final class ClaudeOAuthUsageProvider: RateLimitProvider {
    public let source = AgentSource.claude

    /// 最近一次失败原因（UI 提示用；nil = 正常）
    public private(set) var lastFailure: String?
    private var cached: RateLimitSnapshot?

    public init() {}

    public func snapshot() async -> RateLimitSnapshot? {
        guard let token = Self.readAccessToken() else {
            lastFailure = "未能从钥匙串读取 Claude Code 凭证"
            return staleCache()
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                lastFailure = "凭证过期（\(status)）：跑一次 claude 让它刷新登录态"
                return staleCache()
            }
            guard status == 200 else {
                lastFailure = "接口返回 \(status)（非官方接口可能已变更）"
                return staleCache()
            }
            guard let snapshot = Self.parseUsageResponse(data) else {
                lastFailure = "响应格式无法识别（非官方接口可能已变更）"
                return staleCache()
            }
            lastFailure = nil
            cached = snapshot
            return snapshot
        } catch {
            lastFailure = "请求失败：\(error.localizedDescription)"
            return staleCache()
        }
    }

    /// 失败时给最近一次成功值（标 stale），连缓存都没有则 nil（UI 隐藏）
    private func staleCache() -> RateLimitSnapshot? {
        guard var cached else { return nil }
        cached.isStale = true
        return cached
    }

    // MARK: - 凭证

    /// Keychain 条目 "Claude Code-credentials" 的值是 JSON，
    /// 取 claudeAiOauth.accessToken
    static func readAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", "Claude Code-credentials", "-w",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let json = try? JSONSerialization.jsonObject(
                with: Data(raw.utf8)) as? [String: Any]
        else { return nil }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        return oauth["accessToken"] as? String
    }

    // MARK: - 宽松解析

    /// 已知形态（社区观察，随时可能变）：
    /// `{"five_hour":{"utilization":32,"resets_at":"2026-06-10T16:00:00Z"},
    ///   "seven_day":{...}, "seven_day_opus":{...}}`
    /// utilization 可能是 0-1 小数或 0-100 百分数；只取认识的字段。
    public static func parseUsageResponse(_ data: Data, now: Date = Date()) -> RateLimitSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func window(_ keys: [String], minutes: Int) -> RateLimitWindow? {
            for key in keys {
                guard let dict = root[key] as? [String: Any] else { continue }
                guard let usedRaw = (dict["utilization"] as? Double)
                    ?? (dict["used_percent"] as? Double) else { continue }
                let percent = usedRaw <= 1.0 ? usedRaw * 100 : usedRaw
                var resetsAt: Date?
                if let isoString = dict["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    resetsAt = formatter.date(from: isoString)
                    if resetsAt == nil {
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        resetsAt = formatter.date(from: isoString)
                    }
                } else if let epoch = dict["resets_at"] as? Double {
                    resetsAt = Date(timeIntervalSince1970: epoch)
                }
                return RateLimitWindow(
                    usedPercent: percent, windowMinutes: minutes, resetsAt: resetsAt)
            }
            return nil
        }

        let fiveHour = window(["five_hour", "fiveHour", "session"], minutes: 300)
        let sevenDay = window(["seven_day", "sevenDay", "weekly"], minutes: 10080)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return RateLimitSnapshot(
            source: .claude,
            asOf: now,
            planType: root["plan_type"] as? String ?? root["subscription_type"] as? String,
            primary: fiveHour,
            secondary: sevenDay
        )
    }
}
