// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacSleepMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "mac-sleep-monitor", targets: ["MacSleepMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "MacSleepMonitor",
            linkerSettings: [
                .linkedLibrary("proc"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
