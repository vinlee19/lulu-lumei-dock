import EurekaKit
import Foundation

/// An executor that passed the availability probe: absolute path plus the environment to run it
/// with (the login shell's PATH, so Homebrew / npm installs resolve their own helpers).
public struct ResolvedExecutor: Equatable {
    public var kind: SummaryExecutorKind
    public var path: String
    public var version: String?
    public var environment: [String: String]

    public init(
        kind: SummaryExecutorKind, path: String, version: String?, environment: [String: String]
    ) {
        self.kind = kind
        self.path = path
        self.version = version
        self.environment = environment
    }
}

/// Cancellation shared by the coordinator and the running invocation. Cancelling terminates the
/// attached process group immediately; a process attached after cancellation is terminated on
/// attach.
public final class SummaryCancelToken {
    private let lock = NSLock()
    private var cancelled = false
    private var handle: SummaryProcessHandle?

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = handle
        lock.unlock()
        current?.terminate()
    }

    func attach(_ newHandle: SummaryProcessHandle?) {
        lock.lock()
        handle = newHandle
        let terminateNow = cancelled
        lock.unlock()
        if terminateNow { newHandle?.terminate() }
    }
}

public enum SummaryInvocationOutcome: Equatable {
    case success(text: String)
    case failure(kind: SummaryFailureKind, message: String?)
}

/// Result of one CLI invocation plus what it reported along the way
public struct SummaryInvocationResult: Equatable {
    public var outcome: SummaryInvocationOutcome
    /// Best text seen (final text on success, the partial stream otherwise)
    public var text: String
    public var model: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
}

/// Runs one prompt through one adapter: concurrent stdout/stderr, a bounded diagnostic tail, a
/// timeout, cancellation, and a full drain before the outcome is decided.
public struct SummaryInvoker {
    public var launcher: SummaryProcessLaunching
    public var timeout: TimeInterval
    /// After a timeout or cancel, how long to wait for the process group to exit
    public var exitWait: TimeInterval = 20

    /// stderr kept for diagnostics (tail, bytes)
    public static let stderrTailLimit = 8 * 1024

    public init(launcher: SummaryProcessLaunching, timeout: TimeInterval) {
        self.launcher = launcher
        self.timeout = timeout
    }

    public func run(
        prompt: String, adapter: SummaryExecutorAdapter, executor: ResolvedExecutor,
        workingDirectory: String, model: String?, cancel: SummaryCancelToken,
        onEvent: @escaping (SummaryExecutorEvent) -> Void
    ) -> SummaryInvocationResult {
        let parser = adapter.makeParser()
        let lock = NSLock()
        var lines = JSONLineBuffer()
        var stderrTail = Data()
        var liveText = ""
        var exit: SummaryProcessExit?
        let exited = DispatchSemaphore(value: 0)

        // Called under `lock`; returns events to deliver after unlocking
        func process(_ line: Data) -> [SummaryExecutorEvent] {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else {
                parser.state.nonJSONLines += 1
                return []
            }
            parser.state.jsonLines += 1
            let events = parser.consume(object)
            for event in events {
                switch event {
                case .delta(let text): liveText += text
                case .message(let text): liveText = text
                case .started: break
                }
            }
            return events
        }

        var environment = executor.environment
        for (key, value) in adapter.extraEnvironment { environment[key] = value }
        let spec = SummaryProcessSpec(
            executable: executor.path,
            arguments: adapter.arguments(workingDirectory: workingDirectory, model: model),
            environment: environment, workingDirectory: workingDirectory,
            stdin: Data(prompt.utf8))

        let handle: SummaryProcessHandle
        do {
            handle = try launcher.launch(
                spec,
                onStdout: { chunk in
                    lock.lock()
                    let events = lines.append(chunk).flatMap(process)
                    lock.unlock()
                    events.forEach(onEvent)
                },
                onStderr: { chunk in
                    lock.lock()
                    stderrTail.append(chunk)
                    if stderrTail.count > Self.stderrTailLimit {
                        stderrTail = Data(stderrTail.suffix(Self.stderrTailLimit))
                    }
                    lock.unlock()
                },
                onExit: { status in
                    lock.lock()
                    // Trailing line without a newline still counts (drain before finalizing)
                    let events = lines.finish().map(process) ?? []
                    exit = status
                    lock.unlock()
                    events.forEach(onEvent)
                    exited.signal()
                })
        } catch {
            return SummaryInvocationResult(
                outcome: .failure(kind: .launchFailed, message: Self.diagnostic("\(error)")),
                text: "", model: nil, inputTokens: nil, outputTokens: nil)
        }
        cancel.attach(handle)
        defer { cancel.attach(nil) }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            handle.terminate()
            _ = exited.wait(timeout: .now() + exitWait)
        }

