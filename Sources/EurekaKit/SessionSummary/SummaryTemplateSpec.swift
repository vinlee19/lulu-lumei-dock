import Foundation

/// What a summary should contain: an ordered list of sections (heading + what to write there) and
/// free-text focus instructions. Built-ins ship with the app; people copy and edit them into their
/// own templates. The safety rules and the part / merge pipeline are not part of a template and
/// can't be edited (see `SummaryTemplate`).
public struct SummaryTemplateSpec: Codable, Equatable, Identifiable, Sendable {
    public struct Section: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var heading: String
        /// What to write under the heading (may be empty)
        public var guidance: String

        public init(id: String = UUID().uuidString, heading: String, guidance: String = "") {
            self.id = id
            self.heading = heading
            self.guidance = guidance
        }
    }

    public var id: String
    public var name: String
    /// One line shown in the template picker
    public var summary: String
    public var sections: [Section]
    /// Extra instructions appended to the prompt (perspective, emphasis, length…)
    public var focus: String

    public init(id: String, name: String, summary: String, sections: [Section], focus: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.sections = sections
        self.focus = focus
    }

    public var isBuiltIn: Bool { Self.builtInIds.contains(id) }

    /// Sections with a heading (empty rows from the editor are skipped)
    public var usableSections: [Section] {
        sections.filter { !$0.heading.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A user-owned copy to edit (built-ins are read-only)
    public func duplicated(name: String) -> SummaryTemplateSpec {
        SummaryTemplateSpec(
            id: "custom-" + UUID().uuidString, name: name, summary: summary,
            sections: sections.map { Section(heading: $0.heading, guidance: $0.guidance) },
            focus: focus)
    }

    // MARK: - Built-ins

    public static let defaultId = "collab-review"
    public static let handoffId = "handoff"
    public static let briefId = "brief"
    static let builtInIds: Set<String> = [defaultId, handoffId, briefId]

    /// Headings of the built-in templates. They stay English in every UI language so the result
    /// parses the same way (the UI shows localized titles for them).
    public enum Heading {
        public static let tldr = "TL;DR"
        public static let learned = "What I learned"
        public static let designDecisions = "My design decisions"
        public static let choices = "My choices on AI proposals"
        public static let evolution = "How the approach evolved"
        public static let risks = "Open questions and risks"
        public static let keep = "Worth keeping"
        public static let overview = "Overview"
        public static let outcome = "Outcome"
        public static let nextSteps = "Next steps"
    }

    /// Built-in templates (a computed list: their names follow the current UI language)
    public static var builtIns: [SummaryTemplateSpec] { [collabReview, handoff, brief] }

    public static func builtIn(_ id: String) -> SummaryTemplateSpec? {
        builtIns.first { $0.id == id }
    }

    public static var collabReview: SummaryTemplateSpec {
        SummaryTemplateSpec(
            id: defaultId,
            name: L10n.text("My collaboration review", zhHans: "我的协作复盘"),
            summary: L10n.text(
                "What I learned, the design calls I made and why, and how I chose among the AI's proposals.",
                zhHans: "我学到了什么、做了哪些设计和为什么，以及面对 AI 方案时我是怎么抉择的。"),
            sections: [
                Section(id: "tldr", heading: Heading.tldr, guidance: """
                    Three short lines: what was achieved, where it stands now, and the very next step.
                    """),
                Section(id: "learned", heading: Heading.learned, guidance: """
                    Things I did not know before this session, or understood better because of it: \
                    how something works, a pitfall to avoid, a technique. One bullet each, with the \
                    message that taught it.
                    """),
                Section(id: "design", heading: Heading.designDecisions, guidance: """
                    Design calls I made (architecture, approach, scope, naming, trade-offs), not code \
                    the AI wrote. One bullet each: the decision, then my reason. If the transcript does \
                    not state my reason, write "reason not stated" instead of guessing one.
                    """),
                Section(id: "choices", heading: Heading.choices, guidance: """
                    Every point where the AI proposed something and I accepted, rejected, modified or \
                    overrode it. One bullet each, exactly in this form (keep the bold labels in English): \
                    `- **AI proposed:** <proposal> → **I chose:** <accepted / rejected / modified, and \
                    what I did instead> — **Why:** <my stated reason, or "reason not stated"> [#n]`
                    """),
                Section(id: "evolution", heading: Heading.evolution, guidance: """
                    In order: the first idea, each change of direction and what triggered it, and the \
                    final position. One bullet per step, starting with its [#n] marker.
                    """),
                Section(id: "risks", heading: Heading.risks, guidance: """
                    What is still unresolved, and claims the AI made that the transcript never verified.
                    """),
                Section(id: "keep", heading: Heading.keep, guidance: """
                    Up to 6 items worth saving for future sessions, only when the transcript supports \
                    them. One bullet each, exactly one of these forms (keep the bold kind in English): \
                    `- **Memory** | <short title> | <a fact or decision with its reason, self-contained, \
                    1-3 sentences> [#n]` for knowledge about this project, or \
                    `- **Rule** | <short title> | <how the AI should work with me next time, written as \
                    an instruction> [#n]` for preferences that my corrections reveal. Write "None" if \
                    nothing qualifies.
                    """),
            ],
            focus: """
                Write from my point of view in the first person ("I chose…"). I ran this session; \
                focus on what I learned and decided, not on narrating everything the AI did.
                """)
    }

    public static var handoff: SummaryTemplateSpec {
        SummaryTemplateSpec(
            id: handoffId,
            name: L10n.text("Handoff", zhHans: "交接"),
            summary: L10n.text(
                "Overview, decisions and evidence, finished and verified work, open items and next steps.",
                zhHans: "概览、关键决策与依据、已完成与验证、未决事项和下一步。"),
            sections: [
                Section(id: "overview", heading: Heading.overview),
                Section(id: "changes", heading: "Requirements and approach changes"),
                Section(id: "decisions", heading: "Key decisions and evidence"),
                Section(id: "done", heading: "Completed work and verification"),
                Section(id: "open", heading: "Unresolved items"),
                Section(id: "handoff", heading: "Handoff", guidance: """
                    Under three sub-headings: ### Files, ### Commands, ### Next steps.
                    """),
            ],
            focus: """
                Write for someone taking the work over. Keep four kinds of statements apart and label \
                them inline: **User requirement**, **AI proposal**, **Performed action** (only when a \
                TOOLS line or tool result shows it), **Unverified claim** (the assistant said it, but \
                the transcript shows no evidence).
                """)
    }

    public static var brief: SummaryTemplateSpec {
        SummaryTemplateSpec(
            id: briefId,
            name: L10n.text("Brief", zhHans: "简报"),
            summary: L10n.text(
                "Three lines, what was delivered, and what comes next.",
                zhHans: "三行速览、交付了什么、接下来做什么。"),
            sections: [
                Section(id: "tldr", heading: Heading.tldr, guidance: """
                    Three short lines: what was achieved, where it stands now, and the very next step.
                    """),
                Section(id: "outcome", heading: Heading.outcome, guidance: """
                    What was delivered and whether it was verified, as a short list.
                    """),
                Section(id: "next", heading: Heading.nextSteps, guidance: "At most five concrete steps."),
            ],
            focus: "Be brief: the whole summary should fit on one screen.")
    }
}
