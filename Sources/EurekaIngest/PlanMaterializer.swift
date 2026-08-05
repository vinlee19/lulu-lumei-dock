import EurekaKit
import EurekaStore
import Foundation

/// 把各家 agent 的「计划」物化为可读、可同步的 .md 首类工件。
/// 物化六源：
///   - Codex：Plan Mode 最终 `<proposed_plan>` 优先，`update_plan` 工作清单兜底。
///   - opencode：`opencode.db` 中 `mode='plan'` 的 assistant 消息的 text 分片 → `.md`。
///   - Grok / Kimi：计划本就是 .md（Grok 每会话 `plan.md`；Kimi 每 agent 的 `plans/` 目录），原样拷入暂存。
///   - Gemini / Qwen：启发式提取最后一条「像清单」的助手消息。
/// 直接索引（不物化）：Claude（`~/.claude/plans/*.md`）与 Hermes（`plan` 技能写出的真 .md）。
/// 写前比对，内容不变则不覆盖（保持 mtime 稳定，避免同步每轮重传）。纯 IO、路径入参、可单测。
public enum PlanMaterializer {
    public enum PlanKind: String, Equatable, Sendable {
        case finalPlan
        case workingChecklist
        case document
        case projectDocument

        public var displayName: String {
            switch self {
            case .finalPlan: return "最终方案"
            case .workingChecklist: return "工作清单"
            case .document: return "计划文档"
            case .projectDocument: return "项目文档"
            }
        }
    }

    /// 计划状态（列表状态字 / 图标进度环 / 统计分布共用）。由 kind + 清单完成度派生。
    public enum PlanStatus: String, Equatable, Sendable {
        case complete       // 全部完成
        case inProgress     // 进行中（有清单，部分完成，或无清单的活动方案）
        case draft          // 草稿（有清单但一项未做）
        case document       // 文档（计划文档 / 项目文档，无进度概念）

        public var displayName: String {
            switch self {
            case .complete: return "已完成"
            case .inProgress: return "进行中"
            case .draft: return "草稿"
            case .document: return "文档"
            }
        }
    }

    /// 由任务清单完成度派生状态：无清单 → 文档；否则 完成 / 草稿 / 进行中。
    /// （kind 只表示文档类型，不决定状态——带清单的项目文档同样显示进度。）
    public static func deriveStatus(done: Int, total: Int) -> PlanStatus {
        if total == 0 { return .document }
        if done >= total { return .complete }
        if done == 0 { return .draft }
        return .inProgress
    }

    /// 计划条目（Plans 标签浏览用）
    public struct PlanEntry: Equatable, Sendable, Identifiable {
        public var id: String { path }
        public var source: AgentSource
        public var title: String
        public var kind: PlanKind
        public var path: String
        public var sizeBytes: UInt64
        public var modifiedAt: Date
        /// 项目内 plan 文档 = 所属项目名；agent 计划 = nil
        public var project: String?
        // 派生字段（索引时解析正文得到）
        /// 已完成清单项数
        public var stepsDone: Int
        /// 清单项总数（0 = 无任务清单）
        public var stepsTotal: Int
        /// 派生状态
        public var status: PlanStatus
        /// 一句话摘要（正文首个有意义行）
        public var summary: String?
        /// 来源会话 id（物化计划由 sessions.json 边车提供；真实文件计划为 nil）
        public var sessionId: String?

        /// 完成占比（无清单 → nil）
        public var progress: Double? {
            stepsTotal > 0 ? Double(stepsDone) / Double(stepsTotal) : nil
        }

