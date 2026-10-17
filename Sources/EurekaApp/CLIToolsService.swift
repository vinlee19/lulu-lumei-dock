import AppKit
import EurekaIngest
import EurekaKit
import Foundation

/// CLI tool version detection: local detection (subprocess --version) + a manual online check of
/// the latest npm version. Detection goes through a login shell (zsh -lc) to get the full PATH;
/// never runs installs on the user's behalf.
final class CLIToolsService: ObservableObject {
    struct Tool: Identifiable {
        let id: String
        var name: String
        var source: AgentSource        // icon reuses SourceBadge
        var command: String            // executable name
        var npmPackage: String
        var installCommand: String
        /// Update command: prefer each CLI's own update/upgrade subcommand; those without
        /// self-update use npm @latest. Empty string = can't update automatically (download
        /// guidance only, e.g. antigravity needs its host app installed first).
        var updateCommand: String
        var localVersion: String?      // nil = not installed / not detected
        var latestVersion: String?
        var detecting = false
        var checkingLatest = false

        /// For display and copying on the About page. Prose hints are computed in the current UI
        /// language; pure command lines (npm / curl) are the same in both languages, so the stored
        /// value is used directly.
        var displayInstallCommand: String {
            switch id {
            case "antigravity":
                return L10n.text(
                    "Download Antigravity from https://antigravity.google, then run `agy install`",
                    zhHans: "从 https://antigravity.google 下载 Antigravity 后运行 `agy install`")
            case "qoder":
                return L10n.text(
                    "Download and install Qoder from https://qoder.com (the CN CLI is bundled with the client)",
                    zhHans: "从 https://qoder.com 下载安装 Qoder（CN 版 CLI 随客户端分发）")
            case "cursor":
                return L10n.text(
                    "Download and install Cursor from https://cursor.com (in the IDE, use Cmd+Shift+P → Install 'cursor' command to enable the CLI)",
                    zhHans: "从 https://cursor.com 下载安装 Cursor（命令行入口在 IDE 内 Cmd+Shift+P → Install 'cursor' command）")
            case "trae":
                return L10n.text(
                    "Download and install Trae from https://trae.cn (China) or https://trae.ai",
                    zhHans: "从 https://trae.cn（国内）或 https://trae.ai 下载安装 Trae")
            case "zcode":
                return L10n.text(
                    "Download and install ZCode from https://z.ai (the CLI is bundled with the desktop app)",
                    zhHans: "从 https://z.ai 下载安装 ZCode（CLI 随桌面版分发）")
            default:
                return installCommand
            }
        }
    }

