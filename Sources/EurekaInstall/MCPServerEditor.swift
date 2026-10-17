import EurekaKit
import Foundation

/// The **full definition** of an MCP server (including env / header values).
///
/// ⚠️ Full fidelity may only exist in memory: values only pass through between "read source config
/// → write target config"; they are never persisted, logged, uploaded or shown in the UI - display
/// always goes through MCPConfigIndexer's key-names-only version.
public struct MCPServerDefinition: Equatable {
    public enum Transport: Equatable {
        case stdio
        case remote
    }

    public var name: String
    public var transport: Transport
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]
    public var timeout: Int?

    public init(
        name: String, transport: Transport,
        command: String? = nil, args: [String] = [], env: [String: String] = [:],
        url: String? = nil, headers: [String: String] = [:], timeout: Int? = nil
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.timeout = timeout
    }
}

public enum MCPEditError: Error, LocalizedError, Equatable {
    /// The target config already has a server with this name (never overwritten, same rule as skill
    /// propagation)
    case alreadyExists(String)
    /// The target has no such server on remove / read
    case notFound(String)
    /// Incomplete definition (stdio without command / remote without url), or contains characters
    /// that can't be written safely
    case invalidDefinition(String)
    /// Target format not verified, writes refused (e.g. remote server → TOML target)
    case unsupportedTarget(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name): return L10n.format("A server named “%@” already exists; it will not be overwritten", zhHans: "已存在同名 server「%@」，不覆盖", String(name))
        case .notFound(let name): return L10n.format("No server named “%@” was found", zhHans: "没有找到 server「%@」", String(name))
        case .invalidDefinition(let detail): return L10n.format("Incomplete definition: %@", zhHans: "定义不完整：%@", String(detail))
        case .unsupportedTarget(let detail): return detail
        }
    }
}

/// JSON dialects: how each vendor's fields differ for the same mcpServers semantics (verified
/// locally).
public enum MCPJSONStyle {
    /// claude / qwen: explicit `type` (stdio / http)
    case typed
    /// gemini / cursor / kimi: no `type`, inferred from fields; remote supports `timeout`
    case plain
    /// opencode: `type` local/remote, command is an array (including the executable), env is named
    /// `environment`, carries `enabled`
    case opencode
}

/// Read/write engine for MCP server configs (plain text in/out, zero dependencies, unit-testable).
///
/// The JSON side's parse/serialize contract matches `ClaudeHooksInstaller` byte for byte (empty
/// file → empty object; `.prettyPrinted + .sortedKeys + .withoutEscapingSlashes` + trailing
/// newline; reordering the whole file is the existing contract). The TOML side follows
/// `CodexProfileEditor`'s section surgery: line-level reads/writes, never reorders the whole file,
/// normalised EOF appends, same section-name quoting rules. Every guard runs before any change - a
/// throw means "the original file was not touched".
public enum MCPServerEditor {
    // MARK: - JSON (claude / gemini / cursor / kimi / qwen / opencode)

    /// Writes the server into `container` ("mcpServers", or opencode's "mcp"). Creates the
    /// container if missing; container present but not an object → foreignConfig (never overwrite a
    /// form we don't understand).
    public static func upsertJSON(
        into json: String, definition: MCPServerDefinition,
        container: String, style: MCPJSONStyle
    ) throws -> String {
        try validate(definition)
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard servers[definition.name] == nil else {
            throw MCPEditError.alreadyExists(definition.name)
        }
        servers[definition.name] = encode(definition, style: style)
        root[container] = servers
        return try serialize(root)
    }

    public static func removeJSON(
        from json: String, name: String, container: String
    ) throws -> String {
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard servers[name] != nil else { throw MCPEditError.notFound(name) }
        servers.removeValue(forKey: name)
        // Keep the container (an empty object is normal in every vendor's config, e.g. kimi's
        // mcp.json); less surprising than deleting the key
        root[container] = servers
        return try serialize(root)
    }

    /// Reads the full definition (including env/headers values). Decodes all three JSON dialects
    /// leniently: command may be a string or an array (opencode), and env also accepts
    /// `environment`.
    public static func readDefinitionJSON(
        _ json: String, name: String, container: String
    ) throws -> MCPServerDefinition {
        let root = try parse(json)
        let servers = try serversDict(in: root, container: container)
        guard let entry = servers[name] as? [String: Any] else {
            throw MCPEditError.notFound(name)
        }
        return decodeEntry(name: name, dict: entry)
    }

