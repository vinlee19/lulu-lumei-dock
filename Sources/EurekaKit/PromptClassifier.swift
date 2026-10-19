import Foundation

/// Reuse-value classification for prompts (thresholds set from 2395 local entries; data and
/// trade-offs are recorded in the revision log of docs/specs/2026-08-23-prompt-library-design.md).
///
/// The class is **derived in memory**, not a stored column: thresholds keep changing, and a column
/// would mean a full-DB refresh + schema bump on every tweak. `all()` already loads everything into
/// memory; an O(n) pass over a few thousand entries on a background queue is negligible.
public enum PromptKind: String, Sendable, CaseIterable {
    /// Pseudo user message: injected artifacts like slash-command echoes / local command output /
    /// task notifications, not human-written
    case noise
    /// Trivial phrase ("continue" / "ok"); faster to type than to find, no reuse value
    case trivial
    /// Short follow-up: meaningless outside its session context; shown by default but never pinned
    case followup
    /// Structured instruction: the core reusable asset
    case instruction
    /// Long paste (logs / SQL / errors): context, not a question
    case paste
}

public enum PromptClassifier {
    public struct Thresholds: Sendable {
        /// At or below this many characters counts as trivial (all 418 local entries of ≤12 chars
        /// were "continue"-like)
        public var trivialMaxLength = 12
        /// At or below this many characters counts as a short follow-up
        public var followupMaxLength = 40
        /// At or above this many characters with no markdown structure counts as a long paste
        public var pasteMinLength = 2000
        public init() {}
    }

    /// Trivial-phrase list (supplements the length threshold: these have no reuse value even when
    /// long enough)
    static let trivialPhrases: Set<String> = [
        "继续", "继续吧", "好的", "好", "可以", "行", "嗯", "对", "对的", "不", "不用",
        "你好", "谢谢", "开始", "开始吧", "试试", "再试试", "重试", "提交", "跑一下",
        "ok", "okay", "yes", "no", "go", "go on", "go ahead", "hi", "hello",
        "thanks", "retry", "run", "commit", "continue", "proceed", "done", "next",
    ]

    /// Pseudo-user-message prefixes. **Prefix matching, not block stripping**: this serves raw text
    /// in the existing library with tags not yet stripped (all 296 local noise entries start with a
    /// tag); capture-side stripping is TurnSlicer.realPrompt. The first 7 mirror
    /// TurnSlicer.injectedTags; the last 4 are outside its list (the bash bridge and the
    /// environment context Codex injects).
    static let injectedPrefixes = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-stdout>", "<local-command-caveat>",
        "<task-notification>", "<system-reminder>",
        "<bash-input>", "<bash-stdout>",
        "<environment_context>", "<user_instructions>",
    ]

    /// Whether this is an injected artifact / bare slash command (not a human question)
    public static func isInjectedArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        for prefix in injectedPrefixes where trimmed.hasPrefix(prefix) { return true }
        // Bare slash command ("/compact", "/effort high"): single line, short, starts with / and
        // has no further / (paths like "/usr/bin/..." contain a second / and don't count)
        if trimmed.hasPrefix("/"), !trimmed.contains("\n"), trimmed.count <= 64,
           !trimmed.dropFirst().contains("/") {
            return true
        }
        return false
    }

    /// A harness background call (OpenViking memory compaction, branch-name generation…).
    /// Its title is that prompt, not a session the user started, so history, the session list
    /// and the prompt library fold these instead of listing each one as a normal session.
    public static func isHarnessUtility(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("you are a "), lowered.contains(" utility") { return true }
        if lowered.hasPrefix("generate a short git branch name") { return true }
        return false
    }

    public static func classify(
        _ text: String, thresholds: Thresholds = Thresholds()
    ) -> PromptKind {
        if isInjectedArtifact(text) || isHarnessUtility(text) { return .noise }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if trimmed.count <= thresholds.trivialMaxLength || trivialPhrases.contains(lowered) {
            return .trivial
        }
        if trimmed.count >= thresholds.pasteMinLength && looksLikePaste(trimmed) {
            return .paste
        }
        if trimmed.count <= thresholds.followupMaxLength { return .followup }
        return .instruction
    }

    /// Whether long text looks more like a paste than a hand-written instruction: long hand-written
    /// prompts usually have markdown structure (headings / lists / quotes); log and SQL pastes
    /// don't. Scans only the first 200 lines to cap cost.
    static func looksLikePaste(_ text: String) -> Bool {
        let structured = text.split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(200)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("#") || t.hasPrefix("- ") || t.hasPrefix("* ")
                    || t.hasPrefix("> ")
            }
            .count
        return structured < 3
    }

    /// Duplicate-clustering fingerprint: lowercase + collapsed whitespace, first 512 chars only.
    /// Big pastes aren't worth scanning in full, and long texts sharing a prefix should cluster
    /// together anyway
    public static func normalizedFingerprint(_ text: String) -> String {
        String(text.prefix(512))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Storage truncation: counts characters (safe, never splits grapheme clusters) and appends a
    /// marker. The longest local entry was a 1.98MB log paste; a reuse library neither needs nor
    /// should store that in full.
    public static func truncateForStorage(_ text: String, limit: Int = 65536) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[已截断]"
    }
}
