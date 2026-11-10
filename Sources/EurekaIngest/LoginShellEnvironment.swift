import Foundation

/// The environment a command would see in the user's terminal. A GUI app is started by launchd
/// with the bare system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so anything installed by
/// Homebrew, nvm, uv or cargo — `npx`, `uvx`, `node`, most MCP servers — is invisible to it. The
/// user's shell is asked for its `PATH` once and the answer is cached for the process.
///
/// Only `PATH` is taken from the shell: the rest of the environment stays this process's own, so
/// nothing a shell startup file exports (tokens, keys) is copied into children on top of what
/// they would inherit anyway.
public final class LoginShellEnvironment: @unchecked Sendable {
    public static let shared = LoginShellEnvironment()

    public typealias PathProbe = () -> String?

    private let probe: PathProbe
    private let base: [String: String]
    private let lock = NSLock()
    private var resolved: [String: String]?

    public init(
        base: [String: String] = ProcessInfo.processInfo.environment,
        probe: PathProbe? = nil
    ) {
        self.base = base
        self.probe = probe ?? Self.askLoginShell
    }

    /// This process's environment with the login shell's `PATH` in front of its own (blocking on
    /// first use for as long as the shell takes to start; call off the main thread)
    public func environment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        var env = base
        env["PATH"] = Self.mergePaths(probe(), base["PATH"])
        resolved = env
        return env
    }

    /// Forget the cached answer (e.g. after the user installs a runtime)
    public func invalidate() {
        lock.lock()
        resolved = nil
        lock.unlock()
    }

    /// Login PATH first, then whatever this process had that the shell did not list
    static func mergePaths(_ login: String?, _ own: String?) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for source in [login, own] {
            for dir in (source ?? "").split(separator: ":") where !dir.isEmpty {
                if seen.insert(String(dir)).inserted { parts.append(String(dir)) }
            }
        }
        return parts.joined(separator: ":")
    }

    /// Asks zsh for its `PATH`. An **interactive** login shell first: version managers (nvm,
    /// fnm, asdf…) and most hand-written PATH lines live in `~/.zshrc`, which a plain `-l -c`
    /// shell never reads — on a real machine that left `npx` out. If the interactive start fails
    /// or hangs, a plain login shell is the fallback. The command text is a constant; nothing is
    /// interpolated.
    private static func askLoginShell() -> String? {
        ask(arguments: ["-l", "-i", "-c", command], timeout: 8)
            ?? ask(arguments: ["-l", "-c", command], timeout: 5)
    }

    private static let startMark = "__EUREKA_PATH_START__"
    private static let endMark = "__EUREKA_PATH_END__"
    private static let command = "printf '%s%s%s' '\(startMark)' \"$PATH\" '\(endMark)'"

    private static func ask(arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The value between the markers: startup files may print anything before or after
    public static func parse(_ output: String) -> String? {
        guard let start = output.range(of: startMark, options: .backwards),
              let end = output.range(of: endMark, range: start.upperBound..<output.endIndex)
        else { return nil }
        let value = String(output[start.upperBound..<end.lowerBound])
        return value.contains("/") ? value : nil
    }
}
