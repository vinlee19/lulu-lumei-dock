import Foundation
import EurekaKit

/// Kimi 会话索引：扫 `sessions/<wd_名_12hex>/<session_uuid>/state.json` → AgentSessionInfo。
/// 不依赖 session_index.jsonl（append-only、可能引用已删会话；元数据反正都在 state.json）；
/// 目录名 wd_… 不可反解 cwd —— workDir 一律取 state.json。
public enum KimiSessionIndexer {
    public static func index(
        sessionsRoot: URL = KimiPaths.sessionsRoot(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        var results: [AgentSessionInfo] = []
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for workspaceDir in workspaceDirs where isDirectory(workspaceDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                guard let info = sessionInfo(dir: sessionDir),
                      now.timeIntervalSince(info.lastActiveAt) < window
                else { continue }
                results.append(info)
            }
        }
        return Array(results.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }

    static func sessionInfo(dir: URL) -> AgentSessionInfo? {
        let stateURL = dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        let createdAt = (root["createdAt"] as? String).flatMap(KimiWireDecoder.parseISO)
        let updatedAt = (root["updatedAt"] as? String).flatMap(KimiWireDecoder.parseISO)
        let rawTitle = (root["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 默认标题 "New Session" 不当名字（Kimi 首轮后才自动生成真标题）
        let title: String? = (rawTitle?.isEmpty == false && rawTitle != "New Session")
            ? rawTitle : nil

        // 0 轮次会话（开了就关、默认标题、5 分钟内无更新）不进列表——本机观测的空会话正是此特征；
        // 若真实会话证伪此启发（首轮不更新 updatedAt / 不生成标题），删掉这个过滤即可，最坏多一行。
        if title == nil, let created = createdAt,
           (updatedAt ?? created).timeIntervalSince(created) < 300 {
            return nil
        }

        // size = 所有 agent（main + 子代理）的 wire.jsonl 之和；lastActive 回退 wire mtime
        let agentsDir = dir.appendingPathComponent("agents", isDirectory: true)
        var totalSize: UInt64 = 0
        var newestWireMtime: Date?
        let agentDirs = (try? FileManager.default.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for agentDir in agentDirs where isDirectory(agentDir) {
            let wire = agentDir.appendingPathComponent("wire.jsonl")
            guard let values = try? wire.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            totalSize += UInt64(values.fileSize ?? 0)
            if let mtime = values.contentModificationDate,
               newestWireMtime == nil || mtime > newestWireMtime! {
                newestWireMtime = mtime
            }
        }

        let lastActive = updatedAt ?? newestWireMtime ?? createdAt
            ?? Date(timeIntervalSince1970: 0)

        return AgentSessionInfo(
            source: .kimi,
            id: dir.lastPathComponent,
            cwd: root["workDir"] as? String,
            name: title,
            startedAt: createdAt,
            lastActiveAt: lastActive,
            sizeBytes: totalSize,
            transcriptPath: agentsDir.appendingPathComponent("main/wire.jsonl").path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
