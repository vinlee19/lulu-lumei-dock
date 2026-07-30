import Foundation
import EurekaKit

/// Codex 会话索引：~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// resume 的旧会话在创建日目录原地追加，故整树枚举后按 mtime 窗口过滤。
/// 正式 thread_name 优先；缺失时流式读取 session_meta 与首条完整 user_message 兜底。
public enum CodexSessionIndexer {
    public static func index(
        sessionsRoot: URL,
        threadNameIndexURL: URL? = nil,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        // window 可传 .greatestFiniteMagnitude（"显示全部"），这里必须是无换算的
        // 区间比较——先除 86400 再取 Int 会直接溢出崩溃。
        var candidates: [(URL, Date, UInt64)] = []
        for entry in CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot) {
            guard let mtime = entry.mtime, now.timeIntervalSince(mtime) < window
            else { continue }
            candidates.append((entry.url, mtime, entry.size))
        }
        candidates.sort { $0.1 > $1.1 }
        let names = CodexThreadNameIndex.load(
            threadNameIndexURL ?? CodexThreadNameIndex.resolvedURL(for: sessionsRoot))
        return candidates.prefix(maxSessions).map { file, mtime, size in
            let head = headInfo(fileURL: file)
            let id = head.id ?? fallbackId(file)
            return AgentSessionInfo(
                source: .codex,
                id: id,
                cwd: head.cwd,
                name: names[id] ?? head.name,
                startedAt: head.startedAt,
                lastActiveAt: mtime,
                sizeBytes: size,
                transcriptPath: file.path
            )
        }
    }

    /// 头部扫描字节上界。
    ///
    /// **为什么必须有**：停止条件是「id 与 name 都拿到」，而 `name` 要等第一条
    /// `event_msg/user_message` —— 没有用户消息的会话（子代理 / 自动化 / compact 后的会话，
    /// 实勘 121 个近期 rollout 里 **29 个**如此）永远不满足条件，于是**整文件逐行 JSON 解析**。
    /// Codex 单个 rollout 实测最大 70 MB，121 个文件合计要 65–145 s，而 Claude 的 94 个会话
    /// 只用 0.4 s —— 差的不是数据量，就是这里。
    ///
    /// 1 MB 够用：`session_meta` 是 rollout 的第一行（格式保证，`CodexRolloutDecoder` 也依赖），
    /// `user_message` 是会话第一句话。超限即放弃找标题，`AgentSessionInfo.displayName`
    /// 会退回「会话 <id 前 8 位>」——**与扫完整个文件的结果完全一致**，只是不再白读。
    static let headScanLimit = 1 << 20

    /// 第一级探测窗口。实勘 121 个 rollout 里 92 个的 `session_meta`（第一行）与第一条
    /// `user_message` 都落在前 64 KB 内 —— 先读这么多，读齐就收工，读不齐才补到 `headScanLimit`。
    /// 省掉约 3/4 的读取量；重复扫这 64 KB 的代价远低于多读 960 KB。
    static let headProbeLimit = 64 << 10

    /// 字节级预筛标记：**先按字节找，再决定要不要付 JSON 解析的代价**。
    /// rollout 的单行动辄几百 KB（工具输出 / 文件内容整段回显），而这里只要两个字段；
    /// 无差别地 `JSONSerialization` 每一行，实测 1 MB 要约 0.9 s。
    /// 误命中（正文里恰好提到这两个词）只是多解析一行，`switch` 不匹配就跳过，无害。
    private static let metaMarker = Data("session_meta".utf8)
    private static let userMarker = Data("user_message".utf8)

    /// 只读文件头部，**不走 `CodexJSONLReader`**：那个读取器要维护 offset 记账与超长行语义，
    /// 每处理一行都 `Data(buffer[next...])` 整体拷贝剩余缓冲 + `firstIndex` 全扫，
    /// 实测吞吐只有约 3.4 MB/s（121 个文件要 36 s）。这里的需求简单得多 ——
    /// 读定长头部、切行、找两个字段 —— 一次读取 + 一次 `split` 就够。
    /// （读取器本身的 O(n²) 对 tailer 影响不大：它每次只读新增字节，缓冲很小。）
    static func headInfo(fileURL: URL) -> (id: String?, cwd: String?, name: String?, startedAt: Date?) {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return (nil, nil, nil, nil)
        }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: Self.headProbeLimit), !head.isEmpty else {
            return (nil, nil, nil, nil)
        }
        var result = scan(head)
        // 第一级没读齐（首行 instructions 很长，或这个会话根本没有 user_message）→ 补到上限再扫
        if result.id == nil || result.name == nil, head.count == Self.headProbeLimit,
           let more = try? handle.read(upToCount: Self.headScanLimit - Self.headProbeLimit),
           !more.isEmpty {
            head.append(more)
            result = scan(head)
        }
        return result
    }

    /// 在一段头部字节里找 `session_meta` 与第一条 `user_message`。纯函数，便于两级读取复用。
    ///
    /// **游标逐行而不是 `split`**：`split` 会立即切出全部行（1 MB 里几百个 slice），
    /// 而绝大多数文件在前两行就读齐了 —— 实测 `split` 版比游标版慢 30%。
    /// 游标从上次位置继续找换行符，不重扫已处理的字节，命中即停。
    private static func scan(
        _ head: Data
    ) -> (id: String?, cwd: String?, name: String?, startedAt: Date?) {
        var id: String?
        var cwd: String?
        var name: String?
        var startedAt: Date?
        var cursor = head.startIndex
        while cursor < head.endIndex {
            let lineEnd = head[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? head.endIndex
            let line = head[cursor..<lineEnd]
            cursor = lineEnd < head.endIndex ? head.index(after: lineEnd) : head.endIndex
            guard !line.isEmpty else { continue }
            // 这一行有没有可能带我们要的字段？没有就连 JSON 解析都不做。
            let mayHaveMeta = id == nil && line.range(of: Self.metaMarker) != nil
            let mayHaveUser = name == nil && line.range(of: Self.userMarker) != nil
            guard mayHaveMeta || mayHaveUser else { continue }
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let payload = root["payload"] as? [String: Any]
            else { continue }
            switch root["type"] as? String {
            case "session_meta":
                // **只认第一条**。resume / fork 出来的 rollout 里会写入第二条 session_meta
                // （实勘：5 MB 以上的文件里 `session_meta` 出现 2 次），原来一路扫到文件末尾时
                // `id` 会被后一条覆盖成**别的会话的 id** —— 121 个文件因此只得到 91 个唯一 id，
                // 30 个会话在列表/索引里被错误合并。
                guard id == nil else { break }
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String
                // 新版 Codex 在 payload.timestamp 给出真实开始时间；旧版退顶层时间。
                if let ts = payload["timestamp"] as? String ?? root["timestamp"] as? String {
                    startedAt = ClaudeSessionFirstTimestamp.parse(ts)
                }
            case "event_msg":
                if name == nil, payload["type"] as? String == "user_message",
                   let message = payload["message"] as? String {
                    name = summarizeTitle(message)
                }
            default:
                break
            }
            if id != nil, name != nil { break }
        }
        return (id, cwd, name, startedAt)
    }

    /// rollout-2026-06-08T23-36-02-<uuid>.jsonl → uuid
    private static func fallbackId(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
    }
}
