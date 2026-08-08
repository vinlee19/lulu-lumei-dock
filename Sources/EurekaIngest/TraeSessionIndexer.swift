import Foundation
import EurekaKit

/// Trae 的会话索引 —— **从明文记忆库反推**，因为会话库本身读不了。
///
/// 会话正文/标题/时间都在 `ModularData/ai-agent/database.db` 里，而那个库是 SQLCipher
/// 加密的（见 `TraePaths`）。唯一的明文旁证是 Trae 自己写的记忆库：
///
/// ```
/// ~/.trae-cn/memory/projects/<encoded>/
///   project_memory.md                              ← 项目记忆（归记忆 tab，不在这里用）
///   <YYYYMMDD>/topics.md                           ← 每会话一段叙述式摘要 + session_id + 时间
///   <YYYYMMDD>/session_memory_<sessionId>.jsonl    ← 每回合一行（intent/actions/outcome + 时间）
/// ```
///
/// `topics.md` 的一段形如（实勘，块与块可能不换行相连，故用「下一个块头」定界而不是按行切）：
///
/// ```
/// [session_id: 6a75a6cd602f315c19ec63ac | topic_summary_time: 2026-08-07 17:51:40]User requested…
/// ```
///
/// **这份索引是延迟的**：Trae 的摘要是异步生成的（`compact_summary_meta.mode = async`），
/// 而且用户关掉记忆功能就什么都没有。所以它只服务「会话浏览」，**不是实时通道**
/// —— 实时活动靠 hooks（见 `TraeHooksInstaller`）。
public enum TraeSessionIndexer {
    /// 单个 day 目录里解析出的一段
    public struct Topic: Equatable, Sendable {
        public var sessionId: String
        public var summary: String
        public var summaryTime: Date?
    }

