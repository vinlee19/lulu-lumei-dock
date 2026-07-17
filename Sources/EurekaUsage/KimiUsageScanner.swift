import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.kimi-code/sessions/<ws>/<session>/agents/<agentId>/wire.jsonl。
/// schema 已对真实会话核验：`usage.record` 自带 model + 四段 token
/// （inputOther/output/inputCacheRead/inputCacheCreation，均为该次 LLM 请求的增量）→ 写 usage_records；
/// loop 事件 `tool.call`（Skill/mcp__/Agent…）→ tool_calls；`turn.prompt`(origin=user) → session_stats。
/// 覆盖所有 agent（子代理 token 是真实开销，归属父会话 id），提问只在 main 计。
/// 按 inode+offset 水位增量续读（wire.jsonl 单写者 append-only，无跨文件重复行，无需 dedup_keys）。
public final class KimiUsageScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 每文件私有状态（存 scan_files.extra）：会话归属 + 是否主 agent（提问只在 main 计）
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
        var isMain: Bool?
    }

    /// sessionsRoot 由调用方传入（app/CLI 用 `KimiPaths.sessionsRoot()`，测试用临时目录）——
    /// EurekaUsage 不依赖 EurekaIngest，故此处不设默认值。
    public init(sessionsRoot: URL, store: EurekaStore) {
        self.sessionsRoot = sessionsRoot
        self.store = store
    }

    /// 返回本轮新增的 usage 记录数
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in wireFiles() {
            inserted += try scanFile(file)
        }
        return inserted
    }

    /// sessions/<ws>/<session>/agents/<agentId>/wire.jsonl 全量（三级目录遍历；
    /// 不按 mtime 过滤——scan_state 水位使无新数据的老文件近乎零成本）
    private func wireFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for workspaceDir in workspaceDirs where isDirectory(workspaceDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let agentsDir = sessionDir.appendingPathComponent("agents", isDirectory: true)
                let agentDirs = (try? fm.contentsOfDirectory(
                    at: agentsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for agentDir in agentDirs where isDirectory(agentDir) {
                    let wire = agentDir.appendingPathComponent("wire.jsonl")
                    if fm.fileExists(atPath: wire.path) { results.append(wire) }
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
            resolveOwnership(wireURL: url, into: &extra)
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

            switch type {
            case "turn.prompt":
                // 真实用户提问（origin=user）；提问数只在主 agent 计
                if extra.isMain == true,
                   (root["origin"] as? [String: Any])?["kind"] as? String ?? "user" == "user" {
                    promptCount += 1
                }

            case "usage.record":
                guard let usage = root["usage"] as? [String: Any] else { continue }
                let input = usage["inputOther"] as? Int ?? 0
                let output = usage["output"] as? Int ?? 0
                let cacheRead = usage["inputCacheRead"] as? Int ?? 0
                let cacheCreation = usage["inputCacheCreation"] as? Int ?? 0
                guard input > 0 || output > 0 || cacheRead > 0 || cacheCreation > 0 else { continue }
                records.append(UsageRecord(
                    source: .kimi,
                    // model 就在事件上（如 "kimi-code/k3"，存原样带前缀，pricing 按前缀匹配）
                    model: (root["model"] as? String) ?? "kimi-code/unknown",
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: eventDate(root),
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheCreation,
                    cacheReadTokens: cacheRead))

            case "context.append_loop_event":
                guard let inner = root["event"] as? [String: Any],
                      inner["type"] as? String == "tool.call",
                      let name = inner["name"] as? String, !name.isEmpty
                else { continue }
                let args = inner["args"] as? [String: Any]
                let date = eventDate(root)
                let day = Self.dayFormatter.string(from: date)
                let ts = date.timeIntervalSince1970
                // kind 归类与 Claude 扫描器同口径（技能分析/插件面板跨源一致）
                if name == "Skill" {
                    toolBumps.append((day, "skill", (args?["skill"] as? String) ?? "?", ts))
                } else if name.hasPrefix("mcp__") {
                    let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                    let server = comps.count >= 2 ? comps[1] : name
                    let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                    toolBumps.append((day, "mcp", tool.isEmpty ? server : "\(server).\(tool)", ts))
                } else if name == "Agent" || name == "AgentSwarm" || name == "Task" {
                    let subagent = (args?["subagent_type"] as? String)
                        ?? (args?["agentType"] as? String) ?? (args?["agent_type"] as? String) ?? "?"
                    toolBumps.append((day, "agent", subagent, ts))
                } else {
                    toolBumps.append((day, "tool", name, ts))
                }

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
                    day: bump.day, source: .kimi, kind: bump.kind, name: bump.name,
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

    /// 行时间：epoch 毫秒 `time`（>1e12 判毫秒）；缺失回退当前时间
    private func eventDate(_ root: [String: Any]) -> Date {
        if let number = root["time"] as? Double {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        return Date()
    }

    /// 会话归属：wire.jsonl ← <agentId> ← agents ← session_<uuid>（目录名即会话 id，
    /// 与 KimiSessionIndexer 一致）；workDir 从 state.json 读一次 → 项目名
    private func resolveOwnership(wireURL: URL, into extra: inout FileExtra) {
        let agentDir = wireURL.deletingLastPathComponent()
        let sessionDir = agentDir
            .deletingLastPathComponent()   // agents/
            .deletingLastPathComponent()   // session_<uuid>/
        extra.sessionId = sessionDir.lastPathComponent
        extra.isMain = agentDir.lastPathComponent == "main"
        let stateURL = sessionDir.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any],
           let workDir = root["workDir"] as? String {
            extra.project = projectResolver.projectName(forCwd: workDir)
        }
    }
}
