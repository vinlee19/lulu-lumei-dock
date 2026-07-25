import Foundation

/// `~/.hermes/config.yaml` 里 `skills.disabled` 名单的编辑器（技能启停）。
///
/// 为什么不像其它 agent 那样「把技能目录挪走」来禁用：Hermes 用 `.bundled_manifest`
/// （name:md5）+ curator 记账管理内置技能，目录一动就会被判成用户篡改 / 技能丢失，
/// 所以唯一安全的开关是往 `skills.disabled` 里增删技能的 frontmatter `name`。
///
/// 实现方式与 `CodexProfileEditor` 对齐：**纯文本进 / 纯文本出的行级手术**，不引 YAML 依赖、
/// 不整体重序列化；注释、键顺序、缩进、其它块全部原样保留。已有列表是块式（`- a`）还是
/// 流式（`[a, b]`）就沿用原风格，绝不互相改写。
///
/// 约定：删掉最后一项后**保留 `disabled: []`**（而不是删掉 `disabled:` 键）——裸键
/// `disabled:` 在 YAML 里是 null，Hermes 侧读出来不是列表，容易触发它自己的类型分支。
public enum HermesConfigEditor {
    // MARK: - 读

    /// 解析 `skills.disabled`。缺 `skills:` 块、缺 `disabled:` 键、`[]`、null 均返回空集合；
    /// 同时兼容流式与块式两种列表写法，并剥掉引号与行尾注释。
    public static func disabledSkills(from yaml: String) -> Set<String> {
        let lines = yaml.components(separatedBy: "\n")
        guard case .found(let block) = locateSkillsBlock(lines),
              let key = locateDisabled(lines, in: block) else { return [] }
        if !key.items.isEmpty {
            return Set(key.items.map { itemName(lines[$0]) }.filter { !$0.isEmpty })
        }
        return Set(flowSegments(key.value).map(unquote))
    }

    // MARK: - 写

    /// 增删一个技能名，返回完整新文档。幂等：重复禁用 == 禁用一次；启用未禁用项是空操作。
    /// 遇到无法安全手术的形态（非空内联映射 `skills: {…}`、跨行流式列表）原样返回，绝不猜写。
    public static func setSkillDisabled(_ name: String, disabled: Bool, in yaml: String) -> String {
        let target = name.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return yaml }
        var lines = yaml.components(separatedBy: "\n")

        let block: SkillsBlock
        switch locateSkillsBlock(lines) {
        case .found(let hit): block = hit
        case .unsupported: return yaml  // 非空内联映射：不猜写，也绝不追加出重复 `skills:` 键
        case .absent:
            // 连 `skills:` 块都没有：启用是空操作，禁用则在文档尾部补一个顶层块
            return disabled ? appendSkillsBlock(to: yaml, name: target) : yaml
        }

        guard let key = locateDisabled(lines, in: block) else {
            guard disabled else { return yaml }
            if block.headerIsFlowEmpty {  // `skills: {}` → 先退化成块映射才能挂子键
                let comment = splitComment(lines[block.header]).comment
                lines[block.header] = "skills:" + (comment.isEmpty ? "" : "  " + comment)
            }
            let indent = String(repeating: " ", count: block.childIndent)
            lines.insert(indent + "disabled: [\(render(target))]", at: block.header + 1)
            return lines.joined(separator: "\n")
        }

        if key.items.isEmpty {
            // 流式 / 标量 / 空值：只重写这一行的方括号内容，已有项的原文与引号保持不变
            guard let edited = editedFlowLine(lines[key.index], name: target, disabled: disabled)
            else { return yaml }
            lines[key.index] = edited
            return lines.joined(separator: "\n")
        }

