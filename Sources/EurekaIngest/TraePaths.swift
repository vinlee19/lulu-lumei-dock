import Foundation

/// Trae 的**两套安装**：CN 版与国际版是各自独立的应用，数据目录完全不互通，
/// 但在 Eureka 里合并成同一个来源 `.trae`（同一个品牌、两个渠道）。
///
/// | | dotfile 目录 | Application Support |
/// |---|---|---|
/// | CN（实勘 3.3.84） | `~/.trae-cn` | `~/Library/Application Support/Trae CN` |
/// | 国际版（实勘 3.5.35） | `~/.trae` | `~/Library/Application Support/Trae` |
///
/// 名字来自各自 `product.json` 的 `dataFolderName` / `nameShort`，不是猜的。
///
/// **能力差异**（本机实勘，不要想当然两版对称）：
/// - hooks：**只有 CN 有** —— 只有 CN 的 `libai_agent.dylib` 里有
///   `src/domain/hooks/{config/parser,executor/*,instance/trigger}.rs`；
/// - 记忆库：**只有 CN 有**（`~/.trae-cn/memory`）；
/// - 技能 / 规则 / 计划：两版都有。
///
/// ⚠️ **会话正文、token、限额一律拿不到。** 会话全部在
/// `<appSupport>/ModularData/ai-agent/database.db` 一个库里，而那个库是 SQLCipher
/// 加密的（文件头 16 字节是随机 salt，`sqlite3` 直接报 "file is not a database"），
/// 全机也没有任何明文转录。会话的标题/时间只能从明文记忆库反推（见
/// `TraeSessionIndexer`），实时活动只能靠 hooks（见 `TraeHooksInstaller`）。
///
/// ⚠️ **凭据红线。** `<dataFolder>/trae-jwt-token` 是 JWT，`<dataFolder>/mcp.json`
/// 可能带 API key，`<appSupport>/{Cookies,ModularData/ai-agent/database.db}` 含鉴权与
/// 会话内容。**任何遍历都只准走本文件明确给出的子根，绝不遍历 `dataFolder` 或
/// `appSupport` 本身**（同 CLAUDE.md 里 Cursor `state.vscdb` 那条的性质）。
public enum TraePaths {
    /// 两个发行渠道。CN 在前：它是功能更全的那个（hooks + 记忆库都只有它有）。
    public enum Channel: String, CaseIterable, Sendable {
        case cn
        case intl

        /// home 下的 dotfile 目录名（= product.json 的 `dataFolderName`）
        var dotDirName: String {
            switch self {
            case .cn: return ".trae-cn"
            case .intl: return ".trae"
            }
        }

        /// Application Support 下的目录名（= product.json 的 `nameShort`）
        var appSupportDirName: String {
            switch self {
            case .cn: return "Trae CN"
            case .intl: return "Trae"
            }
        }

        /// 命令行启动器（两个都在 `/usr/local/bin`，由客户端自己装）
        public var cliCommand: String {
            switch self {
            case .cn: return "trae-cn"
            case .intl: return "trae"
            }
        }

        var homeEnvKey: String {
            switch self {
            case .cn: return "EUREKA_TRAE_HOME"
            case .intl: return "EUREKA_TRAE_INTL_HOME"
            }
        }

        var appSupportEnvKey: String {
            switch self {
            case .cn: return "EUREKA_TRAE_APP_SUPPORT"
            case .intl: return "EUREKA_TRAE_INTL_APP_SUPPORT"
            }
        }
    }

    // MARK: - 两个根

    /// dotfile 主目录（env `EUREKA_TRAE_HOME` / `EUREKA_TRAE_INTL_HOME` > `~/.trae-cn` / `~/.trae`）
    public static func configHome(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment[channel.homeEnvKey], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(channel.dotDirName, isDirectory: true)
    }

    /// Application Support 主目录（IDE 状态与加密会话库都在这下面）
    public static func appSupportHome(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment[channel.appSupportEnvKey], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/\(channel.appSupportDirName)", isDirectory: true)
    }

    /// 本机实际装了哪些渠道。判据是 dotfile 目录存在；env 覆盖过的渠道**无条件算装了**
    /// （测试全靠临时目录，不能因为目录名不像就被过滤掉）。
    public static func installedChannels(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [Channel] {
        Channel.allCases.filter { channel in
            if let custom = environment[channel.homeEnvKey], !custom.isEmpty { return true }
            return fileManager.fileExists(
                atPath: configHome(channel, environment: environment).path)
        }
    }

    // MARK: - hooks（只有 CN 支持）

    /// 全局 hooks 配置 `~/.trae-cn/hooks.json`。
    /// 路径出处：Trae 前端资产表 `{assetType:"hook",projectRelPath:".trae/hooks.json",
    /// globalRelPath:"hooks.json"}`，其中 global 根 = `pathService.userHome` +
    /// `productService.dataFolderName`（= `.trae-cn`）。
    public static func hooksConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(.cn, environment: environment)
            .appendingPathComponent("hooks.json", isDirectory: false)
    }

