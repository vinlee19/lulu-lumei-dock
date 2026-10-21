import EurekaKit
import Foundation

/// Fallback terminal attribution when there are no hooks: scan running processes, identify agent
/// CLIs by cwd, then walk up the parent-process chain to find the host terminal app.
///
/// Why: only the relay can see environment variables, so precise collection covers only Claude hooks and Codex notify.
/// The other seven sources (opencode / Hermes / Gemini / Qwen / Kimi / Grok / Antigravity) and **Claude users
/// without hooks** all depend on this path; "works without hooks" is an established principle of this project.
///
/// Less precise than hook collection, so every result is tagged `origin: .probe` (the UI marks it with a dashed outline):
/// it can't get the tmux pane, and when one (source, cwd) has several candidate processes it **deliberately gives up** rather than guess.
///
/// Deliberately doesn't import AppKit: `EurekaIngest` shouldn't depend on the UI layer, and the host app's bundle id
/// can simply be read from `.app/Contents/Info.plist`.
public enum TerminalProber {
    public struct Probe: Equatable, Sendable {
        public var source: AgentSource
        public var cwd: String
        public var binding: TerminalBinding
    }

    /// Accepted executable names per source (basename of `proc_pidpath`).
    ///
    /// Claude Code's real process name is `claude.exe` (a node wrapper), not `claude`, as observed in practice.
    static let agentExecutables: [AgentSource: Set<String>] = [
        .claude: ["claude", "claude.exe"],
        .codex: ["codex", "codex.exe"],
        .opencode: ["opencode", "opencode.exe"],
        .grok: ["grok", "grok.exe"],
        .kimi: ["kimi", "kimi.exe"],
        .gemini: ["gemini", "gemini.exe"],
        .qwen: ["qwen", "qwen.exe"],
        .hermes: ["hermes", "hermes.exe"],
        .zcode: ["zcode", "zcode.exe", "zai", "zai.exe"],
    ]

    /// Maximum parent-chain hops (terminal → shell → possible wrapper → CLI, normally 3-5 hops)
    private static let maxAncestorHops = 12

    /// Fills in attribution for sessions whose cwd is known but whose terminal isn't yet.
    /// Returns immediately with no syscalls when wanted is empty.
    public static func probe(wanted: [(source: AgentSource, cwd: String)]) -> [Probe] {
        guard !wanted.isEmpty else { return [] }
        let table = processTable()
        guard !table.isEmpty else { return [] }

        // Group candidate processes by (source, cwd)
        var candidates: [String: [ProcessEntry]] = [:]
        let wantedKeys = Set(wanted.map { key($0.source, $0.cwd) })
        for entry in table {
            // Criterion one: there must be a controlling terminal. Same-named helpers spawned by
            // GUI apps (e.g.
            // /Applications/ChatGPT.app/Contents/Resources/codex) have no tty,
            // so this alone excludes them; matching on name only would mistake them for terminal
            // sessions.
            guard entry.tty != nil else { continue }
            guard let path = processPath(entry.pid) else { continue }
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard let source = source(forExecutable: name) else { continue }
            guard let cwd = processCWD(entry.pid) else { continue }
            let candidateKey = key(source, cwd)
            guard wantedKeys.contains(candidateKey) else { continue }
            candidates[candidateKey, default: []].append(entry)
        }

        var result: [Probe] = []
        var bundleCache: [String: (bundleId: String?, app: String?)] = [:]
        for (source, cwd) in wanted {
            let group = candidates[key(source, cwd)] ?? []
            // Several running sessions for one (source, cwd) can't be told apart → better nothing
            // than a wrong answer
            guard group.count == 1, let entry = group.first else { continue }
            let host = terminalHost(of: entry, table: table, cache: &bundleCache)
            let binding = TerminalBinding(
                app: host.app, bundleId: host.bundleId, tty: entry.tty,
                tmuxPane: nil,  // Probing can't see the tmux pane (it comes from env vars)
                origin: .probe)
            guard !binding.isEmpty else { continue }
            result.append(Probe(source: source, cwd: cwd, binding: binding))
        }
        return result
    }

    // MARK: - Parent-chain walk

