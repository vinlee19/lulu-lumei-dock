import Foundation

extension L10n {
    /// Health-registry key → English display name. The key is the `HealthRegistry` identity; both
    /// Chinese and English UIs register with the same key. When adding a new `register` name, add a
    /// line here, or the English UI shows the Chinese key as-is.
    static let healthTitles: [String: String] = [
        "用量扫描 Claude": "Usage scan Claude",
        "用量扫描 Codex": "Usage scan Codex",
        "用量扫描 OpenCode": "Usage scan OpenCode",
        "用量扫描 Grok": "Usage scan Grok",
        "用量扫描 Kimi": "Usage scan Kimi",
        "用量扫描 Gemini": "Usage scan Gemini",
        "用量扫描 Qwen": "Usage scan Qwen",
        "用量扫描 Hermes": "Usage scan Hermes",
        "用量扫描 CodeBuddy": "Usage scan CodeBuddy",
        "用量扫描 Cursor": "Usage scan Cursor",
        "用量扫描 ZCode": "Usage scan ZCode",
        "用量扫描 Antigravity（实验）": "Usage scan Antigravity (experimental)",
        "审计扫描 Codex": "Audit scan Codex",
        "审计扫描 CodeBuddy": "Audit scan CodeBuddy",
        "审计扫描 Qoder": "Audit scan Qoder",
        "审计扫描 Cursor": "Audit scan Cursor",
        "审计扫描 Grok": "Audit scan Grok",
        "审计扫描 Qwen": "Audit scan Qwen",
        "云端备份": "Cloud backup",
        "价格目录": "Price catalog",
        "Codex rollout 监视": "Codex rollout watch",
        "opencode 事件监视": "OpenCode event watch",
        "Claude transcript 监视": "Claude transcript watch",
        "kimi 事件监视": "Kimi event watch",
        "grok 事件监视": "Grok event watch",
        "gemini 事件监视": "Gemini event watch",
        "Antigravity 活动监视": "Antigravity activity watch",
        "Cursor 会话监视": "Cursor session watch",
        "Cursor 转录监视": "Cursor transcript watch",
        "事件队列（hooks / notify）": "Event spool (hooks / notify)",
        "Hermes 会话监视": "Hermes session watch",
        "qwen 事件监视": "Qwen event watch",
        "zcode 事件监视": "ZCode event watch",
        "codebuddy 事件监视": "CodeBuddy event watch",
        "qoder 事件监视": "Qoder event watch",
    ]

    public static func healthTitle(_ stableName: String) -> String {
        guard let english = healthTitles[stableName] else { return stableName }
        return text(english, zhHans: stableName)
    }
}
