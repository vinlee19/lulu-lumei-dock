import Foundation
import EurekaKit
import EurekaStore

/// Antigravity 配额（**实验**，设置里默认关闭）：零网络——读 Antigravity IDE 缓存在
/// `User/globalStorage/state.vscdb` 里的 `antigravityUnifiedStateSync.userStatus`。
///
/// ⚠️ 这个值里同时有用户姓名与邮箱。**只按字段号取额度相关的两段，其余字段不解码、不记录、不落库**：
/// - `33.1`（重复）每个模型一条：`1` 显示名（如 "Gemini 3.1 Pro (High)"）、
///   `15.1` 剩余比例（fixed32 float，1.0 = 满）、`15.2.1` 重置时间（Unix 秒）
/// - `36.2` 套餐名（如 "Google AI Pro"）
/// 外层编码：base64 → protobuf `1.2.1` 是又一层 base64 字符串 → 内层 protobuf。
///
/// 缓存只在 IDE 运行时刷新（CLI `agy` 不写），故超过 24h 标 stale、超过 7 天视为无数据。
/// 模型按家族分两条：主窗口 = Gemini 家族剩余最少的那个；副窗口 = 其余（Claude / GPT-OSS）。
public struct AntigravityRateLimitProvider: RateLimitProvider {
    public let source = AgentSource.antigravity
    private let stateDBs: [URL]
    private let staleAfter: TimeInterval
    private let maxAge: TimeInterval

    static let userStatusKey = "antigravityUnifiedStateSync.userStatus"

    public init(stateDBs: [URL], staleAfter: TimeInterval = 86400, maxAge: TimeInterval = 7 * 86400) {
        self.stateDBs = stateDBs
        self.staleAfter = staleAfter
        self.maxAge = maxAge
    }

    public func snapshot() async -> RateLimitSnapshot? {
        // 两个安装（Antigravity / Antigravity IDE）取最近写过的那个
        let candidates = stateDBs.compactMap { url -> (URL, Date)? in
            guard let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .modificationDate] as? Date else { return nil }
            return (url, mtime)
        }.sorted { $0.1 > $1.1 }
        for (url, mtime) in candidates {
            guard Date().timeIntervalSince(mtime) < maxAge else { continue }
            guard let raw = Self.readUserStatus(url),
                  var snapshot = Self.parse(userStatus: raw, asOf: mtime)
            else { continue }
            snapshot.isStale = Date().timeIntervalSince(mtime) > staleAfter
            return snapshot
        }
        return nil
    }

    /// 参数化查询单个键；state.vscdb 是回滚日志模式，只读打开即可
    static func readUserStatus(_ url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path),
              let db = try? SQLiteDB(path: url.path, readOnly: true)
        else { return nil }
        let rows = (try? db.query(
            "SELECT value FROM ItemTable WHERE key = ?", [.text(userStatusKey)]
        ) { row -> Data? in row.blob(0) ?? row.text(0).map { Data($0.utf8) } }) ?? []
        return rows.first ?? nil
    }

    /// 解出额度快照；结构不符返回 nil
    public static func parse(userStatus raw: Data, asOf: Date) -> RateLimitSnapshot? {
        guard let outer = decodeBase64(raw),
              let innerText = ProtobufReader.first(outer, [1, 2, 1])?.data,
              let inner = decodeBase64(innerText)
        else { return nil }
        guard let quotas = ProtobufReader.first(inner, [33])?.data else { return nil }

        struct ModelQuota {
            var label: String
            var remaining: Double
            var resetsAt: Date?
        }
        let models = ProtobufReader.all(quotas, 1).compactMap { field -> ModelQuota? in
            guard let entry = field.data,
                  let label = ProtobufReader.first(entry, [1])?.string,
                  let remaining = ProtobufReader.first(entry, [15, 1])?.float,
                  remaining.isFinite, remaining >= 0, remaining <= 1
            else { return nil }
            let reset = ProtobufReader.first(entry, [15, 2, 1])?.uint
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return ModelQuota(label: label, remaining: Double(remaining), resetsAt: reset)
        }
        guard !models.isEmpty else { return nil }

        func window(_ group: [ModelQuota], label: String) -> RateLimitWindow? {
            guard let worst = group.min(by: { $0.remaining < $1.remaining }) else { return nil }
            return RateLimitWindow(
                usedPercent: (1 - worst.remaining) * 100, windowMinutes: 0,
                resetsAt: group.compactMap(\.resetsAt).min(), label: label)
        }
        let gemini = models.filter { $0.label.hasPrefix("Gemini") }
        let others = models.filter { !$0.label.hasPrefix("Gemini") }
        return RateLimitSnapshot(
            source: .antigravity,
            asOf: asOf,
            planType: ProtobufReader.first(inner, [36, 2])?.string,
            primary: window(gemini, label: "Gemini 模型"),
            secondary: window(others, label: "Claude / GPT-OSS 模型"))
    }

    private static func decodeBase64(_ data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: text)
    }
}
