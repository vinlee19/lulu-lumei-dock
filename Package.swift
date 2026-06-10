// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "eureka",
    platforms: [.macOS(.v14)],
    targets: [
        // 纯领域层：模型、状态机、几何纯函数。无 IO、无 AppKit。
        .target(name: "EurekaKit"),
        // SQLite 持久化（系统 libsqlite3）
        .target(
            name: "EurekaStore",
            dependencies: ["EurekaKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // 事件接入：spool 消费、hook/notify 解码、rollout tailer
        .target(name: "EurekaIngest", dependencies: ["EurekaKit", "EurekaStore"]),
        // 用量统计与限额
        .target(name: "EurekaUsage", dependencies: ["EurekaKit", "EurekaStore"]),
        // hooks / notify 配置安装器（纯文本进出，独立可测）
        .target(name: "EurekaInstall"),
        // 菜单栏应用本体
        .executableTarget(
            name: "eureka",
            dependencies: ["EurekaKit", "EurekaStore", "EurekaIngest", "EurekaUsage", "EurekaInstall"],
            path: "Sources/EurekaApp",
            resources: [.copy("Resources/pricing.json")]
        ),
        // hooks/notify 调用的轻量转发 CLI：静默、永远 exit 0
        .executableTarget(name: "eureka-relay", path: "Sources/eureka-relay"),
        // 测试 runner（CLT 无 XCTest，自建 harness）
        .executableTarget(
            name: "eureka-tests",
            dependencies: ["EurekaKit", "EurekaStore", "EurekaIngest", "EurekaUsage", "EurekaInstall"],
            path: "Tests/EurekaTestsRunner",
            resources: [.copy("Fixtures")]
        ),
    ]
)
