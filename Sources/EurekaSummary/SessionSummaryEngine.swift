import EurekaKit
import Foundation

/// Turns one snapshot into one summary: a single pass when it fits the budget, otherwise one
/// invocation per turn-aware chunk followed by merge passes. Blocking; runs on the coordinator's
/// work queue.
public struct SessionSummaryEngine {
    public struct Input {
        public var snapshot: SummarySnapshot
        public var header: SummaryTemplate.SessionHeader
        public var executor: ResolvedExecutor
        public var adapter: SummaryExecutorAdapter
        public var model: String?
        public var workingDirectory: String
        public var language: AppLanguage

        public init(
            snapshot: SummarySnapshot, header: SummaryTemplate.SessionHeader,
            executor: ResolvedExecutor, adapter: SummaryExecutorAdapter, model: String?,
            workingDirectory: String, language: AppLanguage
        ) {
            self.snapshot = snapshot
            self.header = header
            self.executor = executor
            self.adapter = adapter
            self.model = model
            self.workingDirectory = workingDirectory
            self.language = language
        }
    }

    public enum Progress: Equatable {
        /// Stage change, with chunks finished / total
        case stage(SummaryStage, done: Int, total: Int)
        /// The executor produced an event
        case activity
        /// Live text of the current invocation
        case text(String)
        case coverage(SummaryCoverage)
    }

    public struct Result: Equatable {
        public var outcome: SummaryInvocationOutcome
        /// Final markdown, or the best draft when the run failed
        public var markdown: String
        public var coverage: SummaryCoverage
        public var model: String?
        public var inputTokens: Int?
        public var outputTokens: Int?
    }

    public var invoker: SummaryInvoker
    public var budget: Int

    public init(invoker: SummaryInvoker, budget: Int = SummaryChunker.defaultBudget) {
        self.invoker = invoker
        self.budget = budget
    }

    public func run(
        _ input: Input, cancel: SummaryCancelToken, progress: @escaping (Progress) -> Void
    ) -> Result {
        progress(.stage(.preparing, done: 0, total: 0))
        let plan = SummaryChunker.plan(input.snapshot.messages, budget: budget)
        var coverage = input.snapshot.coverage(
            chunkCount: plan.chunks.count, splitMessages: plan.splitMessages)
        progress(.coverage(coverage))

        var model: String?
        var inputTokens: Int?
        var outputTokens: Int?
        func account(_ result: SummaryInvocationResult) {
            model = result.model ?? model
            if let tokens = result.inputTokens { inputTokens = (inputTokens ?? 0) + tokens }
            if let tokens = result.outputTokens { outputTokens = (outputTokens ?? 0) + tokens }
        }
        func invoke(_ prompt: String, stage: SummaryStage, done: Int, total: Int) -> SummaryInvocationResult {
            progress(.stage(.launching, done: done, total: total))
            progress(.text(""))
            // Events arrive serially from the stdout reader, so plain locals are safe here
            var reported = false
            var live = ""
            let result = invoker.run(
                prompt: prompt, adapter: input.adapter, executor: input.executor,
                workingDirectory: input.workingDirectory, model: input.model, cancel: cancel
            ) { event in
                progress(.activity)
                switch event {
                case .started:
                    progress(.stage(.waiting, done: done, total: total))
                    return
                case .delta(let text):
                    live += text
                case .message(let text):
                    live = text
                }
                if !reported {
                    reported = true
                    progress(.stage(stage, done: done, total: total))
                }
                progress(.text(live))
            }
            account(result)
            return result
        }
        func finish(_ outcome: SummaryInvocationOutcome, markdown: String) -> Result {
            Result(
                outcome: outcome, markdown: markdown, coverage: coverage, model: model,
                inputTokens: inputTokens, outputTokens: outputTokens)
        }
        /// Final text: keep only citations that name a snapshot message
        func complete(_ text: String) -> Result {
            let check = SummaryReferences.validate(text, validIds: input.snapshot.messageIds)
            coverage.validReferences = check.valid
            coverage.droppedReferences = check.dropped
            return finish(.success(text: check.markdown), markdown: check.markdown)
        }

        let total = plan.chunks.count
        if total <= 1 {
            let prompt = SummaryTemplate.singlePassPrompt(
                header: input.header, messages: input.snapshot.messages, language: input.language)
            let result = invoke(prompt, stage: .summarizing, done: 0, total: 1)
            guard case .success(let text) = result.outcome else {
                return finish(result.outcome, markdown: result.text)
            }
            return complete(text)
        }

        // Chunked: notes per part, then merge
        var notes: [String] = []
        for chunk in plan.chunks {
            let prompt = SummaryTemplate.chunkPrompt(
                header: input.header, chunk: chunk, chunkCount: total,
                totalMessages: input.snapshot.messages.count, language: input.language)
            let result = invoke(prompt, stage: .summarizing, done: chunk.index, total: total)
            guard case .success(let text) = result.outcome else {
                return finish(result.outcome, markdown: Self.draft(notes: notes, partial: result.text, total: total))
            }
            notes.append(text)
        }

        var layer = notes
        while true {
            let size = layer.reduce(0) { $0 + SummaryChunker.estimateTokens($1) }
            let final = size <= budget || layer.count <= 2
            let groups = final ? [layer] : Self.group(layer, budget: budget)
            var merged: [String] = []
            for group in groups {
                let prompt = SummaryTemplate.mergePrompt(
                    header: input.header, notes: group,
                    totalMessages: input.snapshot.messages.count, final: final,
                    language: input.language)
                let result = invoke(prompt, stage: .merging, done: total, total: total)
                guard case .success(let text) = result.outcome else {
                    return finish(result.outcome, markdown: Self.draft(notes: notes, partial: result.text, total: total))
                }
                merged.append(text)
            }
            if final {
                return complete(merged[0])
            }
            layer = merged
        }
    }

    /// Consecutive groups of notes, each under the budget (at least two per group so every layer
    /// shrinks)
    static func group(_ notes: [String], budget: Int) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var size = 0
        for note in notes {
            let cost = SummaryChunker.estimateTokens(note)
            if !current.isEmpty, size + cost > budget, current.count >= 2 {
                groups.append(current)
                current = []
                size = 0
            }
            current.append(note)
            size += cost
        }
        if !current.isEmpty {
            if current.count == 1, !groups.isEmpty {
                groups[groups.count - 1].append(contentsOf: current)
            } else {
                groups.append(current)
            }
        }
        return groups
    }

    /// Draft kept when a chunked run fails: the notes finished so far plus the partial output
    static func draft(notes: [String], partial: String, total: Int) -> String {
        var sections = notes.enumerated().map { index, note in
            "<!-- part \(index + 1)/\(total) notes -->\n\(note)"
        }
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sections.append(trimmed) }
        return sections.joined(separator: "\n\n")
    }
}
