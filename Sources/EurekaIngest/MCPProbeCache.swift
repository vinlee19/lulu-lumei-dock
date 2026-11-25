import Foundation

/// **Persistent snapshot** of probe results: the MCP detail page shows "Last checked: Connected ·
/// Yesterday" as soon as it opens, instead of a blank slate after restart waiting for the user to
/// probe (v2.6's "don't make users guess").
///
/// Stores only display fields derived from the status (label/tone/summary/hint/time): no secrets, no
/// response bodies, no headers. The file sits alongside mcp-tools-cache.json. Key = entry.id (source + path +
/// name; a same-named server may be reachable differently per config location, so it must be stored per location).
public struct MCPProbeSnapshot: Codable, Equatable, Sendable {
    public var label: String
    /// String form of MCPProbe.Status.Tone (ok / warning / bad)
    public var tone: String
    /// Handshake summary ("v1.8 · Protocol …") or a short error; optional
    public var detail: String?
    /// Guidance text such as re-authorization; optional
    public var hint: String?
    /// Derived auth scheme ("oauth" / "header-or-key" / "none"; added in v2.7, old caches without
    /// this key still decode). Lets MCPAuthRouter route the authorization flow with zero network,
    /// surviving restarts.
    public var authScheme: String?
    /// Which status this was ("connected", "unauthorized", "httpError:502"…), so the label can be
    /// shown in the current language instead of the one in use when the probe ran. Old caches
    /// without this key still decode and fall back to the stored `label`.
    public var kind: String?
    public var checkedAt: Date

    /// The status label in the current interface language
    public var displayLabel: String {
        guard let kind else { return label }
        let parts = kind.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "connected": return MCPProbe.Status.connected(.init()).label
        case "notMCP": return MCPProbe.Status.notMCP.label
        case "unauthorized": return MCPProbe.Status.unauthorized(code: 401, authServer: nil).label
        case "httpError":
            return MCPProbe.Status.httpError(parts.count > 1 ? Int(parts[1]) ?? 0 : 0).label
        case "unreachable": return MCPProbe.Status.unreachable("").label
        case "commandFound": return MCPProbe.Status.commandFound("").label
        case "commandMissing": return MCPProbe.Status.commandMissing.label
        default: return label
        }
    }

    public init(
        label: String, tone: String, detail: String? = nil,
        hint: String? = nil, authScheme: String? = nil, kind: String? = nil, checkedAt: Date
    ) {
        self.kind = kind
        self.label = label
        self.tone = tone
        self.detail = detail
        self.hint = hint
        self.authScheme = authScheme
        self.checkedAt = checkedAt
    }

    /// Derived from the probe status (single entry point; tests pin the fidelity of each branch)
    public init(status: MCPProbe.Status, authScheme: String? = nil, checkedAt: Date) {
        self.label = status.label
        switch status {
        case .connected: self.kind = "connected"
        case .notMCP: self.kind = "notMCP"
        case .unauthorized: self.kind = "unauthorized"
        case .httpError(let code): self.kind = "httpError:\(code)"
        case .unreachable: self.kind = "unreachable"
        case .commandFound: self.kind = "commandFound"
        case .commandMissing: self.kind = "commandMissing"
        }
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
