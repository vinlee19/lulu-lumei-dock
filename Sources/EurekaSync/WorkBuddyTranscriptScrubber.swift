import EurekaKit
import Foundation

/// Cleans a WorkBuddy transcript before it leaves the Mac (the backup's `workbuddy/projects`
/// category). The local file is never modified; only the uploaded copy is.
///
/// WorkBuddy's own sensitive-data protection stores what it detected **in plain text** inside the
/// transcript (`__codebuddyLocal.sensitiveProtection.items[].plaintext`, next to the ciphertext).
/// The record sits on one line, but the same secret can also appear on others: the prompt it was
/// pasted into, or the raw output of the tool that printed it. So the file is scrubbed in two
/// passes:
/// 1. every line is parsed and each `sensitiveProtection` record found anywhere in it (searched by
///    key, recursively) contributes its plaintext values to the file's secret set;
/// 2. a line holding such a record is replaced by a stub that keeps only its identity
///    (`type: "eureka-redacted"`, id, sessionId, timestamp); on every other line each string value
///    **and key** has the file's secrets masked (see `Masks` for how short values are matched) and
///    then passes through `AuditRedactor`
///    (authorization headers, API-key shapes, `…TOKEN=` assignments, URL credentials, PEM keys),
///    and the line is serialized again. Redacting values one by one keeps every line valid JSON:
///    run over the raw line, the assignment rule's "value runs to the next space" would swallow a
///    string's closing quote and the fields after it.
/// A line that doesn't parse is replaced by a stub too, rather than uploaded unchecked.
public enum WorkBuddyTranscriptScrubber {
    /// How the file's detected values are matched. Every value is masked wherever a string is
    /// exactly that value. Beyond that, short values would wreck the copy if replaced inside other
    /// words, so the match narrows with length:
    /// - 6+ characters: every occurrence, anywhere (keys and tokens; the only local sample is 40);
    /// - 3–5 characters: only where the value stands alone, not touching an ASCII letter, digit or
    ///   `_` on either side;
    /// - 1–2 characters: exact whole-string matches only. Such a value keeps no secret worth the
    ///   name, while masking every standalone "a" or "12" would erase the transcript.
    /// The line that records them is dropped whole in every case.
    struct Masks {
        var exact: Set<String> = []
        var anywhere: [String] = []
        var standalone: [NSRegularExpression] = []

        static let anywhereLength = 6
        static let standaloneLength = 3

        init(_ secrets: Set<String>) {
            exact = secrets
            anywhere = secrets.filter { $0.count >= Self.anywhereLength }
                .sorted { $0.count > $1.count }
            // The value is escaped, so nothing in it is read as regex syntax
            standalone = secrets
                .filter { (Self.standaloneLength..<Self.anywhereLength).contains($0.count) }
                .sorted { $0.count > $1.count }
                .compactMap {
                    try? NSRegularExpression(
                        pattern: "(?<![A-Za-z0-9_])"
                            + NSRegularExpression.escapedPattern(for: $0)
                            + "(?![A-Za-z0-9_])")
                }
        }
    }

    public static func scrub(_ data: Data) -> Data {
        var lines: [Data?] = []
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            lines.append(start < end ? Data(data[start..<end]) : nil)
            start = end < data.endIndex ? data.index(after: end) : end
        }
        let endsWithNewline = data.last == UInt8(ascii: "\n")

        // Pass 1: parse once, collect every protected plaintext in the file
        let parsed = lines.map { line in
            line.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        var secrets = Set<String>()
        for object in parsed {
            guard let object else { continue }
            collectProtected(object, into: &secrets)
        }
        let masks = Masks(secrets)

        // Pass 2: stub protected or unparsable lines, mask the rest
        var output = Data(capacity: data.count)
        for (index, line) in lines.enumerated() {
            if let line {
                output.append(scrubLine(line, object: parsed[index], masks: masks))
            }
            if index < lines.count - 1 || endsWithNewline {
                output.append(UInt8(ascii: "\n"))
            }
        }
        return output
    }

    static func scrubLine(_ line: Data, object: [String: Any]?, masks: Masks) -> Data {
        guard let object else { return stub(from: nil) }
        var found = Set<String>()
        if collectProtected(object, into: &found) { return stub(from: object) }
        let cleaned = redact(object, masks: masks)
        return (try? JSONSerialization.data(withJSONObject: cleaned)) ?? stub(from: object)
    }

    /// Adds the plaintext of every `sensitiveProtection` record under `value` (at any depth);
    /// returns whether any record was found
    @discardableResult
    static func collectProtected(_ value: Any, into secrets: inout Set<String>) -> Bool {
        var found = false
        switch value {
        case let dict as [String: Any]:
            for (key, child) in dict {
                if key == "sensitiveProtection" {
                    found = true
                    plaintexts(in: child, into: &secrets)
                }
                if collectProtected(child, into: &secrets) { found = true }
            }
        case let array as [Any]:
            for child in array where collectProtected(child, into: &secrets) { found = true }
        default:
            break
        }
        return found
    }

    /// Every `plaintext` string under a protection record, whatever its exact nesting
    private static func plaintexts(in value: Any, into secrets: inout Set<String>) {
        switch value {
        case let dict as [String: Any]:
            for (key, child) in dict {
                if key == "plaintext", let text = child as? String, !text.isEmpty {
                    secrets.insert(text)
                }
                plaintexts(in: child, into: &secrets)
            }
        case let array as [Any]:
            for child in array { plaintexts(in: child, into: &secrets) }
        default:
            break
        }
    }

    /// Identity fields only, so the backup still shows where a line was dropped
    static func stub(from object: [String: Any]?) -> Data {
        var stub: [String: Any] = ["type": "eureka-redacted"]
        for key in ["id", "sessionId", "timestamp"] {
            if let value = object?[key] as? String { stub[key] = value }
            if let value = object?[key] as? NSNumber { stub[key] = value }
        }
        return (try? JSONSerialization.data(withJSONObject: stub, options: [.sortedKeys]))
            ?? Data(#"{"type":"eureka-redacted"}"#.utf8)
    }

    static func redact(_ value: Any, masks: Masks) -> Any {
        switch value {
        case let string as String:
            return clean(string, masks: masks)
        case let dict as [String: Any]:
            var result: [String: Any] = [:]
            for (key, child) in dict {
                // Merge rather than overwrite if two keys clean to the same text
                let cleanedKey = clean(key, masks: masks)
                let cleanedChild = redact(child, masks: masks)
                result[result[cleanedKey] == nil ? cleanedKey : "\(cleanedKey)#\(result.count)"] =
                    cleanedChild
            }
            return result
        case let array as [Any]:
            return array.map { redact($0, masks: masks) }
        default:
            return value
        }
    }

    private static func clean(_ text: String, masks: Masks) -> String {
        if masks.exact.contains(text)
            || masks.exact.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return AuditRedactor.mask
        }
        var text = text
        for secret in masks.anywhere where text.contains(secret) {
            text = text.replacingOccurrences(of: secret, with: AuditRedactor.mask)
        }
        let template = NSRegularExpression.escapedTemplate(for: AuditRedactor.mask)
        for regex in masks.standalone {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return AuditRedactor.redact(detail: text, tool: "").text
    }
}
