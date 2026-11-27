import Foundation

/// A rule title in both interface languages. Resolved when shown, never stored resolved, so a rule
/// set built before a language switch still reads right afterwards.
public struct RiskRuleTitle: Equatable, Sendable {
    public var english: String
    public var zhHans: String

    public init(_ english: String, zhHans: String? = nil) {
        self.english = english
        self.zhHans = zhHans ?? english
    }

    public var text: String { L10n.text(english, zhHans: zhHans) }
}

/// One risk rule. Data, not closures, so a rule can be written in a JSON file as well as here.
///
/// What `pattern` is matched against depends on `scope`:
/// - `text`: the whole operation detail
/// - `tool`: the tool name (`server.tool` for MCP)
/// - `segment`: each simple command of a shell command, after `commands` matched its command word
/// - `pipeline`: a command in `commands` whose output reaches one of `pipeInto` (or one of
///   `pipeIntoBare` run without arguments), through a pipe or a substitution
/// - `path`: each path the operation reads or writes (`access`), as written and resolved
public struct RiskRule: Sendable, Equatable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case text, tool, segment, pipeline, path
    }

    public enum Access: String, Codable, Sendable, CaseIterable {
        case read, write, any
    }

    public enum Category: String, Codable, Sendable, CaseIterable {
        case credentials, destructive, versionControl, outbound, system, agentConfig, supplyChain,
             network, mcp, custom

        public var label: String {
            switch self {
            case .credentials: return L10n.text("Credentials", zhHans: "凭据")
            case .destructive: return L10n.text("Destructive", zhHans: "破坏性操作")
            case .versionControl: return L10n.text("Version control", zhHans: "版本控制")
            case .outbound: return L10n.text("Outbound", zhHans: "对外操作")
            case .system: return L10n.text("System", zhHans: "系统")
            case .agentConfig: return L10n.text("Agent config", zhHans: "Agent 配置")
            case .supplyChain: return L10n.text("Supply chain", zhHans: "供应链")
            case .network: return L10n.text("Network", zhHans: "网络")
            case .mcp: return "MCP"
            case .custom: return L10n.text("Custom", zhHans: "自定义")
            }
        }
    }

    public var id: String
    public var title: RiskRuleTitle
    public var level: RiskLevel
    public var category: Category
    /// Operation kinds the rule looks at
    public var kinds: Set<ToolKind>
    public var scope: Scope
    /// Command words (lowercase basenames; a trailing `*` matches a prefix). A wrapper such as
    /// `sudo` matches too. Empty = any command.
    public var commands: [String]
    /// Case-insensitive regex; see the type comment for what it runs against
    public var pattern: String?
    public var pipeInto: [String]
    public var pipeIntoBare: [String]
    /// `path` scope: which of the operation's paths to look at
    public var access: Access
    /// Zones a path operand must be in (empty = any) and must not be in
    public var targets: Set<RiskPathZone>
    public var exceptTargets: Set<RiskPathZone>
    /// A match on the whole detail cancels the hit
    public var exclude: [String]
    /// `segment` scope: skip a command inside `$( )` / backticks, whose output goes into another
    /// command instead of being shown (`TOKEN=$(gcloud auth print-access-token)`)
    public var topLevel: Bool
    /// `segment` scope: skip a command piped straight into one of these (`*` = into anything),
    /// e.g. `env | grep proxy` is a filtered look, not a dump
    public var notPipedInto: [String]
    public var enabled: Bool
    /// A built-in rule the rules file cannot switch off, re-level or allow-list: the rules about
    /// tampering with the audit itself. Without this, whatever is being audited could silence
    /// the rule that reports it and have re-evaluation erase the hit.
    public var isProtected = false

    public init(
        id: String, title: RiskRuleTitle, level: RiskLevel, category: Category,
        kinds: Set<ToolKind>, scope: Scope, commands: [String] = [], pattern: String? = nil,
        pipeInto: [String] = [], pipeIntoBare: [String] = [], access: Access = .any,
        targets: Set<RiskPathZone> = [], exceptTargets: Set<RiskPathZone> = [],
        exclude: [String] = [], topLevel: Bool = false, notPipedInto: [String] = [],
        enabled: Bool = true
    ) {
        self.topLevel = topLevel
        self.notPipedInto = notPipedInto
        self.id = id
        self.title = title
        self.level = level
        self.category = category
        self.kinds = kinds
        self.scope = scope
        self.commands = commands
        self.pattern = pattern
        self.pipeInto = pipeInto
        self.pipeIntoBare = pipeIntoBare
        self.access = access
        self.targets = targets
        self.exceptTargets = exceptTargets
        self.exclude = exclude
        self.enabled = enabled
    }
}

