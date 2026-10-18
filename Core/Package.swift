// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WatchdogCore",
    platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [
        .library(name: "WatchdogCore", targets: ["WatchdogCore"]),
        .executable(name: "watchdog-cli", targets: ["watchdog-cli"]),
    ],
    targets: [
        .target(name: "WatchdogCore", path: "Sources/WatchdogCore"),
        .executableTarget(name: "watchdog-cli", dependencies: ["WatchdogCore"], path: "Sources/watchdog-cli"),
        .testTarget(
            name: "WatchdogCoreTests",
            dependencies: ["WatchdogCore"],
            path: "Tests/WatchdogCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
