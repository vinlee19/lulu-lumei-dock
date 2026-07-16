import AppKit
import EurekaKit
import Foundation

/// CLI 工具版本检测：本机检测（子进程 --version）+ 手动联网检查 npm 最新版。
/// 检测经登录 shell（zsh -lc）拿完整 PATH；绝不代替用户执行安装。
final class CLIToolsService: ObservableObject {
    struct Tool: Identifiable {
        let id: String
        var name: String
        var source: AgentSource        // 图标复用 SourceBadge
        var command: String            // 可执行名
        var npmPackage: String
        var installCommand: String
        var localVersion: String?      // nil = 未安装/未检测
        var latestVersion: String?
        var detecting = false
        var checkingLatest = false
    }

    @Published private(set) var tools: [Tool] = [
        Tool(id: "claude", name: "Claude Code", source: .claude,
             command: "claude", npmPackage: "@anthropic-ai/claude-code",
             installCommand: "npm install -g @anthropic-ai/claude-code"),
        Tool(id: "codex", name: "Codex CLI", source: .codex,
             command: "codex", npmPackage: "@openai/codex",
             installCommand: "npm install -g @openai/codex"),
        Tool(id: "opencode", name: "opencode", source: .opencode,
             command: "opencode", npmPackage: "opencode-ai",
             installCommand: "npm install -g opencode-ai"),
        Tool(id: "grok", name: "Grok CLI", source: .grok,
             command: "grok", npmPackage: "",
             installCommand: "curl -fsSL https://x.ai/cli/install.sh | bash"),
        Tool(id: "antigravity", name: "Antigravity CLI (agy)", source: .antigravity,
             command: "agy", npmPackage: "",
             installCommand: "从 https://antigravity.google 下载 Antigravity 后运行 `agy install`"),
    ]
    @Published private(set) var detected = false

    private let queue = DispatchQueue(label: "com.vinlee.eureka.clitools", qos: .utility)

    /// 本机版本检测（关于页 onAppear 触发一次，主线程调用）
    func detectLocal() {
        guard !detected else { return }
        detected = true
        for index in tools.indices {
            tools[index].detecting = true
        }
        let snapshot = tools
        queue.async { [weak self] in
            for tool in snapshot {
                let version = Self.localVersion(command: tool.command)
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

    /// 手动「检查更新」：逐个查 npm registry（唯一的联网点，用户主动触发）。
    /// 非 npm 分发的工具（如 grok 走 curl 安装脚本）无 registry 可查，跳过。
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
        NSPasteboard.general.setString(tool.installCommand, forType: .string)
    }

    // MARK: - 检测实现

    /// 登录 shell 跑 `<cmd> --version`（GUI app 不继承登录 PATH，走 zsh -lc）
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
        // 取输出里第一个形如 1.2.3 的版本号；取不到就整行截断展示
        if let range = output.range(
            of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) {
            return String(output[range])
        }
        return String(output.prefix(24))
    }

    /// npm registry 最新版本（失败静默返回 nil → UI 显示 —）
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
