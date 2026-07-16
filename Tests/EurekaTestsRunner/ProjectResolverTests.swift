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
        // 回归：含 NUL/控制字符的 cwd（来自二进制来源裸扫的碎片）曾让
        // URL.appendingPathComponent 抛不可捕获的 NSException → 整个 app 崩溃。
        let dirty = "/Users/me/proj\u{00}\u{0E}\u{03}\r"
        let root = ProjectResolver.resolveRoot(cwd: dirty)  // 不应崩溃
        try expect(!root.path.isEmpty)
        try expectEqual(ProjectResolver.resolve(cwd: dirty), "proj")  // 截断到控制字符前
        try expect(ProjectResolver().projectName(forCwd: dirty) == "proj")
        // 纯控制字符 → 安全回退，不崩溃
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
}
