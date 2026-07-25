import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.codebuddy/projects/**/*.jsonl（含 `<sessionId>/subagents/agent-*.jsonl`）。
/// schema 已对真实会话核验（2026-07）：token 挂在 `function_call` 行的
/// `providerData.usage` / `message.usage`（实勘为 camelCase：inputTokens 含缓存读、
/// inputTokensDetails[0].cached_tokens；snake_case Claude 式作兜底）→ 写 usage_records；
/// `function_call` 的 name → tool_calls（Skill/mcp__/Agent 归类与 Kimi 扫描器同口径）；
/// user 消息（非 skipRun 元行）→ session_stats 提问数。
/// 子代理 token 是真实开销，归属父会话 id；提问只在主会话文件计。
/// 按 inode+offset 水位增量续读（jsonl 单写者 append-only，无跨文件重复行，无需 dedup_keys）。
public final class CodeBuddyUsageScanner {
    private let projectsRoot: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 每文件私有状态（存 scan_files.extra）：会话归属 + 是否主会话文件（提问只在主会话计）
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
        var isMain: Bool?
    }

    /// projectsRoot 由调用方传入（app/CLI 用 `CodeBuddyPaths.projectsRoot()`，测试用临时目录）——
    /// EurekaUsage 不依赖 EurekaIngest，故此处不设默认值。
    public init(projectsRoot: URL, store: EurekaStore) {
        self.projectsRoot = projectsRoot
        self.store = store
    }

    /// 返回本轮新增的 usage 记录数
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in sessionFiles() {
            inserted += try scanFile(file)
        }
        return inserted
    }

    /// projects/<slug>/*.jsonl（主会话）+ projects/<slug>/<sessionId>/subagents/*.jsonl
    /// （子代理；不按 mtime 过滤——scan_state 水位使无新数据的老文件近乎零成本）
    private func sessionFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs where isDirectory(projectDir) {
            let entries = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in entries {
                if isDirectory(entry) {
                    let subagents = entry.appendingPathComponent("subagents", isDirectory: true)
                    let files = (try? fm.contentsOfDirectory(
                        at: subagents, includingPropertiesForKeys: nil)) ?? []
                    results += files.filter { $0.pathExtension.lowercased() == "jsonl" }
                } else if entry.pathExtension.lowercased() == "jsonl" {
                    results.append(entry)
                }
            }
        }
        return results
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func scanFile(_ url: URL) throws -> Int {
        let path = url.path
        guard let info = JSONLinesReader.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: path)

        var offset: UInt64 = 0
        var extra = FileExtra()
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
            if let extraJSON = saved.extra,
               let decoded = try? JSONDecoder().decode(FileExtra.self, from: Data(extraJSON.utf8)) {
                extra = decoded
            }
        }
        if extra.sessionId == nil {
            resolveOwnership(fileURL: url, into: &extra)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        var records: [UsageRecord] = []
        var promptCount = 0
        // 工具/技能调用：逐条带真实时间戳（tool_calls.last_ts 取 MAX 用）
        var toolBumps: [(day: String, kind: String, name: String, ts: Double)] = []

        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            if extra.project == nil, let cwd = root["cwd"] as? String {
                extra.project = projectResolver.projectName(forCwd: cwd)
            }

            switch type {
            case "message":
                // 真实用户提问（skipRun 是本地命令回显等元行）；提问数只在主会话文件计
                guard extra.isMain == true,
                      root["role"] as? String == "user",
                      (root["providerData"] as? [String: Any])?["skipRun"] as? Bool != true,
                      let blocks = root["content"] as? [[String: Any]],
                      blocks.contains(where: {
                          $0["type"] as? String == "input_text"
                              && (($0["text"] as? String)?
                                  .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                      })
                else { continue }
                promptCount += 1

            case "function_call":
                let date = eventDate(root)
                if let name = root["name"] as? String, !name.isEmpty {
                    let args = parseArguments(root["arguments"] as? String)
                    let day = Self.dayFormatter.string(from: date)
                    let ts = date.timeIntervalSince1970
                    // kind 归类与 Kimi 扫描器同口径（技能分析/插件面板跨源一致）
                    if name == "Skill" {
                        toolBumps.append((day, "skill", (args["skill"] as? String) ?? "?", ts))
                    } else if name.hasPrefix("mcp__") {
                        let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                        let server = comps.count >= 2 ? comps[1] : name
                        let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                        toolBumps.append((day, "mcp", tool.isEmpty ? server : "\(server).\(tool)", ts))
                    } else if name == "Agent" || name == "AgentSwarm" || name == "Task" {
                        let subagent = (args["subagent_type"] as? String)
                            ?? (args["agentType"] as? String) ?? (args["agent_type"] as? String) ?? "?"
                        toolBumps.append((day, "agent", subagent, ts))
                    } else {
                        toolBumps.append((day, "tool", name, ts))
                    }
                }
                // token：providerData.usage / message.usage（camelCase 主格式，snake_case 兜底）
                let providerData = root["providerData"] as? [String: Any]
                let message = root["message"] as? [String: Any]
                guard let usage = (providerData?["usage"] ?? message?["usage"]) as? [String: Any]
                else { continue }
                let rawInput = intValue(usage, ["inputTokens", "input_tokens"])
                let output = intValue(usage, ["outputTokens", "output_tokens"])
                var cached = intValue(usage, ["cache_read_input_tokens", "cached_tokens"])
                if cached == 0,
                   let details = usage["inputTokensDetails"] as? [[String: Any]] {
                    cached = details.reduce(0) { $0 + intValue($1, ["cached_tokens"]) }
                }
                guard rawInput > 0 || output > 0 || cached > 0 else { continue }
                // camelCase 的 inputTokens 含缓存读（OpenAI 口径）→ 减掉；
                // snake_case 的 input_tokens 不含（Claude 口径）→ 原样
                let input = usage["inputTokens"] != nil ? max(0, rawInput - cached) : rawInput
                records.append(UsageRecord(
                    source: .codebuddy,
                    // model 在 providerData.model（如 "glm-5.2"，存原样）
                    model: ((providerData?["model"] ?? message?["model"]) as? String)
                        ?? "codebuddy/unknown",
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: date,
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached))

            default:
                break
            }
        }

        var inserted = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            try store.usage.insert(records)
            inserted = records.count
            for bump in toolBumps {
                try store.toolCalls.bump(
                    day: bump.day, source: .codebuddy, kind: bump.kind, name: bump.name,
                    ts: bump.ts)
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if extra.isMain == true, let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId, count: promptCount, reset: offset == 0)
            }
        }
        return inserted
    }

    /// 行时间：epoch 毫秒 `timestamp`（>1e12 判毫秒）；缺失回退当前时间
    private func eventDate(_ root: [String: Any]) -> Date {
        if let number = root["timestamp"] as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return Date()
    }

    /// arguments 是 JSON 字符串（如 `{"skill":"tdd"}`）；解析失败按空
    private func parseArguments(_ raw: String?) -> [String: Any] {
        guard let raw,
              let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
        else { return [:] }
        return object as? [String: Any] ?? [:]
    }

    private func intValue(_ dict: [String: Any], _ keys: [String]) -> Int {
        for key in keys {
            if let number = dict[key] as? NSNumber { return number.intValue }
        }
        return 0
    }

    /// 会话归属：主会话文件 = <slug>/<sessionId>.jsonl（文件名 stem 即会话 id）；
    /// 子代理文件 = <slug>/<sessionId>/subagents/agent-*.jsonl（父目录名即会话 id，
    /// token 归父会话、提问不计）
    private func resolveOwnership(fileURL: URL, into extra: inout FileExtra) {
        let parent = fileURL.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            extra.sessionId = parent.deletingLastPathComponent().lastPathComponent
            extra.isMain = false
        } else {
            extra.sessionId = fileURL.deletingPathExtension().lastPathComponent
            extra.isMain = true
        }
    }
}
