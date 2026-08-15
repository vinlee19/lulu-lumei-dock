import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.zcode/cli/rollout/model-io-sess_<id>.jsonl（模型 IO 流水）。
/// schema 已对真实会话核验（2026-08）：每行一次模型请求 `type:"model_io"`，
/// `response.usage` 为四段 token（inputTokens/outputTokens/cacheReadTokens/cacheWriteTokens），
/// `response.modelId` 如 "glm-5.3"，`startedAt` ISO8601。
/// 子代理文件（sess_subagent_*）的 token 是真实开销，一并收（归属该子会话 id）。
/// `response.toolCalls[].name` → tool_calls。
/// 按 inode+offset 水位增量续读（单写者 append-only，无需 dedup_keys）；
/// cwd/项目归属从 db 的 session 表懒查（directory 列，每文件一次）。
/// prompt 计数见 `recordPromptCounts()`：db message 表绝对值聚合（与 opencode 同例）。
public final class ZcodeUsageScanner {
    private let rolloutRoot: URL
    private let dbPath: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 每文件私有状态（存 scan_files.extra）：会话归属项目名（cwd -> 仓库根）
    private struct FileExtra: Codable {
        var project: String?
    }

    /// rolloutRoot/dbPath 由调用方传入（app/CLI 用 `ZcodePaths.*()`，测试用临时目录）——
    /// EurekaUsage 不依赖 EurekaIngest，故此处不设默认值。
    public init(rolloutRoot: URL, dbPath: URL, store: EurekaStore) {
        self.rolloutRoot = rolloutRoot
        self.dbPath = dbPath
        self.store = store
    }

    /// 返回本轮新增的 usage 记录数
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in rolloutFiles() {
            inserted += try scanFile(file)
        }
        return inserted
    }

    /// rollout/ 下全部 model-io-*.jsonl（不按 mtime 过滤——scan_state 水位使
    /// 无新数据的老文件近乎零成本）
    private func rolloutFiles() -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(
            at: rolloutRoot, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("model-io-") }
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
        // 会话 id 从文件名解出（model-io-sess_xxx.jsonl -> sess_xxx）
        guard let sessionId = Self.sessionId(fileName: url.lastPathComponent) else { return 0 }
        if extra.project == nil {
            extra.project = projectFor(sessionId: sessionId)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        var records: [UsageRecord] = []
        var toolBumps: [(day: String, kind: String, name: String, ts: Double)] = []
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                root["type"] as? String == "model_io",
                let response = root["response"] as? [String: Any]
            else { continue }

            // 用量：response.usage（全零/空对象 = error 行或进行中行，跳过）
            if let dict = response["usage"] as? [String: Any] {
                let input = dict["inputTokens"] as? Int ?? 0
                let output = dict["outputTokens"] as? Int ?? 0
                let cacheRead = dict["cacheReadTokens"] as? Int ?? 0
                let cacheWrite = dict["cacheWriteTokens"] as? Int ?? 0
                if input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 {
                    let model = ((response["modelId"] as? String)
                        ?? (root["model"] as? [String: Any])?["modelId"] as? String
                        ?? "glm-unknown").lowercased()
                    let timestamp = (root["startedAt"] as? String).flatMap {
                        isoFraction.date(from: $0) ?? isoPlain.date(from: $0)
                    } ?? Date()
                    records.append(UsageRecord(
                        source: .zcode,
                        model: model,
                        project: extra.project,
                        sessionId: sessionId,
                        timestamp: timestamp,
                        inputTokens: input,
                        outputTokens: output,
                        cacheCreationTokens: cacheWrite,
                        cacheReadTokens: cacheRead))
                }
            }

            // 工具调用：response.toolCalls[].name（kind 归类与 kimi 扫描器同口径）
            if let calls = response["toolCalls"] as? [[String: Any]] {
                let date = (root["startedAt"] as? String).flatMap {
                    isoFraction.date(from: $0) ?? isoPlain.date(from: $0)
                } ?? Date()
                let day = Self.dayFormatter.string(from: date)
                let ts = date.timeIntervalSince1970
                for call in calls {
                    guard let name = call["name"] as? String, !name.isEmpty else { continue }
                    let args = call["input"] as? [String: Any]
                    if name == "Skill" {
                        toolBumps.append((day, "skill", (args?["skill"] as? String) ?? "?", ts))
                    } else if name.hasPrefix("mcp__") {
                        let comps = name.components(separatedBy: "__").filter { !$0.isEmpty }
                        let server = comps.count >= 2 ? comps[1] : name
                        let tool = comps.count >= 3 ? comps[2...].joined(separator: "__") : ""
                        toolBumps.append((day, "mcp", tool.isEmpty ? server : "\(server).\(tool)", ts))
                    } else if name == "Agent" || name == "Task" || name.hasPrefix("Agent_") {
                        let subagent = (args?["subagent_type"] as? String)
                            ?? (args?["description"] as? String) ?? "?"
                        toolBumps.append((day, "agent", subagent, ts))
                    } else {
                        toolBumps.append((day, "tool", name, ts))
                    }
                }
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
                    day: bump.day, source: .zcode, kind: bump.kind, name: bump.name,
                    ts: bump.ts)
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
        }
        return inserted
    }

    /// `model-io-sess_xxx.jsonl` -> `sess_xxx`
    static func sessionId(fileName: String) -> String? {
        guard fileName.hasPrefix("model-io-"), fileName.hasSuffix(".jsonl") else { return nil }
        let body = String(fileName.dropFirst("model-io-".count).dropLast(".jsonl".count))
        return body.isEmpty ? nil : body
    }

    /// 每会话用户提问数：db message 表按 `json_extract(data,'$.role')='user'` 绝对值聚合，
    /// 用 `<db>#<sessionId>` 作 path、reset:true 覆盖写（与 opencode 同例：不依赖水位，
    /// 重扫幂等）。db 缺失/表不存在时静默跳过。
    public func recordPromptCounts() throws {
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }
        let rows = (try? db.query("""
            SELECT session_id, COUNT(*) FROM message
            WHERE json_extract(data, '$.role') = 'user'
            GROUP BY session_id
            """) { row -> (String, Int) in (row.text(0) ?? "", Int(row.int(1))) }) ?? []
        guard !rows.isEmpty else { return }
        try store.scanState.transaction {
            for (sessionId, count) in rows where !sessionId.isEmpty {
                try store.sessionStats.recordPrompts(
                    path: "\(dbPath.path)#\(sessionId)", sessionId: sessionId,
                    count: count, reset: true)
            }
        }
    }

    /// 会话 cwd -> 项目名（db 只读查一次 session.directory；db 不存在时留空）
    private func projectFor(sessionId: String) -> String? {
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return nil }
        let rows = (try? db.query(
            "SELECT directory FROM session WHERE id = ?", [.text(sessionId)]) { $0.text(0) }) ?? []
        guard let cwd = rows.first ?? nil else { return nil }
        return projectResolver.projectName(forCwd: cwd)
    }
}
