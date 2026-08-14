// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanControl", targets: ["FanControlApp"]),
        .executable(name: "FanControlHelper", targets: ["FanControlHelper"]),
        .library(name: "FanControlCore", targets: ["FanControlCore"]),
    ],
    targets: [
        .target(
            name: "FanControlCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "FanControlApp", dependencies: ["FanControlCore"]),
        .executableTarget(name: "FanControlHelper", dependencies: ["FanControlCore"]),
        .testTarget(name: "FanControlCoreTests", dependencies: ["FanControlCore"]),
    ]
)
