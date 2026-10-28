import EurekaUsage
import Foundation

func projectResolverTests(_ t: TestRunner) {
    t.suite("ProjectResolver")

    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    t.test("仓库子目录归到仓库根（semantic-sql → aftership-semantic-layer 场景）") {
        let root = try makeTree()
        let repo = root.appendingPathComponent("aftership-semantic-layer")
        let sub = repo.appendingPathComponent("semantic-sql/src/main")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)

        try expectEqual(ProjectResolver.resolve(cwd: sub.path), "aftership-semantic-layer")
        try expectEqual(ProjectResolver.resolve(cwd: repo.path), "aftership-semantic-layer")
    }

    t.test("子模块（.git 是文件）继续向上归到父仓库") {
        let root = try makeTree()
        let repo = root.appendingPathComponent("parent-repo")
        let module = repo.appendingPathComponent("submodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("gitdir: ../.git/modules/submodule".utf8).write(
            to: module.appendingPathComponent(".git"))

        try expectEqual(ProjectResolver.resolve(cwd: module.path), "parent-repo")
    }

    t.test("非 git 目录回退 cwd 末段") {
        let root = try makeTree()
        let plain = root.appendingPathComponent("scratch/notes")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try expectEqual(ProjectResolver.resolve(cwd: plain.path), "notes")
    }

    t.test("脏 cwd（含控制字符）不崩溃，安全回退") {
        // Regression: a cwd containing NUL/control characters (fragments from raw scans of binary
        // sources) once made URL.appendingPathComponent throw an uncatchable NSException → the
        // whole app crashed.
        let dirty = "/Users/me/proj\u{00}\u{0E}\u{03}\r"
        let root = ProjectResolver.resolveRoot(cwd: dirty)  // must not crash
        try expect(!root.path.isEmpty)
        try expectEqual(ProjectResolver.resolve(cwd: dirty), "proj")  // truncated before the control character
        try expect(ProjectResolver().projectName(forCwd: dirty) == "proj")
        // Control characters only → safe fallback, no crash
        _ = ProjectResolver.resolveRoot(cwd: "\u{00}\u{01}")
    }

    t.test("缓存与空值") {
        let resolver = ProjectResolver()
        try expect(resolver.projectName(forCwd: nil) == nil)
        try expect(resolver.projectName(forCwd: "") == nil)
        let root = try makeTree()
        let repo = root.appendingPathComponent("my-repo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try expectEqual(resolver.projectName(forCwd: repo.path), "my-repo")
        try expectEqual(resolver.projectName(forCwd: repo.path), "my-repo")
    }

    // MARK: Project mode (prompts / sessions display): worktrees and umbrella repos

    func mkdirs(_ urls: URL...) throws {
        for url in urls { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    }

    t.test("项目模式：worktree 归回主仓库，默认模式不变") {
        let root = try makeTree()
        let main = root.appendingPathComponent("eureka")
        let worktree = root.appendingPathComponent("orca/workspaces/eureka/blobfish")
        try mkdirs(main.appendingPathComponent(".git/worktrees/wt1"), worktree.appendingPathComponent("Sources"))
        try Data("gitdir: \(main.path)/.git/worktrees/wt1\n".utf8).write(
            to: worktree.appendingPathComponent(".git"))

        let inside = worktree.appendingPathComponent("Sources").path
        try expectEqual(ProjectResolver.resolve(cwd: inside, mode: .project), "eureka")
        try expectEqual(ProjectResolver.resolve(cwd: worktree.path, mode: .project), "eureka")
        // Default mode is what the usage ledger stores; it must not move.
        try expectEqual(ProjectResolver.resolve(cwd: worktree.path), "blobfish")
    }

    t.test("项目模式：外壳仓库里的普通文件夹按下一层文件夹算项目") {
        let root = try makeTree()
        let shell = root.appendingPathComponent("workspace")
        try mkdirs(
            shell.appendingPathComponent(".git"),
            shell.appendingPathComponent("repo-a/.git"),
            shell.appendingPathComponent("repo-b/.git"),
            shell.appendingPathComponent("olap-poc/perf-scripts/docs"))

        let deep = shell.appendingPathComponent("olap-poc/perf-scripts/docs").path
        try expectEqual(ProjectResolver.resolve(cwd: deep, mode: .project), "olap-poc")
        try expectEqual(
            ProjectResolver.resolve(cwd: shell.appendingPathComponent("olap-poc").path, mode: .project),
            "olap-poc")
        // The shell itself and its own clones resolve as before.
        try expectEqual(ProjectResolver.resolve(cwd: shell.path, mode: .project), "workspace")
        try expectEqual(
            ProjectResolver.resolve(cwd: shell.appendingPathComponent("repo-a").path, mode: .project),
            "repo-a")
        try expectEqual(ProjectResolver.resolve(cwd: deep), "workspace")
    }

    t.test("项目模式：只有一个嵌套仓库或只有子模块时不算外壳") {
        let root = try makeTree()
        let one = root.appendingPathComponent("monorepo")
        try mkdirs(
            one.appendingPathComponent(".git"),
            one.appendingPathComponent("vendored/.git"),
            one.appendingPathComponent("src/app"))
        try expectEqual(
            ProjectResolver.resolve(cwd: one.appendingPathComponent("src/app").path, mode: .project),
            "monorepo")

        // Submodules carry a `.git` file, not a clone: a repo with several stays one project.
        let parent = root.appendingPathComponent("parent")
        try mkdirs(
            parent.appendingPathComponent(".git"),
            parent.appendingPathComponent("mod-a"), parent.appendingPathComponent("mod-b"),
            parent.appendingPathComponent("docs"))
        for name in ["mod-a", "mod-b"] {
            try Data("gitdir: ../.git/modules/\(name)".utf8).write(
                to: parent.appendingPathComponent("\(name)/.git"))
        }
        try expectEqual(
            ProjectResolver.resolve(cwd: parent.appendingPathComponent("docs").path, mode: .project),
            "parent")
        try expectEqual(
            ProjectResolver.resolve(cwd: parent.appendingPathComponent("mod-a").path, mode: .project),
            "parent")
    }

    t.test("项目模式：实例缓存按模式分开") {
        let root = try makeTree()
        let main = root.appendingPathComponent("main-repo")
        let worktree = root.appendingPathComponent("elsewhere/wt")
        try mkdirs(main.appendingPathComponent(".git/worktrees/wt"), worktree)
        try Data("gitdir: \(main.path)/.git/worktrees/wt".utf8).write(to: worktree.appendingPathComponent(".git"))
        try expectEqual(ProjectResolver(mode: .project).projectName(forCwd: worktree.path), "main-repo")
        try expectEqual(ProjectResolver().projectName(forCwd: worktree.path), "wt")
    }
}
