import EurekaKit
import Foundation

func mascotStateTests(_ t: TestRunner) {
    t.suite("MascotBaseResolver")

    func at(hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 12; c.hour = hour; c.minute = 0
        return Calendar.current.date(from: c)!
    }

    t.test("等待任务最高优先级 → waiting") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: true, hasRunningTask: true, idleSeconds: 0, now: at(hour: 14)))
        try expectEqual(state, .waiting)
    }

    t.test("运行中·白天 → working") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: true, idleSeconds: 0, now: at(hour: 14)))
        try expectEqual(state, .working)
    }

    t.test("运行中·深夜 → night") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: true, idleSeconds: 0, now: at(hour: 2)))
        try expectEqual(state, .night)
    }

    t.test("无任务·短空闲·白天 → idle") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: false, idleSeconds: 10,
            sleepThreshold: 60, now: at(hour: 14)))
        try expectEqual(state, .idle)
    }

    t.test("无任务·空闲超阈值 → sleeping") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: false, idleSeconds: 120,
            sleepThreshold: 60, now: at(hour: 14)))
        try expectEqual(state, .sleeping)
    }

    t.test("无任务·深夜(未超空闲阈值)也 → sleeping") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: false, idleSeconds: 5,
            sleepThreshold: 60, now: at(hour: 1)))
        try expectEqual(state, .sleeping)
    }

    t.test("缺图回退链:night→sleeping→idle、idle 到底") {
        try expectEqual(MascotState.night.fallback, .sleeping)
        try expectEqual(MascotState.sleeping.fallback, .idle)
        try expectEqual(MascotState.success.fallback, .working)
        try expectEqual(MascotState.idle.fallback, .idle)
    }

    t.test("精灵网格同时支持 v2 8×11 与 v3 4×12") {
        let v2 = MascotSpriteGrid(columns: 8, rows: 11)
        let v3 = MascotSpriteGrid(columns: 4, rows: 12)
        try expect(v2.contains(row: 10, column: 7), "v2 最后一格应有效")
        try expect(!v2.contains(row: 11, column: 0), "v2 越界行应拒绝")
        try expect(v3.contains(row: 11, column: 3), "v3 最后一格应有效")
        try expect(!v3.contains(row: 0, column: 4), "v3 越界列应拒绝")
    }

    t.test("播放模式:循环取模、单次停在末帧") {
        try expectEqual(MascotPlaybackMode.loop.frameIndex(
            elapsed: 1.25, fps: 4, frameCount: 4), 1)
        try expectEqual(MascotPlaybackMode.onceHoldLast.frameIndex(
            elapsed: 1.25, fps: 4, frameCount: 4), 3)
        try expectEqual(MascotPlaybackMode.onceHoldLast.frameIndex(
            elapsed: -1, fps: 4, frameCount: 4), 0)
    }

    t.test("动画门控:仅可见且清醒时刷新") {
        try expect(MascotAnimationPolicy.shouldAnimate(isVisible: true, isAwake: true),
                   "可见且清醒时应播放")
        try expect(!MascotAnimationPolicy.shouldAnimate(isVisible: false, isAwake: true),
                   "隐藏时应暂停")
        try expect(!MascotAnimationPolicy.shouldAnimate(isVisible: true, isAwake: false),
                   "系统休眠时应暂停")
    }
}

