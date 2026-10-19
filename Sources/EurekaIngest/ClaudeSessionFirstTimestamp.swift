import Foundation

/// The transcript's first-line timestamp = when the session was originally created. When
/// `claude --resume` writes a new file it copies the history along with the original timestamps, so
/// it stays stable across a resume chain (the file creation time is refreshed by resume, so it's
/// unusable).
enum ClaudeSessionFirstTimestamp {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// Parse an ISO8601 timestamp string (with or without fractional seconds)
    static func parse(_ raw: String) -> Date? {
        isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }

    /// Scan at most the first few lines of the head (the first line may be a summary/meta line
    /// without a timestamp)
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