    @Published private(set) var tools: [Tool] = [
        Tool(id: "claude", name: "Claude Code", source: .claude,
             command: "claude", npmPackage: "@anthropic-ai/claude-code",
             installCommand: "npm install -g @anthropic-ai/claude-code",
             updateCommand: "claude update"),
        Tool(id: "codex", name: "Codex CLI", source: .codex,
             command: "codex", npmPackage: "@openai/codex",
             installCommand: "npm install -g @openai/codex",
             updateCommand: "npm install -g @openai/codex@latest"),
        Tool(id: "opencode", name: "OpenCode", source: .opencode,
             command: "opencode", npmPackage: "opencode-ai",
             installCommand: "npm install -g opencode-ai",
             updateCommand: "opencode upgrade"),
        Tool(id: "grok", name: "Grok CLI", source: .grok,
             command: "grok", npmPackage: "",
             installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash",
             updateCommand: "grok update"),
        Tool(id: "antigravity", name: "Antigravity CLI (agy)", source: .antigravity,
             command: "agy", npmPackage: "",
             installCommand: "Download Antigravity from https://antigravity.google, then run `agy install`",
             updateCommand: "agy update"),
        Tool(id: "kimi", name: "Kimi Code CLI", source: .kimi,
             command: "kimi", npmPackage: "@moonshot-ai/kimi-code",
             installCommand: "npm install -g @moonshot-ai/kimi-code",
             updateCommand: "npm install -g @moonshot-ai/kimi-code@latest"),
        Tool(id: "gemini", name: "Gemini CLI", source: .gemini,
             command: "gemini", npmPackage: "@google/gemini-cli",
             installCommand: "npm install -g @google/gemini-cli",
             updateCommand: "npm install -g @google/gemini-cli@latest"),
        Tool(id: "qwen", name: "Qwen Code CLI", source: .qwen,
             command: "qwen", npmPackage: "@qwen-code/qwen-code",
             installCommand: "npm install -g @qwen-code/qwen-code",
             updateCommand: "npm install -g @qwen-code/qwen-code@latest"),
        // Hermes is a Python + git install (~/.hermes/hermes-agent, entry point
        // ~/.local/bin/hermes), not on npm → npmPackage left empty; it ships `hermes update` (which
        // skips built-in skills the user modified).
        Tool(id: "hermes", name: "Hermes Agent", source: .hermes,
             command: "hermes", npmPackage: "",
             installCommand: "curl -fsSL https://hermes.nousresearch.com/install.sh | bash",
             updateCommand: "hermes update"),
        Tool(id: "codebuddy", name: "CodeBuddy", source: .codebuddy,
             command: "codebuddy", npmPackage: "@tencent-ai/codebuddy-code",
             installCommand: "npm install -g @tencent-ai/codebuddy-code",
             updateCommand: "npm install -g @tencent-ai/codebuddy-code@latest"),
        // Qoder CLI (CN) isn't on npm; the binary lives at
        // ~/.qoder-cn/bin/qoderclicn/qoderclicn-<version> (version in the file name, glob picks the
        // newest) → npmPackage left empty, command uses the real path; no known self-update command
        // → updateCommand left empty, download guidance only.
        Tool(id: "qoder", name: "Qoder", source: .qoder,
             command: QoderPaths.cliBinary()?.path ?? "qoderclicn", npmPackage: "",
             installCommand: "Download and install Qoder from https://qoder.com (the CN CLI is bundled with the client)",
             updateCommand: ""),
        // Cursor is an IDE; the `cursor` command-line entry is only installed to /usr/local/bin via
        // Cmd+Shift+P → "Install 'cursor' command" inside the IDE; the app itself uses its built-in
        // updater.
        Tool(id: "cursor", name: "Cursor", source: .cursor,
             command: "cursor", npmPackage: "",
             installCommand: "Download and install Cursor from https://cursor.com (in the IDE, use Cmd+Shift+P → Install 'cursor' command to enable the CLI)",
             updateCommand: ""),
        // Trae is an IDE too. The client installs its own command-line entry into /usr/local/bin:
        // `trae-cn` for CN, `trae` for international (both may be installed; this reports the first
        // installed channel, CN first). The app itself uses its built-in updater → updateCommand
        // left empty.
        Tool(id: "trae", name: "Trae", source: .trae,
             command: TraePaths.installedChannels().first?.cliCommand ?? "trae-cn",
             npmPackage: "",
             installCommand: "Download and install Trae from https://trae.cn (China) or https://trae.ai",
             updateCommand: ""),
        // ZCode CLI ships with /Applications/ZCode.app (there's usually no zcode command on PATH).
        // Version detection reads the app bundle's Info.plist (see the zcode branch of
        // detectLocal); the app updates through its client → updateCommand left empty.
        Tool(id: "zcode", name: "ZCode", source: .zcode,
             command: "zcode", npmPackage: "",
             installCommand: "Download and install ZCode from https://z.ai (the CLI is bundled with the desktop app)",
             updateCommand: ""),
    ]
    @Published private(set) var detected = false

    private let queue = DispatchQueue(label: "com.vinlee.eureka.clitools", qos: .utility)

