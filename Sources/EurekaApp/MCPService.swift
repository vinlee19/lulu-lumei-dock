import AppKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaSync
import EurekaUsage
import Foundation

/// MCP server 的索引与管理服务（「MCP」页签）。
///
/// 读：9 个实勘源的配置索引（键名版，见 MCPConfigIndexer——env/headers 值在解析层就丢弃）。
/// 写：新建 / 跨源安装 / 删除，走 `MCPServerEditor`（方言投影）+ `ConfigFile.backupThenWrite`
/// （守卫先行，抛错即原文件未动；写前留 `.bak.eureka.<ts>` 备份）。
/// 密钥姿势：完整定义（含 env 值）只在"读源配置 → 写目标配置"的内存中转里存在，
/// 不落库、不进日志、不上云、不进 UI；MCP 配置文件也依旧不进云备份白名单。
final class MCPService: ObservableObject {
    @Published private(set) var servers: [MCPServerEntry] = []
    @Published private(set) var scanning = false
    /// 上次扫完的时间。nil = 从未扫过（refresh 的判据）
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    /// 连接检测结果（键 = entry.id）；只在用户点击「检测连接」时填充，绝不自动探测
    @Published private(set) var probeResults: [String: ProbeState] = [:]
    /// 工具探测缓存（键 = server 名小写）：tools/list 实测的工具清单与 schema token
    @Published private(set) var toolCache: [String: MCPToolCacheEntry] = [:]
    /// 浏览器授权进度/结果（键 = entry.id；文案短暂驻留）
    @Published private(set) var oauthNotes: [String: String] = [:]
    /// Eureka 持有令牌的 server 名（小写；存在性标志在 UserDefaults，密钥本体在 Keychain）
    @Published private(set) var oauthTokenNames: Set<String> = []
    /// 持久化的上次探测快照（键 = entry.id）：打开页面即见，重启不丢（v2.6 直显）
    @Published private(set) var probeSnapshots: [String: MCPProbeSnapshot] = [:]
    /// 项目根候选（repo 选择器用）：扫描时与索引共用同一次 ProjectScopeDiscovery 结果
    @Published private(set) var repoRoots: [(root: URL, name: String)] = []
    /// 预注册 client_id（键 = server 名小写；client_id 非密钥，存 UserDefaults）——
    /// AS 不支持动态注册时的规范出口（注册优先级第一位：预注册凭据）
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

    // MARK: - 扫描

    /// force = false：只在「从未扫过」时扫（启动预热 + onAppear 兜底共用，幂等）。
    /// force = true：无条件全量重扫，仅刷新按钮使用。
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

    /// 同名 server 的全部配置处（详情页用；不受搜索过滤影响）
    func entries(named name: String) -> [MCPServerEntry] {
        let key = name.lowercased()
        return allServers.filter { $0.name.lowercased() == key }
    }

    /// 全部条目快照（一致性/漂移检查用；不受搜索过滤影响）
    func allEntries() -> [MCPServerEntry] { allServers }

    /// 该源是否有真实的启停语义（实证 codex/grok TOML、opencode JSON 有 enabled 键）
    static func supportsEnableToggle(_ source: AgentSource) -> Bool {
        source == .codex || source == .grok || source == .opencode
    }

    // MARK: - 写目标表（与 MCPConfigIndexer.globalConfigURL 同一张路径表）

    /// 各写目标的方言（容器键 + 字段风格）；EurekaInstall 不认识 AgentSource，映射放这层
    enum TargetDialect {
        case json(container: String, style: MCPJSONStyle)
        case toml
    }

    struct WritableTarget {
        var source: AgentSource
        var configURL: URL
        var dialect: TargetDialect
        /// 专用小文件（cursor / kimi 的 mcp.json）缺失可新建；
        /// 宿主大配置（~/.claude.json、settings.json、config.toml、opencode.json）缺失
        /// 说明该 CLI 没跑过 —— 绝不凭空造别人的主配置。
        var canCreateFile: Bool
    }

    /// 8 个可写目标（形态全部本机实勘；见方案矩阵）
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

    /// 不可写的原因（矩阵置灰文案）；nil = 可写
    static func writeBlockReason(for source: AgentSource) -> String? {
        switch source {
        case .claude, .codex, .gemini, .cursor, .kimi, .qwen, .grok, .opencode:
            return nil
        case .zcode: return "MCP 由插件注册，无用户级配置"
        case .trae: return "配置与凭证同目录，不读不写"
        default: return "无已知 MCP 配置约定"
        }
    }

