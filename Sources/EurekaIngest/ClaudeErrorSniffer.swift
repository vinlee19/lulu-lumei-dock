import Foundation

/// Stop 事件后的 transcript 尾部嗅探：
/// - 最后一条 assistant 是 API 错误行（model=="<synthetic>" / isApiErrorMessage）→ 升级为出错
/// - 顺手取 ai-title 行升级任务标题
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
        // 从后往前：最新的 assistant 行决定是否出错；最新的 ai-title 作标题
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
                // 子代理（sidechain）的错误不算主任务出错
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