    /// Local version detection (triggered once by the About page's onAppear, called on main)
    func detectLocal() {
        guard !detected else { return }
        detected = true
        for index in tools.indices {
            tools[index].detecting = true
        }
        let snapshot = tools
        queue.async { [weak self] in
            for tool in snapshot {
                let version: String?
                if tool.id == "zcode" {
                    // ZCode CLI ships with the app and has no command on PATH → read ZCode.app's
                    // version
                    version = Self.zcodeBundleVersion()
                } else {
                    version = Self.localVersion(command: tool.command)
                }
                DispatchQueue.main.async {
                    guard let self,
                          let index = self.tools.firstIndex(where: { $0.id == tool.id })
                    else { return }
                    self.tools[index].localVersion = version
                    self.tools[index].detecting = false
                }
            }
        }
    }

    /// CFBundleShortVersionString of /Applications/ZCode.app (nil when not installed)
    private static func zcodeBundleVersion() -> String? {
        let url = URL(fileURLWithPath: "/Applications/ZCode.app/Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any],
              let version = dict["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return nil }
        return version
    }

    /// Manual "Check for updates": queries the npm registry one by one (the only network call,
    /// user-triggered). Tools not distributed via npm (e.g. grok's curl install script) have no
    /// registry to query and are skipped.
    func checkLatest() {
        for index in tools.indices where !tools[index].npmPackage.isEmpty {
            tools[index].checkingLatest = true
        }
        let snapshot = tools.filter { !$0.npmPackage.isEmpty }
        Task { [weak self] in
            for tool in snapshot {
                let latest = await Self.npmLatestVersion(package: tool.npmPackage)
                await self?.applyLatest(toolId: tool.id, version: latest)
            }
        }
    }

    @MainActor
    private func applyLatest(toolId: String, version: String?) {
        guard let index = tools.firstIndex(where: { $0.id == toolId }) else { return }
        tools[index].latestVersion = version
        tools[index].checkingLatest = false
    }

    func copyInstallCommand(_ tool: Tool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.displayInstallCommand, forType: .string)
    }

    /// Run the tool's update command in a visible Terminal (each CLI's own update/upgrade, or npm
    /// @latest). Destructive/interactive package operations aren't run silently in-app — they go to
    /// a visible terminal where the user can watch progress, type a password, and confirm.
    func updateTool(_ tool: Tool) {
        let command = tool.updateCommand
        guard !command.isEmpty else { return }
        queue.async { Self.runInTerminal(command) }
    }

    /// osascript → Terminal `do script`: Terminal starts its own login shell → correct PATH (same
    /// as resumeInTerminal)
    private static func runInTerminal(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Version comparison

    /// Semantic version comparison: a>b → positive / a<b → negative / equal → 0. Tolerates a
    /// leading `v` and pre-release suffixes (compares core numeric fields).
    static func compareSemver(_ a: String, _ b: String) -> Int {
        func core(_ s: String) -> [Int] {
            let trimmed = s.drop(while: { !$0.isNumber })          // strip a leading v etc.
            let head = trimmed.split(separator: "-").first.map(String.init) ?? String(trimmed)
            return head.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let pa = core(a), pb = core(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Whether an update is available (both local and latest versions known, and latest > local)
    static func hasUpdate(_ tool: Tool) -> Bool {
        guard let local = tool.localVersion, let latest = tool.latestVersion else { return false }
        return compareSemver(latest, local) > 0
    }

    // MARK: - Detection implementation

    /// Run `<cmd> --version` in a login shell (GUI apps don't inherit the login PATH, so use zsh
    /// -lc)
    private static func localVersion(command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "\(command) --version 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        // Take the first 1.2.3-style version from the output; if none, show the whole line
        // truncated
        if let range = output.range(
            of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return String(output[range])
        }
        return String(output.prefix(24))
    }

    /// Latest version from the npm registry (failures silently return nil → UI shows —)
    private static func npmLatestVersion(package: String) async -> String? {
        let encoded = package.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? package
        guard let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String
        else { return nil }
        return version
    }
}
