import EurekaKit
import Foundation

/// notify installer for ~/.codex/config.toml (line-level edits; never rewrites the whole TOML).
/// Key invariant: notify is a top-level key and must be inserted before the first `[table]` line -
/// appending it at EOF would land it inside the last table and make the config invalid.
///
/// notify is a single slot. When another program already holds it, installing *chains*
/// instead of refusing: the line becomes
/// `notify = ["<relay>", "codex-notify", "--chain", <original argv…>]`, and the relay
/// launches the original command with the payload before recording the event, so both keep
/// working. Uninstall puts the original argv back. A value we cannot parse with certainty
/// (multi-line array, non-string items) is still refused untouched.
public enum CodexNotifyInstaller {
    /// Separates the relay's own arguments from the chained command's argv.
    public static let chainFlag = "--chain"

    public static func notifyLine(relayPath: String, chaining previous: [String] = []) -> String {
        var argv = [relayPath, "codex-notify"]
        if !previous.isEmpty { argv += [chainFlag] + previous }
        return "notify = " + TOMLStringArray.render(argv)
    }

    public static func install(into toml: String, relayPath: String) throws -> String {
        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")

        if let existing = topLevelNotifyIndex(lines) {
            let line = lines[existing]
            guard let argv = notifyArgv(in: line) else {
                throw InstallError.foreignConfig(
                    L10n.format("Cannot safely parse notify in config.toml (for example, a multiline array): %@\n", zhHans: "config.toml 的 notify 无法安全解析（如跨多行的数组）：%@\n", String(trimmed(line)))
                        + L10n.text("Please change it to a single line manually before installing", zhHans: "请先手动改成单行再安装"))
            }
            // Ours: keep whatever we were already chaining (the path may have changed).
            // Someone else's: wrap it so it keeps receiving every notification
            // (`notify = []` means "off", so there is nothing to chain).
            let chained = RelayIdentity.isOurs(line) ? chainedArgv(of: argv) : argv
            lines[existing] = notifyLine(relayPath: relayPath, chaining: chained)
            return lines.joined(separator: "\n")
        }

        // Insertion point: before the first table header (skipping blank lines right above it, so
        // they stay with the table)
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

    /// Removes our notify line, or restores the chained original in its place.
    public static func uninstall(from toml: String) -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let index = topLevelNotifyIndex(lines), RelayIdentity.isOurs(lines[index]) else {
            return toml
        }
        let chained = notifyArgv(in: lines[index]).map(chainedArgv(of:)) ?? []
        if chained.isEmpty {
            lines.remove(at: index)
        } else {
            lines[index] = "notify = " + TOMLStringArray.render(chained)
        }
        return lines.joined(separator: "\n")
    }

    public static func status(of toml: String) -> InstallStatus {
        let lines = toml.components(separatedBy: "\n")
        guard let index = topLevelNotifyIndex(lines) else { return .none }
        return RelayIdentity.isOurs(lines[index]) ? .installed : .foreign
    }

    /// The command our line forwards to, if any (for display).
    public static func chainedCommand(in toml: String) -> [String]? {
        let lines = toml.components(separatedBy: "\n")
        guard let index = topLevelNotifyIndex(lines), RelayIdentity.isOurs(lines[index]),
              let argv = notifyArgv(in: lines[index]) else { return nil }
        let chained = chainedArgv(of: argv)
        return chained.isEmpty ? nil : chained
    }

    // MARK: - Diagnostics

