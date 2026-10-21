import Foundation
import EurekaKit

/// "Does this Claude session still have a live process?" — answerable only half the time, so it is
/// asked only in one specific situation.
///
/// Both Claude Desktop and the CLI put the session id into argv when they resume a session
/// (`--resume=<id>` / `--resume <id>` / `-r <id>`), while a **fresh** session has no id in argv (the
/// id is generated inside the process). Hence:
/// - resumed sessions can be matched to a process exactly → alive/dead is decidable;
/// - fresh sessions cannot → only the transcript's own exit marker (a trailing `cost-state` line,
///   see `ClaudeSessionBootstrap`) tells.
///
/// Combined: last line is `cost-state` **and** no live process carries this id ⇒ the writer has
/// exited (archive, Desktop's idle sweep, a scheduled task finishing). A resumed process also writes
/// a `cost-state` line at startup (e8d141a0 on this machine ended with one 8 seconds after resuming),
/// so without this check a live idle resumed session would be taken for a dead one.
///
/// Called only when some tail ends with `cost-state`: one sysctl for the process table plus one
/// `proc_pidpath` per process; argv is read only for executables named claude. The environment
/// block is never read.
public enum ClaudeResumeProbe {
    /// Ids of every resumed session in the process table (one scan; the watcher shares it across
    /// all files that need it within one poll)
    public static func liveResumedSessionIds() -> Set<String> {
        let executables = TerminalProber.agentExecutables[.claude] ?? []
        var ids = Set<String>()
        for entry in TerminalProber.processTable() {
            guard let path = TerminalProber.processPath(entry.pid) else { continue }
            guard executables.contains(URL(fileURLWithPath: path).lastPathComponent) else { continue }
            guard let arguments = TerminalProber.processArguments(entry.pid),
                  let id = resumedSessionId(in: arguments) else { continue }
            ids.insert(id)
        }
        return ids
    }

    public static func isAlive(sessionId: String) -> Bool {
        guard !sessionId.isEmpty else { return false }
        return liveResumedSessionIds().contains(sessionId)
    }

    /// The resumed session id in argv (`--resume=<id>` / `--resume <id>` / `-r <id>`); nil when
    /// absent. Pure function, unit-tested.
    public static func resumedSessionId(in arguments: [String]) -> String? {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--resume=") {
                let id = String(argument.dropFirst("--resume=".count))
                return id.isEmpty ? nil : id
            }
            if argument == "--resume" || argument == "-r" {
                guard let id = iterator.next(), !id.hasPrefix("-") else { return nil }
                return id
            }
        }
        return nil
    }
}
