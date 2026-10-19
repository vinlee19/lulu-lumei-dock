import Foundation

/// Editor for the `skills.disabled` list in `~/.hermes/config.yaml` (enabling/disabling skills).
///
/// Why not disable by "moving the skill directory away" like other agents: Hermes manages bundled
/// skills with `.bundled_manifest` (name:md5) plus curator bookkeeping, so touching a directory
/// gets flagged as user tampering / a lost skill. The only safe switch is adding/removing the
/// skill's frontmatter `name` in `skills.disabled`.
///
/// Implementation mirrors `CodexProfileEditor`: **plain-text-in / plain-text-out line-level
/// surgery**, no YAML dependency, no whole-document re-serialisation; comments, key order,
/// indentation and other blocks are all preserved. Whether the existing list is block style (`- a`)
/// or flow style (`[a, b]`), its style is kept; one is never rewritten into the other.
///
/// Convention: removing the last item **keeps `disabled: []`** (rather than deleting the
/// `disabled:` key) - a bare `disabled:` is null in YAML, so Hermes doesn't read back a list and
/// may hit its own type branch.
public enum HermesConfigEditor {
    // MARK: - Read

    /// Parses `skills.disabled`. A missing `skills:` block, missing `disabled:` key, `[]` or null
    /// all return an empty set; supports both flow and block list styles, and strips quotes and
    /// trailing comments.
    public static func disabledSkills(from yaml: String) -> Set<String> {
        let lines = yaml.components(separatedBy: "\n")
        guard case .found(let block) = locateSkillsBlock(lines),
              let key = locateDisabled(lines, in: block) else { return [] }
        if !key.items.isEmpty {
            return Set(key.items.map { itemName(lines[$0]) }.filter { !$0.isEmpty })
        }
        return Set(flowSegments(key.value).map(unquote))
    }

    // MARK: - Write

    /// Adds/removes one skill name and returns the full new document. Idempotent: disabling twice
    /// == disabling once; enabling a non-disabled item is a no-op.
    /// Forms that can't be operated on safely (a non-empty inline map `skills: {…}`, a multi-line
    /// flow list) are returned unchanged, never guess-written.
    public static func setSkillDisabled(_ name: String, disabled: Bool, in yaml: String) -> String {
        let target = name.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return yaml }
        var lines = yaml.components(separatedBy: "\n")

        let block: SkillsBlock
        switch locateSkillsBlock(lines) {
        case .found(let hit): block = hit
        case .unsupported: return yaml  // Non-empty inline map: no guess-writes, no duplicate `skills:` key
        case .absent:
            // No `skills:` block at all: enabling is a no-op; disabling appends a top-level block
            // at the end of the document
            return disabled ? appendSkillsBlock(to: yaml, name: target) : yaml
        }

        guard let key = locateDisabled(lines, in: block) else {
            guard disabled else { return yaml }
            if block.headerIsFlowEmpty {  // `skills: {}` → degrade to a block map before adding a child
                let comment = splitComment(lines[block.header]).comment
                lines[block.header] = "skills:" + (comment.isEmpty ? "" : "  " + comment)
            }
            let indent = String(repeating: " ", count: block.childIndent)
            lines.insert(indent + "disabled: [\(render(target))]", at: block.header + 1)
            return lines.joined(separator: "\n")
        }

        if key.items.isEmpty {
            // Flow / scalar / empty value: rewrite only this line's bracket contents; existing
            // items keep their original text and quotes
            guard let edited = editedFlowLine(lines[key.index], name: target, disabled: disabled)
            else { return yaml }
            lines[key.index] = edited
            return lines.joined(separator: "\n")
        }

        // Block style: only add/remove `- item` lines
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

    // MARK: - Locate

    private struct SkillsBlock {
        let header: Int              // Line holding `skills:`
        let headerIsFlowEmpty: Bool  // `skills: {}`
        let children: Range<Int>     // Child lines (incl. comments / blank lines in between)
        let childIndent: Int         // Child-key indent (2 in real files)
    }

    private struct DisabledKey {
        let index: Int            // Line holding `disabled:`
        let indent: Int
        let value: String         // Right of the colon (comment stripped, trimmed)
        let items: Range<Int>     // Block-style `- x` line range; empty range for flow style
        let itemIndent: Int
    }

    private enum SkillsLookup {
        case found(SkillsBlock)
        case unsupported  // Non-empty inline map like `skills: {a: 1}`; not line-editable
        case absent
    }

    /// Finds the top-level `skills:` (indent must be 0, to avoid same-named keys in other blocks)
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

    /// Looks for `disabled:` only inside the skills block, at exactly the child-key indent. That
    /// way `platform_disabled:` and its child mapping (`telegram: [...]`) are never mistaken for
    /// the target key.
    private static func locateDisabled(_ lines: [String], in block: SkillsBlock) -> DisabledKey? {
        for index in block.children where indentWidth(lines[index]) == block.childIndent {
            let content = splitComment(lines[index]).content.trimmingCharacters(in: .whitespaces)
            guard let (key, value) = splitKeyValue(content), key == "disabled" else { continue }

            var cursor = index + 1
            var lastItem = index
            while cursor < block.children.upperBound {
                if isBlankOrComment(lines[cursor]) { cursor += 1; continue }
                let raw = lines[cursor].trimmingCharacters(in: .whitespaces)
                // A block sequence may share the key's indent (`- a` directly under `disabled:`),
                // hence >=
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

    // MARK: - Line rewriting

    /// Adds/removes in a flow-list line; nil when no change is needed or the form is unsupported
    private static func editedFlowLine(
        _ line: String, name: String, disabled: Bool
    ) -> String? {
        let (content, comment) = splitComment(line)
        guard let (_, value) = splitKeyValue(content.trimmingCharacters(in: .whitespaces))
        else { return nil }
        if value.hasPrefix("["), !value.hasSuffix("]") { return nil }  // Multi-line flow list: leave it

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

    /// The whole `skills:` block is missing: append it at the end of the document (a new top-level
    /// key; no existing block is affected)
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

    // MARK: - Text utilities

    private static func indentWidth(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let raw = line.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty || raw.hasPrefix("#")
    }

    /// Splits off the trailing comment by quote state and returns it verbatim, so "every byte
    /// except the target key is unchanged"
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

    /// `- foo  # comment` → `foo`; empty string for non-list-item lines
    private static func itemName(_ line: String) -> String {
        let content = splitComment(line).content.trimmingCharacters(in: .whitespaces)
        guard content.hasPrefix("-") else { return "" }
        return unquote(String(content.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    /// Splits `[a, "b"]` / `[]` / `null` / a bare scalar into raw segments (**quotes kept**, so
    /// writing back doesn't alter existing items)
    private static func flowSegments(_ value: String) -> [String] {
        var inner = value
        if inner.hasPrefix("["), inner.hasSuffix("]") {
            inner = String(inner.dropFirst().dropLast())
        }
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "null" || trimmed == "~" { return [] }

        // Comma splitting must be quote-aware, or `["a, b", c]` gets split wrong (our own quoted
        // names would hit it too)
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
        guard first == "\"" else { return inner }  // Single quotes only escape '', never needed in skill names
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// Pure kebab / snake / path characters are written bare; everything else is double-quoted
    /// (commas and brackets must be quoted in a flow list)
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
