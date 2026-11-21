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
///    **and key** has the file's secrets masked and then passes through `AuditRedactor`
///    (authorization headers, API-key shapes, `…TOKEN=` assignments, URL credentials, PEM keys),
///    and the line is serialized again. Redacting values one by one keeps every line valid JSON:
///    run over the raw line, the assignment rule's "value runs to the next space" would swallow a
///    string's closing quote and the fields after it.
/// A line that doesn't parse is replaced by a stub too, rather than uploaded unchecked.
public enum WorkBuddyTranscriptScrubber {
    /// Detected values shorter than this are not masked file-wide: masking every "abc" would wreck
    /// the copy, and WorkBuddy's detector flags keys and tokens, which are far longer (40 bytes in
    /// the only local sample). The line that records them is still dropped whole.
    static let minimumSecretLength = 6

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
        let masks = secrets.filter { $0.count >= minimumSecretLength }
            .sorted { $0.count > $1.count }

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

    static func scrubLine(_ line: Data, object: [String: Any]?, masks: [String]) -> Data {
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

    static func redact(_ value: Any, masks: [String]) -> Any {
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

    private static func clean(_ text: String, masks: [String]) -> String {
        var text = text
        for secret in masks where text.contains(secret) {
            text = text.replacingOccurrences(of: secret, with: AuditRedactor.mask)
        }
        return AuditRedactor.redact(detail: text, tool: "").text
    }
}
