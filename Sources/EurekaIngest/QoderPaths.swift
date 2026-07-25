import Foundation

/// Qoder CLI（CN 版）的本地数据路径（默认 `~/.qoder-cn`，v1.1.5 实勘）。
/// 布局为 Claude 式：`projects/<cwd编码>/〈sessionId〉.jsonl`（Claude 式信封，
/// slug = cwd 把 `/` 换成 `-`）+ 伴随 `<sessionId>/subagents/agent-*.jsonl`；
/// 计划 `plans/<slug>.md`；记忆 `memories/<user-hash>/global/<category>/`。
/// CLI 二进制 `bin/qoderclicn/qoderclicn-<version>`（版本号在文件名里）。
/// ⚠️ `.auth/` 是凭据、`settings.json` 含 API key，任何备份/上传都不得纳入。
public enum QoderPaths {
    /// 配置主目录（env `EUREKA_QODER_HOME` > `QODER_CONFIG_DIR` > `~/.qoder-cn`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_QODER_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let custom = environment["QODER_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder-cn", isDirectory: true)
    }

    /// 会话根 `<home>/projects`（每项目一个 cwd 编码目录）
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 计划文档根 `<home>/plans`（plan 模式的 <slug>.md）
    public static func plansRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("plans", isDirectory: true)
    }

    /// 记忆根 `<home>/memories`（<user-hash>/global/<category>/）
    public static func memoriesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memories", isDirectory: true)
    }

    /// CLI 二进制 `<home>/bin/qoderclicn/qoderclicn-<version>`；
    /// 版本号在文件名里，glob 后取语义版本最高者；找不到返回 nil
    public static func cliBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let dir = configHome(environment: environment)
            .appendingPathComponent("bin/qoderclicn", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let prefix = "qoderclicn-"
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .max { lhs, rhs in
                compareVersions(
                    String(lhs.lastPathComponent.dropFirst(prefix.count)),
                    String(rhs.lastPathComponent.dropFirst(prefix.count))) == .orderedAscending
            }
    }

    /// 语义版本比较（数字段逐段比；非数字段按字典序兜底）
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let b = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "0"
            let y = i < b.count ? b[i] : "0"
            if let xi = Int(x), let yi = Int(y), xi != yi {
                return xi < yi ? .orderedAscending : .orderedDescending
            }
            if Int(x) == nil || Int(y) == nil, x != y {
                return String(x).compare(String(y))
            }
        }
        return .orderedSame
    }
}
