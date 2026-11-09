import Foundation

/// Runs another agent's own CLI for a read-only status query (agy `/usage`, `opencode api`).
/// GUI apps don't inherit the login PATH (agy lives in ~/.local/bin, opencode in
/// /opt/homebrew/bin), so the PATH and each command's location come from the login shell once
/// and are cached. Only compile-time command names ever reach the shell.
enum CLIProbe {
    struct Result {
        var status: Int32
        var stdout: Data
    }

    private static let lock = NSLock()
    private static var cachedEnvironment: [String: String]?
    private static var cachedPaths: [String: String?] = [:]

    /// The app environment with the login shell's PATH
    static func environment() -> [String: String] {
        lock.lock()
        if let cachedEnvironment {
            lock.unlock()
            return cachedEnvironment
        }
        lock.unlock()
        var env = ProcessInfo.processInfo.environment
        if let result = runBlocking(
            executable: "/bin/zsh", arguments: ["-lc", #"printf '%s' "$PATH""#],
            environment: env, directory: nil, timeout: 10),
           result.status == 0,
           let output = String(data: result.stdout, encoding: .utf8),
           // Startup files may print noise first; the value is the last line
           let last = output.split(whereSeparator: \.isNewline).last {
            env["PATH"] = String(last)
        }
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        lock.lock()
        cachedEnvironment = env
        lock.unlock()
        return env
    }

    /// Absolute path of a command on the login PATH; nil when not installed. Cached, including
    /// misses (installing the CLI later needs an app restart, same as the summary executors).
    static func locate(_ command: StaticString) -> String? {
        let name = "\(command)"
        lock.lock()
        if let cached = cachedPaths[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        var found: String?
        if let result = runBlocking(
            executable: "/bin/zsh", arguments: ["-lc", "command -v \(name)"],
            environment: environment(), directory: nil, timeout: 10),
           result.status == 0,
           let output = String(data: result.stdout, encoding: .utf8),
           let path = output.split(whereSeparator: \.isNewline)
               .map({ $0.trimmingCharacters(in: .whitespaces) })
               .last(where: { $0.hasPrefix("/") }),
           FileManager.default.isExecutableFile(atPath: path) {
            found = path
        }
        lock.lock()
        cachedPaths[name] = .some(found)
        lock.unlock()
        return found
    }

    /// Runs off the cooperative pool (a probe can take seconds)
    static func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval
    ) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runBlocking(
                    executable: executable, arguments: arguments, environment: environment(),
                    directory: directory, timeout: timeout))
            }
        }
    }

    /// stdout is drained while the process runs (a full pipe would block the child until the
    /// timeout); stderr is discarded. The process is terminated after `timeout`.
    static func runBlocking(
        executable: String, arguments: [String], environment: [String: String],
        directory: URL?, timeout: TimeInterval
    ) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        var output = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return nil
        }
        _ = drained.wait(timeout: .now() + 2)
        return Result(status: process.terminationStatus, stdout: output)
    }
}
