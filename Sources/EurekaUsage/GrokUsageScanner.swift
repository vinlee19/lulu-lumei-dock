import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.grok/sessions/<enc-cwd>/<uuid>/ 下两个文件：
/// - `events.jsonl`：`tool_started`（工具调用 → tool_calls）与 `turn_started`（提问 → session_stats）；
/// - `updates.jsonl`：每轮结束的 `turn_completed`（Grok 1.0.4x 起），`usage.modelUsage.<模型>`
///   带该轮 token 与 `costUsdTicks`（10¹⁰ tick = 1 USD，Grok 自报的 API 等价费用）→ 每轮每模型一行
///   usage_records，费用直接采用自报值（build 模型在价格目录里没有对应条目）。
/// 两个文件各自按 inode+offset 水位增量续读（与 Codex/opencode 扫描器同构）。
public final class GrokUsageScanner {
    private let sessionsRoot: URL
    private let store: EurekaStore

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// 每文件私有状态（存 scan_files.extra）：会话 id（与 GrokSessionIndexer 一致）
    private struct FileExtra: Codable {
        var sessionId: String?
    }

    /// sessionsRoot 由调用方传入（app/CLI 用 `GrokPaths.sessionsRoot()`，测试用临时目录）——
    /// EurekaUsage 不依赖 EurekaIngest，故此处不设默认值。
    public init(sessionsRoot: URL, store: EurekaStore) {
        self.sessionsRoot = sessionsRoot
        self.store = store
    }

    private let projectResolver = ProjectResolver()
    private static let turnCompletedMarker = Data("\"turn_completed\"".utf8)

    /// 返回本轮新增的工具调用计数 + 用量记录数
    @discardableResult
    public func scanOnce() throws -> Int {
        var bumped = 0
        for file in eventFiles() {
            bumped += try scanFile(file)
            let updates = file.deletingLastPathComponent().appendingPathComponent("updates.jsonl")
            if FileManager.default.fileExists(atPath: updates.path) {
                bumped += try autoreleasepool { try scanUpdates(updates) }
            }
        }
        return bumped
    }

    /// updates.jsonl 的 turn_completed → usage_records。
    /// 文件被重写（inode 变 / 变短）时从头重扫：先删该会话已入账的行再重写，不靠 8 天就清理的去重键。
    private func scanUpdates(_ url: URL) throws -> Int {
        let path = url.path
        guard let info = JSONLinesReader.fileInfo(path: path) else { return 0 }
        let saved = try store.scanState.fileState(path: path)
        var offset: UInt64 = 0
        if let saved, saved.inode == info.inode, UInt64(saved.offset) <= info.size {
            offset = UInt64(saved.offset)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        let sessionDir = url.deletingLastPathComponent()
        let sessionId = resolveSessionId(sessionDir: sessionDir)
        // 父目录名是百分号编码的 cwd（%2FUsers%2F…）
        let cwd = sessionDir.deletingLastPathComponent().lastPathComponent.removingPercentEncoding
        let project = projectResolver.projectName(forCwd: cwd)

        var records: [UsageRecord] = []
        for line in chunk.lines {
            // 文件大头是流式正文（最大见过 76MB），先按字节筛再解析
            guard line.range(of: Self.turnCompletedMarker) != nil,
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let params = root["params"] as? [String: Any],
                let update = params["update"] as? [String: Any],
                update["sessionUpdate"] as? String == "turn_completed",
                let usage = update["usage"] as? [String: Any]
            else { continue }
            let meta = params["_meta"] as? [String: Any]
            let timestamp = ((meta?["agentTimestampMs"] as? NSNumber)?.doubleValue).map {
                Date(timeIntervalSince1970: $0 / 1000)
            } ?? ((root["timestamp"] as? NSNumber)?.doubleValue).map(Date.init(timeIntervalSince1970:))
                ?? Date()
            // 按模型拆；老版本没有 modelUsage 时整轮记在 primaryModel / grok 名下
            var perModel = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
            if perModel.isEmpty { perModel = ["grok": usage] }
            for (model, counts) in perModel {
                func int(_ key: String) -> Int { (counts[key] as? NSNumber)?.intValue ?? 0 }
                let input = int("inputTokens")
                let cachedRead = int("cachedReadTokens")
                let output = int("outputTokens")
                let cacheWrite = int("cacheCreationTokens")
                guard input > 0 || output > 0 || cacheWrite > 0 else { continue }
                let ticks = (counts["costUsdTicks"] as? NSNumber)?.doubleValue
                records.append(UsageRecord(
                    source: .grok,
                    model: model,
                    project: project,
                    sessionId: sessionId,
                    timestamp: timestamp,
                    // inputTokens 含缓存读（OpenAI 口径）→ 拆开记；reasoning 已计入 outputTokens
                    inputTokens: max(0, input - cachedRead),
                    outputTokens: output,
                    cacheCreationTokens: cacheWrite,
                    cacheReadTokens: cachedRead,
                    provider: "xai",
                    reportedCostUSD: ticks.map { $0 / 1e10 }))
            }
        }

        try store.scanState.transaction {
            if offset == 0 { try store.usage.deleteRecords(source: .grok, sessionId: sessionId) }
            try store.usage.insert(records)
            try store.scanState.setFileState(
                path: path, .init(inode: info.inode, offset: Int64(chunk.newOffset)))
        }
        return records.count
    }

    /// sessions/<enc-cwd>/<uuid>/events.jsonl 全量（两级目录遍历；
    /// 不按 mtime 过滤——scan_state 水位使无新数据的老文件近乎零成本，
    /// 每行按其 `ts` 归日，历史活动自然落到历史日期，不影响当月统计）。
    private func eventFiles() -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let events = sessionDir.appendingPathComponent("events.jsonl")
                if fm.fileExists(atPath: events.path) { results.append(events) }
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
        // 会话 id：与 GrokSessionIndexer 一致（summary.json info.id，缺则目录名），使
        // session_stats 行能按 id join 到会话列表
        if extra.sessionId == nil {
            extra.sessionId = resolveSessionId(sessionDir: url.deletingLastPathComponent())
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        var promptCount = 0
        var toolBumps: [String: Int] = [:]  // "day\u{1}name" → count
        for line in chunk.lines {
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            switch type {
            case "turn_started":
                promptCount += 1
            case "tool_started":
                guard let name = root["tool_name"] as? String, !name.isEmpty else { continue }
                let day = (root["ts"] as? String).flatMap { Self.isoFormatter.date(from: $0) }
                    .map { Self.dayFormatter.string(from: $0) }
                    ?? Self.dayFormatter.string(from: Date())
                toolBumps["\(day)\u{1}\(name)", default: 0] += 1
            default:
                break
            }
        }

        var bumped = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            for (composite, count) in toolBumps {
                let parts = composite.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { continue }
                try store.toolCalls.bump(
                    day: parts[0], source: .grok, kind: "tool", name: parts[1], by: count)
                bumped += count
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId, count: promptCount, reset: offset == 0)
            }
        }
        return bumped
    }

    /// 同 GrokSessionIndexer：summary.json 的 info.id，缺则会话目录名
    private func resolveSessionId(sessionDir: URL) -> String {
        let summary = sessionDir.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summary),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any],
           let info = root["info"] as? [String: Any],
           let id = info["id"] as? String, !id.isEmpty {
            return id
        }
        return sessionDir.lastPathComponent
    }
}