    /// Edits an existing server (**merge, not re-encode**): the entry must already exist; modeled
    /// fields are written, modeled fields that were cleared are deleted, and **unmodeled keys are
    /// kept as-is** - in particular opencode's `enabled` is never flipped/overwritten on edit (only
    /// added when the key was absent and the dialect requires it).
    public static func updateJSON(
        in json: String, definition: MCPServerDefinition,
        container: String, style: MCPJSONStyle
    ) throws -> String {
        try validate(definition)
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard var entry = servers[definition.name] as? [String: Any] else {
            throw MCPEditError.notFound(definition.name)
        }
        // Clear the full set of modeled fields, then write (this also cleans up stdio ↔ remote
        // switches); enabled is not in the list
        let modeled = ["type", "command", "args", "env", "environment",
                       "headers", "url", "httpUrl", "serverUrl", "timeout"]
        for key in modeled { entry.removeValue(forKey: key) }
        for (key, value) in encode(definition, style: style) {
            if key == "enabled", entry["enabled"] != nil { continue }  // Keep original enabled state
            entry[key] = value
        }
        servers[definition.name] = entry
        root[container] = servers
        return try serialize(root)
    }

    /// Parses a JSON snippet pasted by the user (README's usual `{"mcpServers": {…}}`; also accepts
    /// opencode's `{"mcp": {…}}` or a trimmed snippet whose top level is the server map itself).
    /// Returns an empty array on parse failure / no content, never throws - used for live form
    /// feedback.
    public static func parsePasted(_ text: String) -> [MCPServerDefinition] {
        guard let root = try? parse(text), !root.isEmpty else { return [] }
        let container = (root["mcpServers"] as? [String: Any])
            ?? (root["mcp"] as? [String: Any])
            ?? root
        return container.sorted { $0.key < $1.key }.compactMap { name, value in
            guard let dict = value as? [String: Any] else { return nil }
            let definition = decodeEntry(name: name, dict: dict)
            // An empty shell (neither command nor URL) is not a server - trimmed top-level snippets
            // often mix in other keys
            guard definition.command != nil || definition.url != nil else { return nil }
            return definition
        }
    }

