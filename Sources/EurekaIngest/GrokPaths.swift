import Foundation

/// grok CLI 的本地数据路径（`~/.grok`）。env `EUREKA_GROK_*` 覆盖，便于单测。
/// grok 把每个会话存成一个目录：`sessions/<url-encoded-cwd>/<session-uuid>/`，
/// 内含 `events.jsonl`（生命周期）、`summary.json`（元信息）、`updates.jsonl`（含上下文 token）、
/// `chat_history.jsonl`（消息）。技能/agent 是磁盘上的目录，和 Claude 同构。
public enum GrokPaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 配置主目录 `~/.grok`（env `EUREKA_GROK_HOME`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".grok", isDirectory: true)
    }

    /// 会话根 `~/.grok/sessions`（env `EUREKA_GROK_SESSIONS`）
    public static func sessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_SESSIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// 活跃会话清单 `~/.grok/active_sessions.json`
    public static func activeSessions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("active_sessions.json")
    }

    /// 模型目录缓存 `~/.grok/models_cache.json`（取 context_window 作 ctx% 分母）
    public static func modelsCache(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("models_cache.json")
    }

    /// 统一日志 `~/.grok/logs/unified.jsonl`（含 `billing: fetched credits config` 配额快照）。
    /// env `EUREKA_GROK_UNIFIED_LOG` 覆盖，便于单测。
    public static func unifiedLog(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_UNIFIED_LOG"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return configHome(environment: environment)
            .appendingPathComponent("logs/unified.jsonl")
    }

    /// 系统级技能根 `~/.grok/skills`（env `EUREKA_GROK_SKILLS`）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// 内置/携带技能根 `~/.grok/bundled/skills`（随 grok CLI 分发，只读）
    public static func bundledSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("bundled/skills", isDirectory: true)
    }

    /// 系统级 agent 根：用户 `~/.grok/agents` + 内置 `~/.grok/bundled/agents`。
    /// env `EUREKA_GROK_AGENTS` 覆盖时只用该单一根。
    public static func agentsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let custom = environment["EUREKA_GROK_AGENTS"], !custom.isEmpty {
            return [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        let base = configHome(environment: environment)
        return [
            base.appendingPathComponent("agents", isDirectory: true),
            base.appendingPathComponent("bundled/agents", isDirectory: true),
        ]
    }

    /// 跨会话记忆根 `~/.grok/memory`（env `EUREKA_GROK_MEMORY`；实验特性，可能不存在）
    public static func memoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_MEMORY"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("memory", isDirectory: true)
    }
}
