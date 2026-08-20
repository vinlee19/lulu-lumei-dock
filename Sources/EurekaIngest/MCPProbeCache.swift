import Foundation

/// 探测结果的**持久快照**：让 MCP 详情页打开即见"上次检测：已连接 · 昨天"，
/// 而不是重启后一片空白等用户点检测（v2.6 的"不让用户猜"）。
///
/// 只存状态折算后的展示字段（标签/色调/摘要/引导/时间）——无密钥、无响应体、
/// 无请求头。文件与 mcp-tools-cache.json 同级。键 = entry.id（源+路径+名，
/// 同名 server 各处配置的可达性可能不同，必须按处存）。
public struct MCPProbeSnapshot: Codable, Equatable, Sendable {
    public var label: String
    /// MCPProbe.Status.Tone 的字符串形态（ok / warning / bad）
    public var tone: String
    /// 握手摘要（"v1.8 · 协议 …"）或错误简述；可空
    public var detail: String?
    /// 再授权等引导文案；可空
    public var hint: String?
    /// 鉴权方式折算（"oauth" / "header-or-key" / "none"；v2.7 加，旧缓存无此键照常解码）。
    /// 供 MCPAuthRouter 在零网络下路由授权动线，重启不丢。
    public var authScheme: String?
    public var checkedAt: Date

    public init(
        label: String, tone: String, detail: String? = nil,
        hint: String? = nil, authScheme: String? = nil, checkedAt: Date
    ) {
        self.label = label
        self.tone = tone
        self.detail = detail
        self.hint = hint
        self.authScheme = authScheme
        self.checkedAt = checkedAt
    }

    /// 从探测状态折算（唯一入口，测试钉住各分支的保真）
    public init(status: MCPProbe.Status, authScheme: String? = nil, checkedAt: Date) {
        self.label = status.label
        switch status.tone {
        case .ok: self.tone = "ok"
        case .warning: self.tone = "warning"
        case .bad: self.tone = "bad"
        }
        switch status {
        case .connected(let info):
            self.detail = info.summary.isEmpty ? nil : info.summary
        case .unreachable(let reason):
            self.detail = reason
        case .commandFound(let path):
            self.detail = path
        default:
            self.detail = nil
        }
        self.hint = status.hint
        self.authScheme = authScheme
        self.checkedAt = checkedAt
    }
}

public enum MCPProbeCache {
    public static func defaultURL() -> URL {
        SpoolPaths.root().appendingPathComponent("mcp-probe-cache.json")
    }

    public static func load(from url: URL = defaultURL()) -> [String: MCPProbeSnapshot] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: MCPProbeSnapshot].self, from: data)) ?? [:]
    }

    public static func save(
        _ entries: [String: MCPProbeSnapshot], to url: URL = defaultURL()
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public static func upsert(
        key: String, snapshot: MCPProbeSnapshot, at url: URL = defaultURL()
    ) {
        var entries = load(from: url)
        entries[key] = snapshot
        save(entries, to: url)
    }
}
