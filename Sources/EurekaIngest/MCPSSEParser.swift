import Foundation

/// Incremental Server-Sent Events parser (WHATWG event-stream framing): feed bytes as they arrive,
/// get back the events completed so far. Used for Streamable HTTP responses that come back as an
/// event stream and for the long-lived stream of the 2024-11-05 HTTP+SSE transport.
///
/// Handles `\n`, `\r\n` and `\r` line endings, multi-line `data:` (joined with `\n`), comments
/// (lines starting with `:`), and a chunk boundary anywhere, including inside a UTF-8 sequence.
public struct MCPSSEParser {
    public struct Event: Equatable, Sendable {
        /// `event:` field; "message" when the stream does not name the event
        public var name: String
        public var data: String

        public init(name: String, data: String) {
            self.name = name
            self.data = data
        }
    }

    private var buffer = Data()
    private var eventName = ""
    private var dataLines: [String] = []
    private var sawField = false

    public init() {}

    public mutating func feed(_ chunk: Data) -> [Event] {
        buffer.append(chunk)
        var events: [Event] = []
        while let line = nextLine() {
            if let event = consume(line) { events.append(event) }
        }
        return events
    }

    /// The stream ended: a trailing line without a newline and an event without its terminating
    /// blank line still count (servers answering a single POST often close right after the data)
    public mutating func finish() -> [Event] {
        var events: [Event] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = consume(line) { events.append(event) }
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func nextLine() -> String? {
        guard let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
            return nil
        }
        var next = buffer.index(after: index)
        if buffer[index] == 0x0D {
            // A lone CR at the very end may be the first half of CRLF: wait for more bytes
            guard next < buffer.endIndex else { return nil }
            if buffer[next] == 0x0A { next = buffer.index(after: next) }
        }
        let line = String(decoding: buffer[buffer.startIndex..<index], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex..<next)
        return line
    }

    private mutating func consume(_ line: String) -> Event? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event":
            eventName = String(value)
            sawField = true
        case "data":
            dataLines.append(String(value))
            sawField = true
        default:
            break
        }
        return nil
    }

    private mutating func dispatch() -> Event? {
        defer {
            eventName = ""
            dataLines = []
            sawField = false
        }
        guard sawField else { return nil }
        return Event(
            name: eventName.isEmpty ? "message" : eventName,
            data: dataLines.joined(separator: "\n"))
    }
}
