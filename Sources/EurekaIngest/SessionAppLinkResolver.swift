import EurekaKit
import Foundation

/// Decides whether a session lives in a desktop app and, if so, returns its direct link
/// (`SessionAppLink`).
///
/// Only the two desktop apps are recognized, each by a record the app writes itself:
/// - Claude Desktop: every file under
///   `~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/local_*.json` is one
///   Desktop session; its `cliSessionId` is the transcript's session id and `sessionId` is the
///   Desktop `local_` id. CLI sessions are not there (unless Desktop imported one, in which case
///   Desktop owns it).
/// - Codex Desktop: the first rollout line has `session_meta.payload.originator == "Codex Desktop"`.
///
/// Every read is bounded; see each function for why. Pure file IO: callers run it off the main
/// thread.
public enum SessionAppLinkResolver {
    public static func defaultClaudeDesktopRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Only these two sources have a desktop app to open; the rest need no file reads
    public static func canResolve(_ source: AgentSource) -> Bool {
        source == .claude || source == .codex
    }

    public static func resolve(
        source: AgentSource,
        sessionId: String,
        claudeDesktopRoot: URL = defaultClaudeDesktopRoot(),
        codexSessionsRoot: URL = CodexRolloutTailer.defaultSessionsRoot()
    ) -> SessionAppLink? {
        switch source {
        case .claude:
            return claudeDesktopSessionId(cliSessionId: sessionId, root: claudeDesktopRoot)
                .map { .claudeDesktop(localSessionId: $0) }
        case .codex:
            return isCodexDesktopThread(sessionId: sessionId, sessionsRoot: codexSessionsRoot)
                ? .codexDesktop(threadId: sessionId) : nil
        default:
            return nil
        }
    }

    // MARK: - Claude Desktop

    /// How many leading bytes of a Desktop session file are pre-filtered.
    ///
    /// A single file measured up to 540 KB (mostly the tool schemas in `remoteMcpServersConfig`);
    /// 940 local files total 185 MB, far too much to read and JSON-parse one by one.
    /// `cliSessionId` is the second key and lands in the first 200 bytes in 937 of 940 files, so
    /// 4 KB is plenty; only a file whose head lacks the key at all is read in full.
    static let claudeDesktopHeadLimit = 4 << 10
    private static let cliSessionKey = Data("\"cliSessionId\"".utf8)

    /// CLI session id → Desktop `local_` session id; nil when it is not a Desktop session or the
    /// session is archived.
    ///
    /// Newest file first: a session that just finished or is waiting almost always has one of the
    /// most recently modified files. Search for the session id as bytes first; only a hit is read
    /// in full and confirmed through its fields (the file name is not trusted).
    static func claudeDesktopSessionId(cliSessionId: String, root: URL) -> String? {
        guard SessionAppLink.isUUID(cliSessionId) else { return nil }
        let needle = Data(cliSessionId.utf8)
        for file in claudeDesktopSessionFiles(root: root) {
            guard let handle = FileHandle(forReadingAtPath: file.path) else { continue }
            let head = (try? handle.read(upToCount: claudeDesktopHeadLimit)) ?? Data()
            var candidate = head.range(of: needle) != nil
            if !candidate, head.range(of: cliSessionKey) == nil,
               let rest = try? handle.readToEnd() {
                // The key is not in the head: field order changed or the file is laid out
                // differently, so search the rest once
                candidate = rest.range(of: needle) != nil
            }
            try? handle.close()
            guard candidate,
                  let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["cliSessionId"] as? String == cliSessionId,
                  let localId = object["sessionId"] as? String,
                  SessionAppLink.isClaudeDesktopSessionId(localId),
                  // Desktop's deep link only searches unarchived sessions; an archived one lands
                  // on the Code home page
                  object["isArchived"] as? Bool != true
            else { continue }
            return localId
        }
        return nil
    }

    /// `<root>/<account>/<org>/local_*.json`, newest first
    private static func claudeDesktopSessionFiles(root: URL) -> [URL] {
        let fm = FileManager.default
        var files: [(url: URL, mtime: Date)] = []
        for account in subdirectories(of: root) {
            for org in subdirectories(of: account) {
                let children = (try? fm.contentsOfDirectory(
                    at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for child in children
                where child.lastPathComponent.hasPrefix("local_") && child.pathExtension == "json" {
                    let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate ?? .distantPast
                    files.append((child, mtime))
                }
            }
        }
        return files.sorted { $0.mtime > $1.mtime }.map(\.url)
    }

    private static func subdirectories(of dir: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    // MARK: - Codex Desktop

    /// What the desktop app writes into `session_meta.payload.originator` (the CLI writes
    /// `codex_cli_rs`)
    static let codexDesktopOriginator = "Codex Desktop"

    /// A rollout file name ends with the session id (`rollout-<time>-<id>.jsonl`) and its first line
    /// is `session_meta`. That line carries the full instructions and can be long, so the read is
    /// capped at the session indexer's `headScanLimit`.
    static func isCodexDesktopThread(sessionId: String, sessionsRoot: URL) -> Bool {
        guard SessionAppLink.isUUID(sessionId) else { return false }
        let suffix = "-\(sessionId).jsonl"
        guard let entry = CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot)
            .first(where: { $0.url.lastPathComponent.hasSuffix(suffix) }),
              let handle = FileHandle(forReadingAtPath: entry.url.path)
        else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: CodexSessionIndexer.headScanLimit),
              let lineEnd = head.firstIndex(of: UInt8(ascii: "\n")),
              let object = try? JSONSerialization.jsonObject(
                with: head[head.startIndex..<lineEnd]) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              payload["id"] as? String == sessionId
        else { return false }
        return payload["originator"] as? String == codexDesktopOriginator
    }
}
