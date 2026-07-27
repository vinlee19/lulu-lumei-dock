import Foundation

/// 一个 hook 集成的**诊断**结论。
///
/// 比 `InstallStatus` 多出「异常」这一维：原来的 `status(of:)` 把配置坏掉、路径被改歪、
/// relay 不见了这几种情况一律显示成"未安装"，用户既不知道出了事、也不知道为什么没数据。
/// 这里把它们分开，并明确哪些情况**禁止**自动写入 —— 看不懂的配置绝不"帮忙修好"。
public enum HookDiagnosis: Equatable, Sendable {
    /// 没有自有条目（干净的未安装）
    case notInstalled
    /// 自有条目齐全，且指向稳定路径，relay 可执行
    case installed
    /// 只装了一部分受管事件 —— 通常是 app 升级后受管集合变大了，点更新即可
    case stale(missing: [String])
    /// 自有条目指向的**不是**稳定路径（被手改过，或残留旧 app-bundle 路径）。
    /// app 换位置/升级后这种链接会断，但配置看起来"装着"，属于隐蔽故障。
    case driftedPath(found: [String])
    /// 配置引用的 relay 不存在或不可执行 → 所有事件静默丢失，最难自己发现的一种
    case relayMissing(path: String)
    /// 该键已被他人占用且只能有一个（Codex 的顶层 notify）→ 拒绝自动改
    case foreignOccupied(detail: String)
    /// 配置结构不认识（如 settings.json 不是合法 JSON）→ 拒绝写入
    case unparseable(reason: String)

    /// 一切正常
    public var isHealthy: Bool { self == .installed }

    /// 是否**禁止**自动写入。自动更新遇到这些必须整体跳过并提示，
    /// 而不是拿一个我们没看懂的配置去猜着改。
    public var blocksAutomaticWrite: Bool {
        switch self {
        case .driftedPath, .unparseable, .foreignOccupied: return true
        case .notInstalled, .installed, .stale, .relayMissing: return false
        }
    }

    /// 是否算"用户已经同意装过"（决定自动更新要不要管它）
    public var isInstalledInSomeForm: Bool {
        switch self {
        case .installed, .stale, .driftedPath, .relayMissing: return true
        case .notInstalled, .unparseable, .foreignOccupied: return false
        }
    }

    /// 严重程度，UI 用它决定颜色
    public enum Severity: Sendable { case ok, info, warning, error }

    public var severity: Severity {
        switch self {
        case .installed: return .ok
        case .notInstalled: return .info
        case .stale, .driftedPath: return .warning
        case .relayMissing, .unparseable, .foreignOccupied: return .error
        }
    }

    public var label: String {
        switch self {
        case .notInstalled: return "未安装"
        case .installed: return "已安装"
        case .stale: return "需更新"
        case .driftedPath: return "路径已失效"
        case .relayMissing: return "relay 缺失"
        case .foreignOccupied: return "已被他人占用"
        case .unparseable: return "配置无法解析"
        }
    }

    /// 给用户看的解释：说清发生了什么、后果是什么、我们会/不会做什么
    public var detail: String? {
        switch self {
        case .notInstalled, .installed:
            return nil
        case .stale(let missing):
            return "缺少事件：\(missing.joined(separator: "、"))。点「更新」补齐。"
        case .driftedPath(let found):
            return "配置指向的不是稳定路径，事件可能收不到：\n"
                + found.joined(separator: "\n")
                + "\n为避免覆盖你的手改内容，不会自动修正 —— 点「修复」改为稳定路径。"
        case .relayMissing(let path):
            return "配置引用的转发器不存在或不可执行：\n\(path)\n"
                + "所有事件都会被静默丢弃。重新点「安装/更新」可重建。"
        case .foreignOccupied(let detail):
            return detail
        case .unparseable(let reason):
            return "\(reason)\n拒绝写入以免破坏文件，请先手动修好再回来安装。"
        }
    }
}

/// 同一个配置文件里**他人**的 hook 条目。只用于告知，绝不据此改动什么。
public struct ForeignHookReport: Equatable, Sendable {
    /// 涉及的事件名（Claude settings.json 与 Codex hooks.json 都是事件→条目数组）
    public var events: [String]
    /// 他人命令的可辨识短名（取首个 token 的 basename，不展示完整命令）
    public var tools: [String]

    public var isEmpty: Bool { tools.isEmpty }

    public init(events: [String] = [], tools: [String] = []) {
        self.events = events
        self.tools = tools
    }

    /// 合并两份配置的他人条目（Claude settings.json + Codex hooks.json 各扫一次）
    public func merging(_ other: ForeignHookReport) -> ForeignHookReport {
        ForeignHookReport(
            events: Array(Set(events).union(other.events)).sorted(),
            tools: Array(Set(tools).union(other.tools)).sorted())
    }
}

/// hook 命令行里的可执行路径解析。
///
/// 三种真实形态都要认（本机的 `otty-cli` 用的就是单引号，只认双引号会把尾引号带进短名）：
/// - `"…/eureka-relay" claude-hook`（我们自己，路径含空格必须双引号）
/// - `'/opt/homebrew/bin/otty-cli' hook`（他人，单引号）
/// - `/usr/local/bin/tool hook`（无引号）
enum HookCommandPath {
    private static let quotes: Set<Character> = ["\"", "'"]

    static func extract(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if quotes.contains(first) {
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: first) else { return nil }
            return String(rest[rest.startIndex..<end])
        }
        // 无引号：取首个 token，并去掉可能残留的成对引号
        return trimmed.components(separatedBy: " ").first.map { token in
            String(token.drop(while: { quotes.contains($0) })
                .reversed().drop(while: { quotes.contains($0) }).reversed())
        }
    }

    /// 展示用短名：只取最后一段，避免把完整命令（可能很长）贴到界面上
    static func shortName(of command: String) -> String? {
        guard let path = extract(from: command) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