    /// Diagnosis that recognises anomalies. Pure function: whether the relay is executable is
    /// injected by the caller.
    public static func diagnose(
        toml: String, expectedRelayPath: String,
        relayIsExecutable: (String) -> Bool
    ) -> HookDiagnosis {
        let lines = toml.components(separatedBy: "\n")
        guard let index = topLevelNotifyIndex(lines) else { return .notInstalled }
        let line = trimmed(lines[index])
        let argv = notifyArgv(in: line)

        guard RelayIdentity.isOurs(line) else {
            if let argv {
                guard let program = argv.first else { return .notInstalled }  // `notify = []`
                return .chainable(owner: URL(fileURLWithPath: program).lastPathComponent)
            }
            return .foreignOccupied(detail:
                L10n.format("The top-level notify in config.toml is used by another program and cannot be safely parsed (for example, a multiline array):\n%@\n", zhHans: "config.toml 的顶层 notify 已被他人占用，且无法安全解析（如跨多行的数组）：\n%@\n", String(line))
                    + L10n.text("Only one notify is allowed, so it will not be rewritten automatically. Change it to a single line to chain the installation,", zhHans: "notify 只能有一个，不会自动改写。改成单行后可串联安装，")
                    + L10n.format(" or change it manually to: %@", zhHans: "或手动改为：%@", String(notifyLine(relayPath: expectedRelayPath, chaining: [L10n.text("<original command>", zhHans: "<原命令>"), "…"]))))
        }
        guard let argv, let path = argv.first else {
            return .unparseable(reason: L10n.format("Cannot parse notify in config.toml: %@", zhHans: "config.toml 的 notify 无法解析：%@", String(line)))
        }
        if path != expectedRelayPath,
           !RelayIdentity.isLegacyStablePath(path, expected: expectedRelayPath) {
            return .driftedPath(found: [line])
        }
        if !relayIsExecutable(expectedRelayPath) {
            return .relayMissing(path: expectedRelayPath)
        }
        if path != expectedRelayPath { return .legacyRelayName(found: [line]) }
        return .installed
    }

    // MARK: - Internals

    /// `notify = [...]` → argv; nil when the value is not a single-line array of strings.
    private static func notifyArgv(in line: String) -> [String]? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        return TOMLStringArray.parse(line[line.index(after: equals)...])
    }

    /// Our argv is `[relay, "codex-notify", "--chain", original…]`; returns `original…`.
    private static func chainedArgv(of argv: [String]) -> [String] {
        guard argv.count > 3, argv[2] == chainFlag else { return [] }
        return Array(argv[3...])
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    /// The notify assignment line in the top-level region (before the first table)
    private static func topLevelNotifyIndex(_ lines: [String]) -> Int? {
        for (index, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }  // Entered the table region; stop
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

/// A single-line TOML array of strings — just enough of TOML to wrap and restore a notify
/// argv without guessing. Anything outside that subset parses as nil, and callers treat nil
/// as "do not touch".
public enum TOMLStringArray {
    /// Parses `["a", 'b'] # comment`. Multi-line strings, non-string items and unterminated
    /// arrays (i.e. one continuing on the next line) return nil.
    public static func parse<S: StringProtocol>(_ text: S) -> [String]? {
        var chars = Array(text.unicodeScalars)[...]
        func skipSpaces() {
            while let first = chars.first, first == " " || first == "\t" { chars.removeFirst() }
        }
        skipSpaces()
        guard chars.popFirst() == "[" else { return nil }
        var items: [String] = []
        var closed = false
        while !closed {
            skipSpaces()
            guard let head = chars.first else { return nil }
            if head == "]" {
                chars.removeFirst()
                break
            }
            guard let item = parseString(&chars) else { return nil }
            items.append(item)
            skipSpaces()
            switch chars.popFirst() {
            case ",": continue
            case "]": closed = true
            default: return nil
            }
        }
        skipSpaces()
        guard chars.isEmpty || chars.first == "#" else { return nil }
        return items
    }

    /// Renders as basic strings, escaping what TOML requires.
    public static func render(_ items: [String]) -> String {
        "[" + items.map(quote).joined(separator: ", ") + "]"
    }

    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func parseString(_ chars: inout ArraySlice<Unicode.Scalar>) -> String? {
        guard let quoteChar = chars.popFirst(), quoteChar == "\"" || quoteChar == "'" else {
            return nil
        }
        // `""` followed by a third quote opens a multi-line string — out of scope.
        if chars.count >= 2, chars[chars.startIndex] == quoteChar,
           chars[chars.startIndex + 1] == quoteChar { return nil }
        var out = String.UnicodeScalarView()
        while let scalar = chars.popFirst() {
            if scalar == quoteChar { return String(out) }
            if quoteChar == "'" || scalar != "\\" {
                out.append(scalar)
                continue
            }
            switch chars.popFirst() {
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "u": guard let s = hexScalar(&chars, digits: 4) else { return nil }; out.append(s)
            case "U": guard let s = hexScalar(&chars, digits: 8) else { return nil }; out.append(s)
            default: return nil
            }
        }
        return nil  // unterminated
    }

    private static func hexScalar(
        _ chars: inout ArraySlice<Unicode.Scalar>, digits: Int
    ) -> Unicode.Scalar? {
        guard chars.count >= digits else { return nil }
        let hex = String(String.UnicodeScalarView(chars.prefix(digits)))
        chars.removeFirst(digits)
        return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init)
    }
}
