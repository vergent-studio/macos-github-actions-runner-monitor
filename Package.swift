// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunnerMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "RunnerMonitor",
            targets: ["RunnerMonitor"]
        )
    ],
    targets: [
        .executableTarget(
            name: "RunnerMonitor",
            path: "RunnerMonitor",
            exclude: [
                "Resources/Info.plist"
            ]
        ),
        .testTarget(
            name: "RunnerMonitorTests",
            dependencies: ["RunnerMonitor"],
            path: "RunnerMonitorTests"
        )
    ]
)
