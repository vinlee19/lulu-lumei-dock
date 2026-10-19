import Foundation

/// Immutable, normalized copy of one conversation taken at the start of a run. Every message in
/// it is sent to the executor; nothing is truncated. Built by `ConversationSnapshotBuilder`
/// (EurekaIngest) from the multi-source transcript reader.
public struct SummarySnapshot: Equatable, Sendable {
    public enum Role: String, Sendable, Codable {
        case user
        case assistant
        /// Compact rendering of the tool activity of one turn
        case tools
        case error
    }

    public struct Message: Equatable, Sendable {
        /// Same id as `TranscriptMessage.id`, so citations can jump back to the conversation
        public var id: Int
        public var role: Role
        public var text: String
        public var timestamp: Date?

        public init(id: Int, role: Role, text: String, timestamp: Date? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.timestamp = timestamp
        }
    }

    public var messages: [Message]
    public var compactedToolSteps: Int
    public var excludedThinking: Int

    public init(messages: [Message], compactedToolSteps: Int = 0, excludedThinking: Int = 0) {
        self.messages = messages
        self.compactedToolSteps = compactedToolSteps
        self.excludedThinking = excludedThinking
    }

    public var messageIds: Set<Int> { Set(messages.map(\.id)) }

    /// Content fingerprint: depends only on this session's normalized messages (never on UI
    /// language, file mtimes or a shared database's modification time), so another session's
    /// writes to a shared store never make this summary look stale.
    public var fingerprint: String {
        var hash = SummaryFingerprint()
        for message in messages {
            hash.add("\(message.id)|\(message.role.rawValue)|")
            hash.add(message.text)
            hash.add("\u{1E}")
        }
        return hash.hex
    }

    public func coverage(chunkCount: Int, splitMessages: Int) -> SummaryCoverage {
        SummaryCoverage(
            totalMessages: messages.count,
            userMessages: messages.filter { $0.role == .user }.count,
            firstMessageId: messages.first?.id,
            lastMessageId: messages.last?.id,
            compactedToolSteps: compactedToolSteps,
            excludedThinking: excludedThinking,
            chunkCount: chunkCount,
            splitMessages: splitMessages,
            estimatedTokens: messages.reduce(0) { $0 + SummaryChunker.estimateTokens($1.text) })
    }
}

/// 64-bit FNV-1a over UTF-8 bytes. Change detection only, not a security boundary.
public struct SummaryFingerprint {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    public init() {}

    public mutating func add(_ text: String) {
        for byte in text.utf8 {
            state ^= UInt64(byte)
            state = state &* 0x0000_0100_0000_01B3
        }
    }

    public var hex: String { String(format: "%016llx", state) }
}

/// Turn-aware chunking under an explicit token budget. Guarantees full coverage: every message
/// lands in exactly one chunk, and a message larger than the budget is split into consecutive
/// parts instead of being cut.
public enum SummaryChunker {
    public struct Chunk: Equatable, Sendable {
        public var index: Int
        public var messages: [SummarySnapshot.Message]
        public var estimatedTokens: Int

        public var firstMessageId: Int? { messages.first?.id }
        public var lastMessageId: Int? { messages.last?.id }
    }

    public struct Plan: Equatable, Sendable {
        public var chunks: [Chunk]
        /// Distinct messages that had to be split across parts
        public var splitMessages: Int
    }

    /// Conservative explicit budget for transcript content per invocation (estimated tokens).
    /// Context limits differ per executor and model and are often unknown; this leaves room for
    /// the CLI's own system prompt and the reply even on 128k-token models.
    public static let defaultBudget = 60_000

    /// Rough token estimate: ~4 ASCII characters per token, one token per non-ASCII scalar
    /// (CJK text is close to one token per character). Deliberately pessimistic.
    public static func estimateTokens(_ text: String) -> Int {
        var ascii = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { other += 1 }
        }
        return ascii / 4 + other + 8  // +8 for the per-message marker line
    }

    public static func plan(_ messages: [SummarySnapshot.Message], budget: Int = defaultBudget) -> Plan {
        let budget = max(budget, 200)
        // Turns: a user message opens a new turn; anything before the first one is its own turn
        var turns: [[SummarySnapshot.Message]] = []
        for message in messages {
            if message.role == .user || turns.isEmpty {
                turns.append([message])
            } else {
                turns[turns.count - 1].append(message)
            }
        }

        var chunks: [[SummarySnapshot.Message]] = []
        var current: [SummarySnapshot.Message] = []
        var currentTokens = 0
        var splitIds = Set<Int>()

        func flush() {
            if !current.isEmpty { chunks.append(current) }
            current = []
            currentTokens = 0
        }
        func append(_ message: SummarySnapshot.Message) {
            let cost = estimateTokens(message.text)
            if currentTokens + cost > budget { flush() }
            current.append(message)
            currentTokens += cost
        }

        for turn in turns {
            let turnTokens = turn.reduce(0) { $0 + estimateTokens($1.text) }
            if currentTokens + turnTokens <= budget {
                current += turn
                currentTokens += turnTokens
                continue
            }
            // The turn does not fit what's left: start it in a fresh chunk
            flush()
            if turnTokens <= budget {
                current = turn
                currentTokens = turnTokens
                continue
            }
            // Oversized turn: pack message by message, splitting any single oversized message
            for message in turn {
                if estimateTokens(message.text) <= budget {
                    append(message)
                    continue
                }
                splitIds.insert(message.id)
                let parts = split(message.text, budget: budget)
                for (offset, part) in parts.enumerated() {
                    var piece = message
                    piece.text = "(part \(offset + 1)/\(parts.count))\n" + part
                    flush()
                    current = [piece]
                    currentTokens = estimateTokens(piece.text)
                }
            }
        }
        flush()

        let built = chunks.enumerated().map { index, messages in
            Chunk(
                index: index, messages: messages,
                estimatedTokens: messages.reduce(0) { $0 + estimateTokens($1.text) })
        }
        return Plan(chunks: built, splitMessages: splitIds.count)
    }

    /// Splits text into pieces under the budget, preferring line boundaries
    static func split(_ text: String, budget: Int) -> [String] {
        let target = max(budget - 32, 64)
        var pieces: [String] = []
        var current = ""
        var currentTokens = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var lineText = String(line)
            var lineTokens = estimateTokens(lineText)
            while lineTokens > target {
                // A single line larger than the budget: slice it by characters
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                    currentTokens = 0
                }
                let ratio = Double(target) / Double(lineTokens)
                let cut = max(1, Int(Double(lineText.count) * ratio))
                let index = lineText.index(lineText.startIndex, offsetBy: cut)
                pieces.append(String(lineText[..<index]))
                lineText = String(lineText[index...])
                lineTokens = estimateTokens(lineText)
            }
            if currentTokens + lineTokens > target, !current.isEmpty {
                pieces.append(current)
                current = ""
                currentTokens = 0
            }
            current += current.isEmpty ? lineText : "\n" + lineText
            currentTokens += lineTokens
        }
        if !current.isEmpty || pieces.isEmpty { pieces.append(current) }
        return pieces
    }
}
