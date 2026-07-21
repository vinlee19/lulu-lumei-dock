import Foundation
import EurekaKit
import EurekaStore

/// 扫描 ~/.gemini/tmp/<slug>/chats/session-*.jsonl（Gemini CLI v0.51 实勘格式）。
/// `type == "gemini"` 的消息行自带 model 与 tokens{input, output, cached, thoughts}：
/// Gemini 口径 input 含 cached、thoughts 按输出计费 → 写库时
/// inputTokens = input - cached、cacheRead = cached、outputTokens = output + thoughts。
/// `type == "user"`（非 session_context 注入）计入 session_stats 提问数。
/// 按 inode+offset 水位增量续读；会话恢复可能整写文件（水位失效回 0 重读），
/// 故 usage 记录再用 dedup_keys（gemini:<sessionId>:<messageId>）兜底防重。
public final class GeminiUsageScanner {
    private let tmpRoot: URL
    private let projectsFile: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()

    /// 每文件私有状态（存 scan_files.extra）：会话/项目归属（首扫时从 header/slug 解析）
    private struct FileExtra: Codable {
        var project: String?
        var sessionId: String?
    }

    /// 路径由调用方传入（app/CLI 用 GeminiPaths，测试用临时目录）——
    /// EurekaUsage 不依赖 EurekaIngest，故此处不设默认值。
    public init(tmpRoot: URL, projectsFile: URL, store: EurekaStore) {
        self.tmpRoot = tmpRoot
        self.projectsFile = projectsFile
        self.store = store
    }

    /// 返回本轮新增的 usage 记录数
    @discardableResult
    public func scanOnce() throws -> Int {
        let slugToProject = loadSlugMap()
        var inserted = 0
        for (file, slug) in chatFiles() {
            inserted += try scanFile(file, cwd: slugToProject[slug])
        }
        return inserted
    }

    /// {"projects": {"/abs/path": "slug"}} → slug: path
    private func loadSlugMap() -> [String: String] {
        guard let data = try? Data(contentsOf: projectsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: String]
        else { return [:] }
        var reversed: [String: String] = [:]
        for (path, slug) in projects { reversed[slug] = path }
        return reversed
    }

    private func chatFiles() -> [(URL, String)] {
        let fm = FileManager.default
        var results: [(URL, String)] = []
        let slugDirs = (try? fm.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for slugDir in slugDirs
        where (try? slugDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let chatsDir = slugDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir, includingPropertiesForKeys: nil)) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("session-")
                && file.pathExtension.lowercased() == "jsonl" {
                results.append((file, slugDir.lastPathComponent))
            }
        }
        return results
    }

    private func scanFile(_ url: URL, cwd: String?) throws -> Int {
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
        if extra.project == nil, let cwd {
            extra.project = projectResolver.projectName(forCwd: cwd)
        }
        guard info.size > offset else { return 0 }
        guard let chunk = JSONLinesReader.read(path: path, from: offset) else { return 0 }

        struct Candidate {
            var dedupKey: String
            var record: UsageRecord
        }
        var candidates: [Candidate] = []
        var promptCount = 0

        for line in chunk.lines {
            guard let object = try? JSONSerialization.jsonObject(with: line),
                  let root = object as? [String: Any]
            else { continue }
            // header 行（sessionId 归属）
            if extra.sessionId == nil, let sessionId = root["sessionId"] as? String,
               root["type"] == nil {
                extra.sessionId = sessionId
                continue
            }
            guard root["$set"] == nil, let type = root["type"] as? String else { continue }

            if type == "user" {
                let text = Self.contentText(root["content"])
                if !text.hasPrefix("<session_context>") { promptCount += 1 }
                continue
            }
            guard type == "gemini", let usage = root["tokens"] as? [String: Any] else { continue }
            let rawInput = (usage["input"] as? NSNumber)?.intValue ?? 0
            let output = (usage["output"] as? NSNumber)?.intValue ?? 0
            let cached = (usage["cached"] as? NSNumber)?.intValue ?? 0
            let thoughts = (usage["thoughts"] as? NSNumber)?.intValue ?? 0
            guard rawInput > 0 || output > 0 || thoughts > 0 else { continue }
            let messageId = (root["id"] as? String) ?? UUID().uuidString
            let timestamp = (root["timestamp"] as? String)
                .flatMap(Self.parseISO) ?? Date()
            candidates.append(Candidate(
                dedupKey: "gemini:\(extra.sessionId ?? path):\(messageId)",
                record: UsageRecord(
                    source: .gemini,
                    model: (root["model"] as? String) ?? "gemini-unknown",
                    project: extra.project,
                    sessionId: extra.sessionId,
                    timestamp: timestamp,
                    inputTokens: max(0, rawInput - cached),
                    outputTokens: output + thoughts,
                    cacheCreationTokens: 0,
                    cacheReadTokens: cached)))
        }

        var inserted = 0
        let extraJSON = String(
            data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
        try store.scanState.transaction {
            // 会话恢复可能整写文件 → 用 dedup_keys 过滤已见消息；
            // CLI 流式写入会把同一消息行写两次 → 同批次内也要去重（seenThisBatch）
            let existing = try store.scanState.existingDedupKeys(candidates.map(\.dedupKey))
            var seenThisBatch = Set<String>()
            for candidate in candidates
            where existing[candidate.dedupKey] == nil
                && seenThisBatch.insert(candidate.dedupKey).inserted {
                let recordId = try store.usage.insertReturningId(candidate.record)
                try store.scanState.upsertDedupKey(
                    candidate.dedupKey, recordId: recordId,
                    outputTokens: candidate.record.outputTokens,
                    at: candidate.record.timestamp)
                inserted += 1
            }
            try store.scanState.setFileState(
                path: path,
                .init(inode: info.inode, offset: Int64(chunk.newOffset), extra: extraJSON))
            if let sessionId = extra.sessionId {
                try store.sessionStats.recordPrompts(
                    path: path, sessionId: sessionId, count: promptCount, reset: offset == 0)
            }
        }
        return inserted
    }

    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseISO(_ string: String) -> Date? {
        isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }
}
