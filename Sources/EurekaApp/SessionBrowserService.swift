import AppKit
import EurekaIngest
import EurekaUsage
import Foundation

/// 项目会话浏览：按项目分组列出 Claude 会话（命名/时间/大小）
final class SessionBrowserService: ObservableObject {
    struct ProjectGroup: Identifiable {
        var id: String { name }
        var name: String
        var sessions: [ClaudeSessionInfo]
        var totalBytes: UInt64
        var latestActiveAt: Date
    }

    enum SortMode: String, CaseIterable {
        case time = "按时间"
        case size = "按大小"
    }

    @Published private(set) var groups: [ProjectGroup] = []
    @Published private(set) var scanning = false
    @Published var sortMode: SortMode = .time {
        didSet { resort() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.sessions", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var sessions: [ClaudeSessionInfo] = []

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let indexed = ClaudeSessionIndexer.index(
                projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot())
            DispatchQueue.main.async {
                self.sessions = indexed
                self.scanning = false
                self.resort()
            }
        }
    }

    private func resort() {
        var byProject: [String: [ClaudeSessionInfo]] = [:]
        for session in sessions {
            let name = resolver.projectName(forCwd: session.cwd) ?? "（未知项目）"
            byProject[name, default: []].append(session)
        }
        var result: [ProjectGroup] = byProject.map { name, sessions in
            ProjectGroup(
                name: name,
                sessions: sessions,
                totalBytes: sessions.reduce(0) { $0 + $1.sizeBytes },
                latestActiveAt: sessions.map(\.lastActiveAt).max() ?? .distantPast
            )
        }
        switch sortMode {
        case .time:
            result.sort { $0.latestActiveAt > $1.latestActiveAt }
            for index in result.indices {
                result[index].sessions.sort { $0.lastActiveAt > $1.lastActiveAt }
            }
        case .size:
            result.sort { $0.totalBytes > $1.totalBytes }
            for index in result.indices {
                result[index].sessions.sort { $0.sizeBytes > $1.sizeBytes }
            }
        }
        groups = result
    }

    /// 拷贝恢复命令到剪贴板
    func copyResumeCommand(_ session: ClaudeSessionInfo) {
        var command = "claude --resume \(session.id)"
        if let cwd = session.cwd {
            command = "cd '\(cwd)' && " + command
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