    // MARK: - 项目级写目标（专用小文件，缺失可建）

    /// 有项目级配置约定的源：claude `<repo>/.mcp.json`（MCP 官方的项目共享标准）
    /// 与 cursor `<repo>/.cursor/mcp.json`（与用户级同构）
    static let projectLevelSources: [AgentSource] = [.claude, .cursor]

    /// 项目级写目标；返回 nil = 该源没有项目级约定
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

    /// 该定义能否装到目标。codex 的远程形态已实勘（url + 可选 bearer_token，本机
    /// config.toml 验证）；grok 无远程证据 → 继续拒绝。细粒度边界（非 Authorization
    /// 请求头拒写 http_headers）由 MCPServerEditor 在写入时把关。nil = 可以
    static func installBlockReason(transport: String, to source: AgentSource) -> String? {
        if let reason = writeBlockReason(for: source) { return reason }
        if transport != "stdio", source == .grok {
            return "远程 server 在该目标的格式未验证"
        }
        return nil
    }

    static var writableSources: [AgentSource] {
        AgentSource.allCases.filter { writeBlockReason(for: $0) == nil }
    }

    // MARK: - 写操作（queue 上执行；守卫先行，抛错即原文件未动）

    /// 批量添加：每个定义写到每个目标的**全局配置**；全部完成后**只重扫一次**。
    /// 回调按目标给出失败原因（nil = 成功）；多定义时聚合首个失败。
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

    /// 编辑既有 server（合并式改写：未建模键保留、TOML 原位；写前备份）
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

