import Foundation

/// ~/.codex/config.toml 的 notify 安装器（行级编辑，不整体重写 TOML）。
/// 关键不变量：notify 是顶层键，必须插在首个 `[table]` 行之前——
/// 追加到文件尾会落进最后一个 table 内变成非法配置。
public enum CodexNotifyInstaller {
    static let marker = "eureka-relay"

    public static func notifyLine(relayPath: String) -> String {
        "notify = [\"\(relayPath)\", \"codex-notify\"]"
    }

    public static func install(into toml: String, relayPath: String) throws -> String {
        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")

        if let existing = topLevelNotifyIndex(lines) {
            guard lines[existing].contains(marker) else {
                throw InstallError.foreignConfig(
                    "config.toml 已有他人的 notify 配置：\(lines[existing].trimmingCharacters(in: .whitespaces))\n"
                        + "请手动改为：\(notifyLine(relayPath: relayPath))")
            }
            lines[existing] = notifyLine(relayPath: relayPath)
            return lines.joined(separator: "\n")
        }

        // 插入点：首个 table 头之前（跳过紧贴 table 的空行，保持原有空行归属 table）
        var insertAt = lines.count
        if let firstTable = firstTableIndex(lines) {
            insertAt = firstTable
            while insertAt > 0,
                  lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
        }
        lines.insert(notifyLine(relayPath: relayPath), at: insertAt)
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    public static func uninstall(from toml: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        if let index = topLevelNotifyIndex(lines), lines[index].contains(marker) {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }

    public static func status(of toml: String) -> InstallStatus {
        let lines = toml.components(separatedBy: "\n")
        guard let index = topLevelNotifyIndex(lines) else { return .none }
        return lines[index].contains(marker) ? .installed : .foreign
    }

    // MARK: - 内部

    /// 顶层区域（首个 table 之前）的 notify 赋值行
    private static func topLevelNotifyIndex(_ lines: [String]) -> Int? {
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }  // 进入 table 区域，停止
            guard trimmed.hasPrefix("notify") else { continue }
            let rest = trimmed.dropFirst("notify".count).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("=") { return index }
        }
        return nil
    }

    private static func firstTableIndex(_ lines: [String]) -> Int? {
        lines.firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }
    }
}
