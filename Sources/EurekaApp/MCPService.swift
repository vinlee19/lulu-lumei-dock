import AppKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaSync
import EurekaUsage
import Foundation

/// Index and management service for MCP servers (the "MCP" tab).
///
/// Read: config index over the 9 verified sources (key-names-only; see MCPConfigIndexer — env/headers values are dropped at parse time).
/// Write: create / cross-source install / delete, via `MCPServerEditor` (dialect projection) + `ConfigFile.backupThenWrite`
/// (guards run first, so a throw means the original file is untouched; a `.bak.eureka.<ts>` backup is left before writing).
/// Secret posture: the full definition (env values included) only exists in the in-memory hop "read source config → write target config";
/// it is never persisted, logged, uploaded, or shown in the UI. MCP config files also stay off the cloud-backup whitelist.
final class MCPService: ObservableObject {
    @Published private(set) var servers: [MCPServerEntry] = []
    @Published private(set) var scanning = false
    /// When the last scan finished. nil = never scanned (the criterion `refresh` uses)
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    /// Connection-check results (key = entry.id); only filled when the user clicks "Check
    /// connection", never probed automatically
    @Published private(set) var probeResults: [String: ProbeState] = [:]
    /// Tool-probe cache (key = lowercased server name): tool list and schema tokens measured via
    /// tools/list
    @Published private(set) var toolCache: [String: MCPToolCacheEntry] = [:]
    /// Browser authorization progress/results (key = entry.id; messages linger briefly)
    @Published private(set) var oauthNotes: [String: String] = [:]
    /// Server names whose tokens Eureka holds (lowercased; the presence flag lives in UserDefaults,
    /// the secret itself in Keychain)
    @Published private(set) var oauthTokenNames: Set<String> = []
    /// Persisted last-probe snapshot (key = entry.id): visible as soon as the page opens, survives
    /// restarts (v2.6 direct display)
    @Published private(set) var probeSnapshots: [String: MCPProbeSnapshot] = [:]
    /// Project-root candidates (for the repo picker): shares the same ProjectScopeDiscovery result
    /// as the index during a scan
    @Published private(set) var repoRoots: [(root: URL, name: String)] = []
    /// Pre-registered client_id (key = lowercased server name; client_id is not a secret, stored in
    /// UserDefaults) — the spec-sanctioned way out when the AS doesn't support dynamic registration
    /// (registration priority #1: pre-registered credentials)
    @Published private(set) var preRegisteredClientIDs: [String: String] = [:]
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    enum ProbeState: Equatable {
        case checking
        case done(MCPProbe.Status)
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.mcp", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var allServers: [MCPServerEntry] = []

    // MARK: - Scanning

    /// force = false: scan only if never scanned (shared by launch warm-up and the onAppear
    /// fallback; idempotent). force = true: unconditional full rescan, used only by the refresh
    /// button.
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
        if force { ProjectScopeDiscovery.invalidateCache() }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let roots = ProjectScopeDiscovery.repoRoots(resolver: self.resolver)
            let servers = MCPConfigIndexer.index(projectRoots: roots)
            let cache = MCPToolCache.load()
            let snapshots = MCPProbeCache.load()
            let tokenNames = Set(
                UserDefaults.standard.stringArray(forKey: Self.oauthNamesKey) ?? [])
            let clientIDs = (UserDefaults.standard.dictionary(forKey: Self.clientIDsKey)
                as? [String: String]) ?? [:]
            DispatchQueue.main.async {
                self.allServers = servers
                self.repoRoots = roots
                self.toolCache = cache
                self.probeSnapshots = snapshots
                self.oauthTokenNames = tokenNames
                self.preRegisteredClientIDs = clientIDs
                self.scanning = false
                self.lastScanAt = Date()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            servers = allServers
            return
        }
        servers = allServers.filter {
            [$0.name, $0.commandSummary ?? "", $0.urlSummary ?? "",
             $0.source.displayName, $0.projectName ?? "", $0.configPath]
                .joined(separator: " ").lowercased().contains(query)
        }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Every config location of the same-named server (for the detail page; unaffected by the
    /// search filter)
    func entries(named name: String) -> [MCPServerEntry] {
        let key = name.lowercased()
        return allServers.filter { $0.name.lowercased() == key }
    }

    /// Snapshot of all entries (for consistency/drift checks; unaffected by the search filter)
    func allEntries() -> [MCPServerEntry] { allServers }

    /// Whether this source has real enable/disable semantics (verified: codex/grok TOML and
    /// opencode JSON have an `enabled` key)
    static func supportsEnableToggle(_ source: AgentSource) -> Bool {
        source == .codex || source == .grok || source == .opencode
    }

    // MARK: - Write-target table (same path table as MCPConfigIndexer.globalConfigURL)

    /// Dialect of each write target (container key + field style); EurekaInstall doesn't know
    /// AgentSource, so the mapping lives in this layer
    enum TargetDialect {
        case json(container: String, style: MCPJSONStyle)
        case toml
    }

    struct WritableTarget {
        var source: AgentSource
        var configURL: URL
        var dialect: TargetDialect
        /// Dedicated small files (cursor / kimi mcp.json) may be created when missing;
        /// a missing host config (~/.claude.json, settings.json, config.toml, opencode.json)
        /// means that CLI has never run — never fabricate someone else's main config.
        var canCreateFile: Bool
    }

    /// The 8 writable targets (every shape verified on this machine; see the design matrix)
    static func writableTarget(for source: AgentSource) -> WritableTarget? {
        guard let url = MCPConfigIndexer.globalConfigURL(for: source) else { return nil }
        switch source {
        case .claude:
            return WritableTarget(source: source, configURL: url,
                dialect: .json(container: "mcpServers", style: .typed), canCreateFile: false)
        case .qwen:
            return WritableTarget(source: source, configURL: url,
                dialect: .json(container: "mcpServers", style: .typed), canCreateFile: false)
        case .gemini:
            return WritableTarget(source: source, configURL: url,
                dialect: .json(container: "mcpServers", style: .plain), canCreateFile: false)
        case .cursor:
            return WritableTarget(source: source, configURL: url,
                dialect: .json(container: "mcpServers", style: .plain), canCreateFile: true)
        case .kimi:
            return WritableTarget(source: source, configURL: url,
                dialect: .json(container: "mcpServers", style: .plain), canCreateFile: true)
        case .opencode:
            return WritableTarget(source: source, configURL: url,
                dialect: .json(container: "mcp", style: .opencode), canCreateFile: false)
        case .codex, .grok:
            return WritableTarget(source: source, configURL: url,
                dialect: .toml, canCreateFile: false)
        default:
            return nil
        }
    }

    /// Why a target is not writable (greyed-out matrix copy); nil = writable
    static func writeBlockReason(for source: AgentSource) -> String? {
        switch source {
        case .claude, .codex, .gemini, .cursor, .kimi, .qwen, .grok, .opencode:
            return nil
        case .zcode: return L10n.text("MCP is registered by plugins; no user-level configuration", zhHans: "MCP 由插件注册，无用户级配置")
        case .trae: return L10n.text("Configuration shares a directory with credentials; reading and writing are disabled", zhHans: "配置与凭证同目录，不读不写")
        default: return L10n.text("No known MCP configuration convention", zhHans: "无已知 MCP 配置约定")
        }
    }

    // MARK: - Project-level write targets (dedicated small files, created when missing)

    /// Sources with a project-level config convention: claude `<repo>/.mcp.json` (MCP's official
    /// project-sharing standard) and cursor `<repo>/.cursor/mcp.json` (same shape as the user-level
    /// file)
    static let projectLevelSources: [AgentSource] = [.claude, .cursor]

    /// Project-level write target; nil = this source has no project-level convention
    static func projectTarget(
        for source: AgentSource, projectRoot: URL
    ) -> WritableTarget? {
        switch source {
        case .claude:
            return WritableTarget(
                source: source,
                configURL: projectRoot.appendingPathComponent(".mcp.json"),
                dialect: .json(container: "mcpServers", style: .plain),
                canCreateFile: true)
        case .cursor:
            return WritableTarget(
                source: source,
                configURL: projectRoot.appendingPathComponent(".cursor/mcp.json"),
                dialect: .json(container: "mcpServers", style: .plain),
                canCreateFile: true)
        default:
            return nil
        }
    }

    /// Whether this definition can be installed to the target. codex's remote shape is verified
    /// (url + optional bearer_token, checked against a local config.toml); grok has no remote
    /// evidence → still refused. Finer boundaries (refusing to write non-Authorization request
    /// headers as http_headers) are enforced by MCPServerEditor at write time. nil = allowed
    static func installBlockReason(transport: String, to source: AgentSource) -> String? {
        if let reason = writeBlockReason(for: source) { return reason }
        if transport != "stdio", source == .grok {
            return L10n.text("The remote server format has not been verified for this target", zhHans: "远程 server 在该目标的格式未验证")
        }
        return nil
    }

    static var writableSources: [AgentSource] {
        AgentSource.allCases.filter { writeBlockReason(for: $0) == nil }
    }

    // MARK: - Write operations (run on queue; guards first, so a throw means the original file is untouched)

    /// Batch add: write every definition to every target's **global config**; **rescan only once**
    /// after everything finishes. The callback reports a failure reason per target (nil = success);
    /// with multiple definitions the first failure wins.
    func addAll(
        definitions: [MCPServerDefinition], to targets: [AgentSource],
        completion: (([AgentSource: String?]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            var results: [AgentSource: String?] = [:]
            for source in targets {
                var failure: String?
                for definition in definitions {
                    if let error = Self.write(definition, to: source) {
                        failure = failure ?? error
                    }
                }
                results.updateValue(failure, forKey: source)
            }
            DispatchQueue.main.async {
                completion?(results)
                self?.refresh(force: true)
            }
        }
    }

    /// Edit an existing server (merge-style rewrite: unmodelled keys kept, TOML edited in place;
    /// backup before writing)
    func update(
        _ entry: MCPServerEntry, definition: MCPServerDefinition,
        completion: ((String?) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            var failure: String?
            do {
                let url = URL(fileURLWithPath: entry.configPath)
                let original = ConfigFile.read(url)
                let updated: String
                switch Self.readDialect(for: entry) {
                case .toml:
                    updated = try MCPServerEditor.updateTOML(
                        in: original, definition: definition)
                case .json(let container, let style):
                    updated = try MCPServerEditor.updateJSON(
                        in: original, definition: definition,
                        container: container, style: style)
                }
                try ConfigFile.backupThenWrite(path: url, newContent: updated)
            } catch let error as LocalizedError {
                failure = error.errorDescription ?? "\(error)"
            } catch {
                failure = "\(error)"
            }
            DispatchQueue.main.async {
                completion?(failure)
                self?.refresh(force: true)
            }
        }
    }

    /// Read the full definition at one config location (current env/headers values included) to
    /// prefill the edit form. Values only go into form fields (an explicit edit action): never
    /// persisted, logged, or uploaded.
    func definition(of entry: MCPServerEntry, completion: @escaping (MCPServerDefinition?) -> Void) {
        queue.async {
            let result = try? Self.readDefinition(of: entry)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Install to project-level config (dedicated small files, created when missing): reports
    /// failures per source, rescans once at the end
    func installToProject(
        definitions: [MCPServerDefinition],
        sources: [AgentSource], projectRoot: URL,
        completion: (([AgentSource: String?]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let results = Self.writeToProjectTargets(
                definitions: definitions, sources: sources, projectRoot: projectRoot)
            DispatchQueue.main.async {
                completion?(results)
                self?.refresh(force: true)
            }
        }
    }

    /// Cross-source install to project level (detail-page matrix): read the full definition (env
    /// values included, in-memory hop only), then write
    func propagateToProject(
        _ entry: MCPServerEntry, sources: [AgentSource], projectRoot: URL,
        completion: (([AgentSource: String?]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            var results: [AgentSource: String?]
            if let definition = try? Self.readDefinition(of: entry) {
                results = Self.writeToProjectTargets(
                    definitions: [definition], sources: sources, projectRoot: projectRoot)
            } else {
                results = [:]
                for source in sources { results[source] = L10n.text("Failed to read source definition", zhHans: "读取来源定义失败") }
            }
            DispatchQueue.main.async {
                completion?(results)
                self?.refresh(force: true)
            }
        }
    }

    private static func writeToProjectTargets(
        definitions: [MCPServerDefinition], sources: [AgentSource], projectRoot: URL
    ) -> [AgentSource: String?] {
        var results: [AgentSource: String?] = [:]
        for source in sources {
            guard let target = projectTarget(for: source, projectRoot: projectRoot) else {
                results[source] = L10n.text("This source has no project-level configuration convention", zhHans: "该源没有项目级配置约定")
                continue
            }
            var failure: String?
            for definition in definitions {
                if let error = write(definition, to: target) {
                    failure = failure ?? error
                }
            }
            results[source] = failure
        }
        return results
    }

    /// Cross-source install: read the **full definition** from the entry's config (env values
    /// included, in-memory hop only) and project it into the target
    func propagate(
        _ entry: MCPServerEntry, to targets: [AgentSource],
        completion: (([AgentSource: String?]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let definition: MCPServerDefinition
            do {
                definition = try Self.readDefinition(of: entry)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                DispatchQueue.main.async {
                    var results: [AgentSource: String?] = [:]
                    for target in targets {
                        results.updateValue(L10n.format("Failed to read source definition: %@", zhHans: "读取来源定义失败：%@", String(message)), forKey: target)
                    }
                    completion?(results)
                }
                return
            }
            var results: [AgentSource: String?] = [:]
            for source in targets {
                results.updateValue(Self.write(definition, to: source), forKey: source)
            }
            DispatchQueue.main.async {
                completion?(results)
                self?.refresh(force: true)
            }
        }
    }

    /// Delete this server from one config location (backup before writing; for TOML, all sub-tables
    /// are removed too)
    func remove(_ entry: MCPServerEntry, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var ok = false
            do {
                try Self.removeOne(entry)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Remove the server with this name from **every** config location (closes the idle-cleanup
    /// loop): runs the existing delete logic per location, reporting each one (key = "source ·
    /// path", nil = success); sources whose definition can't be read are skipped automatically.
    func removeEverywhere(
        named name: String, completion: (([String: String?]) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let key = name.lowercased()
            let targets = self?.allServers.filter { $0.name.lowercased() == key } ?? []
            var results: [String: String?] = [:]
            for entry in targets {
                let label = "\(entry.source.displayName) · \(entry.configPath)"
                do {
                    try Self.removeOne(entry)
                    results[label] = nil
                } catch let error as LocalizedError {
                    results[label] = error.errorDescription ?? "\(error)"
                } catch {
                    results[label] = "\(error)"
                }
            }
            DispatchQueue.main.async {
                completion?(results)
                self?.refresh(force: true)
            }
        }
    }

    /// Single-location delete core (shared by remove and removeEverywhere)
    private static func removeOne(_ entry: MCPServerEntry) throws {
        let url = URL(fileURLWithPath: entry.configPath)
        let original = ConfigFile.read(url)
        let updated: String
        switch readDialect(for: entry) {
        case .toml:
            updated = try MCPServerEditor.removeTOML(from: original, name: entry.name)
        case .json(let container, _):
            updated = try MCPServerEditor.removeJSON(
                from: original, name: entry.name, container: container)
        }
        try ConfigFile.backupThenWrite(path: url, newContent: updated)
    }

    /// Enable/disable: codex/grok rewrite TOML in place, opencode merges JSON; backup before
    /// writing. Disabled = tools removed from the context while the config is kept (protocol
    /// semantics); pairs with idle detection.
    func setEnabled(_ entry: MCPServerEntry, _ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var ok = false
            do {
                let url = URL(fileURLWithPath: entry.configPath)
                let original = ConfigFile.read(url)
                let updated: String
                switch entry.source {
                case .codex, .grok:
                    updated = try MCPServerEditor.setEnabledTOML(
                        in: original, name: entry.name, enabled: enabled)
                case .opencode:
                    updated = try MCPServerEditor.setEnabledJSON(
                        in: original, name: entry.name, container: "mcp", enabled: enabled)
                default:
                    throw MCPEditError.unsupportedTarget(L10n.text("This source does not support enabling or disabling servers in its configuration", zhHans: "该源的配置没有启停语义"))
                }
                try ConfigFile.backupThenWrite(path: url, newContent: updated)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Copy as a standard mcpServers JSON snippet (**no secret values**: env/headers values become
    /// empty-string placeholders for the recipient to fill in) — the inverse of "Paste import",
    /// closing the sharing loop
    func copyDefinitionJSON(_ entry: MCPServerEntry, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var text: String?
            if var definition = try? Self.readDefinition(of: entry) {
                definition.env = definition.env.mapValues { _ in "" }
                definition.headers = definition.headers.mapValues { _ in "" }
                let object: [String: Any] = [
                    "mcpServers": [
                        definition.name: MCPServerEditor.encode(definition, style: .typed)
                    ]
                ]
                text = try? MCPServerEditor.serialize(object)
            }
            DispatchQueue.main.async {
                if let text {
                    self?.copyToPasteboard(text)
                    completion?(true)
                } else {
                    completion?(false)
                }
            }
        }
    }

    // MARK: - Browser OAuth authorization (v2.5; the token only serves Eureka's checks and is never written to a CLI credential store)

    private static let oauthKeychainService = "com.vinlee.eureka.mcp"
    private static let oauthNamesKey = "mcpOAuthTokenNames"
    private static let clientIDsKey = "mcpOAuthClientIDs"

    /// Set/clear the pre-registered client_id (empty string = clear; client_id is not a secret,
    /// stored in UserDefaults)
    func setPreRegisteredClientID(_ clientID: String, for entry: MCPServerEntry) {
        let key = entry.name.lowercased()
        var ids = (UserDefaults.standard.dictionary(forKey: Self.clientIDsKey)
            as? [String: String]) ?? [:]
        let trimmed = clientID.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            ids.removeValue(forKey: key)
        } else {
            ids[key] = trimmed
        }
        UserDefaults.standard.set(ids, forKey: Self.clientIDsKey)
        preRegisteredClientIDs = ids
    }

    func preRegisteredClientID(for entry: MCPServerEntry) -> String {
        preRegisteredClientIDs[entry.name.lowercased()] ?? ""
    }

    private static func tokenAccount(_ name: String) -> String {
        "mcp-oauth:\(name.lowercased())"
    }

    static func loadTokenSet(named name: String) -> MCPOAuth.TokenSet? {
        KeychainStore.read(account: tokenAccount(name), service: oauthKeychainService)
            .flatMap(MCPOAuth.decodeTokenSet)
    }

    private static func storeTokenSet(_ set: MCPOAuth.TokenSet, named name: String) {
        guard let encoded = MCPOAuth.encodeTokenSet(set) else { return }
        _ = KeychainStore.write(
            account: tokenAccount(name), secret: encoded, service: oauthKeychainService)
    }

    func hasToken(for entry: MCPServerEntry) -> Bool {
        oauthTokenNames.contains(entry.name.lowercased())
    }

    /// Complete OAuth in the default browser (discover → register → authorize → loopback callback →
    /// exchange token); on success the token goes into Keychain.
    func authorizeInBrowser(_ entry: MCPServerEntry) {
        let entryID = entry.id
        let preRegistered = preRegisteredClientID(for: entry)
        oauthNotes[entryID] = L10n.text("Discovering authorization server…", zhHans: "正在发现授权服务器…")
        queue.async { [weak self] in
            let definition = try? Self.readDefinition(of: entry)
            guard let serverURL = definition?.url else {
                DispatchQueue.main.async {
                    self?.oauthNotes[entryID] = L10n.text("This configuration has no remote URL; browser authorization is unavailable", zhHans: "该配置没有远程 URL，无法浏览器授权")
                }
                return
            }
            do {
                let tokenSet = try MCPOAuthFlow.run(
                    serverURL: serverURL, headers: definition?.headers ?? [:],
                    preRegisteredClientID: preRegistered.isEmpty ? nil : preRegistered
                ) { message in
                    self?.oauthNotes[entryID] = message  // progress callback is already on the main thread
                }
                Self.storeTokenSet(tokenSet, named: entry.name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.mutateTokenNames { $0.insert(entry.name.lowercased()) }
                    self.oauthNotes[entryID] = L10n.text("Authorization succeeded—run “Test Connection” again to see the tool list (the token is only used for Eureka probes; each CLI still needs its own authorization)", zhHans: "授权成功——重新「检测连接」即可看到工具清单（令牌仅供 Eureka 检测；CLI 侧仍需各自授权）")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                DispatchQueue.main.async {
                    self?.oauthNotes[entryID] = L10n.format("Authorization failed: %@", zhHans: "授权失败：%@", String(message))
                }
            }
        }
    }

    /// Revoke the token Eureka holds (Keychain delete + presence-flag update)
    func revokeToken(for entry: MCPServerEntry) {
        let entryID = entry.id
        queue.async { [weak self] in
            _ = KeychainStore.delete(
                account: Self.tokenAccount(entry.name), service: Self.oauthKeychainService)
            DispatchQueue.main.async {
                guard let self else { return }
                self.mutateTokenNames { $0.remove(entry.name.lowercased()) }
                self.oauthNotes[entryID] = L10n.text("Revoked the token stored by Eureka", zhHans: "已撤销 Eureka 持有的令牌")
            }
        }
    }

    private func mutateTokenNames(_ change: (inout Set<String>) -> Void) {
        var names = Set(UserDefaults.standard.stringArray(forKey: Self.oauthNamesKey) ?? [])
        change(&names)
        UserDefaults.standard.set(Array(names).sorted(), forKey: Self.oauthNamesKey)
        oauthTokenNames = names
    }

    // MARK: - Connection check (only started on user click, never probed automatically)

    /// Cancellation ticket: each new batch gets a new ticket, and an old batch stops once it sees
    /// it was cancelled (thread-safe; issued on main, queried on queue)
    private final class ProbeTicket {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
        }
    }
    private var probeTicket: ProbeTicket?
    /// Batch-check progress (nil = no batch check running)
    @Published private(set) var probeProgress: (done: Int, total: Int)?

    /// Check a set of config locations: remote sends an MCP initialize probe (headers go only to
    /// that server's own URL — the intended use of those credentials; the response body is never
    /// read, stored, or logged); stdio checks the command is reachable (pure syscalls, no process
    /// spawned). Results go into probeResults and the UI shows them as chips. Runs serially,
    /// publishing progress after each location; calling again or cancelProbe() cancels the
    /// unfinished old batch.
    func probe(_ entries: [MCPServerEntry]) {
        let ticket = ProbeTicket()
        probeTicket = ticket
        for entry in entries {
            probeResults[entry.id] = .checking
        }
        probeProgress = (0, entries.count)
        queue.async { [weak self] in
            var done = 0
            for entry in entries {
                guard !ticket.isCancelled else {
                    DispatchQueue.main.async { self?.probeProgress = nil }
                    return
                }
                let (status, authScheme) = Self.probeOne(entry)
                // Persist the snapshot (auth method folded in): shown directly next time the page
                // opens (even after restart), so the user isn't left guessing
                let snapshot = MCPProbeSnapshot(
                    status: status, authScheme: authScheme, checkedAt: Date())
                MCPProbeCache.upsert(key: entry.id, snapshot: snapshot)
                done += 1
                DispatchQueue.main.async {
                    guard !ticket.isCancelled else { return }
                    self?.probeResults[entry.id] = .done(status)
                    self?.probeSnapshots[entry.id] = snapshot
                    self?.probeProgress = (done, entries.count)
                }
            }
            // tools/list may have just been persisted → refresh the tool cache (tool-count chip /
            // ctx overhead update with it)
            let cache = MCPToolCache.load()
            DispatchQueue.main.async {
                guard !ticket.isCancelled else { return }
                self?.toolCache = cache
                self?.probeProgress = nil
            }
        }
    }

    /// Cancel the running batch check (single-location "Re-check" uses the same cancel path; no
    /// side effects)
    func cancelProbe() {
        probeTicket?.cancel()
        probeProgress = nil
        for (id, state) in probeResults where state == .checking {
            probeResults.removeValue(forKey: id)
        }
    }

    private struct RPCResponse {
        var statusCode: Int
        var data: Data
        var contentType: String?
        var wwwAuthenticate: String?
        var sessionID: String?
    }

    /// A single JSON-RPC POST (blocks on the queue, using the semaphore technique from
    /// EurekaSync/HTTPTransport). Headers go only to the URL this server configured; the response
    /// body only feeds the parser and is never stored or logged. protocolVersion: per the spec,
    /// requests after initialization **MUST** carry the `MCP-Protocol-Version` header (value = the
    /// version negotiated in the handshake; without it the server assumes 2025-03-26).
    private static func performRPC(
        url: URL, headers: [String: String], body: Data, sessionID: String? = nil,
        protocolVersion: String? = nil, contentType: String = "application/json"
    ) -> Result<RPCResponse, Error> {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<RPCResponse, Error> = .failure(URLError(.timedOut))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                outcome = .success(RPCResponse(
                    statusCode: http.statusCode,
                    data: data ?? Data(),
                    contentType: http.value(forHTTPHeaderField: "Content-Type"),
                    wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate"),
                    sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id")))
            } else {
                outcome = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 8)
        return outcome
    }

    /// One initialize + classification (shared by probing and the refresh retry)
    private static func performHandshake(
        url: URL, headers: [String: String]
    ) -> (MCPProbe.Status, RPCResponse?) {
        let result = performRPC(
            url: url, headers: headers, body: MCPProbe.initializeRequestBody())
        switch result {
        case .failure(let error):
            return (.unreachable((error as? URLError)?.localizedDescription
                ?? error.localizedDescription), nil)
        case .success(let response):
            return (MCPProbe.classify(
                statusCode: response.statusCode,
                body: response.data,
                contentType: response.contentType,
                wwwAuthenticate: response.wwwAuthenticate), response)
        }
    }

    /// One full probe: (1) initialize as a **real handshake** (a 2xx only counts as connected once
    /// a protocolVersion is parsed, removing the "any 200 = connected" false positive; offers
    /// 2025-11-25 and records any negotiated fallback) → (2) initialized notification
    /// → (3) tools/list **following pagination** (with title/description/annotations) → (4) only if
    /// capabilities declare them, count the first page of resources/prompts. Every list call
    /// carries the negotiated `MCP-Protocol-Version` header. Returns (status, folded auth method)
    /// for the snapshot to persist.
    private static func probeOne(_ entry: MCPServerEntry) -> (MCPProbe.Status, String?) {
        let definition = try? readDefinition(of: entry)
        // stdio: deep inspection (v2.8) — briefly launch the configured command and handshake over
        // stdin/stdout to get the tool/prompt/resource lists, exiting once read. Only happens on
        // user click; env values go only to the child process (their intended use) and are never
        // persisted or logged. The auth method is routed by env key names, not folded.
        if entry.transport == "stdio" || (definition?.transport == .stdio) {
            guard let command = definition?.command
                ?? entry.commandSummary?.split(separator: " ").first.map(String.init)
            else { return (.commandMissing, nil) }
            switch MCPStdioProbe.inspect(
                command: command, args: definition?.args ?? [],
                env: definition?.env ?? [:]) {
            case .failure(.commandMissing):
                return (.commandMissing, nil)
            case .failure(.launchFailed(let reason)):
                return (.unreachable(L10n.format("Failed to start: %@", zhHans: "启动失败：%@", String(reason))), nil)
            case .failure(.handshakeFailed(let reason)):
                return (.unreachable(reason), nil)
            case .success(let inspection):
                storeInspection(
                    name: entry.name, info: inspection.handshake,
                    tools: inspection.tools,
                    prompts: inspection.handshake.capabilities.contains("prompts")
                        ? inspection.prompts : nil,
                    resources: inspection.handshake.capabilities.contains("resources")
                        ? inspection.resources : nil,
                    schemaTokens: inspection.schemaTokens)
                return (.connected(inspection.handshake), nil)
            }
        }
        guard let urlText = definition?.url, let url = URL(string: urlText) else {
            return (.unreachable(L10n.text("Invalid URL", zhHans: "URL 无效")), nil)
        }
        var headers = definition?.headers ?? [:]
        // v2.5: with no explicit Authorization header, attach the token Eureka holds from browser
        // OAuth
        let hasExplicitAuth = headers.keys.contains { $0.lowercased() == "authorization" }
        var storedToken: MCPOAuth.TokenSet?
        if !hasExplicitAuth, let stored = loadTokenSet(named: entry.name) {
            storedToken = stored
            headers["Authorization"] = "Bearer \(stored.accessToken)"
        }
        var (status, response) = performHandshake(url: url, headers: headers)
        // access token expired and a refresh token exists → refresh and retry once
        if case .unauthorized = status, let stored = storedToken,
           let refresh = stored.refreshToken,
           let tokenURL = URL(string: stored.tokenEndpoint),
           case .success(let refreshResponse) = performRPC(
               url: tokenURL, headers: [:],
               body: MCPOAuth.refreshRequestBody(
                   refreshToken: refresh, clientID: stored.clientID, resource: urlText),
               contentType: "application/x-www-form-urlencoded"),
           (200...299).contains(refreshResponse.statusCode),
           let renewed = MCPOAuth.parseTokenResponse(
               refreshResponse.data, tokenEndpoint: stored.tokenEndpoint,
               clientID: stored.clientID) {
            storeTokenSet(renewed, named: entry.name)
            headers["Authorization"] = "Bearer \(renewed.accessToken)"
            (status, response) = performHandshake(url: url, headers: headers)
        }
        let authScheme = MCPAuthRouter.scheme(
            for: status, usedToken: storedToken != nil, hadExplicitAuth: hasExplicitAuth)
        guard case .connected(let info) = status, let initResponse = response else {
            return (status, authScheme)
        }

        let session = initResponse.sessionID
        let negotiated = info.protocolVersion
        _ = performRPC(
            url: url, headers: headers,
            body: MCPProbe.initializedNotificationBody(), sessionID: session,
            protocolVersion: negotiated)
        // Shared list-call body: one page request + parse (the response body only feeds the parser,
        // never stored or logged)
        func fetchPage<T>(
            body: Data, parse: (Data, String?) -> T?
        ) -> T? {
            guard case .success(let pageResponse) = performRPC(
                    url: url, headers: headers, body: body, sessionID: session,
                    protocolVersion: negotiated),
                  (200...299).contains(pageResponse.statusCode)
            else { return nil }
            return parse(pageResponse.data, pageResponse.contentType)
        }

        // tools/list follows nextCursor (guardrails: ≤20 pages and ≤1000 tools); the schema tax
        // accumulates across pages
        var tools: [MCPProbe.ToolInfo] = []
        var schemaTokens = 0
        var cursor: String?
        var fetchedAny = false
        for _ in 0..<20 {
            guard case .success(let pageResponse) = performRPC(
                    url: url, headers: headers,
                    body: MCPProbe.toolsListRequestBody(cursor: cursor), sessionID: session,
                    protocolVersion: negotiated),
                  (200...299).contains(pageResponse.statusCode),
                  let page = MCPProbe.parseToolsList(
                      pageResponse.data, contentType: pageResponse.contentType)
            else { break }
            fetchedAny = true
            tools += page.tools
            let payload = MCPProbe.extractJSONPayload(
                pageResponse.data, contentType: pageResponse.contentType)
            schemaTokens += payload.flatMap { String(data: $0, encoding: .utf8) }
                .map { TokenEstimator.estimate($0) } ?? 0
            cursor = page.nextCursor
            guard cursor != nil, tools.count < 1000 else { break }
        }
        if fetchedAny {
            // resources/prompts: only asked if the capability is declared; names + descriptions
            // from the first page (no bodies/URIs read)
            var resources: [MCPProbe.NamedItem]?
            var prompts: [MCPProbe.NamedItem]?
            if info.capabilities.contains("resources") {
                resources = fetchPage(body: MCPProbe.resourcesListRequestBody()) {
                    MCPProbe.parseNamedList($0, contentType: $1, key: "resources")
                }?.items
            }
            if info.capabilities.contains("prompts") {
                prompts = fetchPage(body: MCPProbe.promptsListRequestBody()) {
                    MCPProbe.parseNamedList($0, contentType: $1, key: "prompts")
                }?.items
            }
            storeInspection(
                name: entry.name, info: info, tools: tools,
                prompts: prompts, resources: resources, schemaTokens: schemaTokens)
        }
        return (status, authScheme)
    }

    /// Probe result → tool cache (shared by remote and stdio deep inspection; descriptions
    /// truncated, lists capped, schema bodies and any config values never enter the cache)
    private static func storeInspection(
        name: String, info: MCPProbe.HandshakeInfo, tools: [MCPProbe.ToolInfo],
        prompts: [MCPProbe.NamedItem]?, resources: [MCPProbe.NamedItem]?,
        schemaTokens: Int
    ) {
        func summarize(_ items: [MCPProbe.NamedItem]?) -> [MCPNamedSummary]? {
            items.map { list in
                list.prefix(100).map {
                    MCPNamedSummary(
                        name: $0.name,
                        description: $0.description.map { String($0.prefix(200)) })
                }
            }
        }
        MCPToolCache.upsert(name: name, entry: MCPToolCacheEntry(
            toolCount: tools.count,
            toolNames: tools.map(\.name),
            schemaTokens: schemaTokens,
            serverVersion: info.serverVersion,
            protocolVersion: info.protocolVersion,
            capabilities: info.capabilities,
            tools: tools.map { tool in
                MCPToolSummary(
                    name: tool.name,
                    title: tool.title,
                    description: tool.description.map { String($0.prefix(200)) },
                    readOnly: tool.readOnly,
                    destructive: tool.destructive,
                    hasOutputSchema: tool.hasOutputSchema ? true : nil,
                    params: tool.params.isEmpty ? nil : tool.params)
            },
            resourceCount: resources?.count,
            promptCount: prompts?.count,
            prompts: summarize(prompts),
            resources: summarize(resources),
            measuredAt: Date()))
    }

    // MARK: - Write core (called on queue)

    /// One definition → one target's global config. Returns a failure reason; nil = success.
    private static func write(
        _ definition: MCPServerDefinition, to source: AgentSource
    ) -> String? {
        guard let target = writableTarget(for: source) else {
            return writeBlockReason(for: source) ?? L10n.text("This target does not support writing", zhHans: "该目标不支持写入")
        }
        return write(definition, to: target)
    }

    /// One definition → any write target (global or project level). Returns a failure reason; nil =
    /// success. When a dedicated small file (cursor/kimi global, or either project-level file) is
    /// missing, create the parent dir and then the file; a missing host config is still never
    /// created from nothing.
    private static func write(
        _ definition: MCPServerDefinition, to target: WritableTarget
    ) -> String? {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: target.configURL.path)
        guard exists || target.canCreateFile else {
            return L10n.format("No configuration file found for this agent (%@); a new file will not be created", zhHans: "未检测到该 agent 的配置文件（%@），不凭空创建", String(target.configURL.path))
        }
        do {
            if !exists, target.canCreateFile {
                try fm.createDirectory(
                    at: target.configURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            }
            let original = ConfigFile.read(target.configURL)
            let updated: String
            switch target.dialect {
            case .toml:
                updated = try MCPServerEditor.upsertTOML(into: original, definition: definition)
            case .json(let container, let style):
                updated = try MCPServerEditor.upsertJSON(
                    into: original, definition: definition, container: container, style: style)
            }
            try ConfigFile.backupThenWrite(path: target.configURL, newContent: updated)
            return nil
        } catch let error as LocalizedError {
            return error.errorDescription ?? "\(error)"
        } catch {
            return "\(error)"
        }
    }

    /// Dialect of the config file holding the entry (shared by read-definition / delete)
    private static func readDialect(for entry: MCPServerEntry) -> TargetDialect {
        switch entry.source {
        case .codex, .grok: return .toml
        case .opencode: return .json(container: "mcp", style: .opencode)
        default: return .json(container: "mcpServers", style: .plain)
        }
    }

    private static func readDefinition(of entry: MCPServerEntry) throws -> MCPServerDefinition {
        let text = ConfigFile.read(URL(fileURLWithPath: entry.configPath))
        switch readDialect(for: entry) {
        case .toml:
            return try MCPServerEditor.readDefinitionTOML(text, name: entry.name)
        case .json(let container, _):
            return try MCPServerEditor.readDefinitionJSON(
                text, name: entry.name, container: container)
        }
    }

    // MARK: - Authorization flow ("single-hop authorization")

    /// One executable authorization action: run `command` in a terminal (menu copy in label)
    struct AuthAction: Identifiable {
        var id: String { command }
        var label: String
        var command: String
        /// true = a real authorization command ("Copy command" can be offered); false = open the
        /// CLI guide
        var isDirect: Bool
    }

    /// Authorization action per source. Verified: only codex has a headless authorization command
    /// (`codex mcp login <name>`); claude / gemini / qwen do MCP OAuth inside each REPL's /mcp menu
    /// → open the CLI guide.
    static func authActions(for entry: MCPServerEntry) -> [AuthAction] {
        switch entry.source {
        case .codex:
            return [AuthAction(
                label: L10n.format("Authorize in Terminal (codex mcp login %@)", zhHans: "在终端授权（codex mcp login %@）", String(entry.name)),
                command: "codex mcp login \(shellQuoted(entry.name))",
                isDirect: true)]
        case .claude:
            return [AuthAction(
                label: L10n.text("Open claude in Terminal (enter /mcp to authorize)", zhHans: "在终端打开 claude（输入 /mcp 完成授权）"),
                command: "claude", isDirect: false)]
        case .gemini:
            return [AuthAction(
                label: L10n.text("Open gemini in Terminal (enter /mcp auth to authorize)", zhHans: "在终端打开 gemini（输入 /mcp auth 完成授权）"),
                command: "gemini", isDirect: false)]
        case .qwen:
            return [AuthAction(
                label: L10n.text("Open qwen in Terminal (enter /mcp auth to authorize)", zhHans: "在终端打开 qwen（输入 /mcp auth 完成授权）"),
                command: "qwen", isDirect: false)]
        default:
            return []
        }
    }

    /// Run a command in a new Terminal window (same osascript technique as
    /// SessionBrowserService.resumeInTerminal)
    func openInTerminal(command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Conservative quoting before a server name is mixed into a shell command (names are usually
    /// slugs; wrapped in single quotes when they contain special characters)
    private static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if safe && !text.isEmpty { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - External open (main thread)

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        DispatchQueue.main.async { self.lastError = message }
    }
}
