import EurekaKit
import Foundation

/// Cleans a WorkBuddy transcript before it leaves the Mac (the backup's `workbuddy/projects`
/// category). The local file is never modified; only the uploaded copy is.
///
/// WorkBuddy's own sensitive-data protection stores what it detected **in plain text** inside the
/// transcript (`__codebuddyLocal.sensitiveProtection.items[].plaintext`, next to the ciphertext),
/// and the same secret may also sit in the line's tool output. So:
/// - a line carrying `sensitiveProtection` is replaced by a stub that keeps only its identity
///   (`type: "eureka-redacted"`, id, sessionId, timestamp);
/// - every other line is parsed and each string value is passed through `AuditRedactor`
///   (authorization headers, API-key shapes, `…TOKEN=` assignments, URL credentials, PEM keys),
///   then serialized again. Redacting values one by one keeps every line valid JSON: run over the
///   raw line, the assignment rule's "value runs to the next space" would swallow a string's closing
///   quote and the fields after it.
/// - a line that doesn't parse is replaced by a stub too, rather than uploaded unchecked.
public enum WorkBuddyTranscriptScrubber {
    static let protectionMarker = Data("sensitiveProtection".utf8)

    public static func scrub(_ data: Data) -> Data {
        var output = Data(capacity: data.count)
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let line = data[start..<end]
            if !line.isEmpty { output.append(scrubLine(Data(line))) }
            if end < data.endIndex { output.append(UInt8(ascii: "\n")) }
            start = end < data.endIndex ? data.index(after: end) : end
        }
        return output
    }

    static func scrubLine(_ line: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return stub(from: nil) }
        if line.range(of: protectionMarker) != nil { return stub(from: object) }
        let cleaned = redactStrings(object)
        return (try? JSONSerialization.data(withJSONObject: cleaned)) ?? stub(from: object)
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

    static func redactStrings(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return AuditRedactor.redact(detail: string, tool: "").text
        case let dict as [String: Any]:
            return dict.mapValues { redactStrings($0) }
        case let array as [Any]:
            return array.map { redactStrings($0) }
        default:
            return value
        }
    }
}
