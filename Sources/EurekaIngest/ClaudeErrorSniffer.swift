import Foundation

/// Transcript tail sniffing after a Stop event:
/// - Last assistant is an API error line (model=="<synthetic>" / isApiErrorMessage) → escalate to
///   error
/// - Also picks up the session name (custom-title line → sidecar → legacy ai-title, see
///   `ClaudeSessionTitle`) to upgrade the task title
public enum ClaudeErrorSniffer {
    public struct Findings: Equatable {
        public var isError = false
        public var errorDetail: String?
        public var sessionTitle: String?

        public init(isError: Bool = false, errorDetail: String? = nil, sessionTitle: String? = nil) {
            self.isError = isError
            self.errorDetail = errorDetail
            self.sessionTitle = sessionTitle
        }
    }

    public static func sniff(transcriptPath: String, tailBytes: Int = 65536) -> Findings {
        guard
            let handle = FileHandle(forReadingAtPath: transcriptPath),
            let size = try? handle.seekToEnd()
        else { return Findings() }
        defer { try? handle.close() }

        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return Findings() }

        var findings = Findings()
        var sawLatestAssistant = false
        var customTitle: String?
        var aiTitle: String?
        // Back to front: the newest assistant line decides whether it errored; the newest title
        // line becomes the session name
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }

            if let (isCustom, title) = ClaudeSessionTitle.line(root) {
                if isCustom { if customTitle == nil { customTitle = title } }
                else if aiTitle == nil { aiTitle = title }
            }

            if type == "assistant", !sawLatestAssistant {
                // Subagent (sidechain) errors don't count as the main task erroring
                if root["isSidechain"] as? Bool == true { continue }
                sawLatestAssistant = true
                let message = root["message"] as? [String: Any]
                let isSynthetic = message?["model"] as? String == "<synthetic>"
                if root["isApiErrorMessage"] as? Bool == true || isSynthetic {
                    findings.isError = true
                    if let content = message?["content"] as? [[String: Any]] {
                        findings.errorDetail = content
                            .compactMap { $0["text"] as? String }
                            .first
                            .flatMap { summarizeTitle($0, maxLength: 120) }
                    }
                    if findings.errorDetail == nil {
                        findings.errorDetail = root["error"] as? String
                    }
                }
            }

            if sawLatestAssistant && (customTitle != nil || aiTitle != nil) { break }
        }
        findings.sessionTitle = customTitle
            ?? ClaudeSessionTitle.sidecar(transcriptPath: transcriptPath)
            ?? aiTitle
        return findings
    }
}
