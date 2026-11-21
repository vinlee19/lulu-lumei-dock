import EurekaKit
import Foundation

// Kept apart from PlanMaterializer.swift, which is already far past the size the codebase aims
// for; it shares that type's staging helpers (`writeIfChanged`, `writeSessionMap`).
extension PlanMaterializer {
    /// WorkBuddy has no plans directory in use (`~/.workbuddy/plans` stays empty); a session's plan
    /// is its todo list, which the engine's `TaskCreate` / `TaskUpdate` tools persist as
    /// `tasks/<sessionId>/<N>.json` (`{id, subject, description, activeForm, status:
    /// pending|in_progress|completed, createdAt, updatedAt}`, same record as Claude Code's task
    /// tools). Each session with todos becomes `workbuddy/<sessionId>.md`, the same synthesis route
    /// as Cursor's todos. Scheduled automation runs and internal sessions are skipped, like
    /// everywhere else; the title is the one WorkBuddy shows when its database has it.
    @discardableResult
    public static func materializeWorkBuddy(
        tasksRoot: URL = WorkBuddyPaths.tasksRoot(),
        into stagingRoot: URL,
        lookup: CodeBuddySessionLookup? = WorkBuddySessionCatalog.shared.lookup
    ) -> Int {
        let fm = FileManager.default
        let outDir = stagingRoot.appendingPathComponent("workbuddy", isDirectory: true)
        let sessions = ((try? fm.contentsOfDirectory(atPath: tasksRoot.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        var written = 0
        var smap: [String: String] = [:]
        for sessionId in sessions where !CodeBuddyDialect.isWorkBuddyInternalSession(sessionId) {
            let hints = lookup?(sessionId)
            guard hints?.isAutomation != true else { continue }
            let dir = tasksRoot.appendingPathComponent(sessionId, isDirectory: true)
            let todos = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".json") }
                .compactMap { name -> (order: Int, item: [String: Any])? in
                    guard let data = fm.contents(atPath: dir.appendingPathComponent(name).path),
                          let item = (try? JSONSerialization.jsonObject(with: data))
                            as? [String: Any]
                    else { return nil }
                    // Files are numbered in creation order (1.json, 2.json, …)
                    return (Int(name.dropLast(".json".count)) ?? Int.max, item)
                }
                .sorted { $0.order < $1.order }
                .map(\.item)
            let content = renderWorkBuddyTodos(
                sessionId: sessionId, title: hints?.title, todos: todos)
            guard !content.isEmpty else { continue }
            if writeIfChanged(content, to: outDir.appendingPathComponent("\(sessionId).md")) {
                written += 1
            }
            smap["\(sessionId).md"] = sessionId
        }
        writeSessionMap(smap, outDir: outDir)
        return written
    }

    /// Todo records → markdown checklist, with the same status boxes as the Cursor and Codex
    /// checklists (`[x]` done, `[~]` in progress, `[ ]` pending)
    static func renderWorkBuddyTodos(
        sessionId: String, title: String?, todos: [[String: Any]]
    ) -> String {
        let heading = title.flatMap { summarizeTitle($0) }
            ?? L10n.text("WorkBuddy todo list", zhHans: "WorkBuddy 待办清单")
        var lines = [
            "# \(heading)", "",
            L10n.format("> WorkBuddy todo list · session %@", zhHans: "> WorkBuddy 待办清单 · 会话 %@",
                        sessionId),
            "",
        ]
        var any = false
        for item in todos {
            let subject = (item["subject"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty else { continue }
            let box: String
            switch item["status"] as? String {
            case "completed": box = "[x]"
            case "in_progress": box = "[~]"
            default: box = "[ ]"
            }
            lines.append("- \(box) \(subject)")
            any = true
        }
        guard any else { return "" }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
