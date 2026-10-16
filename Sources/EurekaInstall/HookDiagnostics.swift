import EurekaKit
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
    /// Our entries still name the relay by its pre-0.36 file name at the stable directory.
    /// They keep working (the old name is a symlink), and since the path is our own,
    /// rewriting them is safe to do automatically.
    case legacyRelayName(found: [String])
    /// 配置引用的 relay 不存在或不可执行 → 所有事件静默丢失，最难自己发现的一种
    case relayMissing(path: String)
    /// 该键已被他人占用且只能有一个（Codex 的顶层 notify）→ 拒绝自动改
    case foreignOccupied(detail: String)
    /// The single-slot key is taken by another program but its value is understood, so
    /// installing wraps it: the relay forwards to the original command, which keeps working
    /// (Codex's top-level notify). `owner` is the short name of that program.
    case chainable(owner: String)
    /// 配置结构不认识（如 settings.json 不是合法 JSON）→ 拒绝写入
    case unparseable(reason: String)

    /// 一切正常
    public var isHealthy: Bool { self == .installed }

    /// 是否**禁止**自动写入。自动更新遇到这些必须整体跳过并提示，
    /// 而不是拿一个我们没看懂的配置去猜着改。
    public var blocksAutomaticWrite: Bool {
        switch self {
        case .driftedPath, .unparseable, .foreignOccupied: return true
        case .notInstalled, .installed, .stale, .legacyRelayName, .relayMissing, .chainable:
            return false
        }
    }

    /// 是否算"用户已经同意装过"（决定自动更新要不要管它）
    public var isInstalledInSomeForm: Bool {
        switch self {
        case .installed, .stale, .legacyRelayName, .driftedPath, .relayMissing: return true
        case .notInstalled, .unparseable, .foreignOccupied, .chainable: return false
        }
    }

    /// 严重程度，UI 用它决定颜色
    public enum Severity: Sendable { case ok, info, warning, error }

    public var severity: Severity {
        switch self {
        case .installed: return .ok
        case .notInstalled, .legacyRelayName, .chainable: return .info
        case .stale, .driftedPath: return .warning
        case .relayMissing, .unparseable, .foreignOccupied: return .error
        }
    }

    public var label: String {
        switch self {
        case .notInstalled: return L10n.text("Not installed", zhHans: "未安装")
        case .installed: return L10n.text("Installed", zhHans: "已安装")
        case .stale, .legacyRelayName: return L10n.text("Update required", zhHans: "需更新")
        case .driftedPath: return L10n.text("Path no longer valid", zhHans: "路径已失效")
        case .relayMissing: return L10n.text("Relay missing", zhHans: "relay 缺失")
        case .foreignOccupied: return L10n.text("Used by another program", zhHans: "已被他人占用")
        case .chainable: return L10n.text("Can chain installation", zhHans: "可串联安装")
        case .unparseable: return L10n.text("Cannot parse configuration", zhHans: "配置无法解析")
        }
    }

    /// 给用户看的解释：说清发生了什么、后果是什么、我们会/不会做什么
    public var detail: String? {
        switch self {
        case .notInstalled, .installed:
            return nil
        case .stale(let missing):
            return L10n.format("Missing events: %@. Click “Update” to add them.", zhHans: "缺少事件：%@。点「更新」补齐。", String(missing.joined(separator: L10n.text(", ", zhHans: "、"))))
        case .driftedPath(let found):
            return L10n.text("The configuration does not point to the stable path; events may not arrive:\n", zhHans: "配置指向的不是稳定路径，事件可能收不到：\n")
                + found.joined(separator: "\n")
                + L10n.text("\nTo preserve your manual changes, this will not be fixed automatically. Click “Repair” to use the stable path.", zhHans: "\n为避免覆盖你的手改内容，不会自动修正 —— 点「修复」改为稳定路径。")
        case .legacyRelayName:
            return L10n.format("The configuration still references the old name %@ (kept as a link to the new relay;", zhHans: "配置仍引用旧名 %@（旧名保留为指向新转发器的链接，", String(RelayIdentity.legacyBinaryName))
                + L10n.format(" events still arrive normally). Click “Update” to use %@.", zhHans: "事件照常收到）。点「更新」改用 %@。", String(RelayIdentity.binaryName))
        case .chainable(let owner):
            return L10n.format("Only one notify is allowed; it is currently used by %@. When enabled,", zhHans: "notify 只能有一个，现由 %@ 使用。打开开关后改为先由 ", String(owner))
                + L10n.format(" %@ forwards the notification unchanged to %@ before recording the event, so both work;", zhHans: "%@ 把通知原样转给 %@、再记录事件，两者同时生效；", String(RelayIdentity.binaryName), String(owner))
                + L10n.text(" disabling restores the original notify.", zhHans: "关闭开关会恢复原来的 notify。")
        case .relayMissing(let path):
            return L10n.format("The configured relay does not exist or is not executable:\n%@\n", zhHans: "配置引用的转发器不存在或不可执行：\n%@\n", String(path))
                + L10n.text("All events will be silently discarded. Click “Install/Update” again to recreate it.", zhHans: "所有事件都会被静默丢弃。重新点「安装/更新」可重建。")
        case .foreignOccupied(let detail):
            return detail
        case .unparseable(let reason):
            return L10n.format("%@\nWriting is refused to avoid damaging the file. Please fix it manually before installing.", zhHans: "%@\n拒绝写入以免破坏文件，请先手动修好再回来安装。", String(reason))
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
/// - `"…/lululumei-relay" claude-hook`（我们自己，路径含空格必须双引号）
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
