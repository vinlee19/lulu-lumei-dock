// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "eureka",
    platforms: [.macOS(.v14)],
    dependencies: [
        // In-app updates: pinned exactly so the release machine never drifts to an unverified Sparkle version.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        // Pure domain layer: models, state machine, pure geometry functions. No IO, no AppKit.
        .target(name: "EurekaKit"),
        // SQLite persistence (system libsqlite3)
        .target(
            name: "EurekaStore",
            dependencies: ["EurekaKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Event ingestion: spool consumer, hook/notify decoding, rollout tailers
        .target(name: "EurekaIngest", dependencies: ["EurekaKit", "EurekaStore"]),
        // Usage accounting and rate limits
        .target(name: "EurekaUsage", dependencies: ["EurekaKit", "EurekaStore"]),
        // hooks / notify config installers (pure text in/out). Depends only on EurekaKit so install diagnostics can go through L10n.
        .target(name: "EurekaInstall", dependencies: ["EurekaKit"]),
        // Cloud backup: incremental S3/COS upload (SigV4 signing, sync engine, Keychain credentials)
        .target(name: "EurekaSync", dependencies: ["EurekaKit", "EurekaStore", "EurekaIngest"]),
        // The menu-bar app itself
        .executableTarget(
            name: "eureka",
            dependencies: [
                "EurekaKit", "EurekaStore", "EurekaIngest", "EurekaUsage", "EurekaInstall",
                "EurekaSync",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/EurekaApp",
            resources: [
                .copy("Resources/pricing.json"),
                .copy("Resources/pricing-catalog.json"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/mascots"),
                .copy("Resources/source-logos"),
                .copy("Resources/Fonts"),
            ],
            linkerSettings: [
                // A hand-assembled .app loads Sparkle.framework from Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        // Lightweight forwarding CLI invoked by hooks/notify: silent, always exit 0
        .executableTarget(name: "eureka-relay", path: "Sources/eureka-relay"),
        // Test runner (CLT has no XCTest, so a hand-rolled harness)
        .executableTarget(
            name: "eureka-tests",
            dependencies: ["EurekaKit", "EurekaStore", "EurekaIngest", "EurekaUsage", "EurekaInstall", "EurekaSync"],
            path: "Tests/EurekaTestsRunner",
            resources: [.copy("Fixtures")]
        ),
    ]
)
