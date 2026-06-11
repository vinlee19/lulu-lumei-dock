import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl 的 token_count 事件。
/// 记账用 total_token_usage 的**相邻差值法**（对重连稳健）；
/// 差值为负（compaction/重置）时回退用 last_token_usage。
/// 模型名跟踪 turn_context.payload.model（缺省 "gpt-5.5"）。
public final class CodexUsageScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    /// 回看天数：覆盖月度统计（offset 续读，老文件只在首扫时全量读一次）
    private let lookbackDays = 35

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 每文件的扫描私有状态（存 scan_files.extra）
    private struct FileExtra: Codable {
        var prevInput = 0
        var prevCached = 0
        var prevOutput = 0
        var model: String?
        var project: String?
        var sessionId: String?
    }

    public init(sessionsRoot: URL, store: EurekaStore) {
        self.sessionsRoot = sessionsRoot
        self.store = store
    }

    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for file in rolloutFiles() {
            inserted += try scanFile(file)
        }
        return inserted
    }

    private func rolloutFiles() -> [URL] {
        let fm = FileManager.default
        let calendar = Calendar.current
        var results: [URL] = []
        for dayOffset in 0..<lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else {
                continue
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = sessionsRoot
                .appendingPathComponent(String(format: "%04d", parts.year ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.month ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.day ?? 0), isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            results.append(contentsOf: files.filter {
                $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
            })
        }
        return results
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
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        var records: [UsageRecord] = []
        var promptCount = 0
        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            let payload = root["payload"] as? [String: Any] ?? [:]

            if type == "session_meta" {
                if let cwd = payload["cwd"] as? String {
                    extra.project = projectResolver.projectName(forCwd: cwd)
                }
                if let id = payload["id"] as? String {
                    extra.sessionId = id
                }
                continue
            }
            if type == "turn_context" {
                if let model = payload["model"] as? String {
                    extra.model = model
                }
                if let cwd = payload["cwd"] as? String {
                    extra.project = projectResolver.projectName(forCwd: cwd)
                }
                continue
            }
            if type == "event_msg", payload["type"] as? String == "user_message" {
                promptCount += 1
                continue
            }
            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let payloadInfo = payload["info"] as? [String: Any],
                  let totals = payloadInfo["total_token_usage"] as? [String: Any]
            else { continue }

            let input = totals["input_tokens"] as? Int ?? 0
            let cached = totals["cached_input_tokens"] as? Int ?? 0
            let output = totals["output_tokens"] as? Int ?? 0

            var deltaInput = input - extra.prevInput
            var deltaCached = cached - extra.prevCached
            var deltaOutput = output - extra.prevOutput
            if deltaInput < 0 || deltaCached < 0 || deltaOutput < 0 {
                // 计数器被重置（compaction/会话重建）：退而用单次值
                let last = payloadInfo["last_token_usage"] as? [String: Any] ?? [:]
                deltaInput = last["input_tokens"] as? Int ?? 0
                deltaCached = last["cached_input_tokens"] as? Int ?? 0
                deltaOutput = last["output_tokens"] as? Int ?? 0
            }
            extra.prevInput = input
            extra.prevCached = cached
            extra.prevOutput = output

            guard deltaInput > 0 || deltaOutput > 0 else { continue }
            let timestamp = (root["timestamp"] as? String).flatMap {
                Self.isoFormatter.date(from: $0)
            } ?? Date()
            records.append(UsageRecord(
                source: .codex,
                model: extra.model ?? "gpt-5.5",
                project: extra.project,
                sessionId: extra.sessionId,
                timestamp: timestamp,
                // OpenAI 口径：cached 是 input 的子集 → 拆开记
                inputTokens: max(0, deltaInput - deltaCached),
                outputTokens: deltaOutput,
                cacheReadTokens: deltaCached
            ))
        }

        var newCount = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            try store.usage.insert(records)
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId,
                    count: promptCount, reset: offset == 0)
            }
            newCount = records.count
        }
        return newCount
    }
}
