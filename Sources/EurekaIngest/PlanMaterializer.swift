import EurekaKit
import EurekaStore
import Foundation

/// 把三源的「计划」物化为可读、可同步的 .md 首类工件。
///   - Claude Code：`~/.claude/plans/*.md` 本就是文件，直接索引（不物化）。
///   - Codex：rollout JSONL 里的 `update_plan` function_call（取每个会话最后一次）→ checklist `.md`。
///   - opencode：`opencode.db` 中 `mode='plan'` 的 assistant 消息的 text 分片 → `.md`。
/// 写前比对，内容不变则不覆盖（保持 mtime 稳定，避免同步每轮重传）。纯 IO、路径入参、可单测。
public enum PlanMaterializer {
    /// 计划条目（Plans 标签浏览用）
    public struct PlanEntry: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var source: AgentSource
        public var title: String
        public var path: String
        public var sizeBytes: UInt64
        public var modifiedAt: Date

        public init(
            source: AgentSource, title: String, path: String,
            sizeBytes: UInt64, modifiedAt: Date
        ) {
            self.source = source
            self.title = title
            self.path = path
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
        }
    }

    // MARK: - 默认路径（EUREKA_* 覆盖，便于单测）

    /// 计划物化暂存根 `~/Library/Application Support/Eureka/plans`
    public static func defaultStagingRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_PLANS_STAGING"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eureka/plans", isDirectory: true)
    }

    /// Claude 计划目录 `~/.claude/plans`
    public static func defaultClaudePlansDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        SkillMemoryIndexer.claudeHome(environment: environment)
            .appendingPathComponent("plans", isDirectory: true)
    }

    // MARK: - Codex：rollout JSONL 里的 update_plan → checklist .md

    @discardableResult
    public static func materializeCodex(sessionsRoot: URL, into stagingRoot: URL) -> Int {
        let outDir = stagingRoot.appendingPathComponent("codex", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sessionsRoot.path) else { return 0 }
        var written = 0
        for case let rel as String in enumerator {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let fileURL = sessionsRoot.appendingPathComponent(rel)
            guard let plan = lastUpdatePlan(fileURL) else { continue }  // 无 update_plan 跳过
            let stem = fileURL.deletingPathExtension().lastPathComponent
            let markdown = renderCodexPlan(stem: stem, plan: plan)
            if writeIfChanged(markdown, to: outDir.appendingPathComponent(stem + ".md")) {
                written += 1
            }
        }
        return written
    }

    /// 扫描一个 rollout，返回最后一次 update_plan 的 plan 数组（[{status, step}]）
    private static func lastUpdatePlan(_ url: URL) -> [[String: Any]]? {
        var latest: [[String: Any]]?
        forEachJSONLine(url) { root in
            guard let payload = root["payload"] as? [String: Any],
                  payload["type"] as? String == "function_call",
                  payload["name"] as? String == "update_plan",
                  let argsString = payload["arguments"] as? String,
                  let args = (try? JSONSerialization.jsonObject(
                    with: Data(argsString.utf8))) as? [String: Any],
                  let plan = args["plan"] as? [[String: Any]]
            else { return true }
            latest = plan
            return true
        }
        return latest
    }

    private static func renderCodexPlan(stem: String, plan: [[String: Any]]) -> String {
        var lines = ["# Codex 计划", "", "> 来源：\(stem)", ""]
        for item in plan {
            let step = (item["step"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let box: String
            switch item["status"] as? String {
            case "completed": box = "[x]"
            case "in_progress": box = "[~]"
            default: box = "[ ]"
            }
            lines.append("- \(box) \(step)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - opencode：opencode.db 中 plan 模式 assistant 文本 → .md

    @discardableResult
    public static func materializeOpencode(dbPath: URL, into stagingRoot: URL) -> Int {
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return 0 }
        let outDir = stagingRoot.appendingPathComponent("opencode", isDirectory: true)

        // plan 模式的 assistant 消息，按会话 + 时间排序
        let rows = (try? db.query("""
        SELECT id, session_id, time_created FROM message
        WHERE json_extract(data, '$.mode') = 'plan'
          AND json_extract(data, '$.role') = 'assistant'
        ORDER BY session_id, time_created, id
        """) { row -> (String, String) in
            (row.text(0) ?? "", row.text(1) ?? "")
        }) ?? []

        // 按会话分组（保持首次出现顺序）
        var bySession: [String: [String]] = [:]
        var order: [String] = []
        for (messageId, sessionId) in rows where !sessionId.isEmpty {
            if bySession[sessionId] == nil { order.append(sessionId) }
            bySession[sessionId, default: []].append(messageId)
        }

        var written = 0
        for sessionId in order {
            guard let messageIds = bySession[sessionId] else { continue }
            var pieces: [String] = []
            for messageId in messageIds {
                pieces.append(contentsOf: textParts(db: db, messageId: messageId))
            }
            guard !pieces.isEmpty else { continue }
            let title = opencodeTitle(db: db, sessionId: sessionId) ?? sessionId
            let body = pieces.joined(separator: "\n\n---\n\n")
            let markdown = "# \(title)\n\n> opencode 计划（plan 模式）· 会话 \(sessionId)\n\n\(body)\n"
            if writeIfChanged(markdown, to: outDir.appendingPathComponent(sessionId + ".md")) {
                written += 1
            }
        }
        return written
    }

    private static func textParts(db: SQLiteDB, messageId: String) -> [String] {
        let parts = (try? db.query(
            "SELECT data FROM part WHERE message_id = ? ORDER BY id",
            [.text(messageId)]) { $0.text(0) ?? "{}" }) ?? []
        var texts: [String] = []
        for partJSON in parts {
            guard let part = (try? JSONSerialization.jsonObject(
                with: Data(partJSON.utf8))) as? [String: Any],
                  part["type"] as? String == "text",
                  let text = part["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            texts.append(text)
        }
        return texts
    }

    private static func opencodeTitle(db: SQLiteDB, sessionId: String) -> String? {
        let rows = (try? db.query(
            "SELECT title FROM session WHERE id = ? LIMIT 1",
            [.text(sessionId)]) { $0.text(0) }) ?? []
        guard let title = rows.first.flatMap({ $0 }),
              !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return title
    }

    // MARK: - grok：每会话 plan.md（本就是 markdown）→ 暂存 grok/<uuid>.md

    /// grok 计划已是完整 .md（`~/.grok/sessions/<enc>/<uuid>/plan.md`，带 `# Plan: …`），
    /// 无需从工具调用物化：两级遍历会话目录，非空 plan.md 原样拷进暂存（保持管线统一 + 可同步）。
    @discardableResult
    public static func materializeGrok(sessionsRoot: URL, into stagingRoot: URL) -> Int {
        let fm = FileManager.default
        let outDir = stagingRoot.appendingPathComponent("grok", isDirectory: true)
        var written = 0
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let planURL = sessionDir.appendingPathComponent("plan.md")
                guard let content = try? String(contentsOf: planURL, encoding: .utf8),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }  // 无 plan.md / 空文件（未进过 plan 模式）→ 跳过
                let uuid = sessionDir.lastPathComponent
                if writeIfChanged(content, to: outDir.appendingPathComponent(uuid + ".md")) {
                    written += 1
                }
            }
        }
        return written
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - kimi：会话内 agents/<id>/plans/* → 暂存 kimi/<sessionId>-<名>.md

    /// kimi 计划落在每 agent 的 plans/ 目录（`sessions/<ws>/<session>/agents/<id>/plans/*`）。
    /// 非空文件原样拷进暂存；文件名带会话目录名前缀防跨会话/agent 撞名。
    @discardableResult
    public static func materializeKimi(sessionsRoot: URL, into stagingRoot: URL) -> Int {
        let fm = FileManager.default
        let outDir = stagingRoot.appendingPathComponent("kimi", isDirectory: true)
        var written = 0
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
                    let plansDir = agentDir.appendingPathComponent("plans", isDirectory: true)
                    let plans = (try? fm.contentsOfDirectory(
                        at: plansDir, includingPropertiesForKeys: nil)) ?? []
                    for planURL in plans {
                        guard let content = try? String(contentsOf: planURL, encoding: .utf8),
                              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { continue }
                        let stem = planURL.deletingPathExtension().lastPathComponent
                        let name = "\(sessionDir.lastPathComponent)-\(stem).md"
                        if writeIfChanged(content, to: outDir.appendingPathComponent(name)) {
                            written += 1
                        }
                    }
                }
            }
        }
        return written
    }

    // MARK: - 索引（Plans 标签用）：Claude 目录 + 暂存 codex/opencode/grok/kimi

    public static func index(claudePlansDir: URL, stagingRoot: URL) -> [PlanEntry] {
        var result: [PlanEntry] = []
        collect(dir: claudePlansDir, source: .claude, into: &result)
        collect(dir: stagingRoot.appendingPathComponent("codex", isDirectory: true),
                source: .codex, into: &result)
        collect(dir: stagingRoot.appendingPathComponent("opencode", isDirectory: true),
                source: .opencode, into: &result)
        collect(dir: stagingRoot.appendingPathComponent("grok", isDirectory: true),
                source: .grok, into: &result)
        collect(dir: stagingRoot.appendingPathComponent("kimi", isDirectory: true),
                source: .kimi, into: &result)
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func collect(dir: URL, source: AgentSource, into result: inout [PlanEntry]) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        for url in items where url.pathExtension.lowercased() == "md" {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            result.append(PlanEntry(
                source: source,
                title: planTitle(url),
                path: url.path,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
    }

    /// 标题 = 首个 `# ` 标题行，否则文件名
    private static func planTitle(_ url: URL) -> String {
        if let head = readHead(url) {
            for line in head.components(separatedBy: "\n") where line.hasPrefix("# ") {
                let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - 工具

    /// 内容与磁盘相同则不写（保持 mtime 稳定）；否则原子写入。
    @discardableResult
    private static func writeIfChanged(_ content: String, to url: URL) -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            return false
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 逐行解析 jsonl（坏行容错跳过）；body 返回 false 提前终止
    private static func forEachJSONLine(_ url: URL, _ body: ([String: Any]) -> Bool) {
        guard let data = FileManager.default.contents(atPath: url.path) else { return }
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            let lineData = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
            guard !lineData.isEmpty,
                  let root = (try? JSONSerialization.jsonObject(
                    with: Data(lineData))) as? [String: Any]
            else { continue }
            if !body(root) { return }
        }
    }

    private static func readHead(_ url: URL, bytes: Int = 4096) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path),
              let data = try? handle.read(upToCount: bytes) else { return nil }
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    }
}
