import EurekaKit
import Foundation

/// Prompt library collector: extracts user prompts (`role == .user`) from session transcripts.
///
/// Reuses every source loader in `TranscriptReader` — 12 sources can be extracted directly
/// (including the shared-DB opencode/hermes/cursor/zcode, queried by sessionId); antigravity
/// (protobuf) and trae (SQLCipher) each return only a single toolNote, so naturally nothing
/// is extracted from them.
public enum PromptExtractor {
    /// Single-session extraction: fully parses the transcript, filters user messages and applies
    /// three layers of noise removal (12.4% of the 2395 surveyed entries were pseudo-user
    /// messages — storing them for reuse is pointless):
    /// 1. `TurnSlicer.realPrompt` strips injected tags block by block (a caveat followed by a real
    ///    prompt is kept); skip if nothing remains;
    /// 2. `PromptClassifier.isInjectedArtifact` covers prefixes outside TurnSlicer's list
    ///    (bash-input / Codex environment context) and bare slash commands;
    /// 3. `truncateForStorage` truncates oversized pastes (the longest surveyed was a 1.98MB log).
    /// `firstSeen` is passed in by the caller (one scan batch shares a timestamp, keeping order
    /// stable).
    public static func extract(from session: AgentSessionInfo, at now: Date) -> [PromptEntry] {
        extract(
            messages: TranscriptReader.load(session: session).messages,
            session: session, at: now)
    }

    /// Pure-function overload: the caller loads messages itself (extraction and turn evaluation
    /// share one parse — fully re-parsing the transcript is the main cost of the extraction
    /// pipeline, so it must not be loaded again for evaluation)
    public static func extract(
        messages: [TranscriptMessage], session: AgentSessionInfo, at now: Date
    ) -> [PromptEntry] {
        return messages.compactMap { message in
            guard message.role == .user else { return nil }
            guard let real = TurnSlicer.realPrompt(message.text) else { return nil }
            guard !PromptClassifier.isInjectedArtifact(real) else { return nil }
            let text = PromptClassifier.truncateForStorage(real)
            return PromptEntry(
                id: PromptEntry.makeId(
                    source: session.source, sessionId: session.id, messageIdx: message.id),
                source: session.source,
                sessionId: session.id,
                messageIdx: message.id,
                text: text,
                timestamp: message.timestamp,
                cwd: session.cwd,
                firstSeen: now)
        }
    }
}
