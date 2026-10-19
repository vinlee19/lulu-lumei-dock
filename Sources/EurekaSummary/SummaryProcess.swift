import Darwin
import Foundation

/// One executor invocation: executable path + argument array, never a shell command line. The
/// prompt goes through stdin, so transcript text is never interpolated into argv.
public struct SummaryProcessSpec {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: String
    public var stdin: Data

    public init(
        executable: String, arguments: [String], environment: [String: String],
        workingDirectory: String, stdin: Data
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.stdin = stdin
    }
}

public struct SummaryProcessExit: Equatable, Sendable {
    /// Exit code, or the signal number when `signaled`
    public var status: Int32
    public var signaled: Bool

    public init(status: Int32, signaled: Bool) {
        self.status = status
        self.signaled = signaled
    }

    public var isSuccess: Bool { !signaled && status == 0 }
}

public protocol SummaryProcessHandle: AnyObject {
    /// SIGTERM to the whole process group, SIGKILL after a grace period
    func terminate()
}

/// Process seam: the real launcher spawns a process group; tests inject a scripted fake.
public protocol SummaryProcessLaunching {
    /// Callbacks may arrive on any thread. `onExit` is delivered exactly once, after every stdout
    /// and stderr chunk has been delivered.
    func launch(
        _ spec: SummaryProcessSpec,
        onStdout: @escaping (Data) -> Void,
        onStderr: @escaping (Data) -> Void,
        onExit: @escaping (SummaryProcessExit) -> Void
    ) throws -> SummaryProcessHandle
}

public struct SummaryLaunchError: Error, CustomStringConvertible {
    public let description: String
}

/// `posix_spawn` launcher. The child becomes the leader of a new process group, so cancellation
/// and cleanup reach every descendant (MCP helpers, plugin processes) and not just the CLI.
public final class PosixSummaryProcessLauncher: SummaryProcessLaunching {
    /// Grace period between SIGTERM and SIGKILL
    public var killGrace: TimeInterval = 3

    public init() {}

    public func launch(
        _ spec: SummaryProcessSpec,
        onStdout: @escaping (Data) -> Void,
        onStderr: @escaping (Data) -> Void,
        onExit: @escaping (SummaryProcessExit) -> Void
    ) throws -> SummaryProcessHandle {
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        var errors: [Int32] = [-1, -1]
        guard pipe(&input) == 0, pipe(&output) == 0, pipe(&errors) == 0 else {
            for fd in input + output + errors where fd >= 0 { close(fd) }
            throw SummaryLaunchError(description: "pipe() failed: \(String(cString: strerror(errno)))")
        }
        // Parent ends must not leak into processes other threads spawn meanwhile
        for fd in [input[1], output[0], errors[0]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Writing to a child that already exited must yield EPIPE, not kill the app
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group (pgid = child pid); close every other inherited descriptor; reset
        // the signal mask and dispositions the app may have changed
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD] {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        let argv = ([spec.executable] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executable, &actions, &attributes, argv, envp)
        // Child ends belong to the child now (or to nobody, if spawning failed)
        close(input[0])
        close(output[1])
        close(errors[1])
        guard rc == 0 else {
            close(input[1])
            close(output[0])
            close(errors[0])
            throw SummaryLaunchError(description: "posix_spawn failed: \(String(cString: strerror(rc)))")
        }

        let handle = PosixProcessHandle(pid: pid, killGrace: killGrace)
        let readers = DispatchGroup()
        Self.pump(fd: output[0], group: readers, handler: onStdout)
        Self.pump(fd: errors[0], group: readers, handler: onStderr)
        Self.feed(fd: input[1], data: spec.stdin)

        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            handle.markExited()
            // The leader is gone: anything left in its group is a stray helper. Ask it to stop,
            // then make sure, so no descendant keeps the pipes (and the app) waiting.
            kill(-pid, SIGTERM)
            if readers.wait(timeout: .now() + 2) == .timedOut {
                kill(-pid, SIGKILL)
                _ = readers.wait(timeout: .now() + 2)
            }
            let low = status & 0x7f
            let exit = low == 0
                ? SummaryProcessExit(status: (status >> 8) & 0xff, signaled: false)
                : SummaryProcessExit(status: low, signaled: true)
            onExit(exit)
        }
        return handle
    }

    /// Blocking reader on a background thread until EOF
    private static func pump(fd: Int32, group: DispatchGroup, handler: @escaping (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let size = 64 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
            defer {
                buffer.deallocate()
                close(fd)
                group.leave()
            }
            while true {
                let count = read(fd, buffer, size)
                if count > 0 {
                    handler(Data(bytes: buffer, count: count))
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    /// Writes the whole prompt to stdin, then closes it (EOF tells the CLI the prompt is complete)
    private static func feed(fd: Int32, data: Data) {
        DispatchQueue.global(qos: .utility).async {
            data.withUnsafeBytes { raw in
                guard var pointer = raw.baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written > 0 {
                        pointer += written
                        remaining -= written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        break  // EPIPE: the child stopped reading; its exit status tells why
                    }
                }
            }
            close(fd)
        }
    }
}

final class PosixProcessHandle: SummaryProcessHandle {
    private let pid: pid_t
    private let killGrace: TimeInterval
    private let lock = NSLock()
    private var exited = false

    init(pid: pid_t, killGrace: TimeInterval) {
        self.pid = pid
        self.killGrace = killGrace
    }

    func markExited() {
        lock.lock()
        exited = true
        lock.unlock()
    }

    private var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    func terminate() {
        guard !hasExited else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) { [self] in
            guard !hasExited else { return }
            kill(-pid, SIGKILL)
        }
    }
}

/// Splits a byte stream into lines. Works on raw bytes, so a UTF-8 sequence or a JSON object
/// split across reads is only decoded once its line is complete.
public struct JSONLineBuffer {
    private var pending = Data()
    /// A single line larger than this is discarded (a runaway stream, not an event)
    public static let maxLineBytes = 32 * 1024 * 1024
    public private(set) var discardedLines = 0

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        var start = pending.startIndex
        while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
            var line = pending[start..<newline]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
            start = pending.index(after: newline)
        }
        pending = Data(pending[start...])
        if pending.count > Self.maxLineBytes {
            pending = Data()
            discardedLines += 1
        }
        return lines
    }

    /// Trailing bytes without a final newline (emitted when the stream ends)
    public mutating func finish() -> Data? {
        defer { pending = Data() }
        let trimmed = pending.last == UInt8(ascii: "\r") ? pending.dropLast() : pending[...]
        return trimmed.isEmpty ? nil : Data(trimmed)
    }
}
