import Foundation
import EurekaKit

/// 一步工具/检索轨迹（会话详情按轮聚合展示用）。
/// 思考明文本地不可得（Claude 落盘剥离、Codex 新版加密），轨迹是"这一轮做了什么"的可行替代。
public struct ToolStep: Equatable, Sendable {
    /// 工具分类。已上移到 EurekaKit（`ToolKind`）供审计共用，此处保留 typealias 源码兼容。
    public typealias Kind = ToolKind

    public var kind: Kind
    public var name: String    // 展示用工具名（Read / exec_command / server.tool / 子代理类型…）
    public var detail: String  // 关键参数摘要（解析期截断，命令只取首行）
    public var isError: Bool

    public init(kind: Kind, name: String, detail: String, isError: Bool = false) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.isError = isError
    }
}

/// tool_use / function_call → ToolStep 的分类与参数摘要（UI 展示用，对全保真 AuditExtractor 结果做截断）。
public enum ToolStepExtractor {
    /// detail 摘要上限（解析期截断，超长命令/patch 不驻留内存）
    static let detailLimit = 160

    // MARK: - Claude（assistant content 的 tool_use 块）

    public static func claude(name: String, input: [String: Any]?) -> ToolStep {
        clip(AuditExtractor.claude(name: name, input: input))
    }

    // MARK: - Codex（response_item 的 function_call，arguments 是 JSON 字符串）

    public static func codex(name: String, argumentsJSON: String?) -> ToolStep {
        clip(AuditExtractor.codex(name: name, argumentsJSON: argumentsJSON))
    }

    /// 全保真操作 → 展示用 ToolStep：命令类只取首行，其余整体截断
    private static func clip(_ op: AuditExtractor.Operation) -> ToolStep {
        let detail = op.kind == .command ? clipFirstLine(op.detail) : clip(op.detail)
        return ToolStep(kind: op.kind, name: op.name, detail: detail)
    }

    /// 首个 String 值（TranscriptReader 的 mcp arguments 摘要复用）
    static func firstString(in input: [String: Any]?) -> String {
        AuditExtractor.firstString(in: input)
    }

    // MARK: - 摘要工具

    /// 截断到 detailLimit（超长参数不驻留内存）
    static func clip(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return "" }
        return raw.count <= detailLimit ? raw : String(raw.prefix(detailLimit)) + "…"
    }

    /// 命令类摘要：只取首行再截断
    static func clipFirstLine(_ raw: String?) -> String {
        guard let raw else { return "" }
        let firstLine = raw.split(separator: "\n", maxSplits: 1,
                                  omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let clipped = clip(firstLine)
        // 多行命令加省略标记（首行本身没超限时 clip 不会加）
        if raw.contains("\n"), !clipped.hasSuffix("…") { return clipped + " …" }
        return clipped
    }

    /// 轨迹纯文本渲染（turnTrail 消息的 text：会话内搜索/导出兜底可命中）
    public static func plainText(_ steps: [ToolStep]) -> String {
        var lines = ["本轮轨迹（\(steps.count) 步）"]
        for step in steps {
            let flag = step.isError ? "（失败）" : ""
            let detail = step.detail.isEmpty ? "" : " \(step.detail)"
            lines.append("[\(step.kind.label)] \(step.name)\(flag)\(detail)")
        }
        return lines.joined(separator: "\n")
    }
}
