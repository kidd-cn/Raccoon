// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Raccoon",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CleanKit"),
        .target(
            name: "ScanKit",
            dependencies: ["CleanKit"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "AppCore",
            dependencies: ["ScanKit", "CleanKit"]
        ),
        .executableTarget(
            name: "Raccoon",
            dependencies: ["AppCore", "ScanKit", "CleanKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit", "CleanKit"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ScanKit", "CleanKit"]),
    ]
)
