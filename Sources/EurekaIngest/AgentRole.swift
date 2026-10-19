import EurekaKit
import Foundation

/// Subagent role classification (the semantic axis for role avatars / labels / model stats on the
/// Agents page).
/// There is no explicit role field: the role is inferred heuristically from the agent name +
/// description; pure string logic, no IO, unit-testable.
/// Colors are mapped in the app layer by `Theme.roleColor(_:)` (this module doesn't use AppKit).
public enum AgentRole: String, CaseIterable, Sendable, Equatable {
    case general    // General
    case explore    // Explore
    case implement  // Implement
    case review     // Review
    case plan       // Plan
    case model      // Modeling
    case doc        // Docs

    public var displayName: String {
        switch self {
        case .general: return L10n.text("General", zhHans: "通用")
        case .explore: return L10n.text("Explore", zhHans: "探索")
        case .implement: return L10n.text("Implement", zhHans: "实现")
        case .review: return L10n.text("Review", zhHans: "审查")
        case .plan: return L10n.text("Plan", zhHans: "规划")
        case .model: return L10n.text("Model", zhHans: "建模")
        case .doc: return L10n.text("Document", zhHans: "文档")
        }
    }

    /// Single-glyph role avatar (one CJK character per role in zhHans, G/E/I/R/P/M/D in English)
    public var glyph: String {
        switch self {
        case .general: return L10n.text("G", zhHans: "通")
        case .explore: return L10n.text("E", zhHans: "探")
        case .implement: return L10n.text("I", zhHans: "实")
        case .review: return L10n.text("R", zhHans: "审")
        case .plan: return L10n.text("P", zhHans: "规")
        case .model: return L10n.text("M", zhHans: "建")
        case .doc: return L10n.text("D", zhHans: "文")
        }
    }

    /// Infers the role heuristically from agent name + description: known built-in names match
    /// exactly first, the rest go by keyword, falling back to general.
    public static func classify(name: String, description: String? = nil) -> AgentRole {
        let n = name.lowercased()
        switch n {
        case "general-purpose", "claude", "codex-default", "agent":
            return .general
        case "explore", "kimi-scout":
            return .explore
        case "plan", "wayfinder":
            return .plan
        case "coder":
            return .implement
        default:
            break
        }
        let hay = n + " " + (description?.lowercased() ?? "")
        func has(_ keywords: [String]) -> Bool { keywords.contains { hay.contains($0) } }
        // Order matters: check the more specific roles first (review before plan, so plan
        // doesn't swallow it)
        if has(["review", "审查", "reviewer", "silent-failure", "type-design", "comment-analyz", "评审", "审阅"]) {
            return .review
        }
        if has(["test", "tdd", "实现", "runner", "impl", "编码", "写码", "开发"]) {
            return .implement
        }
        if has(["explore", "scout", "探索", "search", "research", "调研", "搜索"]) {
            return .explore
        }
        if has(["plan", "规划", "architect", "wayfind", "roadmap", "方案设计"]) {
            return .plan
        }
        if has(["doc-", "-doc", "writer", "文档", "documentation", "笔记", "note"]) {
            return .doc
        }
        if has(["model", "domain", "建模", "领域", "schema", "ontolog"]) {
            return .model
        }
        return .general
    }
}

/// Normalizes a model name into a display label (free-form string → Opus / Sonnet / Haiku /
/// GPT-5-Codex / K2 / Inherit...).
/// nil / empty / inherit / default → the "Inherit" label. Used for the model chips on Agents
/// rows/cards and the "model distribution" stats.
public func normalizeModelName(_ raw: String?) -> String {
    // Display label, computed per interface language. The test suite is pinned to zhHans, so the
    // spec still checks the zhHans "Inherit" label.
    let inherited = L10n.text("Inherit", zhHans: "继承")
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return inherited }
    let m = raw.lowercased()
    if m == "inherit" || m == "default" { return inherited }
    if m.contains("opus") { return "Opus" }
    if m.contains("sonnet") { return "Sonnet" }
    if m.contains("haiku") { return "Haiku" }
    if m.contains("gpt-5") && m.contains("codex") { return "GPT-5-Codex" }
    if m.contains("codex") { return "Codex" }
    if m.contains("gpt-5") { return "GPT-5" }
    if m.contains("gpt-4") { return "GPT-4" }
    if m.hasPrefix("k2") || m.contains("kimi-k2") { return "K2" }
    if m.contains("gemini") { return "Gemini" }
    if m.contains("grok") { return "Grok" }
    if m.contains("qwen") { return "Qwen" }
    if m.hasPrefix("glm") { return "GLM" }       // CodeBuddy (Zhipu GLM family, e.g. glm-5.2)
    if m.hasPrefix("qmodel") { return "QModel" } // Qoder (qmodel_*)
    // provider/model form (e.g. anthropic/claude-... or openai:...): capitalize the last segment
    let tail = raw.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? raw
    return tail.prefix(1).uppercased() + tail.dropFirst()
}
