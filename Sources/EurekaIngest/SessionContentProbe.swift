import EurekaKit
import Foundation

/// Tells a session with a conversation from one that never had one, so the session list can
/// leave the empty ones out.
///
/// "Empty" means neither a typed prompt nor a model reply. Measured locally (2026-11-26): 12 of
/// 398 Codex rollouts (all under 28 KB: a session opened and closed without a word), 3 Antigravity
/// conversations with zero steps, and no Claude transcript at all. Sessions with only a prompt
/// (an interrupted turn) or only replies (subagents) keep their content and stay listed.
public enum SessionContentProbe {
    /// Larger transcript files are assumed to hold a conversation without being read: the empty
    /// sessions found were at most 28 KB decompressed (17 KB as Codex `.zst`). Measured on 2,574
    /// local sessions, a 512 KB limit read 1,756 Claude transcripts and took 7.2 s; 64 KB reads a
    /// handful, takes 0.2 s and hides the same 15 sessions.
    public static let fileSizeLimit: UInt64 = 64 << 10

    /// Messages read before deciding; reaching the budget means the session has content
    static let budget = 4

    /// false = empty (hide), true = has a conversation, nil = can't tell (keep): Trae's session
    /// database is encrypted, so its sessions are never judged
    public static func hasConversation(
        _ session: AgentSessionInfo,
        catalog: AntigravityConversationCatalog = .shared
    ) -> Bool? {
        switch session.source {
        case .trae:
            return nil
        case .antigravity:
            if let steps = catalog.summaries()[session.id]?.stepCount { return steps > 0 }
        default:
            break
        }
        if !session.source.usesSharedSessionDatabase, session.sizeBytes > fileSizeLimit {
            return true
        }
        let result = TranscriptReader.load(session: session, maxMessages: budget)
        if result.truncated { return true }
        return result.messages.contains { message in
            (message.role == .user || message.role == .assistant)
                && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
