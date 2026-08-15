import EurekaKit
import Foundation

/// 按 AgentSource 的配置约定表：各 agent 把技能 / MCP / 记忆 / 子智能体定义放在哪些路径。
/// 逐源尽力填写；未知源目录全空，退化为「对话消息 + 系统提示词(含其余)」两类估算。
public struct AgentContextProfile: Equatable, Sendable {
    /// 技能目录（读其中 */SKILL.md 的 frontmatter 描述）
    public var skillDirs: [String]
    /// MCP 配置文件（只数 server 个数；工具 schema 不可得，按常量估算）
    public var mcpConfigFiles: [String]
    /// 记忆/指令文件（全文注入 system prompt）
    public var memoryFiles: [String]
    /// 子智能体定义目录（*.md frontmatter 注入工具列表）
    public var agentDirs: [String]
    /// 系统提示词基线（估算基线：CLI 骨架提示词，transcript 不记录，经验值兜底）
    public var baselineSystemPromptTokens: Int
    /// 内建工具 schema 基线（估算基线：schema 不进 transcript，经验值兜底）
    public var baselineBuiltinToolTokens: Int
    /// 每个已配置 MCP server 的固定估算（schema 不可得，只能按常驻常量估）
    public var perMCPServerTokens: Int

    public init(
        skillDirs: [String], mcpConfigFiles: [String], memoryFiles: [String],
        agentDirs: [String], baselineSystemPromptTokens: Int,
        baselineBuiltinToolTokens: Int, perMCPServerTokens: Int
    ) {
        self.skillDirs = skillDirs
        self.mcpConfigFiles = mcpConfigFiles
        self.memoryFiles = memoryFiles
        self.agentDirs = agentDirs
        self.baselineSystemPromptTokens = baselineSystemPromptTokens
        self.baselineBuiltinToolTokens = baselineBuiltinToolTokens
        self.perMCPServerTokens = perMCPServerTokens
    }

    // MARK: - 估算基线常量（集中定义，偏大无害：reconcile 拿到真实总量会按比例压缩）

    static let defaultSystemPromptBaseline = 2_000
    static let defaultBuiltinToolBaseline = 4_000
    static let defaultPerMCPServerTokens = 1_500

