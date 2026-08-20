import EurekaIngest
import Foundation

func skillPropagatorTests(_ t: TestRunner) {
    t.suite("SkillPropagator（技能跨源传播）")

    /// 在临时目录里搭一个带素材的技能：SKILL.md + references/ + scripts/ +
    /// 剪枝目录 node_modules/ + 隐藏文件 .DS_Store
    func makeFixtureSkill(in base: URL) throws -> URL {
        let fm = FileManager.default
        let dir = base.appendingPathComponent("commit-helper", isDirectory: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("references"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("node_modules/dep"), withIntermediateDirectories: true)
        try "---\nname: commit-helper\ndescription: 提交助手\n---\n正文"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "规则文档".write(
            to: dir.appendingPathComponent("references/rules.md"),
            atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(
            to: dir.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        try "junk".write(
            to: dir.appendingPathComponent("node_modules/dep/index.js"),
            atomically: true, encoding: .utf8)
        try "junk".write(
            to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        return dir
    }

    func tempBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-propagator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    t.test("完整复制：SKILL.md 与素材子目录逐文件到位") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = try makeFixtureSkill(in: base)
        let targetRoot = base.appendingPathComponent("target/skills", isDirectory: true)

        let dest = try SkillPropagator.install(skillDirectory: skill, into: targetRoot)

        let fm = FileManager.default
        try expectEqual(dest.lastPathComponent, "commit-helper")
        try expect(fm.fileExists(atPath: dest.appendingPathComponent("SKILL.md").path))
        try expectEqual(
            try String(contentsOf: dest.appendingPathComponent("references/rules.md"),
                       encoding: .utf8),
            "规则文档", "素材子目录必须保留")
        try expect(fm.fileExists(atPath: dest.appendingPathComponent("scripts/run.sh").path))
    }

    t.test("剪枝与隐藏项：node_modules 与 .DS_Store 不复制") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = try makeFixtureSkill(in: base)
        let targetRoot = base.appendingPathComponent("target/skills", isDirectory: true)

        let dest = try SkillPropagator.install(skillDirectory: skill, into: targetRoot)

        let fm = FileManager.default
        try expect(!fm.fileExists(atPath: dest.appendingPathComponent("node_modules").path),
            "依赖目录必须剪掉")
        try expect(!fm.fileExists(atPath: dest.appendingPathComponent(".DS_Store").path),
            "隐藏文件必须剪掉")
    }

    t.test("同名冲突：目标已存在则抛错且不覆盖") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = try makeFixtureSkill(in: base)
        let targetRoot = base.appendingPathComponent("target/skills", isDirectory: true)
        let existing = targetRoot.appendingPathComponent("commit-helper", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try "已有内容".write(
            to: existing.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        do {
            try SkillPropagator.install(skillDirectory: skill, into: targetRoot)
            try expect(false, "应当抛 alreadyExists")
        } catch let error as SkillPropagator.PropagationError {
            guard case .alreadyExists = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
        try expectEqual(
            try String(contentsOf: existing.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "已有内容", "已有文件不能被覆盖")
    }

    t.test("停用区同名也算冲突（避免装上却被停用区遮蔽）") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = try makeFixtureSkill(in: base)
        let targetRoot = base.appendingPathComponent("target/skills", isDirectory: true)
        let disabledTwin = base.appendingPathComponent(
            "target/skills.eureka-disabled/commit-helper", isDirectory: true)
        try FileManager.default.createDirectory(
            at: disabledTwin, withIntermediateDirectories: true)

        do {
            try SkillPropagator.install(skillDirectory: skill, into: targetRoot)
            try expect(false, "应当抛 alreadyExists")
        } catch let error as SkillPropagator.PropagationError {
            guard case .alreadyExists = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    t.test("源目录没有 SKILL.md：拒绝复制") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let notASkill = base.appendingPathComponent("random-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: notASkill, withIntermediateDirectories: true)

        do {
            try SkillPropagator.install(
                skillDirectory: notASkill,
                into: base.appendingPathComponent("target", isDirectory: true))
            try expect(false, "应当抛 missingSkillFile")
        } catch let error as SkillPropagator.PropagationError {
            guard case .missingSkillFile = error else {
                try expect(false, "错误类型不对：\(error)")
                return
            }
        }
    }

    t.test("自定义 slug：目标目录名可与源目录名不同") {
        let base = try tempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let skill = try makeFixtureSkill(in: base)
        let targetRoot = base.appendingPathComponent("target/skills", isDirectory: true)

        let dest = try SkillPropagator.install(
            skillDirectory: skill, into: targetRoot, slug: "renamed-helper")

        try expectEqual(dest.lastPathComponent, "renamed-helper")
        try expect(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("SKILL.md").path))
    }
}
