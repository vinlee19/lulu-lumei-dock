import Foundation

/// MCP server 的工具探测缓存：`tools/list` 的结果按 server 名（小写）落盘，
/// 供两处复用：① MCP 页展示工具清单与上下文开销；② `ContextBreakdownEstimator`
/// 用真实 schema token 数替换每 server 1500 的拍脑袋常量。
///
/// 只存工具**名称/标题/描述（截断）/注解/数量/token 估算/握手元信息**——不存 schema
/// 正文、不存任何配置值，无密钥暴露面。文件在 App Support（与 pricing.json /
/// context-windows.json 同级）。
public struct MCPToolCacheEntry: Codable, Equatable, Sendable {
    public var toolCount: Int
    public var toolNames: [String]
    /// tools/list 响应正文的 token 估算 ≈ 该 server 每轮注入上下文的 schema 开销
    public var schemaTokens: Int
    public var serverVersion: String?
    public var protocolVersion: String?
    public var capabilities: [String]
    /// 工具明细（v2.7 加：title/描述/注解；旧缓存无此键照常解码）
    public var tools: [MCPToolSummary]?
    /// resources/list 第一页计数（server 未声明该能力则 nil）
    public var resourceCount: Int?
    /// prompts/list 第一页计数
    public var promptCount: Int?
    /// 提示词清单（v2.8 加：名字+描述，上限由写入方裁；旧缓存无此键照常解码）
    public var prompts: [MCPNamedSummary]?
    /// 资源清单（名字+描述，不存 URI/正文）
    public var resources: [MCPNamedSummary]?
    public var measuredAt: Date

    public init(
        toolCount: Int, toolNames: [String], schemaTokens: Int,
        serverVersion: String? = nil, protocolVersion: String? = nil,
        capabilities: [String] = [], tools: [MCPToolSummary]? = nil,
        resourceCount: Int? = nil, promptCount: Int? = nil,
        prompts: [MCPNamedSummary]? = nil, resources: [MCPNamedSummary]? = nil,
        measuredAt: Date
    ) {
        self.toolCount = toolCount
        self.toolNames = toolNames
        self.schemaTokens = schemaTokens
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.tools = tools
        self.resourceCount = resourceCount
        self.promptCount = promptCount
        self.prompts = prompts
        self.resources = resources
        self.measuredAt = measuredAt
    }
}

/// 单个工具的展示摘要（description 在写入前截断，schema 正文不进缓存）
public struct MCPToolSummary: Codable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var readOnly: Bool?
    public var destructive: Bool?
    public var hasOutputSchema: Bool?
    /// 参数名（必填带 `*` 后缀；v2.8 加，只有名字没有 schema 正文）
    public var params: [String]?

    public init(
        name: String, title: String? = nil, description: String? = nil,
        readOnly: Bool? = nil, destructive: Bool? = nil, hasOutputSchema: Bool? = nil,
        params: [String]? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.readOnly = readOnly
        self.destructive = destructive
        self.hasOutputSchema = hasOutputSchema
        self.params = params
    }
}

/// 提示词/资源的展示摘要（名字 + 截断描述）
public struct MCPNamedSummary: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public enum MCPToolCache {
    public static func defaultURL() -> URL {
        SpoolPaths.root().appendingPathComponent("mcp-tools-cache.json")
    }

    /// 读缓存（缺失/解析失败 → 空表，best-effort）
    public static func load(from url: URL = defaultURL()) -> [String: MCPToolCacheEntry] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: MCPToolCacheEntry].self, from: data)) ?? [:]
    }

    public static func save(
        _ entries: [String: MCPToolCacheEntry], to url: URL = defaultURL()
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 单条更新（键 = server 名小写；同名 server 跨源共享一份工具清单）
    public static func upsert(
        name: String, entry: MCPToolCacheEntry, at url: URL = defaultURL()
    ) {
        var entries = load(from: url)
        entries[name.lowercased()] = entry
        save(entries, to: url)
    }
}