/// The rules in force and the built-in rule list.
public enum RiskRuleEngine {
    private static let shells = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
    private static let interpreters = ["python", "python3", "node", "ruby", "perl", "php", "osascript"]
    private static let recursiveFlag = #"\s-[a-z]*r[a-z]*(\s|$)|\s--recursive(\s|$)"#

    private static let secretVariable =
        // The sensitive word is a whole `_`-separated part of the name: $GITHUB_TOKEN, not
        // $TOKENIZER_PATH
        #"\$\{?(?:[a-z0-9]+_)*(KEY|KEYS|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIALS?)(?:_[a-z0-9]+)*\}?(?![a-z0-9_]|:[-+?=])"#
    private static let pathRead: Set<ToolKind> = [.read, .search, .command]
    private static let pathWrite: Set<ToolKind> = [.edit, .command]

    private static func rule(
        _ id: String, _ english: String, _ zhHans: String, _ level: RiskLevel,
        _ category: RiskRule.Category, kinds: Set<ToolKind> = [.command],
        scope: RiskRule.Scope = .segment, commands: [String] = [], pattern: String? = nil,
        pipeInto: [String] = [], pipeIntoBare: [String] = [], access: RiskRule.Access = .any,
        targets: Set<RiskPathZone> = [], exclude: [String] = [], topLevel: Bool = false,
        notPipedInto: [String] = [], enabled: Bool = true
    ) -> RiskRule {
        RiskRule(
            id: id, title: RiskRuleTitle(english, zhHans: zhHans), level: level,
            category: category, kinds: kinds, scope: scope, commands: commands, pattern: pattern,
            pipeInto: pipeInto, pipeIntoBare: pipeIntoBare, access: access, targets: targets,
            exclude: exclude, topLevel: topLevel, notPipedInto: notPipedInto, enabled: enabled)
    }

    private static func protected(_ rule: RiskRule) -> RiskRule {
        var rule = rule
        rule.isProtected = true
        return rule
    }

