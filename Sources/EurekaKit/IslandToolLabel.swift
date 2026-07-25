import Foundation

/// 岛上任务行的「在做什么」标签：工具名 + 尽量短的对象串。
///
/// 岛上一行要同时容纳标题、这个标签、ctx% 与计时器，空间很紧。所以这里给对象串定预算，
/// 而不是交给 `truncationMode(.middle)` —— 那会把 `swift build -c release` 挤成
/// `s…release`（既没信息量，还顺带把标题也压掉了）。装不下就只留工具名：
/// 完整对象在「等待授权」卡与审计页里都看得到，这一行不必承担全部。
///
/// 路径取末段（`/repo/src/main.swift` → `main.swift`，那才是有辨识力的部分）；
/// 命令则从**头部**截断 —— 命令里带斜杠不代表它是路径（`rm -rf node_modules/`），
/// 而且命令最该先看见的就是动词和参数（`rm -rf` 正是要留住的部分）。
public func compactToolLabel(tool: String, detail: String?, budget: Int = 12) -> String {
    guard let detail, !detail.isEmpty else { return tool }
    let short: String
    if isPathLike(detail) {
        // 末段可能因结尾斜杠为空（`/a/b/` → 取 b）
        let parts = detail.split(separator: "/", omittingEmptySubsequences: true)
        short = parts.last.map(String.init) ?? detail
    } else {
        short = detail
    }
    guard short.count > budget else { return "\(tool) \(short)" }
    return "\(tool) \(short.prefix(budget))…"
}

/// 看起来是单个文件/目录路径（而不是含路径的命令）
func isPathLike(_ text: String) -> Bool {
    guard !text.contains(" ") else { return false }  // 有空格就是命令
    return text.hasPrefix("/") || text.hasPrefix("~/") || text.hasPrefix("./")
        || text.contains("/")
}

