import EurekaKit
import Foundation

/// Slices a flat `[TranscriptMessage]` into per-turn `TurnInput`s (input to the lineage graph and
/// per-turn diagnostics).
///
/// Why "slice" instead of "parse again": `TranscriptReader` already normalizes 13 sources into one
/// message model, and all the turn-boundary information (user message positions, trail
/// containers, thinking messages) is already in it. A second, parallel parse chain would mean
/// parsing 2000 messages twice, and the two chains' semantics would slowly drift apart.
///
/// **Turn boundary = a real user message**. It is the only criterion that holds for every source:
///  - Claude/Codex/Qoder: `TranscriptReader` resets `trailIndex` at user messages, the same
///    origin as here;
///  - Codex also has a real `turn_id`, but it is already used at read time to reset the trail,
///    so there is no need to consume it again here;
///  - the other sources have no turn concept; user messages are the only divider.
///
/// Content before the first user message (session resume, system injection) goes into "turn 0"
/// with `promptMessageId == nil` rather than being dropped: it often holds a resume summary, and
/// dropping it would make the first turn appear to start out of nowhere.
public enum TurnSlicer {
    public static func slice(_ messages: [TranscriptMessage]) -> [TurnInput] {
        var turns: [TurnInput] = []
        var current = TurnInput(turnIndex: 0)
        var stepIndex = 0
        var hasContent = false

        func flush() {
            // Don't emit empty shells (e.g. the trailing turn when a file ends on a user message)
            guard hasContent || current.promptMessageId != nil else { return }
            turns.append(current)
        }

        for message in messages {
            switch message.role {
            case .user:
                // Slash-command echoes / background task notifications **are not real prompts**
                // and must not open a new turn. Locally, 240 of 483 string-typed user messages
                // were such injections (a full half); without stripping them the turn list
                // drowns in "0-step empty turns".
                guard let prompt = Self.realPrompt(message.text) else { continue }
                flush()
                current = TurnInput(
                    turnIndex: turns.count,
                    promptMessageId: message.id,
                    promptText: prompt,
                    startedAt: message.timestamp)
                stepIndex = 0
                hasContent = false

            case .thinking:
                current.thinkingTexts.append(message.text)
                hasContent = true
                touch(&current, message.timestamp)

            case .turnTrail:
                for step in message.steps {
                    current.steps.append(TurnInput.Step(
                        kind: step.kind, name: step.name, detail: step.detail,
                        isError: step.isError, batch: step.batch, callId: step.callId,
                        messageId: message.id, stepIndex: stepIndex,
                        subSteps: step.subSteps.map {
                            TurnInput.Step(
                                kind: $0.kind, name: $0.name, detail: $0.detail,
                                isError: $0.isError, batch: $0.batch, callId: $0.callId,
                                messageId: message.id)
                        }))
                    stepIndex += 1
                }
                if !message.steps.isEmpty { hasContent = true }
                touch(&current, message.timestamp)

            case .toolNote:
                // Sources without a trail (opencode/grok/kimi/qwen/hermes/cursor/codebuddy…):
                // each 🔧 note is one step. The name carries an emoji prefix; strip it here.
                let name = message.text.hasPrefix("🔧 ")
                    ? String(message.text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    : message.text
                current.steps.append(TurnInput.Step(
                    kind: .other, name: name, detail: "",
                    batch: stepIndex, messageId: message.id, stepIndex: stepIndex))
                stepIndex += 1
                hasContent = true
                touch(&current, message.timestamp)

            case .assistant:
                current.answerMessageIds.append(message.id)
                current.answerText = current.answerText.isEmpty
                    ? message.text : current.answerText + "\n" + message.text
                hasContent = true
                touch(&current, message.timestamp)

            case .error:
                current.errorTexts.append(message.text)
                hasContent = true
                touch(&current, message.timestamp)
            }
        }
        flush()
        return turns
    }

    /// Wrapper tags the CLI injects into the conversation stream that **the user did not type**
    /// (verified on Claude; other sources have no such set)
    private static let injectedTags = [
        "local-command-caveat", "command-name", "command-message", "command-args",
        "local-command-stdout", "task-notification", "system-reminder",
    ]

    /// The real prompt left after stripping injected blocks; nil if nothing remains (= this is not
    /// a prompt).
    ///
    /// Can't drop the whole message on seeing `<local-command-caveat>`: the caveat is often
    /// **followed by a real prompt** (the slash command's output is injected first, the user's
    /// words come after). So strip block by block, then see what's left.
    static func realPrompt(_ text: String) -> String? {
        var stripped = text
        for tag in injectedTags {
            stripped = removeBlocks(tag: tag, in: stripped)
        }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes every `<tag>…</tag>` block (including an unclosed trailing block: truncated
    /// injected content shouldn't count as a prompt either). A hand-written scan rather than a
    /// regex: content may contain newlines and angle brackets, and external input never gets
    /// spliced into a regex.
    private static func removeBlocks(tag: String, in text: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var result = text
        while let start = result.range(of: open) {
            if let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    /// A turn's end time is the last timestamp seen in it (most sources timestamp every message;
    /// grok is turn-level granularity)
    private static func touch(_ turn: inout TurnInput, _ timestamp: Date?) {
        guard let timestamp else { return }
        if turn.startedAt == nil { turn.startedAt = timestamp }
        if let ended = turn.endedAt, ended > timestamp { return }
        turn.endedAt = timestamp
    }
}
