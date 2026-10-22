import EurekaKit
import Foundation

/// Whether an executor can be offered, and why not
public struct SummaryExecutorAvailability: Equatable, Identifiable {
    public var kind: SummaryExecutorKind
    public var executor: ResolvedExecutor?
    /// nil when available; otherwise a user-facing reason
    public var reason: String?

    public var id: String { kind.rawValue }
    public var isAvailable: Bool { executor != nil }

    public init(kind: SummaryExecutorKind, executor: ResolvedExecutor?, reason: String?) {
        self.kind = kind
        self.executor = executor
        self.reason = reason
    }
}

/// Availability probe. Installed is not enough: the adapter is only offered when the binary
/// resolves through the login shell **and** every flag the adapter relies on appears in its help
/// text. Sign-in can't be checked without a model call; auth failures surface at run time.
public final class SummaryExecutorResolver {
    public typealias Probe = (_ executable: String, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String)?

    private let probe: Probe
    private let lock = NSLock()
    private var cache: [SummaryExecutorKind: SummaryExecutorAvailability] = [:]
    private var loginEnvironment: [String: String]?

    public init(probe: Probe? = nil) {
        self.probe = probe ?? Self.runProbe
    }

    /// Cached result (probes on first use; call on a background queue)
    public func availability(
        for kind: SummaryExecutorKind, adapter: SummaryExecutorAdapter
    ) -> SummaryExecutorAvailability {
        // Checked before the cache and the probe: the adapter carries the current config
        // (e.g. Codex MCP names), so an unisolatable run is refused on every call
        if let problem = adapter.isolationProblem {
            return SummaryExecutorAvailability(kind: kind, executor: nil, reason: problem)
        }
        lock.lock()
        if let cached = cache[kind] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let result = resolve(kind: kind, adapter: adapter)
        lock.lock()
        cache[kind] = result
        lock.unlock()
        return result
    }

    /// Forget cached results (e.g. after the user installs a CLI)
    public func invalidate() {
        lock.lock()
        cache = [:]
        loginEnvironment = nil
        lock.unlock()
    }

    private func environment() -> [String: String] {
        lock.lock()
        if let cached = loginEnvironment {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var env = ProcessInfo.processInfo.environment
        // GUI apps don't inherit the login PATH; ask the login shell once
        if let result = probe("/bin/zsh", ["-lc", #"printf '%s' "$PATH""#], env),
           result.status == 0, !result.output.isEmpty {
            // Startup files may print noise first; the value is the last line
            let lines = result.output.split(whereSeparator: \.isNewline)
            if let last = lines.last { env["PATH"] = String(last) }
        }
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        lock.lock()
        loginEnvironment = env
        lock.unlock()
        return env
    }

    private func resolve(
        kind: SummaryExecutorKind, adapter: SummaryExecutorAdapter
    ) -> SummaryExecutorAvailability {
        let env = environment()
        // The command name is a compile-time constant; it is the only text given to the shell
        guard let located = probe("/bin/zsh", ["-lc", "command -v \(kind.commandName)"], env),
              located.status == 0,
              let path = located.output.split(whereSeparator: \.isNewline)
                .map({ String($0).trimmingCharacters(in: .whitespaces) })
                .last(where: { $0.hasPrefix("/") }),
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path)
        else {
            return SummaryExecutorAvailability(
                kind: kind, executor: nil,
                reason: L10n.format(
                    "`%@` was not found on your login shell PATH.",
                    zhHans: "在登录 shell 的 PATH 中找不到 `%@`。", kind.commandName))
        }
        let versionOutput = probe(path, ["--version"], env)?.output ?? ""
        let version = versionOutput.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression)
            .map { String(versionOutput[$0]) }
        guard let help = probe(path, adapter.helpArguments, env), help.status == 0 else {
            return SummaryExecutorAvailability(
                kind: kind, executor: nil,
                reason: L10n.text(
                    "The CLI did not answer its help command, so its headless mode can't be verified.",
                    zhHans: "该 CLI 未响应帮助命令，无法确认其无界面模式。"))
        }
        let missing = adapter.requiredFlags.filter { !help.output.contains($0) }
        guard missing.isEmpty else {
            return SummaryExecutorAvailability(
                kind: kind, executor: nil,
                reason: L10n.format(
                    "This version (%@) lacks %@; update the CLI.",
                    zhHans: "该版本（%@）缺少 %@，请更新 CLI。",
                    version ?? "?", missing.joined(separator: ", ")))
        }
        return SummaryExecutorAvailability(
            kind: kind,
            executor: ResolvedExecutor(kind: kind, path: path, version: version, environment: env),
            reason: nil)
    }

    /// Short-lived probe with a 15 s cap; stdout and stderr are merged into the output
    public static func runProbe(
        executable: String, arguments: [String], environment: [String: String]
    ) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let reader = DispatchQueue(label: "com.vinlee.eureka.summary-probe")
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 15) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()
        // Help output can be long; keep the first 256 KB
        return (process.terminationStatus, String(decoding: data.prefix(256 * 1024), as: UTF8.self))
    }
}