func mascotCustomizationTests(_ t: TestRunner) {
    t.suite("MascotCustomization")

    t.test("包 id:内置 / 预设 / 自定义往返,旧目录名 id 保持兼容") {
        try expectEqual(MascotPackRef(id: "built-in"), .builtIn)
        try expectEqual(MascotPackRef(id: ""), .builtIn)
        try expectEqual(MascotPackRef(id: "preset:shiba"), .preset("shiba"))
        try expectEqual(MascotPackRef(id: "my-lulu"), .custom("my-lulu"))
        try expectEqual(MascotPackRef.preset("shiba").id, "preset:shiba")
        try expectEqual(MascotPackRef.custom("my-lulu").id, "my-lulu")
        try expectEqual(MascotPackRef.builtIn.id, "built-in")
    }

    t.test("包 id:路径越界 / 隐藏目录一律回退内置") {
        try expectEqual(MascotPackRef(id: "../evil"), .builtIn)
        try expectEqual(MascotPackRef(id: "a/b"), .builtIn)
        try expectEqual(MascotPackRef(id: ".."), .builtIn)
        try expectEqual(MascotPackRef(id: ".hidden"), .builtIn)
        try expectEqual(MascotPackRef(id: "preset:../x"), .builtIn)
        try expectEqual(MascotPackRef(id: "preset:"), .builtIn)
    }

    t.test("上传 manifest:单张基础图,带 upload 标记") {
        let data = MascotManifestEditor.makeUploadManifest(name: "小猫", baseFile: "idle-1.png")
        try expect(MascotManifestEditor.isUpload(data), "应标记为界面上传")
        try expectEqual(MascotManifestEditor.name(data), "小猫")
        try expectEqual(MascotManifestEditor.stateFiles(data), [.idle: "idle-1.png"])
    }

    t.test("按状态换图 / 恢复,保留无关字段") {
        let base = Data("""
        {"name":"手写包","origin":"upload","captions":{"idle":"YO"},
         "states":{"idle":"a.png","working":["w1.png","w2.png"]}}
        """.utf8)
        let updated = try MascotManifestEditor.settingState(.error, file: "e.png", in: base)
        try expectEqual(MascotManifestEditor.stateFiles(updated), [.idle: "a.png", .error: "e.png"])
        let root = try JSONSerialization.jsonObject(with: updated) as? [String: Any]
        try expectEqual((root?["captions"] as? [String: String])?["idle"], "YO")
        let states = root?["states"] as? [String: Any]
        try expectEqual(states?["working"] as? [String], ["w1.png", "w2.png"])

        let reset = try MascotManifestEditor.settingState(.error, file: nil, in: updated)
        try expectEqual(MascotManifestEditor.stateFiles(reset), [.idle: "a.png"])
    }

    t.test("基础形象不能清除,坏 manifest 报错") {
        let data = MascotManifestEditor.makeUploadManifest(name: "x", baseFile: "a.png")
        do {
            _ = try MascotManifestEditor.settingState(.idle, file: nil, in: data)
            try expect(false, "清除 idle 应抛错")
        } catch let error as MascotManifestEditor.EditError {
            try expectEqual(error, .cannotRemoveBase)
        }
        do {
            _ = try MascotManifestEditor.renaming(to: "y", in: Data("[1]".utf8))
            try expect(false, "非对象 manifest 应抛错")
        } catch let error as MascotManifestEditor.EditError {
            try expectEqual(error, .malformed)
        }
    }

    t.test("改名只动 name") {
        let data = MascotManifestEditor.makeUploadManifest(name: "旧名", baseFile: "a.png")
        let renamed = try MascotManifestEditor.renaming(to: "新名", in: data)
        try expectEqual(MascotManifestEditor.name(renamed), "新名")
        try expect(MascotManifestEditor.isUpload(renamed), "改名后仍是上传包")
        try expectEqual(MascotManifestEditor.stateFiles(renamed), [.idle: "a.png"])
    }

    t.test("未配图的状态沿回退链复用") {
        let onlyBase: [MascotState: String] = [.idle: "a.png"]
        try expectEqual(MascotManifestEditor.effectiveSource(for: .error, files: onlyBase), .idle)
        let withWorking: [MascotState: String] = [.idle: "a.png", .working: "w.png"]
        try expectEqual(MascotManifestEditor.effectiveSource(for: .success, files: withWorking), .working)
        try expectEqual(MascotManifestEditor.effectiveSource(for: .sleeping, files: withWorking), .idle)
        try expectEqual(MascotManifestEditor.effectiveSource(for: .night, files: [:]), nil)
    }

    t.test("上传命名:目录名按时间生成且避开重名,文件名带时间戳") {
        let now = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14 17:46:40 UTC
        try expectEqual(
            MascotUploadNaming.directoryName(now: now, existing: []),
            "upload-20261014-174640")
        try expectEqual(
            MascotUploadNaming.directoryName(
                now: now, existing: ["upload-20261014-174640", "upload-20261014-174640-2"]),
            "upload-20261014-174640-3")
        try expectEqual(
            MascotUploadNaming.imageFileName(state: .working, stamp: 42, ext: "PNG"),
            "working-42.png")
        try expectEqual(MascotUploadNaming.displayName(fromFileName: " 我的猫.png"), "我的猫")
        try expectEqual(MascotUploadNaming.displayName(fromFileName: "   "), "我的形象")
    }
}