    /// 读出某处配置的完整定义（含 env/headers 现值），供编辑表单预填。
    /// 值只进表单字段（显式编辑动作），不落库、不进日志、不上云。
    func definition(of entry: MCPServerEntry, completion: @escaping (MCPServerDefinition?) -> Void) {
        queue.async {
            let result = try? Self.readDefinition(of: entry)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// 安装到项目级配置（专用小文件，缺失可建）：逐源汇报失败，全部完成只重扫一次
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

    /// 跨源安装到项目级（详情页矩阵）：读出完整定义（含 env 值，仅内存中转）后写入
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
                for source in sources { results[source] = "读取来源定义失败" }
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
                results[source] = "该源没有项目级配置约定"
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

    /// 跨源安装：从 entry 所在配置读出**完整定义**（含 env 值，仅内存中转），投影写入目标
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
                        results.updateValue("读取来源定义失败：\(message)", forKey: target)
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

    /// 从某处配置里删除该 server（写前备份；TOML 连带清除全部子段）
    func remove(_ entry: MCPServerEntry, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var ok = false
            do {
                let url = URL(fileURLWithPath: entry.configPath)
                let original = ConfigFile.read(url)
                let updated: String
                switch Self.readDialect(for: entry) {
                case .toml:
                    updated = try MCPServerEditor.removeTOML(from: original, name: entry.name)
                case .json(let container, _):
                    updated = try MCPServerEditor.removeJSON(
                        from: original, name: entry.name, container: container)
                }
                try ConfigFile.backupThenWrite(path: url, newContent: updated)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// 启停：codex/grok 走 TOML 原位改写，opencode 走 JSON 合并；写前备份。
    /// 停用 = 把工具从上下文里摘掉但保留配置（协议语义），配合闲置检测使用。
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
                    throw MCPEditError.unsupportedTarget("该源的配置没有启停语义")
                }
                try ConfigFile.backupThenWrite(path: url, newContent: updated)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// 复制为标准 mcpServers JSON 片段（**不含密钥值**：env/headers 值以空串占位，
    /// 收件人自填）——与「粘贴导入」互逆，分享闭环
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

    // MARK: - 浏览器 OAuth 授权（v2.5；token 只服务 Eureka 的检测，绝不写 CLI 凭证存储）

    private static let oauthKeychainService = "com.vinlee.eureka.mcp"
    private static let oauthNamesKey = "mcpOAuthTokenNames"
    private static let clientIDsKey = "mcpOAuthClientIDs"

    /// 设置/清除预注册 client_id（空串 = 清除；client_id 非密钥，存 UserDefaults）
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

    /// 默认浏览器完成 OAuth（发现→注册→授权→回环回调→换 token），成功后令牌进 Keychain。
    func authorizeInBrowser(_ entry: MCPServerEntry) {
        let entryID = entry.id
        let preRegistered = preRegisteredClientID(for: entry)
        oauthNotes[entryID] = "正在发现授权服务器…"
        queue.async { [weak self] in
            let definition = try? Self.readDefinition(of: entry)
            guard let serverURL = definition?.url else {
                DispatchQueue.main.async {
                    self?.oauthNotes[entryID] = "该配置没有远程 URL，无法浏览器授权"
                }
                return
            }
            do {
                let tokenSet = try MCPOAuthFlow.run(
                    serverURL: serverURL, headers: definition?.headers ?? [:],
                    preRegisteredClientID: preRegistered.isEmpty ? nil : preRegistered
                ) { message in
                    self?.oauthNotes[entryID] = message  // progress 回调已在主线程
                }
                Self.storeTokenSet(tokenSet, named: entry.name)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.mutateTokenNames { $0.insert(entry.name.lowercased()) }
                    self.oauthNotes[entryID] = "授权成功——重新「检测连接」即可看到工具清单"
                        + "（令牌仅供 Eureka 检测；CLI 侧仍需各自授权）"
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                DispatchQueue.main.async {
                    self?.oauthNotes[entryID] = "授权失败：\(message)"
                }
            }
        }
    }

    /// 撤销 Eureka 持有的令牌（Keychain 删除 + 存在性标志更新）
    func revokeToken(for entry: MCPServerEntry) {
        let entryID = entry.id
        queue.async { [weak self] in
            _ = KeychainStore.delete(
                account: Self.tokenAccount(entry.name), service: Self.oauthKeychainService)
            DispatchQueue.main.async {
                guard let self else { return }
                self.mutateTokenNames { $0.remove(entry.name.lowercased()) }
                self.oauthNotes[entryID] = "已撤销 Eureka 持有的令牌"
            }
        }
    }

    private func mutateTokenNames(_ change: (inout Set<String>) -> Void) {
        var names = Set(UserDefaults.standard.stringArray(forKey: Self.oauthNamesKey) ?? [])
        change(&names)
        UserDefaults.standard.set(Array(names).sorted(), forKey: Self.oauthNamesKey)
        oauthTokenNames = names
    }

    // MARK: - 连接检测（只在用户点击时发起，绝不自动探测）

    /// 取消票据：新批次发放新票据，旧批次发现被取消即停（线程安全，main 发放/queue 查询）
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
    /// 批量检测进度（nil = 不在批量检测中）
    @Published private(set) var probeProgress: (done: Int, total: Int)?

    /// 检测一组配置处：remote 发 MCP initialize 探测（headers 只发往该 server 自己的
    /// URL——这是这些凭证的既定用途；响应体不读不存不记日志）；stdio 查命令可达（纯
    /// syscall，不 spawn 进程）。结果进 probeResults，UI 以 chip 呈现。
    /// 串行逐处执行，每处完成即发布进度；再次调用或 cancelProbe() 取消未完成的旧批次。
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
                // 快照落盘（含鉴权方式折算）：下次打开页面（含重启后）直显，不让用户猜
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
            // tools/list 可能刚落盘 → 刷新工具缓存（工具数 chip / ctx 开销随之更新）
            let cache = MCPToolCache.load()
            DispatchQueue.main.async {
                guard !ticket.isCancelled else { return }
                self?.toolCache = cache
                self?.probeProgress = nil
            }
        }
    }

    /// 取消进行中的批量检测（单处「重新检测」也走同一条取消路径，无副作用）
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

    /// 单次 JSON-RPC POST（队列上阻塞等待，照 EurekaSync/HTTPTransport 的信号量手法）。
    /// headers 只发往该 server 自己配置的 URL；响应体只喂给解析器，不存不记日志。
    /// protocolVersion：初始化后的请求按规范 **MUST** 带 `MCP-Protocol-Version` 头
    /// （值 = 握手协商到的版本；不带的话 server 会按 2025-03-26 猜）。
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

    /// 一次 initialize + 分类（探测与 refresh 重试共用）
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

    /// 一次完整探测：① initialize **真握手**（2xx 还要解析出 protocolVersion 才算已连接，
    /// 消除"任意 200 = 已连接"的误报；报 2025-11-25，协商回落照记）→ ② initialized 通知
    /// → ③ tools/list **跟随分页**（含 title/描述/注解）→ ④ capabilities 声明了才
    /// resources/prompts 各取第一页计数。列表调用全部带协商版本的
    /// `MCP-Protocol-Version` 头。返回（状态, 鉴权方式折算）供快照落盘。
    private static func probeOne(_ entry: MCPServerEntry) -> (MCPProbe.Status, String?) {
        let definition = try? readDefinition(of: entry)
        // stdio：深度检测（v2.8）——短暂启动配置的命令走 stdin/stdout 握手拿
        // 工具/提示词/资源清单，读完即退。只在用户点击时发生；env 值只传给子进程
        // （其既定用途），不落库不记日志。鉴权方式由 env 键名路由，不折算。
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
                return (.unreachable("启动失败：\(reason)"), nil)
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
            return (.unreachable("URL 无效"), nil)
        }
        var headers = definition?.headers ?? [:]
        // v2.5：无显式 Authorization 头时，附上 Eureka 经浏览器 OAuth 持有的令牌
        let hasExplicitAuth = headers.keys.contains { $0.lowercased() == "authorization" }
        var storedToken: MCPOAuth.TokenSet?
        if !hasExplicitAuth, let stored = loadTokenSet(named: entry.name) {
            storedToken = stored
            headers["Authorization"] = "Bearer \(stored.accessToken)"
        }
        var (status, response) = performHandshake(url: url, headers: headers)
        // access token 失效且有 refresh token → 换新重试一次
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
        // 列表调用共用体：一页请求 + 解析（响应体只喂解析器，不存不记日志）
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

        // tools/list 跟随 nextCursor（护栏 ≤20 页且 ≤1000 工具）；schema 税按各页累加
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
            // resources/prompts：能力声明了才问，第一页的名字+描述（不读正文/URI）
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

    /// 探测结果 → 工具缓存（remote 与 stdio 深探共用；描述截断、清单封顶，
    /// schema 正文与任何配置值不进缓存）
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

    // MARK: - 写内核（queue 上调用）

    /// 单个定义 → 单个目标的全局配置。返回失败原因；nil = 成功。
    private static func write(
        _ definition: MCPServerDefinition, to source: AgentSource
    ) -> String? {
        guard let target = writableTarget(for: source) else {
            return writeBlockReason(for: source) ?? "该目标不支持写入"
        }
        return write(definition, to: target)
    }

    /// 单个定义 → 任意写目标（全局或项目级）。返回失败原因；nil = 成功。
    /// 专用小文件（cursor/kimi 全局、项目级两种）缺失时先建父目录再新建文件；
    /// 宿主大配置缺失依旧拒绝凭空创建。
    private static func write(
        _ definition: MCPServerDefinition, to target: WritableTarget
    ) -> String? {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: target.configURL.path)
        guard exists || target.canCreateFile else {
            return "未检测到该 agent 的配置文件（\(target.configURL.path)），不凭空创建"
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

    /// entry 所在配置文件的方言（读定义 / 删除共用）
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

    // MARK: - 授权动线（"单点跳转授权"）

    /// 一条可执行的授权动作：在终端里跑 `command`（menu 文案见 label）
    struct AuthAction: Identifiable {
        var id: String { command }
        var label: String
        var command: String
        /// true = 真·授权命令（可提供"复制命令"）；false = 打开 CLI 引导
        var isDirect: Bool
    }

    /// 各源的授权动作。实测只有 codex 有 headless 授权命令（`codex mcp login <name>`）；
    /// claude / gemini / qwen 的 MCP OAuth 在各自 REPL 的 /mcp 菜单里 → 打开 CLI 引导。
    static func authActions(for entry: MCPServerEntry) -> [AuthAction] {
        switch entry.source {
        case .codex:
            return [AuthAction(
                label: "在终端授权（codex mcp login \(entry.name)）",
                command: "codex mcp login \(shellQuoted(entry.name))",
                isDirect: true)]
        case .claude:
            return [AuthAction(
                label: "在终端打开 claude（输入 /mcp 完成授权）",
                command: "claude", isDirect: false)]
        case .gemini:
            return [AuthAction(
                label: "在终端打开 gemini（输入 /mcp auth 完成授权）",
                command: "gemini", isDirect: false)]
        case .qwen:
            return [AuthAction(
                label: "在终端打开 qwen（输入 /mcp auth 完成授权）",
                command: "qwen", isDirect: false)]
        default:
            return []
        }
    }

    /// 在 Terminal 新窗口执行命令（照 SessionBrowserService.resumeInTerminal 的 osascript 手法）
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

    /// server 名混入 shell 命令前的保守引用（名字通常是 slug；含特殊字符时单引号包裹）
    private static func shellQuoted(_ text: String) -> String {
        let safe = text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        if safe && !text.isEmpty { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 外部打开（主线程）

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