        // 块式：只增删 `- item` 行
        let existing = key.items.map { (index: $0, name: itemName(lines[$0])) }
        if disabled {
            guard !existing.contains(where: { $0.name == target }) else { return yaml }
            let indent = String(repeating: " ", count: key.itemIndent)
            lines.insert(indent + "- " + render(target), at: key.items.upperBound)
            return lines.joined(separator: "\n")
        }
        let doomed = existing.filter { $0.name == target }.map(\.index)
        guard !doomed.isEmpty else { return yaml }
        if doomed.count == existing.filter({ !$0.name.isEmpty }).count {
            let comment = splitComment(lines[key.index]).comment
            let indent = String(repeating: " ", count: key.indent)
            lines[key.index] = indent + "disabled: []" + (comment.isEmpty ? "" : "  " + comment)
        }
        for index in doomed.sorted(by: >) { lines.remove(at: index) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 定位

    private struct SkillsBlock {
        let header: Int              // `skills:` 所在行
        let headerIsFlowEmpty: Bool  // `skills: {}`
        let children: Range<Int>     // 块内子行（含夹在中间的注释 / 空行）
        let childIndent: Int         // 子键缩进（真实文件是 2）
    }

    private struct DisabledKey {
        let index: Int            // `disabled:` 所在行
        let indent: Int
        let value: String         // 冒号右侧（已剥注释、已 trim）
        let items: Range<Int>     // 块式 `- x` 行区间；流式为空区间
        let itemIndent: Int
    }

    private enum SkillsLookup {
        case found(SkillsBlock)
        case unsupported  // `skills: {a: 1}` 这类非空内联映射，行级手术做不了
        case absent
    }

    /// 找顶层 `skills:`（缩进必须为 0，避免撞到别的块里的同名键）
    private static func locateSkillsBlock(_ lines: [String]) -> SkillsLookup {
        for (index, line) in lines.enumerated() {
            guard indentWidth(line) == 0 else { continue }
            let content = splitComment(line).content.trimmingCharacters(in: .whitespaces)
            guard let (key, value) = splitKeyValue(content), key == "skills" else { continue }
            guard value.isEmpty || value == "{}" else { return .unsupported }

            var end = index + 1
            while end < lines.count {
                let raw = lines[end].trimmingCharacters(in: .whitespaces)
                if !raw.isEmpty, !raw.hasPrefix("#"), indentWidth(lines[end]) == 0 { break }
                end += 1
            }
            let children = (index + 1)..<end
            let childIndent = children.first { !isBlankOrComment(lines[$0]) }
                .map { indentWidth(lines[$0]) } ?? 2
            return .found(SkillsBlock(
                header: index, headerIsFlowEmpty: value == "{}",
                children: children, childIndent: childIndent))
        }
        return .absent
    }

    /// 只在 skills 块内、且缩进恰好等于子键缩进处找 `disabled:`。
    /// 这样 `platform_disabled:` 及其子映射（`telegram: [...]`）都不会被误当成目标键。
    private static func locateDisabled(_ lines: [String], in block: SkillsBlock) -> DisabledKey? {
        for index in block.children where indentWidth(lines[index]) == block.childIndent {
            let content = splitComment(lines[index]).content.trimmingCharacters(in: .whitespaces)
            guard let (key, value) = splitKeyValue(content), key == "disabled" else { continue }

            var cursor = index + 1
            var lastItem = index
            while cursor < block.children.upperBound {
                if isBlankOrComment(lines[cursor]) { cursor += 1; continue }
                let raw = lines[cursor].trimmingCharacters(in: .whitespaces)
                // 块式序列允许与键同缩进（`disabled:` 下面直接 `- a`），故用 >= 判断
                guard raw.hasPrefix("-"), indentWidth(lines[cursor]) >= block.childIndent
                else { break }
                lastItem = cursor
                cursor += 1
            }
            let items = (index + 1)..<(lastItem == index ? index + 1 : lastItem + 1)
            let firstItem = items.first { lines[$0].trimmingCharacters(in: .whitespaces)
                .hasPrefix("-") }
            return DisabledKey(
                index: index, indent: block.childIndent, value: value, items: items,
                itemIndent: firstItem.map { indentWidth(lines[$0]) } ?? block.childIndent + 2)
        }
        return nil
    }

    // MARK: - 行改写

    /// 流式列表行的增删；无需改动或形态不支持时返回 nil
    private static func editedFlowLine(
        _ line: String, name: String, disabled: Bool
    ) -> String? {
        let (content, comment) = splitComment(line)
        guard let (_, value) = splitKeyValue(content.trimmingCharacters(in: .whitespaces))
        else { return nil }
        if value.hasPrefix("["), !value.hasSuffix("]") { return nil }  // 跨行流式列表：不动

        var segments = flowSegments(value)
        let hit = segments.contains { unquote($0) == name }
        if disabled {
            guard !hit else { return nil }
            segments.append(render(name))
        } else {
            guard hit else { return nil }
            segments.removeAll { unquote($0) == name }
        }
        let indent = String(repeating: " ", count: indentWidth(content))
        return indent + "disabled: [" + segments.joined(separator: ", ") + "]"
            + (comment.isEmpty ? "" : "  " + comment)
    }

    /// `skills:` 整块缺失：追加到文档尾部（新顶层键，不影响任何已有块）
    private static func appendSkillsBlock(to yaml: String, name: String) -> String {
        var lines = yaml.isEmpty ? [] : yaml.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        lines.append("skills:")
        lines.append("  disabled: [\(render(name))]")
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    // MARK: - 文本工具

    private static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let raw = line.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty || raw.hasPrefix("#")
    }

    /// 按引号状态切出行尾注释，注释原样带回，保证「除目标键外字节不变」
    private static func splitComment(_ line: String) -> (content: String, comment: String) {
        var inSingle = false
        var inDouble = false
        for index in line.indices {
            switch line[index] {
            case "'" where !inDouble: inSingle.toggle()
            case "\"" where !inSingle: inDouble.toggle()
            case "#" where !inSingle && !inDouble:
                return (String(line[..<index]), String(line[index...]))
            default: break
            }
        }
        return (line, "")
    }

    private static func splitKeyValue(_ trimmed: String) -> (key: String, value: String)? {
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    /// `- foo  # 注释` → `foo`；非列表项行返回空串
    private static func itemName(_ line: String) -> String {
        let content = splitComment(line).content.trimmingCharacters(in: .whitespaces)
        guard content.hasPrefix("-") else { return "" }
        return unquote(String(content.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// 把 `[a, "b"]` / `[]` / `null` / 裸标量切成原文片段（**保留引号**，以便回写时不改动已有项）
    private static func flowSegments(_ value: String) -> [String] {
        var inner = value
        if inner.hasPrefix("["), inner.hasSuffix("]") {
            inner = String(inner.dropFirst().dropLast())
        }
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "null" || trimmed == "~" { return [] }

        // 逗号切分必须感知引号，否则 `["a, b", c]` 会被切坏（我们自己写引号名时也会踩到）
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for char in inner {
            switch char {
            case "'" where !inDouble: inSingle.toggle(); current.append(char)
            case "\"" where !inSingle: inDouble.toggle(); current.append(char)
            case "," where !inSingle && !inDouble: segments.append(current); current = ""
            default: current.append(char)
            }
        }
        segments.append(current)
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        guard first == "\"" else { return inner }  // 单引号里只有 '' 转义，技能名用不到
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// 纯 kebab / snake / 路径字符裸写，其它一律双引号（流式列表里逗号、方括号必须被引起来）
    private static func render(_ name: String) -> String {
        let plain = !name.isEmpty && name.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "/"
        }
        guard !plain else { return name }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
