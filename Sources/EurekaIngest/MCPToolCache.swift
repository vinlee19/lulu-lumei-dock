import Foundation

/// Tool probe cache for MCP servers: `tools/list` results are persisted keyed by server name
/// (lowercased) and reused in two places: (1) the MCP page showing the tool list and context cost;
/// (2) `ContextBreakdownEstimator`, which replaces the guessed 1500-per-server constant with real
/// schema token counts.
///
/// Stores only tool **names/titles/descriptions (truncated)/annotations/counts/token estimates/handshake
/// metadata**: no schema bodies, no config values, so no secret exposure surface. The file lives in App
/// Support (alongside pricing.json / context-windows.json).
public struct MCPToolCacheEntry: Codable, Equatable, Sendable {
    public var toolCount: Int
    public var toolNames: [String]
    /// Token estimate of the tools/list response body ≈ the schema cost this server injects into
    /// context each turn
    public var schemaTokens: Int
    public var serverVersion: String?
    public var protocolVersion: String?
    public var capabilities: [String]
    /// Tool details (added in v2.7: title/description/annotations; old caches without this key
    /// still decode)
    public var tools: [MCPToolSummary]?
    /// resources/list first-page count (nil if the server does not declare the capability)
    public var resourceCount: Int?
    /// prompts/list first-page count
    public var promptCount: Int?
    /// Prompt list (added in v2.8: name + description, capped by the writer; old caches without
    /// this key still decode)
    public var prompts: [MCPNamedSummary]?
    /// Resource list (name + description; URIs/bodies are not stored)
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

/// Display summary for a single tool (description is truncated before writing; schema bodies never
/// enter the cache)
public struct MCPToolSummary: Codable, Equatable, Sendable {
    public var name: String
    public var title: String?
    public var description: String?
    public var readOnly: Bool?
    public var destructive: Bool?
    public var hasOutputSchema: Bool?
    /// Parameter names (required ones get a `*` suffix; added in v2.8, names only, no schema body)
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

/// Display summary for a prompt/resource (name + truncated description)
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

    /// Reads the cache (missing / parse failure → empty map, best-effort)
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

    /// Updates a single entry (key = lowercased server name; same-named servers across sources
    /// share one tool list)
    public static func upsert(
        name: String, entry: MCPToolCacheEntry, at url: URL = defaultURL()
    ) {
        var entries = load(from: url)
        entries[name.lowercased()] = entry
        save(entries, to: url)
    }
}
