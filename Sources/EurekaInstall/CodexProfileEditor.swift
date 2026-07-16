import Foundation

/// Codex 的「agent」= config.toml 里的 `[profiles.<name>]` 预设
/// （model / 推理强度 / persona / 审批策略）。仅覆盖常用键，未识别键在 upsert 时原样保留。
public struct CodexProfile: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var model: String?
    public var reasoningEffort: String?   // model_reasoning_effort
    public var personality: String?
    public var approvalPolicy: String?    // approval_policy

    public init(
        name: String, model: String? = nil, reasoningEffort: String? = nil,
        personality: String? = nil, approvalPolicy: String? = nil
    ) {
        self.name = name
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.personality = personality
        self.approvalPolicy = approvalPolicy
    }
}

/// `~/.codex/config.toml` 的 profile 段编辑器：行级读/写/删，**不整体重序列化 TOML**。
/// 关键不变量：profile 是 `[table]` 段，追加到文件尾安全（不同于顶层 `notify` 键的插入约束）；
/// upsert 只改段内被管理的键、保留其它行；因此 mcp_servers / notify / 其它 profile 均不受影响。
public enum CodexProfileEditor {
    /// 被管理的键（写入顺序即此顺序）
    static let managedKeys = ["model", "model_reasoning_effort", "personality", "approval_policy"]

    // MARK: - 读

    public static func read(from toml: String) -> [CodexProfile] {
        let lines = toml.components(separatedBy: "\n")
        var profiles: [CodexProfile] = []
        var index = 0
        while index < lines.count {
            guard let name = profileName(fromHeader: lines[index]) else { index += 1; continue }
            var profile = CodexProfile(name: name)
            index += 1
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { break }  // 下一个 table，段结束
                index += 1
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                      let (key, rawValue) = splitKeyValue(trimmed) else { continue }
                let value = unquote(rawValue)
                switch key {
                case "model": profile.model = value
                case "model_reasoning_effort": profile.reasoningEffort = value
                case "personality": profile.personality = value
                case "approval_policy": profile.approvalPolicy = value
                default: break
                }
            }
            profiles.append(profile)
        }
        return profiles.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - 写

    /// 段存在 → 改/删段内被管理键、保留其它行；不存在 → 在文件尾追加新段
    public static func upsert(into toml: String, profile: CodexProfile) -> String {
        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")
        let managed = managedPairs(profile)

        if let start = lines.firstIndex(where: { profileName(fromHeader: $0) == profile.name }) {
            var end = start + 1
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }

            var newBody: [String] = []
            var written = Set<String>()
            for line in lines[(start + 1)..<end] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let (key, _) = splitKeyValue(trimmed), managedKeys.contains(key) {
                    if let value = managed[key] {  // 改：写新值；nil：删（跳过）
                        newBody.append(keyLine(key, value))
                        written.insert(key)
                    }
                } else {
                    newBody.append(line)  // 未识别键 / 注释 / 空行原样保留
                }
            }
            for key in managedKeys where managed[key] != nil && !written.contains(key) {
                newBody.append(keyLine(key, managed[key]!))
            }
            lines.replaceSubrange((start + 1)..<end, with: newBody)
            return lines.joined(separator: "\n")
        }

        // 不存在：文件尾追加新段
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if !lines.isEmpty { lines.append("") }
        lines.append(headerLine(for: profile.name))
        for key in managedKeys where managed[key] != nil {
            lines.append(keyLine(key, managed[key]!))
        }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    public static func remove(from toml: String, name: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { profileName(fromHeader: $0) == name }) else {
            return toml
        }
        var end = start + 1
        while end < lines.count,
              !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
        var removeStart = start
        // 顺带吃掉段前一个空行，避免堆积空行
        if removeStart > 0, lines[removeStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            removeStart -= 1
        }
        lines.removeSubrange(removeStart..<end)
        return lines.joined(separator: "\n")
    }

    // MARK: - 内部

    private static func managedPairs(_ profile: CodexProfile) -> [String: String] {
        var pairs: [String: String] = [:]
        func set(_ key: String, _ value: String?) {
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty { pairs[key] = value }
        }
        set("model", profile.model)
        set("model_reasoning_effort", profile.reasoningEffort)
        set("personality", profile.personality)
        set("approval_policy", profile.approvalPolicy)
        return pairs
    }

    /// 解析 profile 段头 `[profiles.<name>]`（裸名或带引号名）；非该形态返回 nil。
    /// 裸名含点视为子表（如 `[profiles.x.mcp_servers]`），不当作 profile。
    static func profileName(fromHeader line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("profiles.") else { return nil }
        var name = String(inner.dropFirst("profiles.".count))
        if name.count >= 2, name.first == "\"", name.last == "\"" {
            return String(name.dropFirst().dropLast())
        }
        if name.contains(".") { return nil }  // 子表，非 profile 本身
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func splitKeyValue(_ trimmed: String) -> (key: String, value: String)? {
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func keyLine(_ key: String, _ value: String) -> String {
        "\(key) = \"\(escape(value))\""
    }

    private static func headerLine(for name: String) -> String {
        let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return bare && !name.isEmpty
            ? "[profiles.\(name)]"
            : "[profiles.\"\(escape(name))\"]"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
