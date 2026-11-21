import EurekaKit
import Foundation

/// WorkBuddy's live channel, without hooks.
///
/// The engine inside WorkBuddy supports Claude-style hooks, but it treats a hook that is missing,
/// fails to start or times out as a refusal: the tool call or prompt is blocked. A relay entry left
/// behind by an uninstalled Eureka would break WorkBuddy, so nothing is installed. Everything comes
/// from files WorkBuddy writes anyway:
/// - the transcript tail (`CodeBuddyChatTailer`, workbuddy dialect): turns, tools, questions,
///   errors, titles, context use, subagents;
/// - the audit log (`WorkBuddyPermissionWatcher`): permission prompts;
/// - the database (`WorkBuddySessionCatalog`): titles, context windows, scheduled runs to skip.
///
/// One timer runs the transcript first and the audit log second, on one queue: a tool call's line
/// lands in the transcript before its permission prompt lands in the audit log, so this order keeps
/// the transcript's activity event from overtaking (and clearing) the waiting event.
public final class WorkBuddyLiveChannel {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let chat: CodeBuddyChatTailer
    private let permissions: WorkBuddyPermissionWatcher
    private let queue = DispatchQueue(label: "com.vinlee.eureka.workbuddy-live")
    private var timer: DispatchSourceTimer?

    public init(
        projectsRoot: URL = WorkBuddyPaths.projectsRoot(),
        auditLogRoot: URL = WorkBuddyPaths.auditLogRoot(),
        catalog: WorkBuddySessionCatalog = .shared,
        handler: @escaping Handler
    ) {
        chat = CodeBuddyChatTailer(
            projectsRoot: projectsRoot, dialect: .workbuddy, lookup: catalog.lookup,
            handler: handler)
        permissions = WorkBuddyPermissionWatcher(
            root: auditLogRoot, lookup: catalog.lookup, handler: handler)
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(
            CodeBuddyChatTailer.healthName(for: .workbuddy), expectedInterval: pollInterval)
        HealthRegistry.shared.register(
            WorkBuddyPermissionWatcher.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.scanOnce() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Public for tests; in the app only the timer calls it
    public func scanOnce() {
        chat.scanOnce()
        permissions.scanOnce()
    }
}
