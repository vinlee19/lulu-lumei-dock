import Foundation

/// transcript 首行时间戳 = 会话最初创建时间。
/// `claude --resume` 生成新文件时会连原始时间戳一起拷贝历史，
/// 所以它跨 resume 链稳定（文件创建时间反而会被 resume 刷新，不可用）。
enum ClaudeSessionFirstTimestamp {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// 解析 ISO8601 时间戳字符串（带/不带小数秒都容忍）
    static func parse(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }

    /// 头部最多扫前几行（首行可能是无 timestamp 的 summary/meta 行）
    static func read(transcriptPath: String, headBytes: Int = 16384) -> Date? {
        guard
            let handle = FileHandle(forReadingAtPath: transcriptPath),
            let data = try? handle.read(upToCount: headBytes)
        else { return nil }
        try? handle.close()

        for line in data.split(separator: UInt8(ascii: "\n")).prefix(10) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let raw = root["timestamp"] as? String,
                let date = isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
            else { continue }
            return date
        }
        return nil
    }
}
