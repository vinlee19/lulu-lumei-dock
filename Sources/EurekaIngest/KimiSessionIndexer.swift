import Foundation
import EurekaKit

/// Kimi session index: scans `sessions/<wd_name_12hex>/<session_uuid>/state.json` →
/// AgentSessionInfo. Does not rely on session_index.jsonl (append-only, may reference deleted
/// sessions; the metadata is all in state.json anyway); the wd_… directory name cannot be reversed
/// into a cwd — workDir always comes from state.json.
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
        // The default title "New Session" is not a name (Kimi only generates a real title after the
        // first turn)
        let title: String? = (rawTitle?.isEmpty == false && rawTitle != "New Session")
            ? rawTitle : nil

        // Zero-turn sessions (opened then closed, default title, no update within 5 minutes) stay
        // out of the list — exactly the trait of the empty sessions observed locally. If real
        // sessions disprove this heuristic (first turn doesn't update updatedAt / generate a
        // title), just drop this filter; worst case is one extra row.
        if title == nil, let created = createdAt,
           (updatedAt ?? created).timeIntervalSince(created) < 300 {
            return nil
        }

        // size = sum of every agent's (main + subagents) wire.jsonl; lastActive falls back to the
        // wire mtime
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
