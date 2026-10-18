// swift-tools-version: 6.3
// 下限刻意低于本机工具链(6.4):tools-version 是「最低要求」不是「版本记录」,
// 声明过高会让所有用已发布 Xcode 的贡献者一律构建失败(GitHub macos-latest 为 6.3.3)。
// 6.x 系列语言模式同为 Swift 6,故 6.3 与 6.4 下语义一致;该下限由 CI 实测背书。
import PackageDescription

let package = Package(
    name: "Raccoon",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CleanKit"),
        .target(
            name: "ScanKit",
            dependencies: ["CleanKit"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "UninstallKit",
            dependencies: ["CleanKit"]
        ),
        .target(
            name: "DiskKit",
            dependencies: ["CleanKit"]
        ),
        .target(
            name: "AppCore",
            dependencies: ["ScanKit", "CleanKit", "UninstallKit", "DiskKit"]
        ),
        .executableTarget(
            name: "Raccoon",
            dependencies: ["AppCore", "ScanKit", "CleanKit", "UninstallKit", "DiskKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit", "CleanKit"]),
        .testTarget(name: "UninstallKitTests", dependencies: ["UninstallKit", "CleanKit"]),
        .testTarget(name: "DiskKitTests", dependencies: ["DiskKit", "CleanKit"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ScanKit", "CleanKit", "UninstallKit"]),
    ]
)
