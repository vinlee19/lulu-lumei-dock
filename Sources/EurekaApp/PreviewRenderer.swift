import AppKit
import EurekaKit
import SwiftUI

/// 离屏渲染灵动岛各形态为 PNG：无需屏幕录制权限即可做视觉走查/自检。
@MainActor
enum PreviewRenderer {
    static func renderAll(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let notched = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTopInset: 32, notchWidth: 196, menuBarHeight: 32)
        let plain = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTopInset: 0, notchWidth: nil, menuBarHeight: 24)

        let now = Date()
        let running1 = AgentTask(
            source: .claude, sessionId: "p1", title: "重构用户认证模块",
            cwd: "/Users/me/work/auth-service", startedAt: now.addingTimeInterval(-754))
        let running2 = AgentTask(
            source: .codex, sessionId: "p2", title: "修复 CI 失败用例",
            cwd: "/Users/me/work/ci", startedAt: now.addingTimeInterval(-135))
        let waitingTask = AgentTask(
            source: .claude, sessionId: "p3", title: "批量更新依赖版本",
            cwd: "/Users/me/work/deps", startedAt: now.addingTimeInterval(-301),
            phase: .waiting(.permission, since: now.addingTimeInterval(-20)))
        let finished = FinishedTask(
            source: .claude, sessionId: "p1", title: "重构用户认证模块",
            cwd: "/Users/me/work/auth-service",
            startedAt: now.addingTimeInterval(-754), finishedAt: now, outcome: .success)
        let errored = FinishedTask(
            source: .codex, sessionId: "p4", title: "迁移旧数据管道",
            cwd: "/Users/me/work/pipeline",
            startedAt: now.addingTimeInterval(-95), finishedAt: now, outcome: .error,
            detail: "API Error: 403 Request not allowed")

        func snapshot(_ name: String, screen: IslandGeometry.ScreenInfo, configure: (IslandViewModel) -> Void) {
            let vm = IslandViewModel()
            vm.updateScreen(screen)
            configure(vm)
            let root = IslandRootView(viewModel: vm)
                .frame(width: vm.layout.panelSize.width, height: vm.layout.panelSize.height)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            guard
                let image = renderer.nsImage,
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                print("渲染失败: \(name)")
                return
            }
            let url = dir.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("已渲染 \(url.path)")
        }

        snapshot("1-compact-notched", screen: notched) {
            $0.updateActiveTasks([running1, running2])
        }
        snapshot("2-compact-plain", screen: plain) {
            $0.updateActiveTasks([running1])
        }
        snapshot("3-compact-waiting", screen: notched) {
            $0.updateActiveTasks([running1, waitingTask])
        }
        snapshot("4-card-finished", screen: notched) {
            $0.updateActiveTasks([running2])
            $0.enqueueFinished(finished)
        }
        snapshot("5-card-error", screen: notched) {
            $0.enqueueFinished(errored)
        }
        snapshot("6-card-waiting", screen: notched) {
            $0.updateActiveTasks([waitingTask])
            $0.enqueueWaiting(waitingTask)
        }
        snapshot("7-card-queued", screen: notched) {
            $0.enqueueFinished(finished)
            $0.enqueueFinished(errored)
        }
        snapshot("8-tasklist", screen: notched) {
            $0.updateActiveTasks([running1, running2, waitingTask])
            $0.islandTapped()
        }
    }
}