    public static func index(
        memoryProjectsRoot: URL = TraePaths.memoryProjectsRoot(),
        workspaceStorageRoots: [URL] = TraePaths.workspaceStorageRoots(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let knownCwds = workspaceFolders(roots: workspaceStorageRoots)
        let cutoff = now.addingTimeInterval(-window)

        // sessionId → 累积状态。一个会话可以横跨多个 <YYYYMMDD> 目录，必须跨目录合并。
        struct Accum {
            var cwd: String?
            var summary: String?
            /// 当前 summary 的 `topic_summary_time`，用来决定谁覆盖谁
            var summaryAt: Date?
            var first: Date?
            var last: Date?
            var topicsPath: String?
        }
        var accum: [String: Accum] = [:]

        func note(
            sessionId: String, cwd: String?, summary: String?, summaryAt: Date?,
            times: [Date], topicsPath: String?
        ) {
            var entry = accum[sessionId] ?? Accum()
            if entry.cwd == nil { entry.cwd = cwd }
            // 越新的叙述越贴近会话最终形态 → 按 topic_summary_time 取最新那份。
            // **不能靠遍历顺序**：`contentsOfDirectory` 不保证顺序，按天的目录名先后随机，
            // 那样会随机拿到第一天的摘要（此处曾因此挂过一次测试）。
            if let summary, !summary.isEmpty {
                let newer = switch (entry.summaryAt, summaryAt) {
                case (nil, _): true                              // 还没有摘要 → 收下
                case (_, nil): false                             // 新的没有时间 → 不覆盖已有
                case (let old?, let new?): new >= old
                }
                if newer {
                    entry.summary = summary
                    entry.summaryAt = summaryAt
                }
            }
            for time in times {
                entry.first = entry.first.map { min($0, time) } ?? time
                entry.last = entry.last.map { max($0, time) } ?? time
            }
            if let topicsPath { entry.topicsPath = topicsPath }
            accum[sessionId] = entry
        }

        let projectDirs = ((try? fm.contentsOfDirectory(
            at: memoryProjectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let cwd = resolveCwd(encodedDirName: projectDir.lastPathComponent, knownCwds: knownCwds)
            let dayDirs = ((try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

            for dayDir in dayDirs {
                let topicsURL = dayDir.appendingPathComponent("topics.md")
                for topic in parseTopics(fileURL: topicsURL) {
                    note(
                        sessionId: topic.sessionId, cwd: cwd, summary: topic.summary,
                        summaryAt: topic.summaryTime,
                        times: [topic.summaryTime].compactMap { $0 },
                        topicsPath: topicsURL.path)
                }
                // 逐回合流水：只取时间戳（正文归记忆 tab，不进会话标题）
                let files = (try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil))
                    ?? []
                for file in files
                where file.lastPathComponent.hasPrefix("session_memory_")
                    && file.pathExtension == "jsonl" {
                    let sessionId = String(
                        file.deletingPathExtension().lastPathComponent
                            .dropFirst("session_memory_".count))
                    guard !sessionId.isEmpty else { continue }
                    let times = turnTimestamps(fileURL: file)
                    guard !times.isEmpty else { continue }
                    note(
                        sessionId: sessionId, cwd: cwd, summary: nil, summaryAt: nil,
                        times: times, topicsPath: nil)
                }
            }
        }

        return accum.compactMap { sessionId, entry -> AgentSessionInfo? in
            guard let last = entry.last, last >= cutoff else { return nil }
            return AgentSessionInfo(
                source: .trae,
                id: sessionId,
                cwd: entry.cwd,
                name: entry.summary.map { tightenPlanTitle($0, maxLength: 80) },
                startedAt: entry.first,
                lastActiveAt: last,
                // 同 cursor / hermes / opencode：共享库的源不报单会话体积
                sizeBytes: 0,
                // 刻意**不填加密库路径**，填信息真正的来源（明文 topics.md）。
                // `usesSharedSessionDatabase == true` 会让 UI 不展示这个路径，
                // 这里只是别留一个空串。
                transcriptPath: entry.topicsPath ?? "")
        }
        .sorted { $0.lastActiveAt > $1.lastActiveAt }
        .prefix(maxSessions)
        .map { $0 }
    }

    /// 会话涉及的工程目录集合（供项目发现并入）
    public static func recentDirectories(
        memoryProjectsRoot: URL = TraePaths.memoryProjectsRoot(),
        workspaceStorageRoots: [URL] = TraePaths.workspaceStorageRoots(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [String] {
        var seen = Set<String>()
        return index(
            memoryProjectsRoot: memoryProjectsRoot,
            workspaceStorageRoots: workspaceStorageRoots,
            window: window, maxSessions: maxSessions, now: now
        )
        .compactMap { $0.cwd }
        .filter { seen.insert($0).inserted }
    }

    // MARK: - topics.md 解析

    /// 从 `topics.md` 里切出每个会话的一段。
    ///
    /// 用「下一个块头的起点」定界而不是按行切：实勘文件是**单行无换行**的
    /// `[头]正文`，若还有第二个会话，它可能紧跟其后而不换行。
    public static func parseTopics(fileURL: URL) -> [Topic] {
        guard let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return [] }

        // [session_id: <id> | topic_summary_time: <yyyy-MM-dd HH:mm:ss>]
        let pattern = #"\[\s*session_id\s*:\s*([^\s|\]]+)\s*\|\s*topic_summary_time\s*:\s*([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return [] }

        var result: [Topic] = []
        for (offset, match) in matches.enumerated() {
            guard let idRange = Range(match.range(at: 1), in: text) else { continue }
            let sessionId = String(text[idRange]).trimmingCharacters(in: .whitespaces)
            guard !sessionId.isEmpty else { continue }

            let time = Range(match.range(at: 2), in: text)
                .map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
                .flatMap(parseLocalTimestamp)

            // 正文 = 本块头结束 → 下一块头开始（最后一块到文末）
            guard let bodyStart = Range(match.range, in: text)?.upperBound else { continue }
            let bodyEnd: String.Index = offset + 1 < matches.count
                ? (Range(matches[offset + 1].range, in: text)?.lowerBound ?? text.endIndex)
                : text.endIndex
            guard bodyStart <= bodyEnd else { continue }
            let summary = text[bodyStart..<bodyEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            result.append(Topic(sessionId: sessionId, summary: summary, summaryTime: time))
        }
        return result
    }

    /// `session_memory_<id>.jsonl` 里每回合的时间。
    /// 优先 `compact_summary_meta.created_at_ms`（epoch 毫秒，无时区歧义），
    /// 退回 `message_summary_time`（本地时间字符串，无时区标记）。
    static func turnTimestamps(fileURL: URL, maxBytes: Int = 1 << 20) -> [Date] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        // 逐回合一行、每行几百字节；超限就只读头部（时间只用来定 first/last，够用）
        let slice = data.count > maxBytes ? data.prefix(maxBytes) : data
        guard let text = String(data: slice, encoding: .utf8) else { return [] }

        var result: [Date] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let root = object as? [String: Any]
            else { continue }
            if let meta = root["compact_summary_meta"] as? [String: Any],
                let millis = (meta["created_at_ms"] as? NSNumber)?.doubleValue, millis > 0 {
                result.append(Date(timeIntervalSince1970: millis / 1000))
                continue
            }
            if let raw = root["message_summary_time"] as? String,
                let date = parseLocalTimestamp(raw) {
                result.append(date)
            }
        }
        return result
    }

    /// `"2026-08-07 17:51:40"` —— 没有时区标记，按本机时区解释（Trae 就是本地应用写的）
    static func parseLocalTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return localFormatter.date(from: trimmed)
    }

    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - cwd 反查

    /// `workspace.json` 的 `folder` 字段给出的**真实绝对路径**集合（多渠道合并、去重）。
    /// 这是唯一不走有损编码的 cwd 来源，所以优先用它。
    static func workspaceFolders(roots: [URL]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for root in roots {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                let file = dir.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: file),
                    let object = try? JSONSerialization.jsonObject(with: data),
                    let root = object as? [String: Any],
                    let folder = root["folder"] as? String,
                    let path = URL(string: folder)?.path, !path.isEmpty,
                    seen.insert(path).inserted
                else { continue }
                result.append(path)
            }
        }
        return result
    }

    /// 记忆库项目目录名 → 真实 cwd。
    ///
    /// 目录名形如 `-Users-wl-xiao-vinlee-workspace-lerobot--p2-832ae42141a2828b9304`：
    /// 正斜杠编码（`/`、`.`、`_` 都变 `-`，见 `SkillMemoryIndexer.encodeProjectDirName`）
    /// 加一个 `--p<N>-<hash>` 后缀。
    ///
    /// **编码是多对一、不可反解**（`-` 可能来自 `/`、`.`、`_` 或原有连字符），所以只能
    /// 把已知的真实路径**正向编码**后去比对 —— 绝不能反着 split `-`：那会把
    /// `aftership-semantic-layer` 切成 `layer`（CLAUDE.md 里记着这个坑）。
    /// 比不中就返回 nil（宁可不显示 cwd，也不显示一个错的）。
    public static func resolveCwd(encodedDirName: String, knownCwds: [String]) -> String? {
        let stripped = stripProjectSuffix(encodedDirName)
        for cwd in knownCwds {
            let encoded = SkillMemoryIndexer.encodeProjectDirName(
                URL(fileURLWithPath: cwd).standardizedFileURL.path)
            if encoded == stripped || encoded == encodedDirName { return cwd }
        }
        return nil
    }

    /// 去掉 `--p<N>-<hash>` 后缀。找不到该形态就原样返回（老版本可能没有后缀）。
    public static func stripProjectSuffix(_ name: String) -> String {
        guard let range = name.range(of: "--p", options: .backwards) else { return name }
        // `--p` 之后必须是数字才算后缀，否则可能是路径里本来就有的 `--p…`
        let rest = name[range.upperBound...]
        guard let first = rest.first, first.isNumber else { return name }
        return String(name[..<range.lowerBound])
    }
}