    public static func profile(
        for source: AgentSource,
        cwd: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AgentContextProfile {
        func at(_ base: String?, _ path: String) -> [String] {
            guard let base, !base.isEmpty else { return [] }
            return [URL(fileURLWithPath: base).appendingPathComponent(path).path]
        }
        switch source {
        case .claude:
            return AgentContextProfile(
                skillDirs: [home.appendingPathComponent(".claude/skills").path]
                    + at(cwd, ".claude/skills"),
                mcpConfigFiles: [home.appendingPathComponent(".claude.json").path]
                    + at(cwd, ".mcp.json"),
                memoryFiles: [home.appendingPathComponent(".claude/CLAUDE.md").path]
                    + at(cwd, "CLAUDE.md"),
                agentDirs: [home.appendingPathComponent(".claude/agents").path]
                    + at(cwd, ".claude/agents"),
                // Claude Code 系统提示词骨架 + 内建工具 schema 都偏大（实测量级）
                baselineSystemPromptTokens: 3_000,
                baselineBuiltinToolTokens: 13_000,
                perMCPServerTokens: defaultPerMCPServerTokens)
        case .kimi:
            return AgentContextProfile(
                skillDirs: [home.appendingPathComponent(".agents/skills").path]
                    + at(cwd, ".agents/skills"),
                mcpConfigFiles: [home.appendingPathComponent(".kimi-code/config.toml").path],
                memoryFiles: at(cwd, "AGENTS.md"),
                agentDirs: [],
                baselineSystemPromptTokens: 3_000,
                baselineBuiltinToolTokens: 8_000,
                perMCPServerTokens: defaultPerMCPServerTokens)
        case .codex:
            return AgentContextProfile(
                skillDirs: [home.appendingPathComponent(".codex/skills").path],
                mcpConfigFiles: [home.appendingPathComponent(".codex/config.toml").path],
                memoryFiles: [home.appendingPathComponent(".codex/AGENTS.md").path]
                    + at(cwd, "AGENTS.md"),
                agentDirs: [],
                baselineSystemPromptTokens: 4_000,
                baselineBuiltinToolTokens: 8_000,
                perMCPServerTokens: defaultPerMCPServerTokens)
        case .gemini:
            return AgentContextProfile(
                skillDirs: [],
                mcpConfigFiles: [home.appendingPathComponent(".gemini/settings.json").path],
                memoryFiles: [home.appendingPathComponent(".gemini/GEMINI.md").path]
                    + at(cwd, "GEMINI.md"),
                agentDirs: [],
                baselineSystemPromptTokens: defaultSystemPromptBaseline,
                baselineBuiltinToolTokens: defaultBuiltinToolBaseline,
                perMCPServerTokens: defaultPerMCPServerTokens)
        case .qwen:
            return AgentContextProfile(
                skillDirs: [],
                mcpConfigFiles: [],
                memoryFiles: at(cwd, "QWEN.md"),
                agentDirs: [],
                baselineSystemPromptTokens: defaultSystemPromptBaseline,
                baselineBuiltinToolTokens: defaultBuiltinToolBaseline,
                perMCPServerTokens: defaultPerMCPServerTokens)
        default:
            // 无配置约定的源：目录全空，只剩基线 + 对话消息两类
            return AgentContextProfile(
                skillDirs: [], mcpConfigFiles: [], memoryFiles: [], agentDirs: [],
                baselineSystemPromptTokens: defaultSystemPromptBaseline,
                baselineBuiltinToolTokens: defaultBuiltinToolBaseline,
                perMCPServerTokens: defaultPerMCPServerTokens)
        }
    }
}

/// 上下文用量分类估算器：最后一轮真实总量（若有）+ 对话消息估算 + 配置文件测量。
/// 全部 best-effort：任何文件缺失/解析失败都安静跳过，不抛错。
public enum ContextBreakdownEstimator {
    /// 入口：按源估五类，再与最后一轮真实总量对账。
    /// - model：该会话 token 最多的模型（决定窗口大小）；nil → 默认窗口。
    /// - lastTurnTotalTokens：LastTurnUsageReader 的结果；nil → 总量为纯估算。
    public static func estimate(
        source: AgentSource,
        cwd: String?,
        messages: [TranscriptMessage],
        model: String?,
        lastTurnTotalTokens: Int?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ContextBreakdown {
        let profile = AgentContextProfile.profile(for: source, cwd: cwd, home: home)
        var estimates: [ContextBreakdown.Category: Int] = [
            .messages: messages.reduce(0) { $0 + TokenEstimator.estimate($1.text) },
            .systemPrompt: profile.baselineSystemPromptTokens,
            .tools: profile.baselineBuiltinToolTokens,
            .mcp: mcpServerCount(profile: profile) * profile.perMCPServerTokens,
            .skills: 0,
        ]
        estimates[.systemPrompt, default: 0] += profile.memoryFiles.reduce(0) {
            $0 + estimateFileText(at: $1)
        }
        estimates[.tools, default: 0] += profile.agentDirs.reduce(0) {
            $0 + estimateMarkdownFrontmatter(inDir: $1)
        }
        estimates[.skills, default: 0] = profile.skillDirs.reduce(0) {
            $0 + estimateSkills(inDir: $1)
        }
        return reconcile(
            estimates: estimates,
            windowTokens: ContextWindows.window(forModel: model),
            lastTurnTotalTokens: lastTurnTotalTokens)
    }

    /// 对账（纯函数，可单测）：
    /// 有真实总量 R 时 —— 估算合计 E < R，差值并入 systemPrompt（「系统提示词」含其余
    /// 开销）；E > R 则各类按比例缩放到 R（残差补到最大类，保证合计严格等于 R）。
    /// 没有 R → totalIsReal = false，总量 = 估算合计。
    public static func reconcile(
        estimates: [ContextBreakdown.Category: Int],
        windowTokens: Int,
        lastTurnTotalTokens: Int?
    ) -> ContextBreakdown {
        var tokens: [ContextBreakdown.Category: Int] = [:]
        for category in ContextBreakdown.Category.allCases {
            tokens[category] = max(0, estimates[category] ?? 0)
        }
        let estimateTotal = tokens.values.reduce(0, +)

        if let real = lastTurnTotalTokens, real > 0 {
            if estimateTotal < real {
                tokens[.systemPrompt, default: 0] += real - estimateTotal
            } else if estimateTotal > real {
                var scaled: [ContextBreakdown.Category: Int] = [:]
                for (category, value) in tokens {
                    scaled[category] = Int((Double(value) * Double(real) / Double(estimateTotal)).rounded())
                }
                // 舍入残差补到最大类，保证缩放后合计 == R
                let residual = real - scaled.values.reduce(0, +)
                if residual != 0,
                   let largest = scaled.max(by: { $0.value < $1.value })?.key {
                    scaled[largest, default: 0] += residual
                }
                tokens = scaled
            }
            return ContextBreakdown(
                entries: ContextBreakdown.Category.allCases.map {
                    .init(category: $0, tokens: tokens[$0] ?? 0)
                },
                totalTokens: real, windowTokens: windowTokens, totalIsReal: true)
        }
        return ContextBreakdown(
            entries: ContextBreakdown.Category.allCases.map {
                .init(category: $0, tokens: tokens[$0] ?? 0)
            },
            totalTokens: estimateTotal, windowTokens: windowTokens, totalIsReal: false)
    }

    // MARK: - 私有：各类目测量

    /// 技能目录：每个子目录的 SKILL.md 只取 frontmatter 的 name+description 估算
    /// （注入 context 的就是这段描述，不是技能全文）
    private static func estimateSkills(inDir dir: String) -> Int {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var total = 0
        for sub in subs {
            let skillFile = URL(fileURLWithPath: dir)
                .appendingPathComponent(sub).appendingPathComponent("SKILL.md").path
            guard let head = readHead(path: skillFile) else { continue }
            let frontmatter = frontmatterFields(head, keys: ["name", "description"])
            // frontmatter 缺失时按目录名兜底（有技能就该计入一点开销）
            total += frontmatter.isEmpty
                ? TokenEstimator.estimate(sub)
                : TokenEstimator.estimate(frontmatter)
        }
        return total
    }

    /// Markdown 定义目录（子智能体等）：逐个 *.md 取 frontmatter name+description 估算
    private static func estimateMarkdownFrontmatter(inDir dir: String) -> Int {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var total = 0
        for file in files where file.hasSuffix(".md") {
            guard let head = readHead(
                path: URL(fileURLWithPath: dir).appendingPathComponent(file).path)
            else { continue }
            let frontmatter = frontmatterFields(head, keys: ["name", "description"])
            total += TokenEstimator.estimate(frontmatter.isEmpty ? head : frontmatter)
        }
        return total
    }

    /// 记忆/指令文件：全文注入 system prompt，整篇估算
    private static func estimateFileText(at path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return 0 }
        return TokenEstimator.estimate(text)
    }

