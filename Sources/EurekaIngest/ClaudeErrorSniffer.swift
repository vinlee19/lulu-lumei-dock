import Foundation

/// Transcript tail sniffing after a Stop event:
/// - Last assistant is an API error line (model=="<synthetic>" / isApiErrorMessage) → escalate to
///   error
/// - Also picks up the ai-title line to upgrade the task title
public enum ClaudeErrorSniffer {
    public struct Findings: Equatable {
        public var isError = false
        public var errorDetail: String?
        public var aiTitle: String?

        public init(isError: Bool = false, errorDetail: String? = nil, aiTitle: String? = nil) {
            self.isError = isError
            self.errorDetail = errorDetail
            self.aiTitle = aiTitle
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
        // Back to front: the newest assistant line decides whether it errored; the newest ai-title
        // becomes the title
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }

            if type == "ai-title", findings.aiTitle == nil {
                findings.aiTitle = root["aiTitle"] as? String
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

            if sawLatestAssistant && findings.aiTitle != nil { break }
        }
        return findings
    }
}