        public init(
            source: AgentSource, title: String, path: String,
            kind: PlanKind = .document,
            sizeBytes: UInt64, modifiedAt: Date,
            project: String? = nil,
            stepsDone: Int = 0, stepsTotal: Int = 0,
            status: PlanStatus = .document,
            summary: String? = nil,
            sessionId: String? = nil
        ) {
            self.source = source
            self.title = title
            self.kind = kind
            self.path = path
            self.sizeBytes = sizeBytes
            self.modifiedAt = modifiedAt
            self.project = project
            self.stepsDone = stepsDone
            self.stepsTotal = stepsTotal
            self.status = status
            self.summary = summary
            self.sessionId = sessionId
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

    // MARK: - Codex：Plan Mode 最终方案优先，update_plan 工作清单兜底

    private enum CodexPlanContent {
        case finalPlan(String)
        case workingChecklist([[String: Any]])
    }

    private struct CodexPlanArtifact {
        var sessionId: String
        var title: String
        var content: CodexPlanContent
    }

    /// Codex 物化增量指纹（staging/codex/.scan-state.json）：
    /// rollout 路径 → size+mtime + 产物名 + 会话/标题（线程改名时失效重渲）。
    /// 全量解析 rollouts 是 O(GB) 级成本，指纹跳过是 Plans 页刷新速度的关键。
    private struct CodexScanState: Codable {
        struct Entry: Codable {
            var size: Int64
            var mtime: Double
            /// 该 rollout 的物化产物文件名；nil = 已解析过且不含计划（同样跳过重解析）
            var output: String?
            var sessionId: String?
            var title: String?
        }
        var files: [String: Entry] = [:]
    }

    @discardableResult
    public static func materializeCodex(
        sessionsRoot: URL,
        into stagingRoot: URL,
        threadNameIndexURL: URL? = nil
    ) -> Int {
        let outDir = stagingRoot.appendingPathComponent("codex", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: sessionsRoot.path) else { return 0 }
        let threadNames = CodexThreadNameIndex.load(
            threadNameIndexURL ?? CodexThreadNameIndex.resolvedURL(for: sessionsRoot))
        let stateURL = outDir.appendingPathComponent(".scan-state.json")
        let oldState = (try? JSONDecoder().decode(
            CodexScanState.self, from: Data(contentsOf: stateURL))) ?? CodexScanState()
        var newState = CodexScanState()
        var changed = 0
        var expected = Set<String>()
        for case let rel as String in enumerator {
            let name = (rel as NSString).lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let fileURL = sessionsRoot.appendingPathComponent(rel)
            let stem = fileURL.deletingPathExtension().lastPathComponent
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = ((attrs?[.modificationDate] as? Date) ?? .distantPast)
                .timeIntervalSince1970

            // 指纹未变且线程名未变 → 跳过全文解析，沿用缓存产物。
            // mtime 比较带 1ms 容差：Double 经 JSON 往返有精度漂移，精确相等会跨进程全量失配
            if let cached = oldState.files[fileURL.path],
               cached.size == size, abs(cached.mtime - mtime) < 0.001,
               !titleChanged(cached, threadNames: threadNames) {
                newState.files[fileURL.path] = cached
                if let output = cached.output { expected.insert(output) }
                continue
            }

            guard let artifact = extractCodexPlan(
                fileURL, stem: stem, threadNames: threadNames) else {
                // 不含计划也记指纹，避免每轮反复重解析
                newState.files[fileURL.path] = .init(
                    size: size, mtime: mtime, output: nil, sessionId: nil, title: nil)
                continue
            }
            let outputName = stem + ".md"
            expected.insert(outputName)
            let markdown: String
            switch artifact.content {
            case .finalPlan(let body):
                markdown = renderCodexFinalPlan(artifact: artifact, body: body)
            case .workingChecklist(let plan):
                markdown = renderCodexChecklist(artifact: artifact, plan: plan)
            }
            if writeIfChanged(markdown, to: outDir.appendingPathComponent(outputName)) {
                changed += 1
            }
            newState.files[fileURL.path] = .init(
                size: size, mtime: mtime, output: outputName,
                sessionId: artifact.sessionId, title: artifact.title)
        }

        // 来源会话被删除、或最后已不再含计划时，移除陈旧物化副本。
        let staged = (try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        for file in staged
        where file.pathExtension.lowercased() == "md" && !expected.contains(file.lastPathComponent) {
            if (try? fm.removeItem(at: file)) != nil { changed += 1 }
        }

        if let data = try? JSONEncoder().encode(newState) {
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }

        // 边车覆盖该轮所有仍存在的物化产物（含指纹跳过、未重写的），两个来源合一：
        // 新解析的走 artifact.sessionId，跳过的走缓存 state 里同样携带的 sessionId。
        var smap: [String: String] = [:]
        for entry in newState.files.values {
            if let output = entry.output, let sessionId = entry.sessionId {
                smap[output] = sessionId
            }
        }
        writeSessionMap(smap, outDir: outDir)
        return changed
    }

    /// 线程被改名 → 缓存标题失效需重渲；索引里查不到名字（用兜底标题）不算变
    private static func titleChanged(
        _ cached: CodexScanState.Entry, threadNames: [String: String]
    ) -> Bool {
        guard let sessionId = cached.sessionId,
              let current = threadNames[sessionId] else { return false }
        return current != cached.title
    }

    private static func extractCodexPlan(
        _ url: URL, stem: String, threadNames: [String: String]
    ) -> CodexPlanArtifact? {
        var sessionId: String?
        var fallbackTitle: String?
        var eventThreadName: String?
        var finalPlan: String?
        var latestChecklist: [[String: Any]]?

        forEachJSONLine(url) { root in
            let rootType = root["type"] as? String
            let payload = root["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String

            if rootType == "session_meta" {
                sessionId = payload["id"] as? String ?? sessionId
            } else if rootType == "event_msg", payloadType == "user_message",
                      fallbackTitle == nil, let message = payload["message"] as? String {
                fallbackTitle = summarizeTitle(message)
            } else if rootType == "event_msg", payloadType == "thread_name_updated",
                      let name = payload["thread_name"] as? String {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { eventThreadName = trimmed }
            }

            if rootType == "response_item", payloadType == "message",
               payload["role"] as? String == "assistant" {
                for item in payload["content"] as? [[String: Any]] ?? []
                where item["type"] as? String == "output_text" {
                    if let text = item["text"] as? String,
                       let proposed = extractProposedPlan(text) {
                        finalPlan = proposed
                    }
                }
            }

            // 兼容未来 rollout 直接持久化 app-server 的 ThreadItem.plan。
            if payloadType == "plan", let text = payload["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { finalPlan = trimmed }
            }
            if rootType == "event_msg", payloadType == "item_completed",
               let item = payload["item"] as? [String: Any],
               item["type"] as? String == "plan", let text = item["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { finalPlan = trimmed }
            }

            if rootType == "response_item", payloadType == "function_call",
               payload["name"] as? String == "update_plan",
               let argsString = payload["arguments"] as? String,
               let args = (try? JSONSerialization.jsonObject(
                    with: Data(argsString.utf8))) as? [String: Any],
               let plan = args["plan"] as? [[String: Any]] {
                latestChecklist = plan
            }
            return true
        }

        let id = sessionId ?? stem
        let title = threadNames[id] ?? eventThreadName ?? fallbackTitle ?? "Codex 计划"
        if let finalPlan {
            return CodexPlanArtifact(sessionId: id, title: title, content: .finalPlan(finalPlan))
        }
        if let latestChecklist {
            return CodexPlanArtifact(
                sessionId: id, title: title, content: .workingChecklist(latestChecklist))
        }
        return nil
    }

    private static func extractProposedPlan(_ text: String) -> String? {
        guard let open = text.range(of: "<proposed_plan>", options: .backwards) else { return nil }
        let remainder = text[open.upperBound...]
        guard let close = remainder.range(of: "</proposed_plan>") else { return nil }
        let body = remainder[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func renderCodexFinalPlan(artifact: CodexPlanArtifact, body: String) -> String {
        let title = summarizeTitle(artifact.title) ?? "Codex 计划"
        var lines = body.components(separatedBy: "\n")
        if let first = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), lines[first].hasPrefix("# ") {
            lines.remove(at: first)  // 正式线程名统一作为物化文档标题，避免双 H1。
        }
        let content = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "# \(title)\n\n> Codex Plan Mode 最终方案 · 会话 \(artifact.sessionId)\n\n\(content)\n"
    }

    private static func renderCodexChecklist(
        artifact: CodexPlanArtifact, plan: [[String: Any]]
    ) -> String {
        let title = summarizeTitle(artifact.title) ?? "Codex 工作清单"
        var lines = ["# \(title)", "", "> Codex 工作清单 · 会话 \(artifact.sessionId)", ""]
        for item in plan {
            let step = (item["step"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !step.isEmpty else { continue }
            let box: String
            switch item["status"] as? String {
            case "completed": box = "[x]"
            case "in_progress", "inProgress": box = "[~]"
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
        var smap: [String: String] = [:]
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
            smap[sessionId + ".md"] = sessionId
        }
        writeSessionMap(smap, outDir: outDir)
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
        var smap: [String: String] = [:]
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
                smap[uuid + ".md"] = uuid
            }
        }
        writeSessionMap(smap, outDir: outDir)
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

    // MARK: - qoder：plans/<slug>.md（本就是 markdown）→ 暂存 qoder/<名>.md

    /// qoder 计划已是完整 .md（`~/.qoder-cn/plans/<slug>.md`，plan 模式产物），
    /// 非空文件原样拷进暂存（保持管线统一 + 可同步）。codebuddy 无 plans 目录，无物化。
    @discardableResult
    public static func materializeQoder(plansRoot: URL, into stagingRoot: URL) -> Int {
        let fm = FileManager.default
        let outDir = stagingRoot.appendingPathComponent("qoder", isDirectory: true)
        var written = 0
        let plans = (try? fm.contentsOfDirectory(
            at: plansRoot, includingPropertiesForKeys: nil)) ?? []
        for planURL in plans where planURL.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: planURL, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            if writeIfChanged(
                content, to: outDir.appendingPathComponent(planURL.lastPathComponent)) {
                written += 1
            }
        }
        return written
    }

    // MARK: - cursor：composerData.todos → 暂存 cursor/<composerId>.md

    /// Cursor **没有 plans 目录**（`composer.planMigrationToHomeDirCompleted=true`，
    /// 但迁移目标目录根本不存在），它的计划是会话内的 `todos` 数组，由 `todo_write`
    /// 工具写进 `composerData`。所以走合成路线，与 codex 的 `update_plan` 同一套路
    /// （实勘 154 个会话里 22 个带 todos，状态 completed / in_progress / pending / cancelled）。
    ///
    /// 只物化**有 todos** 的会话；每会话一份 `<composerId>.md`，内容不变就不重写
    /// （`writeIfChanged` 保持 mtime 稳定，备份才不会每轮都判为变更）。
    @discardableResult
    public static func materializeCursor(
        dbPath: URL = CursorPaths.globalStateDB(),
        into stagingRoot: URL,
        maxSessions: Int = 500
    ) -> Int {
        guard FileManager.default.fileExists(atPath: dbPath.path),
            let db = try? SQLiteDB(path: dbPath.path, readOnly: true)
        else { return 0 }
        let outDir = stagingRoot.appendingPathComponent("cursor", isDirectory: true)

        // 键前缀范围扫描走覆盖索引；`json_array_length(...todos) > 0` 让 SQLite 在 C 侧
        // 筛掉绝大多数会话，不用把 200KB 的 JSON 搬进 Swift（同 CursorSessionIndexer 的取舍）
        let rows = (try? db.query(
            """
            SELECT substr(key, 14),
                   json_extract(value, '$.name'),
                   json_extract(value, '$.todos')
            FROM cursorDiskKV
            WHERE key >= 'composerData:' AND key < 'composerData;'
              AND json_array_length(json_extract(value, '$.todos')) > 0
            ORDER BY json_extract(value, '$.lastUpdatedAt') DESC
            LIMIT ?
            """, [.int(Int64(maxSessions))]
        ) { row in
            (row.text(0) ?? "", row.text(1), row.text(2) ?? "[]")
        }) ?? []

        var written = 0
        var smap: [String: String] = [:]
        for (composerId, name, todosJSON) in rows where !composerId.isEmpty {
            guard let data = todosJSON.data(using: .utf8),
                let todos = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
                !todos.isEmpty
            else { continue }
            let content = renderCursorTodos(composerId: composerId, name: name, todos: todos)
            guard !content.isEmpty else { continue }
            if writeIfChanged(content, to: outDir.appendingPathComponent("\(composerId).md")) {
                written += 1
            }
            smap["\(composerId).md"] = composerId
        }
        writeSessionMap(smap, outDir: outDir)
        return written
    }

    /// `todos` → markdown 清单。状态框与 codex 清单一致（`[x]` / `[~]` / `[ ]`），
    /// 另加 `[-]` 表示 Cursor 特有的 `cancelled`：放弃的步骤不该看起来像还没做。
    static func renderCursorTodos(
        composerId: String, name: String?, todos: [[String: Any]]
    ) -> String {
        let title = name.flatMap { summarizeTitle($0) } ?? "Cursor 工作清单"
        var lines = ["# \(title)", "", "> Cursor 工作清单 · 会话 \(composerId)", ""]
        var any = false
        for item in todos {
            let content = (item["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let box: String
            switch item["status"] as? String {
            case "completed": box = "[x]"
            case "in_progress", "inProgress": box = "[~]"
            case "cancelled", "canceled": box = "[-]"
            default: box = "[ ]"
            }
            lines.append("- \(box) \(content)")
            any = true
        }
        guard any else { return "" }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    // MARK: - 索引（Plans 标签用）：Claude 目录 + 暂存 codex/opencode/grok/kimi/qoder/cursor

    /// hermesPlansDirs：Hermes 的计划由 `plan` 技能用 write_file 直接写成 .md
    /// （项目内 `<repo>/.hermes/plans/`，profile 级 `~/.hermes/plans/` 可选），
    /// 本就是真文件 → 同 Claude 一样直接索引，**不需要物化**。
    public static func index(
        claudePlansDir: URL, stagingRoot: URL, hermesPlansDirs: [URL] = []
    ) -> [PlanEntry] {
        var result: [PlanEntry] = []
        collect(dir: claudePlansDir, source: .claude, into: &result)
        for dir in hermesPlansDirs {
            collect(dir: dir, source: .hermes, into: &result)
        }
        // 物化暂存源：各自读 sessions.json 边车补 sessionId（kimi/gemini/qwen/qoder 没有边车文件，
        // sessionMap(dir:) 读不到就返回空表，传了也无害）。
        let codexDir = stagingRoot.appendingPathComponent("codex", isDirectory: true)
        collect(dir: codexDir, source: .codex, into: &result, sessionMap: sessionMap(dir: codexDir))
        let opencodeDir = stagingRoot.appendingPathComponent("opencode", isDirectory: true)
        collect(dir: opencodeDir, source: .opencode, into: &result,
                sessionMap: sessionMap(dir: opencodeDir))
        let grokDir = stagingRoot.appendingPathComponent("grok", isDirectory: true)
        collect(dir: grokDir, source: .grok, into: &result, sessionMap: sessionMap(dir: grokDir))
        let kimiDir = stagingRoot.appendingPathComponent("kimi", isDirectory: true)
        collect(dir: kimiDir, source: .kimi, into: &result, sessionMap: sessionMap(dir: kimiDir))
        let geminiDir = stagingRoot.appendingPathComponent("gemini", isDirectory: true)
        collect(dir: geminiDir, source: .gemini, into: &result, sessionMap: sessionMap(dir: geminiDir))
        let qwenDir = stagingRoot.appendingPathComponent("qwen", isDirectory: true)
        collect(dir: qwenDir, source: .qwen, into: &result, sessionMap: sessionMap(dir: qwenDir))
        let qoderDir = stagingRoot.appendingPathComponent("qoder", isDirectory: true)
        collect(dir: qoderDir, source: .qoder, into: &result, sessionMap: sessionMap(dir: qoderDir))
        let cursorDir = stagingRoot.appendingPathComponent("cursor", isDirectory: true)
        collect(dir: cursorDir, source: .cursor, into: &result, sessionMap: sessionMap(dir: cursorDir))
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: - Gemini / Qwen：无显式 plan 产物 → 启发式提取（保守：只认任务清单）

    /// 助手消息"像一份工作清单"的保守判定：≥3 条任务清单行（- [ ] / - [x] / - [~]）
    static func looksLikeChecklistPlan(_ text: String) -> Bool {
        var count = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["- [ ]", "- [x]", "- [X]", "- [~]"] where trimmed.hasPrefix(marker) {
                count += 1
                break
            }
            if count >= 3 { return true }
        }
        return false
    }

    /// Gemini：每会话取最后一条"像清单"的助手消息（与 Codex 取最后一次 update_plan 同语义）
    @discardableResult
    public static func materializeGemini(
        tmpRoot: URL, projectsFile: URL, into stagingRoot: URL
    ) -> Int {
        let outDir = stagingRoot.appendingPathComponent("gemini", isDirectory: true)
        var changed = 0
        var expected = Set<String>()
        for session in GeminiSessionIndexer.index(
            tmpRoot: tmpRoot, projectsFile: projectsFile, maxSessions: 1000) {
            let result = TranscriptReader.loadGemini(
                path: session.transcriptPath, maxMessages: 2000)
            guard let plan = result.messages.last(where: {
                $0.role == .assistant && looksLikeChecklistPlan($0.text)
            }) else { continue }
            let name = "gemini-\(session.id.prefix(8)).md"
            expected.insert(name)
            let title = summarizeTitle(session.name ?? "") ?? "Gemini 计划"
            let markdown = "# \(title)\n\n> Gemini 工作清单（启发式提取，只读物化副本） · 会话 \(session.id)\n\n\(plan.text)\n"
            if writeIfChanged(markdown, to: outDir.appendingPathComponent(name)) { changed += 1 }
        }
        changed += removeStale(in: outDir, keeping: expected)
        return changed
    }

    /// Qwen：同 Gemini 的启发式
    @discardableResult
    public static func materializeQwen(projectsRoot: URL, into stagingRoot: URL) -> Int {
        let outDir = stagingRoot.appendingPathComponent("qwen", isDirectory: true)
        var changed = 0
        var expected = Set<String>()
        for session in QwenSessionIndexer.index(projectsRoot: projectsRoot, maxSessions: 1000) {
            let result = TranscriptReader.loadQwen(
                path: session.transcriptPath, maxMessages: 2000)
            guard let plan = result.messages.last(where: {
                $0.role == .assistant && looksLikeChecklistPlan($0.text)
            }) else { continue }
            let name = "qwen-\(session.id.prefix(8)).md"
            expected.insert(name)
            let title = summarizeTitle(session.name ?? "") ?? "Qwen 计划"
            let markdown = "# \(title)\n\n> Qwen 工作清单（启发式提取，只读物化副本） · 会话 \(session.id)\n\n\(plan.text)\n"
            if writeIfChanged(markdown, to: outDir.appendingPathComponent(name)) { changed += 1 }
        }
        changed += removeStale(in: outDir, keeping: expected)
        return changed
    }

    /// 清理不再对应任何会话的陈旧物化副本
    private static func removeStale(in outDir: URL, keeping expected: Set<String>) -> Int {
        let fm = FileManager.default
        var removed = 0
        let staged = (try? fm.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)) ?? []
        for file in staged
        where file.pathExtension.lowercased() == "md" && !expected.contains(file.lastPathComponent) {
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    /// 项目仓库内的 plan 文档：`<root>/plans/` + `<root>/docs` 子树内名为 `plans` 的目录（深度 ≤4）。
    /// 收 *.md（忽略 README.md），每项目上限 200 条防大仓库失控。
    public static func indexProjectPlans(
        roots: [(root: URL, name: String)]
    ) -> [PlanEntry] {
        let fm = FileManager.default
        var result: [PlanEntry] = []
        for (root, projectName) in roots {
            var planDirs: [URL] = [root.appendingPathComponent("plans", isDirectory: true)]
            let docsRoot = root.appendingPathComponent("docs", isDirectory: true)
            if let enumerator = fm.enumerator(
                at: docsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let url as URL in enumerator {
                    // docs 下深度 ≤4 内名为 plans 的目录
                    if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                    guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory == true else { continue }
                    if url.lastPathComponent == "plans" {
                        planDirs.append(url)
                        enumerator.skipDescendants()
                    }
                }
            }
            var count = 0
            for dir in planDirs {
                let items = (try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                for url in items
                where url.pathExtension.lowercased() == "md"
                    && url.lastPathComponent.lowercased() != "readme.md" {
                    guard count < 200 else { break }
                    count += 1
                    let values = try? url.resourceValues(
                        forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let body = readBody(url) ?? ""
                    let check = PlanParsing.checklist(body)
                    result.append(PlanEntry(
                        source: .claude,  // 占位：项目文档以 kind/project 区分，不按 source 展示
                        title: planTitle(body: body, url: url),
                        path: url.path,
                        kind: .projectDocument,
                        sizeBytes: UInt64(values?.fileSize ?? 0),
                        modifiedAt: values?.contentModificationDate ?? .distantPast,
                        project: projectName,
                        stepsDone: check.done, stepsTotal: check.total,
                        status: deriveStatus(done: check.done, total: check.total),
                        summary: PlanParsing.summary(body)))
                }
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func collect(
        dir: URL, source: AgentSource, into result: inout [PlanEntry],
        sessionMap: [String: String] = [:]
    ) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        for url in items where url.pathExtension.lowercased() == "md" {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let body = readBody(url) ?? ""
            let kind = planKind(body: body, source: source)
            let check = PlanParsing.checklist(body)
            result.append(PlanEntry(
                source: source,
                title: planTitle(body: body, url: url),
                path: url.path,
                kind: kind,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                stepsDone: check.done, stepsTotal: check.total,
                status: deriveStatus(done: check.done, total: check.total),
                summary: PlanParsing.summary(body),
                sessionId: sessionMap[url.lastPathComponent]))
        }
    }

    /// 物化时的占位标题：会话既没有 thread name、也没有可用的首条用户消息时写入。
    /// 这类标题信息量为零（本机 110 份 Codex 计划里 45 份都叫「Codex 计划」），索引阶段改用正文首步替代。
    static let placeholderTitles: Set<String> = [
        "Codex 计划", "Codex 工作清单", "Gemini 计划", "Qwen 计划", "opencode 计划",
    ]

    /// 标题 = 首个 `# ` 标题行，否则文件名。两处收紧：
    ///   1. 占位标题 → 换成正文第一条清单步骤（「这份计划实际要做什么」比「Codex 计划」有用）；
    ///   2. 整段提示词当标题 → 按句读边界收短，列表里才读得出重点。
    private static func planTitle(body: String, url: URL) -> String {
        var heading: String?
        for line in body.components(separatedBy: "\n") where line.hasPrefix("# ") {
            let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                heading = title
                break
            }
        }
        if let heading, !placeholderTitles.contains(heading) {
            return tightenPlanTitle(heading)
        }
        if let step = PlanParsing.firstStep(body) {
            return tightenPlanTitle(step)
        }
        return heading ?? url.deletingPathExtension().lastPathComponent
    }

    private static func planKind(body: String, source: AgentSource) -> PlanKind {
        guard source == .codex else { return .document }
        if body.contains("> Codex Plan Mode 最终方案") { return .finalPlan }
        if body.contains("> Codex 工作清单") { return .workingChecklist }
        return .document
    }

    /// 读计划正文（较 readHead 更大上限，供清单/摘要解析；仍限最大字节防超大文件）
    private static func readBody(_ url: URL, maxBytes: Int = 512 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path),
              let data = try? handle.read(upToCount: maxBytes) else { return nil }
        try? handle.close()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 工具

    /// 物化目录「文件名 → 会话 id」边车（collect 读取；仅物化器知道会话归属）
    static func writeSessionMap(_ map: [String: String], outDir: URL) {
        let url = outDir.appendingPathComponent("sessions.json")
        guard !map.isEmpty else { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func sessionMap(dir: URL) -> [String: String] {
        let url = dir.appendingPathComponent("sessions.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return obj
    }

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
        CodexJSONLReader.forEachCompleteLine(url, includeTrailingLine: true) { line in
            guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            else { return true }
            return body(root)
        }
    }

}