    /// MCP server 个数：JSON 配置数 mcpServers 键；TOML 数 [mcp_servers.xxx] 段。
    /// server 的工具 schema 拿不到（需实际连接），只能按个数 × 常驻常量估算。
    private static func mcpServerCount(profile: AgentContextProfile) -> Int {
        var count = 0
        for path in profile.mcpConfigFiles {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            if path.hasSuffix(".json") {
                if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let servers = root["mcpServers"] as? [String: Any] {
                    count += servers.count
                }
            } else {
                // TOML 无解析器依赖，按段头计数（codex [mcp_servers.xxx] / kimi [mcp.xxx]）
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[mcp_servers.") || trimmed.hasPrefix("[mcp.") {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    /// 文件头部（frontmatter 都在开头，读 8KB 足够）
    private static func readHead(path: String, bytes: Int = 8192) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: bytes)
        return String(data: data, encoding: .utf8)
    }

    /// 提取 YAML frontmatter（--- 包裹段）里指定键的取值文本
    private static func frontmatterFields(_ head: String, keys: [String]) -> String {
        let lines = head.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return "" }
        var values: [String] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            for key in keys where trimmed.hasPrefix("\(key):") {
                values.append(String(trimmed.dropFirst(key.count + 1))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return values.joined(separator: " ")
    }
}
