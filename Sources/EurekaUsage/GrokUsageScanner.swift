import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.grok/sessions/<enc-cwd>/<uuid>/events.jsonl，统计工具调用与提问数。
/// grok 订阅制、transcript 无 per-request token/费用 → **不写 usage_records**（不入费用账），
/// 只计 `tool_started`（工具调用 → tool_calls）与 `turn_started`（提问 → session_stats），
/// 供「技能/插件」面板与会话列表「N 段」使用。按 inode+offset 水位增量续读
/// （与 Codex/opencode 扫描器同构，scan_state 使重读廉价）。
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

    /// 返回本轮新增的工具调用计数
    @discardableResult
    public func scanOnce() throws -> Int {
        var bumped = 0
        for file in eventFiles() {
            bumped += try scanFile(file)
        }
        return bumped
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