    /// 项目级 hooks 配置 `<repo>/.trae/hooks.json`（本 app 只读它做诊断，从不改）
    public static func projectHooksConfig(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/hooks.json", isDirectory: false)
    }

    // MARK: - 技能

    /// 用户技能根 `<dataFolder>/skills/<name>/SKILL.md`（标准 Claude 式布局：
    /// YAML frontmatter 的 `name` / `description` + 正文）
    public static func skillsRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// 内置技能根 `<dataFolder>/builtin_skills`（`TRAE-code-review` 等，随客户端分发 → 只读）
    public static func builtinSkillsRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("builtin_skills", isDirectory: true)
    }

    /// 另一处内置技能根 `<dataFolder>/builtin/global/skills`（`TRAE-computer-use` 等，
    /// 与 `builtin_skills` 并存且内容不同 —— 两处都要扫，只扫一处会漏一半）
    public static func builtinGlobalSkillsRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("builtin/global/skills", isDirectory: true)
    }

    /// 项目级技能根 `<repo>/.trae/skills`
    public static func projectSkillsRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/skills", isDirectory: true)
    }

    /// 全部已装渠道的**可写**用户技能根（新建技能落这里）
    public static func userSkillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        installedChannels(environment: environment, fileManager: fileManager)
            .map { skillsRoot($0, environment: environment) }
    }

    /// 全部已装渠道的**只读**内置技能根（两种 builtin 布局都收）
    public static func bundledSkillsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        installedChannels(environment: environment, fileManager: fileManager)
            .flatMap {
                [
                    builtinSkillsRoot($0, environment: environment),
                    builtinGlobalSkillsRoot($0, environment: environment),
                ]
            }
    }

    // MARK: - 记忆库（只有 CN 有）

    /// 记忆库根 `~/.trae-cn/memory`
    public static func memoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(.cn, environment: environment)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// 全局用户画像 `~/.trae-cn/memory/user_profile.md`（Trae 自己写的 → 记忆，不是指令）
    public static func userProfileFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        memoryRoot(environment: environment)
            .appendingPathComponent("user_profile.md", isDirectory: false)
    }

    /// 项目记忆根 `~/.trae-cn/memory/projects`。
    /// 子目录名形如 `-Users-wl-xiao-vinlee-workspace-lerobot--p2-832ae42141a2828b9304`
    /// —— 正斜杠编码 + `--p<N>-<hash>` 后缀，**同 Claude 一样不可逆**（`-` 既可能来自
    /// `/` 也可能来自 `.`/`_`/原有连字符），只能正向编码已知仓库根再匹配。
    public static func memoryProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        memoryRoot(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    // MARK: - 指令（用户手写规则）

    /// 全局用户规则单文件 `<dataFolder>/user_rules.md`（Trae 前端叫 `legacyUserRuleFilePath`）
    public static func userRulesFile(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("user_rules.md", isDirectory: false)
    }

    /// 全局用户规则目录 `<dataFolder>/user_rules/*.md`（新版布局，与单文件并存）
    public static func userRulesDir(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(channel, environment: environment)
            .appendingPathComponent("user_rules", isDirectory: true)
    }

    /// 项目规则目录 `<repo>/.trae/rules/*.md`（含旧的单文件名 `project_rules.md`）
    public static func projectRulesRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/rules", isDirectory: true)
    }

    // MARK: - 计划

    /// 计划文档目录 `<repo>/.trae/documents`（`plan_<yyyyMMdd>_<HHmmss>.md`，本就是 markdown）
    public static func projectDocumentsRoot(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".trae/documents", isDirectory: true)
    }

    // MARK: - IDE 状态（只用来反查 cwd，绝不进备份）

    /// 工作区存储根 `<appSupport>/User/workspaceStorage`
    /// （每 workspace 一个 hash 目录，`workspace.json` 的 `folder` 字段 = cwd）
    public static func workspaceStorageRoot(
        _ channel: Channel,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        appSupportHome(channel, environment: environment)
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }

    /// 全部已装渠道的工作区存储根。**只读 `workspace.json` 一个字段**（cwd 反查），
    /// 同目录下的 `state.vscdb` 不碰、也绝不进备份。
    public static func workspaceStorageRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        installedChannels(environment: environment, fileManager: fileManager)
            .map { workspaceStorageRoot($0, environment: environment) }
    }

    // 刻意不提供的路径，省得后人以为漏了：
    // - `<dataFolder>/commands`（斜杠命令）：本 app 对**任何**来源都不索引斜杠命令
    //   （Claude 的 `~/.claude/commands` 也没索引），单给 Trae 开一个面会不一致。
    // - `<dataFolder>/mcp.json`、`<dataFolder>/trae-jwt-token`：凭据，见文件头红线。
    // - `<appSupport>/ModularData/ai-agent/database.db`：加密会话库，读不了也不能备份。
    // - `<appSupport>/logs/*/Modular/ai-agent_*_stdout.log`：内部 Rust tracing 日志，
    //   100MB/1.5h、目录名每次启动变、格式随版本改 —— 明确不作为数据源。
}
