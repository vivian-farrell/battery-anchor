// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryAnchor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "battery-anchor", targets: ["battery-anchor"]),
        .executable(name: "battery-anchord", targets: ["battery-anchord"]),
        .executable(name: "BatteryAnchorBar", targets: ["BatteryAnchorBar"]),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "AnchorCore",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "battery-anchord", dependencies: ["AnchorCore"]),
        .executableTarget(name: "battery-anchor", dependencies: ["AnchorCore"]),
        .executableTarget(name: "BatteryAnchorBar", dependencies: ["AnchorCore"]),
        .testTarget(name: "AnchorCoreTests", dependencies: ["AnchorCore"]),
    ]
)