    /// Walk the parent-process chain to the first `.app` ancestor: that's the host terminal (or an
    /// IDE's built-in terminal)
    private static func terminalHost(
        of entry: ProcessEntry, table: [ProcessEntry],
        cache: inout [String: (bundleId: String?, app: String?)]
    ) -> (bundleId: String?, app: String?) {
        var byPID: [Int32: ProcessEntry] = [:]
        for item in table { byPID[item.pid] = item }

        var current = entry.ppid
        var hops = 0
        while current > 1, hops < maxAncestorHops {
            if let path = processPath(current), let bundleRoot = appBundleRoot(of: path) {
                if let cached = cache[bundleRoot] { return cached }
                let resolved = bundleIdentity(at: bundleRoot)
                cache[bundleRoot] = resolved
                return resolved
            }
            guard let parent = byPID[current]?.ppid else { break }
            current = parent
            hops += 1
        }
        return (nil, nil)
    }

    /// `/Applications/iTerm.app/Contents/MacOS/iTerm2` → `/Applications/iTerm.app`
    public static func appBundleRoot(of executablePath: String) -> String? {
        let marker = ".app/Contents/MacOS/"
        guard let range = executablePath.range(of: marker) else { return nil }
        return String(executablePath[executablePath.startIndex..<range.lowerBound]) + ".app"
    }

    /// Read `Info.plist` for the bundle id and display name (see the type comment for why AppKit
    /// isn't imported)
    private static func bundleIdentity(at bundleRoot: String) -> (bundleId: String?, app: String?) {
        let plistURL = URL(fileURLWithPath: bundleRoot)
            .appendingPathComponent("Contents/Info.plist")
        let appName = URL(fileURLWithPath: bundleRoot).lastPathComponent
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        else { return (nil, appName) }
        return (plist["CFBundleIdentifier"] as? String, appName)
    }

    private static func source(forExecutable name: String) -> AgentSource? {
        let lowered = name.lowercased()
        for (source, names) in agentExecutables where names.contains(lowered) {
            return source
        }
        return nil
    }

    private static func key(_ source: AgentSource, _ cwd: String) -> String {
        "\(source.rawValue)|\(cwd)"
    }

    // MARK: - Process-table primitives

    public struct ProcessEntry: Equatable {
        public var pid: Int32
        public var ppid: Int32
        /// Controlling-terminal device path; nil = no controlling terminal (GUI-spawned process)
        public var tty: String?
    }

    /// Full process table (pid / ppid / controlling terminal)
    public static func processTable() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // The process count may grow between sizing and the actual read, so leave some headroom
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return (0..<(size / stride)).map { index in
            let info = buffer[index]
            return ProcessEntry(
                pid: info.kp_proc.p_pid, ppid: info.kp_eproc.e_ppid,
                tty: ttyPath(of: info.kp_eproc.e_tdev))
        }
    }

    /// Controlling-terminal device number → concrete path. -1 / 0 = no controlling terminal.
    public static func ttyPath(of device: dev_t) -> String? {
        guard device != -1, device != 0, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Current working directory of a process (`PROC_PIDVNODEPATHINFO`; fails for other users'
    /// processes → nil)
    public static func processCWD(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
        return path.isEmpty ? nil : path
    }

    /// Full executable path of a process
    public static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    /// Process argv (`KERN_PROCARGS2`); another user's process / an exited one → nil.
    /// A resumed Claude session carries its id in argv (`--resume=<id>`), the only clue without hooks
    /// for "which process belongs to which session".
    public static func processArguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Data(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2` buffer layout: int32 argc | executable path \0 | alignment \0s | argc
    /// NUL-terminated arguments | environment…
    /// Pure parsing, unit-tested; only argc arguments are taken and the environment is never read
    /// (it may hold credentials).
    public static func parseProcArgs(_ data: Data) -> [String]? {
        guard data.count > 4 else { return nil }
        let argc = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) })
        guard argc >= 0 else { return nil }
        var index = data.startIndex + 4
        while index < data.endIndex, data[index] != 0 { index += 1 }  // executable path
        while index < data.endIndex, data[index] == 0 { index += 1 }  // alignment padding
        var args: [String] = []
        var current: [UInt8] = []
        while index < data.endIndex, args.count < argc {
            let byte = data[index]
            if byte == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            index += 1
        }
        return args
    }
}