    /// "Quick install" parsing: one input box takes a command / URL / JSON (modelled on ZCode's
    /// quick-install tab).
    /// - Starts with `{…}` → parsed as a JSON snippet (may contain several servers);
    /// - `http(s)://…` → remote server, name derived from the domain (`mcp.notion.com` → notion);
    /// - Anything else → local command line, name derived from the package name
    ///   (`npx -y chrome-devtools-mcp@latest` → chrome-devtools-mcp;
    ///   `@upstash/context7-mcp` → context7-mcp).
    /// Returns an empty array on parse failure / empty input, never throws - used for the live form
    /// preview.
    public static func parseQuickInput(_ text: String) -> [MCPServerDefinition] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("{") { return parsePasted(trimmed) }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return [] }

        if first.hasPrefix("http://") || first.hasPrefix("https://") {
            guard let url = URL(string: first) else { return [] }
            return [MCPServerDefinition(
                name: deriveName(fromURL: url),
                transport: .remote,
                url: first)]
        }
        // Command line: the first token is the executable, the rest are args; multi-line input is
        // split on whitespace like newlines
        return [MCPServerDefinition(
            name: deriveName(fromCommand: first, args: Array(tokens.dropFirst())),
            transport: .stdio,
            command: first,
            args: Array(tokens.dropFirst()))]
    }

    /// Domain → server name: strip the `mcp.` prefix, then take the first label (`mcp.notion.com` →
    /// notion, `example.com` → example); falls back to "remote-mcp" when nothing can be derived
    static func deriveName(fromURL url: URL) -> String {
        guard var host = url.host, !host.isEmpty else { return "remote-mcp" }
        if host.hasPrefix("mcp.") { host = String(host.dropFirst(4)) }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        let slug = sanitizeName(label)
        return slug.isEmpty ? "remote-mcp" : slug
    }

    /// Command line → server name: prefer a non-flag arg containing "mcp" (usually the package
    /// name), else the first non-flag arg, else the command itself; then strip the npm version
    /// suffix and scope/path prefix.
    static func deriveName(fromCommand command: String, args: [String]) -> String {
        let candidates = args.filter { !$0.hasPrefix("-") }
        let picked = candidates.first { $0.lowercased().contains("mcp") }
            ?? candidates.first
            ?? command
        let slug = sanitizeName(stripPackageDecorations(picked))
        return slug.isEmpty ? "mcp-server" : slug
    }

    /// `@scope/name@1.2` → name; `some/path/binary` → binary; `pkg@latest` → pkg
    private static func stripPackageDecorations(_ token: String) -> String {
        var name = token
        if name.hasPrefix("@"), let slash = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slash)...])  // Drop the npm scope
        }
        if let at = name.lastIndex(of: "@"), at != name.startIndex {
            name = String(name[..<at])  // Drop the version suffix
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])  // Take the last path component
        }
        return name
    }

    /// Sanitises a name into a slug every vendor accepts: anything other than letters/digits/-/_
    /// folds into -
    private static func sanitizeName(_ text: String) -> String {
        var slug = String(text.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
        })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Entry decoder covering all three dialects (shared by readDefinitionJSON / parsePasted)
    private static func decodeEntry(name: String, dict entry: [String: Any]) -> MCPServerDefinition {
        var command: String?
        var args: [String] = []
        if let text = entry["command"] as? String {
            command = text
            args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        } else if let array = entry["command"] as? [Any] {
            let parts = array.compactMap { $0 as? String }
            command = parts.first
            args = Array(parts.dropFirst())
        }
        var env: [String: String] = [:]
        for key in ["env", "environment"] {
            for (envKey, value) in (entry[key] as? [String: Any]) ?? [:] {
                env[envKey] = stringValue(value)
            }
        }
        var headers: [String: String] = [:]
        for (key, value) in (entry["headers"] as? [String: Any]) ?? [:] {
            headers[key] = stringValue(value)
        }
        let url = (entry["url"] as? String)
            ?? (entry["httpUrl"] as? String)
            ?? (entry["serverUrl"] as? String)
        return MCPServerDefinition(
            name: name,
            transport: url == nil ? .stdio : .remote,
            command: command, args: args, env: env,
            url: url, headers: headers,
            timeout: entry["timeout"] as? Int)
    }

    /// Enable/disable (JSON dialect; in practice only opencode has enabled semantics): only the
    /// enabled key changes, every other field is kept as-is.
    public static func setEnabledJSON(
        in json: String, name: String, container: String, enabled: Bool
    ) throws -> String {
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard var entry = servers[name] as? [String: Any] else {
            throw MCPEditError.notFound(name)
        }
        entry["enabled"] = enabled
        servers[name] = entry
        root[container] = servers
        return try serialize(root)
    }

    /// Enable/disable (TOML dialect; codex / grok verified to have an enabled key): rewrites the
    /// `enabled = …` line in place within the main section (appended at the section end if absent);
    /// other lines are kept as-is.
    public static func setEnabledTOML(
        in toml: String, name: String, enabled: Bool
    ) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let main = sectionRange(in: lines, name: name, subsection: nil) else {
            throw MCPEditError.notFound(name)
        }
        let rendered = "enabled = \(enabled)"
        var replaced = false
        for index in (main.lowerBound + 1)..<main.upperBound {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = unquote(String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces))
            if key == "enabled" {
                lines[index] = rendered
                replaced = true
                break
            }
        }
        if !replaced {
            // Append at the section end (skipping trailing blank lines, same insertion point as
            // updateTOML)
            var insertAt = main.upperBound
            while insertAt > main.lowerBound + 1,
                  lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(rendered, at: insertAt)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - TOML (codex / grok `[mcp_servers.<name>]`)

    /// Appends a `[mcp_servers.<name>]` section (+ optional `.env` subsection / remote auth key).
    /// The remote form is verified (local codex config.toml): a `url` key enables a remote server;
    /// the `Authorization` header → `bearer_token` (official field, sent with the Bearer scheme at
    /// runtime). Other headers need `http_headers`, whose form is unverified → writes refused to
    /// avoid producing a broken config (grok has no remote evidence; MCPService.installBlockReason
    /// keeps refusing it at the matrix layer).
    public static func upsertTOML(
        into toml: String, definition: MCPServerDefinition
    ) throws -> String {
        try validate(definition)
        try guardRemoteHeadersForTOML(definition)
        if definition.transport == .stdio, definition.command == nil {
            throw MCPEditError.invalidDefinition(L10n.text("The stdio server is missing a command", zhHans: "stdio server 缺少 command"))
        }
        let existing = sectionRanges(in: toml.components(separatedBy: "\n"))
        if existing.keys.contains(definition.name) {
            throw MCPEditError.alreadyExists(definition.name)
        }
        // Values must not contain newlines/control characters: line-level TOML can't write
        // multi-line strings, so refuse rather than corrupt the file
        for value in [definition.command ?? "", definition.url ?? ""] + definition.args
            + definition.env.keys + definition.env.values + definition.headers.values {
            if value.contains("\n") || value.contains("\r") {
                throw MCPEditError.invalidDefinition(L10n.text("The value contains a newline and cannot be safely written to TOML", zhHans: "值包含换行，无法安全写入 TOML"))
            }
        }

        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")
        // Normalised EOF append (as in CodexProfileEditor): strip trailing blank lines → one blank
        // separator line → section
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if !lines.isEmpty { lines.append("") }
        lines.append(headerLine(name: definition.name))
        if definition.transport == .remote {
            lines.append("url = \"\(escape(definition.url ?? ""))\"")
            if let token = authorizationBearerToken(of: definition) {
                lines.append("bearer_token = \"\(escape(token))\"")
            }
        } else {
            lines.append("command = \"\(escape(definition.command ?? ""))\"")
            if !definition.args.isEmpty {
                let items = definition.args.map { "\"\(escape($0))\"" }.joined(separator: ", ")
                lines.append("args = [\(items)]")
            }
            if !definition.env.isEmpty {
                lines.append("")
                lines.append(headerLine(name: definition.name, subsection: "env"))
                for key in definition.env.keys.sorted() {
                    lines.append("\(key) = \"\(escape(definition.env[key] ?? ""))\"")
                }
            }
        }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// Auth boundary for installing a remote definition into a TOML target: only `Authorization` is
    /// accepted (→ bearer_token); other headers need `http_headers`, whose form is unverified →
    /// refused (shared by create and edit).
    private static func guardRemoteHeadersForTOML(
        _ definition: MCPServerDefinition
    ) throws {
        guard definition.transport == .remote else { return }
        if let extra = definition.headers.keys
            .first(where: { $0.lowercased() != "authorization" }) {
            throw MCPEditError.unsupportedTarget(
                L10n.format("Custom headers (%@) have not been verified for this target; only Authorization (bearer_token) is supported for now", zhHans: "该目标对自定义请求头（%@）的写法未验证，暂只支持 Authorization（bearer_token）", String(extra)))
        }
    }

    /// `Authorization` header value → bearer_token value: the JSON side often carries a "Bearer "
    /// prefix, while codex's bearer_token adds the Bearer scheme itself at runtime, so strip the
    /// prefix to avoid doubling it
    private static func authorizationBearerToken(
        of definition: MCPServerDefinition
    ) -> String? {
        guard let value = definition.headers
            .first(where: { $0.key.lowercased() == "authorization" })?.value else { return nil }
        if value.lowercased().hasPrefix("bearer ") { return String(value.dropFirst(7)) }
        return value
    }

    /// Edits an existing TOML server (**rewritten in place**, the section doesn't move): rewrites
    /// command/args/url/bearer_token inside the main section (unrecognised keys like `enabled` and
    /// comments are kept as-is - same in-section approach as CodexProfileEditor.upsert); env has
    /// three forms: an existing `.env` subsection → rewrite the whole subsection body (delete the
    /// subsection when cleared); only an inline `env = {…}` → rewrite that line; neither and env
    /// non-empty → append an inline line at the end of the main section. Other subsections such as
    /// `.tools.*` are left untouched. Unlike upsert: an entry that is already remote may change its
    /// url (the stdio-only restriction applies to creation only).
    public static func updateTOML(
        in toml: String, definition: MCPServerDefinition
    ) throws -> String {
        try validate(definition)
        try guardRemoteHeadersForTOML(definition)
        for value in [definition.command ?? "", definition.url ?? ""] + definition.args
            + definition.env.keys + definition.env.values {
            if value.contains("\n") || value.contains("\r") {
                throw MCPEditError.invalidDefinition(L10n.text("The value contains a newline and cannot be safely written to TOML", zhHans: "值包含换行，无法安全写入 TOML"))
            }
        }
        var lines = toml.components(separatedBy: "\n")
        guard sectionRange(in: lines, name: definition.name, subsection: nil) != nil else {
            throw MCPEditError.notFound(definition.name)
        }

        // Pass A: the .env subsection (done first - it sits after the main section, so editing the
        // main body doesn't affect locating it, but the reverse would)
        var hasEnvSubsection = false
        if let envRange = sectionRange(in: lines, name: definition.name, subsection: "env") {
            if definition.env.isEmpty {
                var start = envRange.lowerBound
                if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    start -= 1
                }
                lines.removeSubrange(start..<envRange.upperBound)
            } else {
                hasEnvSubsection = true
                let body = definition.env.keys.sorted().map {
                    "\($0) = \"\(escape(definition.env[$0] ?? ""))\""
                }
                lines.replaceSubrange((envRange.lowerBound + 1)..<envRange.upperBound, with: body)
            }
        }

        // Pass B: rewrite the main section body (Pass A may have shifted line numbers, so locate
        // again)
        guard let main = sectionRange(in: lines, name: definition.name, subsection: nil) else {
            throw MCPEditError.notFound(definition.name)
        }
        func managedLine(_ key: String) -> String? {
            switch key {
            case "command":
                return definition.command.map { "command = \"\(escape($0))\"" }
            case "args":
                guard !definition.args.isEmpty else { return nil }
                let items = definition.args.map { "\"\(escape($0))\"" }.joined(separator: ", ")
                return "args = [\(items)]"
            case "url":
                guard definition.transport == .remote else { return nil }
                return definition.url.map { "url = \"\(escape($0))\"" }
            case "bearer_token":
                guard definition.transport == .remote else { return nil }
                return authorizationBearerToken(of: definition)
                    .map { "bearer_token = \"\(escape($0))\"" }
            case "env":
                // Don't write inline when the subsection is authoritative; don't write when env is
                // cleared either
                guard !hasEnvSubsection, !definition.env.isEmpty else { return nil }
                let pairs = definition.env.keys.sorted().map {
                    "\($0) = \"\(escape(definition.env[$0] ?? ""))\""
                }.joined(separator: ", ")
                return "env = { \(pairs) }"
            default:
                return nil
            }
        }
        let managedKeys = ["command", "args", "url", "bearer_token", "env"]
        var newBody: [String] = []
        var written = Set<String>()
        for line in lines[(main.lowerBound + 1)..<main.upperBound] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") {
                let key = unquote(String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces))
                if managedKeys.contains(key) {
                    // Changed: write the new value; cleared / taken over by the subsection: delete
                    // the line
                    if !written.contains(key), let rendered = managedLine(key) {
                        newBody.append(rendered)
                    }
                    written.insert(key)
                    continue
                }
            }
            newBody.append(line)  // Unmodeled keys (enabled etc.) / comments / blanks kept
        }
        // Modeled keys the section didn't have before are appended at the section end (before
        // trailing blank lines)
        var insertAt = newBody.count
        while insertAt > 0,
              newBody[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        for key in managedKeys where !written.contains(key) {
            if let rendered = managedLine(key) {
                newBody.insert(rendered, at: insertAt)
                insertAt += 1
            }
        }
        lines.replaceSubrange((main.lowerBound + 1)..<main.upperBound, with: newBody)
        return lines.joined(separator: "\n")
    }

    /// Deletes `[mcp_servers.<name>]` and **all its subsections** (`.env` / `.tools.*`; codex
    /// verified to have the latter), each also swallowing its leading blank line (same blank-line
    /// rule as CodexProfileEditor.remove).
    public static func removeTOML(from toml: String, name: String) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        var removedAny = false
        while let range = firstSectionRange(in: lines, matching: name) {
            var start = range.lowerBound
            if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                start -= 1
            }
            lines.removeSubrange(start..<range.upperBound)
            removedAny = true
        }
        guard removedAny else { throw MCPEditError.notFound(name) }
        return lines.joined(separator: "\n")
    }

    /// Reads the full definition (including env values): command / args / url + inline `env = {…}`
    /// and the `.env` subsection.
    public static func readDefinitionTOML(
        _ toml: String, name: String
    ) throws -> MCPServerDefinition {
        var command: String?
        var args: [String] = []
        var url: String?
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        var found = false
        var inMain = false
        var inEnvSub = false
        /// Multi-line array collection state (same technique as MCPConfigIndexer): while `args = [`
        /// is unclosed, consume lines up to `]`
        var pendingArgs: String?

        for rawLine in toml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let buffer = pendingArgs {
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("[") {
                    pendingArgs = nil  // Malformed, unclosed: give up, fall to header handling
                } else {
                    let merged = buffer.isEmpty ? line : buffer + " " + line
                    if arrayLiteralClosed(merged) {
                        args = inlineArrayStrings(merged)
                        pendingArgs = nil
                    } else {
                        pendingArgs = merged
                    }
                    continue
                }
            }
            if line.hasPrefix("[") {
                inMain = false
                inEnvSub = false
                guard let path = headerPath(line) else { continue }
                guard path.count >= 2, path[0] == "mcp_servers", path[1] == name else { continue }
                found = true
                if path.count == 2 {
                    inMain = true
                } else if path.count == 3, path[2] == "env" {
                    inEnvSub = true
                }
                continue
            }
            guard inMain || inEnvSub, !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if inEnvSub {
                env[key] = unquote(value)
                continue
            }
            switch key {
            case "command": command = unquote(value)
            case "url": url = unquote(value)
            case "args":
                if arrayLiteralClosed(value) {
                    args = inlineArrayStrings(value)
                } else {
                    pendingArgs = value
                }
            case "bearer_token":
                // Sent with the Bearer scheme at runtime → reconstruct the Authorization header
                // value on read, so the probe and the edit form can use it directly with HTTP
                // semantics (stable round-trip)
                headers["Authorization"] = "Bearer \(unquote(value))"
            case "env":
                for (envKey, envValue) in inlineTablePairs(value) { env[envKey] = envValue }
            default: break
            }
        }
        guard found else { throw MCPEditError.notFound(name) }
        return MCPServerDefinition(
            name: name,
            transport: url == nil ? .stdio : .remote,
            command: command, args: args, env: env, url: url, headers: headers)
    }

    // MARK: - JSON private (parse/serialize contract follows ClaudeHooksInstaller)

    /// Public so tests and the form preview can reuse it (contract matches
    /// ClaudeHooksInstaller.parse)
    public static func parse(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let dict = object as? [String: Any]
        else { throw InstallError.invalidJSON }
        return dict
    }

    public static func serialize(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func serversDict(
        in root: [String: Any], container: String
    ) throws -> [String: Any] {
        guard let value = root[container] else { return [:] }
        guard let servers = value as? [String: Any] else {
            throw InstallError.foreignConfig(
                L10n.format("The %@ field in the configuration is not an object and cannot be recognized. No changes were made to avoid overwriting unrecognized content.", zhHans: "配置里的 %@ 字段不是对象，无法识别。为避免覆盖看不懂的内容，不做任何改动。", String(container)))
        }
        return servers
    }

    private static func validate(_ definition: MCPServerDefinition) throws {
        let name = definition.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw MCPEditError.invalidDefinition(L10n.text("The name cannot be empty", zhHans: "名称不能为空")) }
        switch definition.transport {
        case .stdio:
            guard let command = definition.command,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPEditError.invalidDefinition(L10n.text("The stdio server is missing a command", zhHans: "stdio server 缺少 command"))
            }
        case .remote:
            guard let url = definition.url,
                  !url.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPEditError.invalidDefinition(L10n.text("The remote server is missing a URL", zhHans: "远程 server 缺少 URL"))
            }
        }
    }

    /// Per-dialect field projection (empty collections are not written, keeping the config clean)
    public static func encode(_ definition: MCPServerDefinition, style: MCPJSONStyle) -> [String: Any] {
        var entry: [String: Any] = [:]
        switch (style, definition.transport) {
        case (.typed, .stdio):
            entry["type"] = "stdio"
            entry["command"] = definition.command ?? ""
            if !definition.args.isEmpty { entry["args"] = definition.args }
            if !definition.env.isEmpty { entry["env"] = definition.env }
        case (.typed, .remote):
            entry["type"] = "http"
            entry["url"] = definition.url ?? ""
            if !definition.headers.isEmpty { entry["headers"] = definition.headers }
        case (.plain, .stdio):
            entry["command"] = definition.command ?? ""
            if !definition.args.isEmpty { entry["args"] = definition.args }
            if !definition.env.isEmpty { entry["env"] = definition.env }
        case (.plain, .remote):
            entry["url"] = definition.url ?? ""
            if !definition.headers.isEmpty { entry["headers"] = definition.headers }
            if let timeout = definition.timeout { entry["timeout"] = timeout }
        case (.opencode, .stdio):
            entry["type"] = "local"
            entry["command"] = [definition.command ?? ""] + definition.args
            if !definition.env.isEmpty { entry["environment"] = definition.env }
            entry["enabled"] = true
        case (.opencode, .remote):
            entry["type"] = "remote"
            entry["url"] = definition.url ?? ""
            if !definition.headers.isEmpty { entry["headers"] = definition.headers }
            entry["enabled"] = true
        }
        return entry
    }

    private static func stringValue(_ value: Any) -> String {
        if let text = value as? String { return text }
        return "\(value)"
    }

    // MARK: - TOML private (section surgery rules follow CodexProfileEditor)

    /// Section header → path components
    /// (`[mcp_servers."my name".env]` → ["mcp_servers","my name","env"]).
    /// Same limitation as the indexer: a `.` inside a quoted section name gets split wrongly
    /// (no such form observed; best-effort).
    private static func headerPath(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        return inner.split(separator: ".").map {
            unquote(String($0).trimmingCharacters(in: .whitespaces))
        }
    }

    /// Name → line number for every `[mcp_servers.<name>]` main section (subsections excluded)
    private static func sectionRanges(in lines: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard let path = headerPath(line), path.count == 2,
                  path[0] == "mcp_servers" else { continue }
            if result[path[1]] == nil { result[path[1]] = index }
        }
        return result
    }

    /// Locates the [header, next header) line range of the main section (subsection = nil) or a
    /// given subsection (e.g. "env")
    private static func sectionRange(
        in lines: [String], name: String, subsection: String?
    ) -> Range<Int>? {
        for (index, line) in lines.enumerated() {
            guard let path = headerPath(line), path.count >= 2,
                  path[0] == "mcp_servers", path[1] == name else { continue }
            let matches = subsection == nil
                ? path.count == 2
                : (path.count == 3 && path[2] == subsection)
            guard matches else { continue }
            var end = index + 1
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end += 1
            }
            return index..<end
        }
        return nil
    }

    /// The [header, next header) line range of the first section belonging to this server (main or
    /// any subsection)
    private static func firstSectionRange(
        in lines: [String], matching name: String
    ) -> Range<Int>? {
        for (index, line) in lines.enumerated() {
            guard let path = headerPath(line), path.count >= 2,
                  path[0] == "mcp_servers", path[1] == name else { continue }
            var end = index + 1
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end += 1
            }
            return index..<end
        }
        return nil
    }

    private static func headerLine(name: String, subsection: String? = nil) -> String {
        let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let segment = bare && !name.isEmpty ? name : "\"\(escape(name))\""
        let suffix = subsection.map { ".\($0)" } ?? ""
        return "[mcp_servers.\(segment)\(suffix)]"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unquote(_ text: String) -> String {
        var value = text
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote)
            && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Single-line array `["-y", "pkg"]` → elements (multi-line forms are joined by the caller
    /// first)
    private static func inlineArrayStrings(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("[") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("]") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").map {
            unquote(String($0).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
    }

    /// Whether the array literal is closed: only a `]` outside quotes counts (inside quotes it's
    /// element content); a `\"` escape inside quotes doesn't flip the quote state. Same technique
    /// as MCPConfigIndexer (the modules don't depend on each other)
    private static func arrayLiteralClosed(_ value: String) -> Bool {
        var inString = false
        var escaped = false
        for character in value {
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "]" where !inString: return true
            default: break
            }
        }
        return false
    }

    /// Single-line inline table `{ A = "x", B = "y" }` → key/value pairs (values **are** needed
    /// here: propagation needs the full definition)
    private static func inlineTablePairs(_ value: String) -> [(String, String)] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("{") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("}") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").compactMap { piece in
            let pair = String(piece)
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            let key = unquote(String(pair[..<eq]).trimmingCharacters(in: .whitespaces))
            let val = unquote(String(pair[pair.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces))
            return key.isEmpty ? nil : (key, val)
        }
    }
}
