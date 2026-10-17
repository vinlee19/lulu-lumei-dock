import EurekaKit
import Foundation

/// Per-AgentSource config conventions: where each agent keeps its skills / MCP / memory /
/// subagent definitions. Filled in best-effort per source; unknown sources have no dirs and
/// degrade to a two-way estimate: conversation messages + system prompt (incl. everything else).
public struct AgentContextProfile: Equatable, Sendable {
    /// Skill dirs (reads the frontmatter description of each */SKILL.md)
    public var skillDirs: [String]
    /// MCP config files (counts servers only; tool schemas are unavailable, estimated by constant)
    public var mcpConfigFiles: [String]
    /// Memory / instruction files (injected verbatim into the system prompt)
    public var memoryFiles: [String]
    /// Subagent definition dirs (*.md frontmatter is injected into the tool list)
    public var agentDirs: [String]
    /// System prompt baseline (CLI skeleton prompt; not in the transcript, empirical fallback)
    public var baselineSystemPromptTokens: Int
    /// Built-in tool schema baseline (schemas aren't in the transcript; empirical fallback)
    public var baselineBuiltinToolTokens: Int
    /// Fixed estimate per configured MCP server (schema unavailable; a resident constant)
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

    // MARK: - Estimate baselines (centralized; overshoot is harmless: reconcile scales to the real total)

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
                // Claude Code's system prompt skeleton and built-in tool schemas are both large
                // (measured magnitude)
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
        case .zcode:
            // zcode skills live in the shared ~/.agents/skills; memory follows the AGENTS.md
            // convention (no global memory file seen)
            return AgentContextProfile(
                skillDirs: [home.appendingPathComponent(".agents/skills").path]
                    + at(cwd, ".agents/skills"),
                mcpConfigFiles: [home.appendingPathComponent(".zcode/cli/config.json").path],
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
            // Sources with no config convention: no dirs, only the baselines + conversation
            // messages
            return AgentContextProfile(
                skillDirs: [], mcpConfigFiles: [], memoryFiles: [], agentDirs: [],
                baselineSystemPromptTokens: defaultSystemPromptBaseline,
                baselineBuiltinToolTokens: defaultBuiltinToolBaseline,
                perMCPServerTokens: defaultPerMCPServerTokens)
        }
    }
}

/// Context usage breakdown estimator: last turn's real total (if any) + conversation message
/// estimate + measured config files. All best-effort: a missing or unparsable file is skipped
/// silently, never thrown.
public enum ContextBreakdownEstimator {
    /// Entry point: estimate the five categories per source, then reconcile against the last
    /// turn's real total.
    /// - model: the session's model with the most tokens (decides the window size);
    ///   nil → default window.
    /// - lastTurnTotalTokens: result of LastTurnUsageReader; nil → the total is a pure estimate.
    /// - windowOverride: the real window carried in session data (codex `model_context_window` /
    ///   kimi config.toml `max_context_size`); takes precedence over the built-in ContextWindows
    ///   table.
    public static func estimate(
        source: AgentSource,
        cwd: String?,
        messages: [TranscriptMessage],
        model: String?,
        lastTurnTotalTokens: Int?,
        windowOverride: Int? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ContextBreakdown {
        let profile = AgentContextProfile.profile(for: source, cwd: cwd, home: home)
        var estimates: [ContextBreakdown.Category: Int] = [
            .messages: messages.reduce(0) { $0 + TokenEstimator.estimate($1.text) },
            .systemPrompt: profile.baselineSystemPromptTokens,
            .tools: profile.baselineBuiltinToolTokens,
            .mcp: mcpTokens(profile: profile),
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
            windowTokens: windowOverride ?? ContextWindows.window(forModel: model),
            lastTurnTotalTokens: lastTurnTotalTokens)
    }

    /// Reconcile (pure function, unit-testable): with a real total R — if the estimate sum E < R,
    /// the difference goes into systemPrompt ("system prompt" includes all other overhead); if E >
    /// R, every category is scaled proportionally down to R (the residual goes to the largest
    /// category so the sum is exactly R). Without R → totalIsReal = false and the total is the
    /// estimate sum.
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
                // Add the rounding residual to the largest category so the scaled sum == R
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

    // MARK: - Private: per-category measurement

    /// Skill dirs: for each subdir's SKILL.md, estimate only the frontmatter name+description
    /// (that description is what gets injected into context, not the full skill)
    private static func estimateSkills(inDir dir: String) -> Int {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var total = 0
        for sub in subs {
            let skillFile = URL(fileURLWithPath: dir)
                .appendingPathComponent(sub).appendingPathComponent("SKILL.md").path
            guard let head = readHead(path: skillFile) else { continue }
            let frontmatter = frontmatterFields(head, keys: ["name", "description"])
            // Fall back to the dir name when frontmatter is missing (a skill should cost something)
            total += frontmatter.isEmpty
                ? TokenEstimator.estimate(sub)
                : TokenEstimator.estimate(frontmatter)
        }
        return total
    }

    /// Markdown definition dirs (subagents etc.): estimate each *.md from frontmatter
    /// name+description
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

    /// Memory / instruction files: injected verbatim into the system prompt, so estimate the whole
    /// file
    private static func estimateFileText(at path: String) -> Int {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8)
        else { return 0 }
        return TokenEstimator.estimate(text)
    }

    /// MCP context overhead: prefer the **real schema tokens** from the probe cache (MCPToolCache,
    /// measured via tools/list and persisted when the MCP page's "test connection" runs); servers
    /// never probed fall back to the constant estimate.
    /// Server name resolution: JSON takes the mcpServers keys; TOML takes the first segment after
    /// [mcp_servers.<name>] (`.env` / `.tools.*` subsections belong to the same server and are no
    /// longer counted again by line prefix — the old implementation over-counted).
    private static func mcpTokens(profile: AgentContextProfile) -> Int {
        let cache = MCPToolCache.load()
        var names: Set<String> = []
        for path in profile.mcpConfigFiles {
            guard let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            if path.hasSuffix(".json") {
                if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let servers = root["mcpServers"] as? [String: Any] {
                    names.formUnion(servers.keys.map { $0.lowercased() })
                }
            } else {
                // No TOML parser dependency; take names from section headers
                // (codex [mcp_servers.xxx] / kimi [mcp.xxx])
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
                    let parts = trimmed.dropFirst().dropLast().split(separator: ".")
                    guard parts.count >= 2,
                          parts[0] == "mcp_servers" || parts[0] == "mcp" else { continue }
                    let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    names.insert(name.lowercased())
                }
            }
        }
        return names.reduce(0) { total, name in
            total + (cache[name]?.schemaTokens ?? profile.perMCPServerTokens)
        }
    }

    /// File head (frontmatter is always at the top; 8KB is enough)
    private static func readHead(path: String, bytes: Int = 8192) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: bytes)
        return String(data: data, encoding: .utf8)
    }

    /// Extract the value text of the given keys from the YAML frontmatter (the --- delimited block)
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
