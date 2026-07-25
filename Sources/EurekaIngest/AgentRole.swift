import Foundation

/// 子代理角色分类（Agents 页角色头像 / 标签 / 模型统计的语义轴）。
/// 代码里没有显式 role 字段——角色从 agent 名称 + 描述启发式推导；纯字符串逻辑、无 IO、可单测。
/// 颜色映射在 app 层 `Theme.roleColor(_:)` 完成（本模块不依赖 AppKit）。
public enum AgentRole: String, CaseIterable, Sendable, Equatable {
    case general    // 通用
    case explore    // 探索
    case implement  // 实现
    case review     // 审查
    case plan       // 规划
    case model      // 建模
    case doc        // 文档

    public var displayName: String {
        switch self {
        case .general: return "通用"
        case .explore: return "探索"
        case .implement: return "实现"
        case .review: return "审查"
        case .plan: return "规划"
        case .model: return "建模"
        case .doc: return "文档"
        }
    }

    /// 角色头像单字（通/探/实/审/规/建/文）
    public var glyph: String {
        switch self {
        case .general: return "通"
        case .explore: return "探"
        case .implement: return "实"
        case .review: return "审"
        case .plan: return "规"
        case .model: return "建"
        case .doc: return "文"
        }
    }

    /// 从 agent 名称 + 描述启发式推断角色：已知内置名优先精确匹配，其余按关键词，兜底 通用。
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
        // 顺序敏感：先判更具体的角色（review 早于 plan，避免误吞）
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

/// 模型名规整为展示标签（自由字符串 → Opus / Sonnet / Haiku / GPT-5-Codex / K2 / 继承…）。
/// nil / 空 / inherit / default → 「继承」。用于 Agents 行/卡的模型芯片与「模型分布」统计。
public func normalizeModelName(_ raw: String?) -> String {
    guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "继承" }
    let m = raw.lowercased()
    if m == "inherit" || m == "default" { return "继承" }
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
    if m.hasPrefix("glm") { return "GLM" }       // CodeBuddy（智谱 GLM 系，如 glm-5.2）
    if m.hasPrefix("qmodel") { return "QModel" } // Qoder（qmodel_*）
    // provider/model 形式（如 anthropic/claude-… 或 openai:…）取末段并首字母大写
    let tail = raw.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? raw
    return tail.prefix(1).uppercased() + tail.dropFirst()
}
