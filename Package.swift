// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "STS2MacLauncher",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "STS2LauncherCore", targets: ["STS2LauncherCore"]),
        .executable(name: "STS2LauncherApp", targets: ["STS2LauncherApp"]),
        .executable(name: "sts2-poc", targets: ["sts2-poc"])
    ],
    targets: [
        .target(
            name: "STS2LauncherCore",
            path: "Sources/STS2LauncherCore"
        ),
        .executableTarget(
            name: "STS2LauncherApp",
            dependencies: ["STS2LauncherCore"],
            path: "Sources/STS2LauncherApp"
        ),
        .executableTarget(
            name: "sts2-poc",
            dependencies: ["STS2LauncherCore"],
            path: "Sources/sts2-poc"
        ),
        .testTarget(
            name: "STS2LauncherCoreTests",
            dependencies: ["STS2LauncherCore"],
            path: "Tests/STS2LauncherCoreTests"
        )
    ]
)