    /// Built-in rules. Order is the priority within a level: more specific rules come first.
    public static var builtinRules: [RiskRule] { [
        // ── critical: an agent got hold of a secret ──────────────────────────
        rule("read-private-key", "Read a private key", "读取私钥", .critical, .credentials,
             kinds: pathRead, scope: .path,
             pattern: #"(^|/)id_(rsa|ed25519|dsa|ecdsa)$|\.(p12|pfx|ppk)$|(^|/)\.ssh/[^/]+\.key$"#,
             access: .read),
        rule("read-env-file", "Read a .env file", "读取 .env 文件", .critical, .credentials,
             kinds: pathRead, scope: .path,
             pattern: #"(^|/)\.env(\.(?!example$|sample$|template$|dist$)[\w-]+)?$"#,
             access: .read),
        rule("read-cloud-credentials", "Read cloud credentials", "读取云凭据", .critical,
             .credentials, kinds: pathRead, scope: .path,
             pattern: #"/\.aws/credentials$|(^|/)\.netrc$|application_default_credentials\.json$"#
                + #"|/\.kube/config$|/\.docker/config\.json$|service[-_]?account[\w.-]*\.json$"#,
             access: .read),
        rule("read-agent-credentials", "Read an agent's stored credentials", "读取 agent 凭据",
             .critical, .credentials, kinds: pathRead, scope: .path,
             pattern: #"/\.claude/\.credentials\.json$|/\.codex/auth\.json$|oauth[-_]token"#
                + #"|/\.gemini/oauth_creds\.json$|trae-jwt-token$|/\.config/gh/hosts\.yml$"#,
             access: .read),
        rule("keychain-read", "Read a password from the keychain", "从钥匙串读取密码", .critical,
             .credentials, commands: ["security"],
             // Without -w / -g / -d these print attributes only (service and account names)
             pattern: #"\sfind-(generic|internet)-password\b.*\s-[a-z]*[wg]\b"#
                + #"|\sdump-keychain\b.*\s-[a-z]*d\b|\ssecurity\s+export\b"#),
        rule("env-dump", "Dump environment variables", "导出环境变量", .critical, .credentials,
             commands: ["printenv", "env", "export"],
             pattern: #"^\s*\S*(printenv|env)\s*(\d?>.*)?$|^\s*export\s+-p\b"#
                + #"|\bprintenv\s+\S*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)"#,
             topLevel: true, notPipedInto: ["grep", "egrep", "fgrep", "rg", "wc", "cut"]),
        rule("env-grep-secret", "Search the environment for secrets", "在环境变量里找密钥",
             .critical, .credentials, scope: .text,
             pattern: #"(^|[;&|(]\s*)(printenv|env)\s*\|\s*(e?grep|rg)\b[^|;&\n]*(key|token|secret|passw|credential)"#),
        rule("print-secret-variable", "Print a secret environment variable", "输出密钥环境变量",
             .critical, .credentials, commands: ["echo", "printf"],
             // The variable is an argument itself, not something tested inside `$( )` or `[ ]`
             pattern: #"^\s*(echo|printf)\b(?:(?!\$\(|\[|`).)*?"# + secretVariable,
             topLevel: true, notPipedInto: ["*"]),
        protected(rule(
            "audit-tamper", "Change the audit's own rules or data", "改动审计自身的规则或数据",
            .critical, .agentConfig, kinds: pathWrite, scope: .path,
            pattern: #"/Application Support/Eureka/(audit-rules\.json|eureka\.sqlite(-wal|-shm)?|bin/)"#
                + #"|(^|/)audit-rules\.json$"#,
            access: .write)),
        // ── high ─────────────────────────────────────────────
        rule("rm-rf", "Recursive deletion outside the project", "递归删除项目之外的路径", .high,
             .destructive, commands: ["rm"], pattern: recursiveFlag, targets: [.home, .system]),
        rule("curl-pipe-sh", "Run downloaded content directly", "下载内容直接执行", .high,
             .supplyChain, scope: .pipeline, commands: ["curl", "wget", "fetch"],
             pipeInto: shells, pipeIntoBare: interpreters),
        rule("base64-pipe-sh", "Run decoded base64 content", "base64 解码后执行", .high,
             .supplyChain, scope: .pipeline, commands: ["base64"], pattern: #"\s-{1,2}d"#,
             pipeInto: shells, pipeIntoBare: interpreters),
        rule("dd-to-device", "dd writes directly to a block device", "dd 直写块设备", .high,
             .destructive, commands: ["dd"],
             pattern: #"\bof=/dev/(?!null\b|zero\b|stdout\b|stderr\b|fd/)"#),
        rule("mkfs", "Format a file system", "格式化文件系统", .high, .destructive,
             commands: ["mkfs*", "newfs*"]),
        rule("diskutil-erase", "diskutil erases or repartitions a disk", "diskutil 抹盘/重分区",
             .high, .destructive, commands: ["diskutil"],
             pattern: #"\s(erase\w*|reformat|partition\w*|zeroDisk|randomDisk|secureErase)\b"#),
        rule("sql-destructive", "Destructive SQL statement", "破坏性 SQL 语句", .high,
             .destructive,
             commands: ["psql", "mysql", "mariadb", "sqlite3", "clickhouse-client", "clickhouse",
                        "bq", "duckdb", "spanner-cli", "mongosh", "redis-cli"],
             pattern: #"\bdrop\s+(table|database|schema|view|index)\b|\btruncate\s+(table\s+)?[\w.`"]"#
                + #"|\bdelete\s+from\s+[\w.`"]+\s*(;|"|'|$)|\bflushall\b|dropDatabase"#),
        rule("terraform-helm-apply", "Apply infrastructure changes", "变更基础设施", .high,
             .outbound, commands: ["terraform", "tofu", "pulumi", "helm"],
             pattern: #"\b(terraform|tofu)\s+(\S+\s+)*?(apply|destroy)\b|\bpulumi\s+(up|destroy)\b"#
                + #"|\bhelm\s+(\S+\s+)*?(install|upgrade|uninstall|delete|rollback)\b"#),
        rule("kubectl-delete", "kubectl delete", "kubectl 删除资源", .high, .outbound,
             commands: ["kubectl"], pattern: #"\sdelete\b"#),
        rule("gh-repo-delete", "Delete a GitHub repository", "删除 GitHub 仓库", .high, .outbound,
             commands: ["gh"], pattern: #"\srepo\s+delete\b"#),
        rule("package-publish", "Publish a package", "发布软件包", .high, .outbound,
             commands: ["npm", "pnpm", "yarn", "cargo", "poetry", "twine", "gem"],
             pattern: #"\b(npm|pnpm|yarn|cargo|poetry)\s+(-\S+\s+)*publish(\s|$)|\btwine\s+upload\b|\bgem\s+push\b"#),
        rule("git-force-push-main", "Force push to the main branch", "强制推送到主干分支", .high,
             .versionControl, commands: ["git"],
             pattern: #"\spush\b(?=.*\s(-f|--force\S*)(\s|$))(?=.*[\s:+](main|master)(\s|$))"#),
        rule("print-token", "Print an access token", "打印访问令牌", .high, .credentials,
             commands: ["gh", "gcloud", "aws", "op"],
             pattern: #"\bgh\s+auth\s+token\b|\bauth\s+(application-default\s+)?print-(access|identity)-token\b"#
                + #"|\baws\s+configure\s+(get|export-credentials)\b|\bop\s+read\b"#,
             // Captured into a variable or a header is ordinary API use; shown is the risk
             topLevel: true),
        rule("secret-in-command", "Credential written out in a command", "命令里写着明文凭据",
             .high, .credentials, scope: .text,
             // One shared `\b(?=[sagxe])` in front: this runs over every command in full, and
             // testing eleven alternatives at every position was the slowest part of a pass
             pattern: #"\b(?=[sagxe])(?:sk-ant-[a-z0-9_-]{16,}|sk-[a-z0-9_-]{20,}"#
                + #"|(?<!Credential=)(AKIA|ASIA)[0-9A-Z]{16}\b"#
                + #"|(ghp|gho|ghu|ghs|ghr)_[a-z0-9]{30,}\b|github_pat_[a-z0-9_]{40,}\b"#
                + #"|glpat-[a-z0-9_-]{20,}\b|xox[baprs]-[a-z0-9-]{10,}\b|AIza[0-9a-z_-]{35}\b"#
                + #"|eyJ[a-z0-9_-]{8,}\.[a-z0-9_-]{8,}\.[a-z0-9_-]{8,}"#
                + #"|authorization\s*:\s*(bearer|basic|token)\s+[a-z0-9._~+/=-]{16,}"#
                + #"|x-api-key\s*:\s*[a-z0-9._~+/=-]{16,})"#),
        rule("chmod-777", "chmod 777 grants all permissions", "chmod 777 开放全权限", .high,
             .system, commands: ["chmod"], pattern: #"\s0?777(\s|$)"#),
        rule("write-ssh", "Write to the ~/.ssh directory", "写入 ~/.ssh 目录", .high, .system,
             kinds: pathWrite, scope: .path, pattern: #"(^|/)\.ssh/"#, access: .write),
        rule("write-launch-agent", "Write a startup item", "写入开机自启项", .high, .system,
             kinds: pathWrite, scope: .path, pattern: #"/Library/Launch(Agents|Daemons)/"#,
             access: .write),
        rule("launchctl-load", "Load a launchd job", "加载 launchd 启动任务", .high, .system,
             commands: ["launchctl"], pattern: #"\s(load|bootstrap|enable|submit)\b"#),
        rule("crontab-edit", "Change the crontab", "修改 crontab", .high, .system,
             commands: ["crontab"], pattern: #"\bcrontab\b(?!\s+-l\b)"#),
        rule("shell-profile-write", "Write a shell startup file", "写入 shell 启动文件", .high,
             .system, kinds: pathWrite, scope: .path,
             pattern: #"(^|/)\.(zshrc|zshenv|zprofile|zlogin|bashrc|bash_profile|bash_login|profile)$"#
                + #"|/\.config/fish/config\.fish$"#,
             access: .write),
        rule("write-etc", "Write to the system /etc directory", "写入系统 /etc 目录", .high,
             .system, kinds: pathWrite, scope: .path, pattern: #"^(/private)?/etc/"#,
             access: .write),
        rule("macos-protection-off", "Turn off a macOS protection", "关闭 macOS 安全保护", .high,
             .system, commands: ["spctl", "csrutil"], pattern: #"disable"#),
        rule("agent-config-edit", "Change an agent's own configuration", "修改 agent 自身配置",
             .high, .agentConfig, kinds: pathWrite, scope: .path,
             pattern: #"/\.claude/settings(\.local)?\.json$|/\.claude\.json$|/\.claude/hooks/"#
                + #"|/\.codex/(config\.toml|hooks\.json)$|(^|/)\.mcp\.json$|/\.cursor/mcp\.json$"#
                + #"|/\.gemini/settings\.json$"#,
             access: .write),
        rule("permission-bypass-flag", "Start an agent with approvals bypassed",
             "以跳过审批的方式启动 agent", .high, .agentConfig,
             commands: ["claude", "codex", "gemini", "qwen", "grok", "opencode", "cursor-agent"],
             pattern: #"--dangerously-skip-permissions|--dangerously-bypass-approvals-and-sandbox"#
                + #"|\s--yolo\b|bypassPermissions|danger-full-access"#),
        rule("mcp-destructive", "MCP tool that deletes", "MCP 删除类操作", .high, .mcp,
             kinds: [.mcp], scope: .tool,
             pattern: #"\.[^.]*(delete|(?<!un)trash|remove|destroy|drop_|purge|destructive)[^.]*$"#),
        // ── notice ───────────────────────────────────────────
        rule("rm-rf-rel", "Recursive deletion inside the project", "递归删除（项目内）", .notice,
             .destructive, commands: ["rm"], pattern: recursiveFlag,
             targets: [.cwd, .relative, .unknown]),
        rule("read-registry-credentials", "Read package registry credentials in the home directory",
             "读取家目录下的包仓库凭据", .notice, .credentials, kinds: pathRead, scope: .path,
             pattern: #"(^|/)\.(npmrc|pypirc)$"#, access: .read, targets: [.home]),
        rule("read-pem", "Read a PEM file (certificate or key)", "读取 PEM 文件（证书或密钥）",
             .notice, .credentials, kinds: pathRead, scope: .path, pattern: #"\.pem$"#,
             access: .read),
        rule("git-force-push", "git force push", "git 强制推送", .notice, .versionControl,
             commands: ["git"], pattern: #"\spush\b.*\s(-f|--force\S*)(\s|$)"#),
        rule("git-push-main", "Push to the main branch", "推送到主干分支", .notice,
             .versionControl, commands: ["git"],
             pattern: #"\spush\b.*[\s:](main|master)(\s|$)"#),
        rule("git-reset-hard", "git hard reset", "git 硬重置", .notice, .versionControl,
             commands: ["git"], pattern: #"\sreset\b.*\s--hard\b"#),
        rule("git-clean", "git clean forced cleanup", "git clean 强制清理", .notice,
             .versionControl, commands: ["git"], pattern: #"\sclean\b.*\s-[a-z]*f"#),
        rule("gh-merge-release", "Merge a pull request or publish a release", "合并 PR / 发布 Release",
             .notice, .outbound, commands: ["gh"],
             pattern: #"\s(pr\s+merge|release\s+(create|delete|edit|upload)|workflow\s+run|secret\s+set|repo\s+(create|edit|archive))\b"#),
        rule("kubectl-mutate", "kubectl changes cluster state", "kubectl 变更集群状态", .notice,
             .outbound, commands: ["kubectl"],
             pattern: #"\s(apply|scale|patch|edit|replace|create|drain|cordon|exec|annotate|label|rollout\s+(restart|undo))\b"#),
        rule("cloud-mutate", "Change cloud resources", "变更云资源", .notice, .outbound,
             commands: ["gcloud", "aws", "gsutil", "az"],
             pattern: #"\s(delete|remove|rm|rb|mb|create|update|deploy|terminate-instances|set-iam-policy|add-iam-policy-binding|remove-iam-policy-binding)\b"#),
        rule("macos-security-setting", "Change a macOS setting", "修改 macOS 设置", .notice,
             .system, commands: ["defaults", "tccutil", "xattr"],
             pattern: #"\bdefaults\s+write\b|\btccutil\s+reset\b|com\.apple\.quarantine"#),
        rule("sudo", "sudo privileged execution", "sudo 提权执行", .notice, .system,
             commands: ["sudo"]),
        rule("global-install", "Install software globally", "全局安装软件", .notice, .supplyChain,
             commands: ["npm", "pnpm", "yarn", "brew", "pip", "pip3", "pipx", "uv", "cargo", "go",
                        "gem"],
             pattern: #"\b(npm|pnpm)\s+(i|install|add)\b.*\s(-g|--global)\b|\byarn\s+global\s+add\b"#
                + #"|\bbrew\s+(install|reinstall|tap)\b|\bpip3?\s+install\b|\bpipx\s+install\b"#
                + #"|\buv\s+tool\s+install\b|\b(cargo|go|gem)\s+install\b"#),
        rule("remote-package-run", "Run a package fetched on the fly", "临时下载并运行软件包",
             .notice, .supplyChain, commands: ["npx", "uvx", "bunx"], enabled: false),
        rule("upload-file", "Upload a local file", "上传本地文件", .notice, .network,
             scope: .path, commands: ["curl"], access: .read,
             exclude: [#"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])"#]),
        rule("remote-copy", "Copy files to or from a remote host", "与远端主机互传文件", .notice,
             .network, commands: ["scp", "sftp", "rsync"],
             pattern: #"\s[\w.-]+@[\w.-]+:|\s[\w.-]+:[/~]"#),
        rule("tunnel", "Open a tunnel or a listening socket", "建立隧道或监听端口", .notice,
             .network, commands: ["ngrok", "cloudflared", "nc", "ncat", "socat"],
             pattern: #"\bngrok\b|\bcloudflared\s+tunnel\b|\b(nc|ncat)\s.*-[a-z]*l|\bsocat\b.*listen"#),
        rule("mcp-send-message", "MCP tool that sends a message", "MCP 发送消息", .notice, .mcp,
             kinds: [.mcp], scope: .tool,
             pattern: #"\.[^.]*(send[-_]?(message|email|mail|dm)|schedule[-_]message|post[-_]message)[^.]*$"#),
        rule("mcp-execute", "MCP tool that deploys, merges or approves", "MCP 发布 / 合并 / 审批",
             .notice, .mcp, kinds: [.mcp], scope: .tool,
             pattern: #"\.[^.]*(deploy|publish|merge|transition|approve|backfill|clear_task|mark_(task|dag))[^.]*$"#),
    ] }

    /// Bumped whenever a built-in rule's matching changes, so stored history is evaluated again
    /// even if the rule list hashes the same
    public static let builtinVersion = 6

    private static let lock = NSLock()
    private static var installed: RiskRuleSet?

    /// The rule set every evaluation uses. Built-in rules until something else is installed.
    public static var current: RiskRuleSet {
        lock.lock()
        defer { lock.unlock() }
        if let installed { return installed }
        let builtin = RiskRuleSet(rules: builtinRules)
        installed = builtin
        return builtin
    }

    public static func install(_ ruleSet: RiskRuleSet) {
        lock.lock()
        installed = ruleSet
        lock.unlock()
    }

    /// Identifies the rules history was last evaluated with
    public static var fingerprint: String {
        "\(builtinVersion):\(current.fingerprint)"
    }

    /// Display title of a rule id stored with an audit record; nil for a rule that no longer exists
    public static func title(forRule id: String) -> String? {
        current.rule(id: id)?.title.text
    }

    /// Assess one operation's risk. Returns the first match (highest level, earliest in rule
    /// order), or nil if none.
    public static func evaluate(
        kind: ToolKind, tool: String, detail: String, cwd: String? = nil,
        source: AgentSource? = nil, home: String = NSHomeDirectory()
    ) -> RiskHit? {
        current.evaluate(
            kind: kind, tool: tool, detail: detail, cwd: cwd, source: source, home: home)
    }
}

/// Alert throttling: the same (session, rule) passes only once per cooldown, so repeated sudo
/// doesn't flood the screen. Pure logic (now is injected), unit-testable.
public struct RiskAlertThrottle: Sendable {
    private let cooldown: TimeInterval
    private let maxEntries: Int
    private var lastFired: [String: Date] = [:]

    public init(cooldown: TimeInterval = 600, maxEntries: Int = 256) {
        self.cooldown = cooldown
        self.maxEntries = maxEntries
    }

    /// `cooldown` overrides the default for this call (critical alerts repeat sooner)
    public mutating func shouldAlert(
        sessionId: String, ruleId: String, now: Date, cooldown override: TimeInterval? = nil
    ) -> Bool {
        let key = sessionId + "\u{1}" + ruleId
        if let last = lastFired[key], now.timeIntervalSince(last) < (override ?? cooldown) {
            return false
        }
        // Simple growth guard: clear everything past the cap (very few keys, so resetting is cheap)
        if lastFired.count >= maxEntries {
            lastFired.removeAll(keepingCapacity: true)
        }
        lastFired[key] = now
        return true
    }
}
