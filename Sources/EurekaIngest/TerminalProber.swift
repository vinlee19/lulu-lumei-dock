import EurekaKit
import Foundation

/// 无 hook 时的终端归属兜底：扫运行中的进程，按 cwd 认出 agent CLI，再沿父进程链上溯
/// 找到宿主终端应用。
///
/// 为什么需要：环境变量只有 relay 能拿到，所以精确采集只覆盖 Claude hooks 与 Codex notify。
/// 其余七个源（opencode / Hermes / Gemini / Qwen / Kimi / Grok / Antigravity）以及**没装
/// hook 的 Claude 用户**都得靠这条路 —— 「不装 hook 也能用」是本项目的既有原则。
///
/// 精度低于 hook 采集，故产出一律标 `origin: .probe`（UI 用虚线描边区分）：
/// 拿不到 tmux pane，且同一 (源, cwd) 有多个候选进程时会**主动放弃**而不是猜。
///
/// 刻意不 import AppKit：`EurekaIngest` 不该依赖 UI 层，宿主应用的 bundle id 从
/// `.app/Contents/Info.plist` 读出来即可。
public enum TerminalProber {
    public struct Probe: Equatable, Sendable {
        public var source: AgentSource
        public var cwd: String
        public var binding: TerminalBinding
    }

    /// 各源可接受的可执行名（取 `proc_pidpath` 的 basename）。
    ///
    /// Claude Code 的真实进程名是 `claude.exe`（node 包装器），不是 `claude` —— 实测所得。
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

    /// 父链最多上溯几层（终端 → shell → 可能的 wrapper → CLI，正常 3~5 层）
    private static let maxAncestorHops = 12

    /// 为「知道 cwd 但还不知道终端」的会话补齐归属。
    /// wanted 为空时立即返回，不做任何 syscall。
    public static func probe(wanted: [(source: AgentSource, cwd: String)]) -> [Probe] {
        guard !wanted.isEmpty else { return [] }
        let table = processTable()
        guard !table.isEmpty else { return [] }

        // 按 (源, cwd) 归组候选进程
        var candidates: [String: [ProcessEntry]] = [:]
        let wantedKeys = Set(wanted.map { key($0.source, $0.cwd) })
        for entry in table {
            // 判据一：必须有控制终端。GUI 应用派生的同名助手（如
            // /Applications/ChatGPT.app/Contents/Resources/codex）没有 tty，
            // 靠这一条就能排掉，否则光按名字匹配会把它们误当成终端会话。
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
            // 同一 (源, cwd) 有多个在跑的会话时无法判断谁是谁 → 宁可没有也不给错的
            guard group.count == 1, let entry = group.first else { continue }
            let host = terminalHost(of: entry, table: table, cache: &bundleCache)
            let binding = TerminalBinding(
                app: host.app, bundleId: host.bundleId, tty: entry.tty,
                tmuxPane: nil,  // 探测拿不到 tmux pane（那是环境变量）
                origin: .probe)
            guard !binding.isEmpty else { continue }
            result.append(Probe(source: source, cwd: cwd, binding: binding))
        }
        return result
    }

    // MARK: - 父链上溯

    /// 沿父进程链找第一个 `.app` 祖先 —— 那就是宿主终端（或 IDE 的内置终端）
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

    /// 读 `Info.plist` 拿 bundle id 与展示名（不 import AppKit 的原因见类型注释）
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

    // MARK: - 进程表原语

    public struct ProcessEntry: Equatable {
        public var pid: Int32
        public var ppid: Int32
        /// 控制终端设备路径；nil = 无控制终端（GUI 派生进程）
        public var tty: String?
    }

    /// 全进程表（pid / ppid / 控制终端）
    public static func processTable() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // 取完 size 到真正读取之间进程数可能增加，多留一截余量
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

    /// 控制终端设备号 → 具体路径。-1 / 0 = 没有控制终端。
    public static func ttyPath(of device: dev_t) -> String? {
        guard device != -1, device != 0, let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// 进程当前工作目录（`PROC_PIDVNODEPATHINFO`；他用户进程会失败 → nil）
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

    /// 进程可执行完整路径
    public static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }
}