        lock.lock()
        let state = parser.state
        let finalExit = exit
        let tail = String(decoding: stderrTail, as: UTF8.self)
        let partial = liveText
        lock.unlock()

        let text = state.succeeded && !state.finalText.isEmpty ? state.finalText : partial
        var result = SummaryInvocationResult(
            outcome: .success(text: text), text: text, model: state.model,
            inputTokens: state.inputTokens, outputTokens: state.outputTokens)
        result.outcome = Self.classify(
            state: state, exit: finalExit, text: text, stderrTail: tail,
            cancelled: cancel.isCancelled, timedOut: timedOut)
        return result
    }

    static func classify(
        state: SummaryParseState, exit: SummaryProcessExit?, text: String, stderrTail: String,
        cancelled: Bool, timedOut: Bool
    ) -> SummaryInvocationOutcome {
        if cancelled { return .failure(kind: .cancelled, message: nil) }
        if timedOut { return .failure(kind: .timeout, message: nil) }
        if let error = state.errorMessage {
            return .failure(
                kind: looksLikeAuthFailure(error) ? .authentication : .executorError,
                message: diagnostic(error))
        }
        guard let exit else { return .failure(kind: .nonzeroExit, message: nil) }
        if !exit.isSuccess {
            let detail = lastLines(stderrTail)
            let code = exit.signaled ? "signal \(exit.status)" : "exit code \(exit.status)"
            return .failure(
                kind: looksLikeAuthFailure(stderrTail) ? .authentication : .nonzeroExit,
                message: diagnostic(detail.isEmpty ? code : "\(code): \(detail)"))
        }
        if state.jsonLines == 0 {
            return .failure(kind: .malformedOutput, message: diagnostic(lastLines(stderrTail)))
        }
        if !state.succeeded {
            return .failure(
                kind: .malformedOutput,
                message: "The CLI ended without a completion event.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(kind: .emptyOutput, message: nil) }
        return .success(text: trimmed)
    }

    static let authPattern = try! NSRegularExpression(
        pattern: #"(?i)(not logged in|please run /login|log ?in again|unauthori[sz]ed|invalid api key|invalid x-api-key|authentication|\b401\b|\b403\b|oauth token|token (?:has )?expired|credentials? (?:are |is )?(?:missing|invalid))"#)

    static func looksLikeAuthFailure(_ text: String) -> Bool {
        authPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Last few non-empty lines of stderr (the useful part of a crash or usage error)
    static func lastLines(_ text: String, count: Int = 4) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }

    static let ansiPattern = try! NSRegularExpression(pattern: #"\u001B\[[0-9;?]*[A-Za-z]"#)

    /// Diagnostics shown to the user: ANSI stripped, credentials redacted, length bounded
    static func diagnostic(_ text: String) -> String {
        let plain = ansiPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        let redacted = AuditRedactor.redact(detail: plain, tool: "summary").text
        return redacted.count > 1200 ? String(redacted.prefix(1200)) + "…" : redacted
    }
}
