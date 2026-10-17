# Raccoon 二期(应用卸载 + 残留清理)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在既有四道安全门下交付「应用卸载 + 关联数据清理 + 孤儿残留扫描」,全部删除仍只经 `CleanExecutor` → `FileManager.trashItem`。

**Architecture:** 新增纯逻辑库 `UninstallKit`(发现/位置表/残留定位/孤儿扫描,根目录全部注入),`AppCore` 增加 `UninstallViewModel` 状态机,`Raccoon` 启用侧边栏「卸载」模块并抽出共用报告视图;执行层原样复用 `CleanExecutor` / `ProtectionStore` / `ExclusionsStore` / `JSONHistoryStore`。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing(`Scripts/test.sh` 唯一测试入口)、macOS 14+。

**Spec:** `docs/superpowers/specs/2026-10-17-raccoon-phase2-design.md`

---

## 执行前准备

- [ ] 从最新 `main` 建工作分支(勿直接在 main 写):

```bash
cd /Users/adder.chia/programs/github/macCleaner
git switch main && git pull --ff-only 2>/dev/null || true
git switch -c feat/phase2
```

- [ ] 确认基线全绿:`Scripts/test.sh`(预期 81 用例全过)。
- [ ] **纪律提醒**:
  - 测试唯一入口是 `Scripts/test.sh`(勿裸跑 `swift test`,CLT 工具链缺宏插件路径)。
  - 任何删除实现都不许出现 `removeItem`/`unlink`;唯一删除动作是 `FileManager.trashItem`(经 `CleanExecutor`)。
  - `README.md` 工作区可能有用户未提交的格式化改动;本计划只在 Task 14 动 README,届时把现状一并提交并在提交信息注明。
  - 本机 CLT 工具链下 `@State`/`@Binding` 需手写展开;视图里可用 `@Bindable`。
  - 临时目录在 `/var`(符号链接到 `/private/var`),测试夹具必须先 `resolvingSymlinksInPath()`,否则 `AppDiscovery` 解析后的路径与断言路径不同形(下方 Fixtures 已处理)。

---

### Task 1: 工具链接线 + UninstallKit 模型/协议骨架

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CleanKit/CleanProgress.swift`
- Create: `Sources/UninstallKit/UninstallModels.swift`
- Create: `Tests/UninstallKitTests/SmokeTests.swift`

- [ ] **Step 1: 先写会失败的骨架测试**

`Tests/UninstallKitTests/SmokeTests.swift`:

```swift
import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class SmokeTests {
    @Test func modelsAreConstructible() {
        let app = InstalledApp(bundleID: "com.example.foo", name: "Foo", version: "1.2",
                               appPath: "/Applications/Foo.app", sizeBytes: 1024, isRunning: false)
        #expect(app.id == "com.example.foo")
        let leftover = AppLeftover(path: "/tmp/x", sizeBytes: 1, safety: .regenerable,
                                   ownership: .bundleID, locationID: "caches")
        #expect(leftover.id == "/tmp/x")
        #expect(LeftoverSafety.userData.rawValue == "userData")
        #expect(CleanProgress(done: 1, total: 2) == CleanProgress(done: 1, total: 2))
    }
}
```

- [ ] **Step 2: 接线 Package.swift 并跑测试确认失败**

`Package.swift` 改为:

```swift
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
            name: "AppCore",
            dependencies: ["ScanKit", "CleanKit", "UninstallKit"]
        ),
        .executableTarget(
            name: "Raccoon",
            dependencies: ["AppCore", "ScanKit", "CleanKit", "UninstallKit"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit", "CleanKit"]),
        .testTarget(name: "UninstallKitTests", dependencies: ["UninstallKit", "CleanKit"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "ScanKit", "CleanKit", "UninstallKit"]),
    ]
)
```

Run: `Scripts/test.sh --filter UninstallKitTests`
Expected: FAIL(编译错误:`cannot find 'InstalledApp' in scope` / 目标源文件不存在)。

- [ ] **Step 3: 加共享进度类型**

`Sources/CleanKit/CleanProgress.swift`:

```swift
import Foundation

/// 清理执行进度(已处理项 / 总项)。扫描页与卸载页共用同一形状,
/// 供 `CleanExecutor.onProgress` 回投主线程后驱动确定进度条。
public struct CleanProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}
```

- [ ] **Step 4: 写模型与协议**

`Sources/UninstallKit/UninstallModels.swift`:

```swift
import Foundation
import CleanKit

/// 已安装应用(来自 /Applications 与 ~/Applications 的 .app 包)。
public struct InstalledApp: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let version: String?
    public let appPath: String      // 绝对路径,已 resolve 符号链接
    public let sizeBytes: Int64     // .app 本体递归大小(不跟随符号链接)
    public let isRunning: Bool
    public init(bundleID: String, name: String, version: String? = nil,
                appPath: String, sizeBytes: Int64, isRunning: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.appPath = appPath
        self.sizeBytes = sizeBytes
        self.isRunning = isRunning
    }
}

/// 关联数据/残留的安全分级:regenerable 默认勾选;userData 默认不勾、橙色、单独确认。
public enum LeftoverSafety: String, Equatable, Sendable {
    case regenerable
    case userData
}

/// 归属置信度:精确 Bundle ID;名称匹配的低置信(未确认归属,永不默认勾选)。
public enum LeftoverOwnership: Equatable, Sendable {
    case bundleID
    case appName
}

public struct AppLeftover: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64
    public let safety: LeftoverSafety
    public let ownership: LeftoverOwnership
    public let locationID: String
    public init(path: String, sizeBytes: Int64, safety: LeftoverSafety,
                ownership: LeftoverOwnership, locationID: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.safety = safety
        self.ownership = ownership
        self.locationID = locationID
    }
}

public struct AppDiscoveryResult: Sendable {
    public let apps: [InstalledApp]
    public let unreadableCount: Int
    public init(apps: [InstalledApp], unreadableCount: Int) {
        self.apps = apps
        self.unreadableCount = unreadableCount
    }
}

public struct AppDiscoveryProgress: Equatable, Sendable {
    public let enumeratedCount: Int
    public init(enumeratedCount: Int) { self.enumeratedCount = enumeratedCount }
}

public struct OrphanScanResult: Sendable {
    public let orphans: [AppLeftover]
    public let failedLocationIDs: Set<String>
    public init(orphans: [AppLeftover], failedLocationIDs: Set<String>) {
        self.orphans = orphans
        self.failedLocationIDs = failedLocationIDs
    }
}

public struct OrphanScanProgress: Equatable, Sendable {
    public let completedLocations: Int
    public let totalLocations: Int
    public init(completedLocations: Int, totalLocations: Int) {
        self.completedLocations = completedLocations
        self.totalLocations = totalLocations
    }
}

public protocol AppDiscovering: Sendable {
    func discover(exclusions: [String],
                  progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult
}

public protocol LeftoverLocating: Sendable {
    func leftovers(for app: InstalledApp, exclusions: [String]) async -> [AppLeftover]
}

public protocol OrphanScanning: Sendable {
    func scan(installedBundleIDs: Set<String>,
              installedAppNames: Set<String>,
              exclusions: [String],
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult
}

/// 已安装集合的 LaunchServices 侧(生产实现经主线程查询 NSWorkspace;测试注入固定集合)。
public protocol InstalledBundleResolving: Sendable {
    func isResolvable(_ bundleID: String) async -> Bool
}

/// 运行中判定(生产读 NSRunningApplication;测试注入固定集合)。
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleID: String) -> Bool
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `Scripts/test.sh --filter UninstallKitTests`
Expected: PASS(1 test)。

- [ ] **Step 6: 提交**

```bash
git add Package.swift Sources/CleanKit/CleanProgress.swift Sources/UninstallKit/UninstallModels.swift Tests/UninstallKitTests/SmokeTests.swift
git commit -m "feat(UninstallKit): 二期骨架——目标接线、领域模型与注入协议"
```

---

### Task 2: 文件大小统计 + 测试夹具

**Files:**
- Create: `Sources/UninstallKit/FileSize.swift`
- Create: `Tests/UninstallKitTests/Fixtures.swift`
- Create: `Tests/UninstallKitTests/FileSizeTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/UninstallKitTests/FileSizeTests.swift`:

```swift
import Testing
import Foundation
@testable import UninstallKit

@Suite
final class FileSizeTests {
    let home = TempHome()

    @Test func sumsNestedRegularFiles() throws {
        let root = try home.makeDir("a", bytes: 10)
        _ = try home.makeFile("a/nested/b.bin", bytes: 25)
        #expect(FileSize.bytes(at: root) == 35)
    }

    @Test func doesNotFollowSymlinks() throws {
        let root = try home.makeDir("a", bytes: 10)
        let outside = try home.makeFile("outside.bin", bytes: 99)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("a/link.bin"), withDestinationURL: outside)
        #expect(FileSize.bytes(at: root) == 10)
    }

    @Test func missingPathIsZero() {
        #expect(FileSize.bytes(at: home.url.appendingPathComponent("nope")) == 0)
    }
}
```

`Tests/UninstallKitTests/Fixtures.swift`:

```swift
import Foundation
import CleanKit

/// 临时主目录夹具:所有测试只在这里造数据,绝不触碰真实 ~/Library。
final class TempHome {
    let url: URL
    let fm = FileManager.default

    init() {
        // 临时目录在 /var(符号链接到 /private/var):必须先解析,
        // 否则 AppDiscovery 的 resolvingSymlinksInPath 结果与断言路径不同形。
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        url = base.appendingPathComponent("raccoon-uninstall-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: url) }

    @discardableResult
    func makeDir(_ relative: String, bytes: Int = 0) throws -> URL {
        let dir = url.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if bytes > 0 { _ = try makeFile("\(relative)/payload.bin", bytes: bytes) }
        return dir
    }

    @discardableResult
    func makeFile(_ relative: String, bytes: Int = 1) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: file)
        return file
    }

    /// 假 .app:Info.plist + 可计量的本体文件。
    @discardableResult
    func makeApp(_ name: String, bundleID: String, inRoot root: URL,
                 version: String? = "1.0", bodyBytes: Int = 100) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x42, count: bodyBytes).write(to: contents.appendingPathComponent("binary"))
        return app
    }

    func appRoot(_ name: String = "Applications") throws -> URL {
        let root = url.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 测试用保护层:不设硬保护根(硬保护行为由 CleanKit 既有测试覆盖)。
    func protection(userExclusions: [String] = []) -> ProtectionStore {
        ProtectionStore(hardRoots: [], userExclusions: userExclusions)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter FileSizeTests`
Expected: FAIL(编译错误:`cannot find 'FileSize' in scope`)。

- [ ] **Step 3: 实现**

`Sources/UninstallKit/FileSize.swift`:

```swift
import Foundation

/// 递归累计目录内普通文件字节数;符号链接与不可读条目一律跳过(不跟随链接)。
enum FileSize {
    static func bytes(at url: URL, fm: FileManager = .default) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isSymbolicLink != true,
                values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter FileSizeTests`
Expected: PASS(3 tests)。

- [ ] **Step 5: 提交**

```bash
git add Sources/UninstallKit/FileSize.swift Tests/UninstallKitTests/Fixtures.swift Tests/UninstallKitTests/FileSizeTests.swift
git commit -m "feat(UninstallKit): 文件大小统计(不跟随符号链接)与临时目录夹具"
```

---

### Task 3: 位置表与分级

**Files:**
- Create: `Sources/UninstallKit/LeftoverLocations.swift`
- Create: `Tests/UninstallKitTests/LeftoverLocationsTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/UninstallKitTests/LeftoverLocationsTests.swift`:

```swift
import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class LeftoverLocationsTests {
    @Test func tableHasExpectedIDsAndGrading() {
        let byID = Dictionary(uniqueKeysWithValues: LeftoverLocations.all.map { ($0.id, $0) })
        #expect(Set(byID.keys) == [
            "caches", "logs", "webkit", "httpstorages", "saved-state", "launch-agents",
            "app-support", "containers", "group-containers", "app-scripts",
            "app-support-name", "logs-name",
        ])
        #expect(byID["caches"]?.safety == .regenerable)
        #expect(byID["logs"]?.safety == .regenerable)
        #expect(byID["webkit"]?.safety == .userData)
        #expect(byID["httpstorages"]?.safety == .regenerable)
        #expect(byID["saved-state"]?.safety == .regenerable)
        #expect(byID["launch-agents"]?.safety == .regenerable)
        #expect(byID["app-support"]?.safety == .userData)
        #expect(byID["containers"]?.safety == .userData)
        #expect(byID["group-containers"]?.safety == .userData)
        #expect(byID["app-scripts"]?.safety == .userData)
        #expect(byID["logs-name"]?.safety == .regenerable)
        #expect(byID["app-support-name"]?.safety == .userData)
        #expect(byID["saved-state"]?.match == .exactSuffixed(".savedState"))
        #expect(byID["launch-agents"]?.match == .exactSuffixed(".plist"))
        #expect(byID["group-containers"]?.match == .groupContainer)
        #expect(byID["app-support-name"]?.match == .appName)
        #expect(byID["logs-name"]?.match == .appName)
    }

    // 事实断言:一期硬保护整棵覆盖 Preferences/Cookies,二期不列出这两处(列了也删不掉)。
    // 若有人放松硬保护,此测会红,提醒同步二期方案。
    @Test func preferencesAndCookiesAreHardProtected() {
        let home = NSHomeDirectory()
        let protection = ProtectionStore()
        #expect(protection.isDenied("\(home)/Library/Preferences/com.example.foo.plist"))
        #expect(protection.isDenied("\(home)/Library/Cookies/com.example.foo.binarycookies"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter LeftoverLocationsTests`
Expected: FAIL(编译错误:`cannot find 'LeftoverLocations' in scope`)。

- [ ] **Step 3: 实现**

`Sources/UninstallKit/LeftoverLocations.swift`:

```swift
import Foundation

/// 关联数据位置表(声明式,代码内静态表)。位置一律相对 ~/Library;
/// `<id>` = Bundle ID,`.appName` 表示按应用名匹配的低置信位置。
public struct LeftoverLocation: Equatable, Sendable {
    public enum Match: Equatable, Sendable {
        case exact                        // <id>
        case exactSuffixed(String)        // <id><suffix>,如 .savedState / .plist
        case groupContainer               // <id> 或 *.<id>
        case appName                      // <name>(低置信)
    }
    public let id: String
    public let folder: String
    public let match: Match
    public let safety: LeftoverSafety
    public init(id: String, folder: String, match: Match, safety: LeftoverSafety) {
        self.id = id
        self.folder = folder
        self.match = match
        self.safety = safety
    }
}

public enum LeftoverLocations {
    /// 按 id 字典序排列:同一路径被多条位置命中时,先命中者胜出(去重口径)。
    public static let all: [LeftoverLocation] = [
        .init(id: "app-scripts", folder: "Application Scripts", match: .exact, safety: .userData),
        .init(id: "app-support", folder: "Application Support", match: .exact, safety: .userData),
        .init(id: "app-support-name", folder: "Application Support", match: .appName, safety: .userData),
        .init(id: "caches", folder: "Caches", match: .exact, safety: .regenerable),
        .init(id: "containers", folder: "Containers", match: .exact, safety: .userData),
        .init(id: "group-containers", folder: "Group Containers", match: .groupContainer, safety: .userData),
        .init(id: "httpstorages", folder: "HTTPStorages", match: .exact, safety: .regenerable),
        .init(id: "launch-agents", folder: "LaunchAgents", match: .exactSuffixed(".plist"), safety: .regenerable),
        .init(id: "logs", folder: "Logs", match: .exact, safety: .regenerable),
        .init(id: "logs-name", folder: "Logs", match: .appName, safety: .regenerable),
        .init(id: "saved-state", folder: "Saved Application State", match: .exactSuffixed(".savedState"), safety: .regenerable),
        .init(id: "webkit", folder: "WebKit", match: .exact, safety: .userData),
    ]

    /// 明确不列出的受保护位置:一期硬保护整棵覆盖(Preferences / Cookies)。
    /// 放开需改动门 1(窄口豁免 + 回归测试),已列为三期候选。
    public static let excludedFolders = ["Preferences", "Cookies"]
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter LeftoverLocationsTests`
Expected: PASS(2 tests)。

- [ ] **Step 5: 提交**

```bash
git add Sources/UninstallKit/LeftoverLocations.swift Tests/UninstallKitTests/LeftoverLocationsTests.swift
git commit -m "feat(UninstallKit): 关联数据位置表与分级,断言 Preferences/Cookies 硬保护事实"
```

---

### Task 4: 应用发现

**Files:**
- Create: `Sources/UninstallKit/AppDiscovery.swift`
- Create: `Tests/UninstallKitTests/AppDiscoveryTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/UninstallKitTests/AppDiscoveryTests.swift`:

```swift
import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class AppDiscoveryTests {
    let home = TempHome()

    struct Running: RunningAppChecking {
        var ids: Set<String> = []
        func isRunning(bundleID: String) -> Bool { ids.contains(bundleID) }
    }

    func discover(roots: [URL], exclusions: [String] = [],
                  running: Set<String> = []) async throws -> AppDiscoveryResult {
        let discovery = AppDiscovery(appRoots: roots, running: Running(ids: running))
        return try await discovery.discover(exclusions: exclusions, progress: { _ in })
    }

    @Test func findsTopLevelAndOneSubdirectoryLevel() async throws {
        let root = try home.appRoot()
        try home.makeApp("Alpha", bundleID: "com.example.alpha", inRoot: root)
        let sub = try home.makeDir("Utilities")
        try home.makeApp("Beta", bundleID: "com.example.beta", inRoot: sub)
        try home.makeDir("Deep/More")
        try home.makeApp("Gamma", bundleID: "com.example.gamma",
                         inRoot: home.url.appendingPathComponent("Deep/More"))

        let result = try await discover(roots: [root])
        #expect(Set(result.apps.map(\.bundleID)) == ["com.example.alpha", "com.example.beta"])
        #expect(result.unreadableCount == 0)
    }

    @Test func skipsAppleAppsAndMissingPlist() async throws {
        let root = try home.appRoot()
        try home.makeApp("Safari", bundleID: "com.apple.Safari", inRoot: root)
        try home.makeApp("Good", bundleID: "com.example.good", inRoot: root)
        // 无 Info.plist 的 .app
        let broken = root.appendingPathComponent("Broken.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)

        let result = try await discover(roots: [root])
        #expect(result.apps.map(\.bundleID) == ["com.example.good"])
        #expect(result.unreadableCount == 1)
    }

    @Test func dedupesSameBundleIDByRootOrder() async throws {
        let first = try home.appRoot("Applications")
        let second = try home.appRoot("UserApplications")
        try home.makeApp("Foo", bundleID: "com.example.foo", inRoot: first)
        try home.makeApp("Foo", bundleID: "com.example.foo", inRoot: second)

        let result = try await discover(roots: [first, second])
        #expect(result.apps.count == 1)
        #expect(result.apps[0].appPath == first.appendingPathComponent("Foo.app").path)
    }

    @Test func skipsSymlinkEscapingRoot() async throws {
        let root = try home.appRoot()
        let outside = try home.makeApp("Outside", bundleID: "com.example.outside", inRoot: home.url)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Outside.app"), withDestinationURL: outside)

        let result = try await discover(roots: [root])
        #expect(result.apps.isEmpty)
    }

    @Test func skipsUserExclusionsAndMarksRunning() async throws {
        let root = try home.appRoot()
        let excluded = try home.makeApp("Excluded", bundleID: "com.example.excluded", inRoot: root)
        try home.makeApp("Running", bundleID: "com.example.running", inRoot: root)

        let result = try await discover(roots: [root], exclusions: [excluded.path],
                                        running: ["com.example.running"])
        #expect(result.apps.map(\.bundleID) == ["com.example.running"])
        #expect(result.apps[0].isRunning)
    }

    @Test func reportsProgressWhileEnumerating() async throws {
        let root = try home.appRoot()
        try home.makeApp("A", bundleID: "com.example.a", inRoot: root)
        try home.makeApp("B", bundleID: "com.example.b", inRoot: root)
        final class Box: @unchecked Sendable { var values: [AppDiscoveryProgress] = [] }
        let box = Box()
        let discovery = AppDiscovery(appRoots: [root], running: Running())
        _ = try await discovery.discover(exclusions: []) { box.values.append($0) }
        #expect(box.values.map(\.enumeratedCount) == [1, 2])
    }

    @Test func sortsByName() async throws {
        let root = try home.appRoot()
        try home.makeApp("Zeta", bundleID: "com.example.zeta", inRoot: root)
        try home.makeApp("Alpha", bundleID: "com.example.alpha", inRoot: root)
        let result = try await discover(roots: [root])
        #expect(result.apps.map(\.name) == ["Alpha", "Zeta"])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter AppDiscoveryTests`
Expected: FAIL(编译错误:`cannot find 'AppDiscovery' in scope`)。

- [ ] **Step 3: 实现**

`Sources/UninstallKit/AppDiscovery.swift`:

```swift
import Foundation
import CleanKit

/// 枚举应用根下的 .app(最多一层子目录),读取 Info.plist,过滤 Apple 应用、
/// 越界符号链接与用户排除项;同 Bundle ID 按根顺序去重。
public struct AppDiscovery: AppDiscovering {
    let appRoots: [URL]
    let running: RunningAppChecking
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager

    public init(appRoots: [URL], running: RunningAppChecking, fm: FileManager = .default) {
        self.appRoots = appRoots
        self.running = running
        self.fm = fm
    }

    public func discover(exclusions: [String],
                         progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult {
        let protection = ProtectionStore(userExclusions: exclusions)
        var apps: [InstalledApp] = []
        var seenIDs = Set<String>()
        var unreadable = 0
        var enumerated = 0
        for root in appRoots {
            for candidate in Self.appCandidates(in: root, fm: fm) {
                try Task.checkCancellation()
                enumerated += 1
                progress(AppDiscoveryProgress(enumeratedCount: enumerated))
                let resolved = candidate.resolvingSymlinksInPath()
                guard Self.isUnder(resolved, root: root) else { continue }
                // 原始与解析后两种形态都校验:用户排除项常是未解析路径(如经 NSOpenPanel),
                // isDenied 契约要求路径与规则同形,这里对两种形态都问一次。
                guard !protection.isDenied(candidate.path),
                      !protection.isDenied(resolved.path) else { continue }
                guard let meta = Self.bundleMetadata(at: resolved) else {
                    unreadable += 1
                    continue
                }
                guard !meta.bundleID.lowercased().hasPrefix("com.apple.") else { continue }
                guard !seenIDs.contains(meta.bundleID) else { continue }
                seenIDs.insert(meta.bundleID)
                apps.append(InstalledApp(
                    bundleID: meta.bundleID,
                    name: meta.name,
                    version: meta.version,
                    appPath: resolved.path,
                    sizeBytes: FileSize.bytes(at: resolved, fm: fm),
                    isRunning: running.isRunning(bundleID: meta.bundleID)
                ))
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return AppDiscoveryResult(apps: apps, unreadableCount: unreadable)
    }

    struct BundleMetadata {
        let bundleID: String
        let name: String
        let version: String?
    }

    static func bundleMetadata(at app: URL) -> BundleMetadata? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else { return nil }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        return BundleMetadata(bundleID: bundleID, name: name,
                              version: dict["CFBundleShortVersionString"] as? String)
    }

    /// 根下第一层的 .app + 根下第一层目录内的 .app(不超过一层子目录)。
    static func appCandidates(in root: URL, fm: FileManager) -> [URL] {
        guard let level1 = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var out: [URL] = []
        for entry in level1 {
            if entry.pathExtension.lowercased() == "app" {
                out.append(entry)
                continue
            }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let level2 = (try? fm.contentsOfDirectory(
                at: entry, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            out += level2.filter { $0.pathExtension.lowercased() == "app" }
        }
        return out
    }

    /// 解析链接后仍须位于该根之下(根自身也先解析,允许根是符号链接)。
    static func isUnder(_ url: URL, root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().path
        let path = url.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter AppDiscoveryTests`
Expected: PASS(7 tests)。

- [ ] **Step 5: 提交**

```bash
git add Sources/UninstallKit/AppDiscovery.swift Tests/UninstallKitTests/AppDiscoveryTests.swift
git commit -m "feat(UninstallKit): 应用发现——一层子目录、去重、符号链接与排除过滤"
```

---

### Task 5: 作用域白名单 + 关联数据定位

**Files:**
- Create: `Sources/UninstallKit/LeftoverScope.swift`
- Create: `Sources/UninstallKit/LeftoverLocator.swift`
- Create: `Tests/UninstallKitTests/LeftoverLocatorTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/UninstallKitTests/LeftoverLocatorTests.swift`:

```swift
import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class LeftoverLocatorTests {
    let home = TempHome()

    func app(name: String = "Foo", bundleID: String = "com.example.foo") -> InstalledApp {
        InstalledApp(bundleID: bundleID, name: name, version: "1.0",
                     appPath: home.url.appendingPathComponent("Applications/\(name).app").path,
                     sizeBytes: 100, isRunning: false)
    }

    func leftovers(_ app: InstalledApp, exclusions: [String] = []) async -> [AppLeftover] {
        await LeftoverLocator(home: home.url).leftovers(for: app, exclusions: exclusions)
    }

    @Test func findsExactLocationsWithGrading() async throws {
        try home.makeDir("Library/Caches/com.example.foo", bytes: 10)
        try home.makeDir("Library/Logs/com.example.foo", bytes: 20)
        try home.makeDir("Library/WebKit/com.example.foo", bytes: 30)
        try home.makeDir("Library/HTTPStorages/com.example.foo", bytes: 40)
        try home.makeDir("Library/Saved Application State/com.example.foo.savedState", bytes: 50)
        try home.makeFile("Library/LaunchAgents/com.example.foo.plist", bytes: 5)
        try home.makeDir("Library/Application Support/com.example.foo", bytes: 60)
        try home.makeDir("Library/Containers/com.example.foo", bytes: 70)
        try home.makeDir("Library/Group Containers/TEAMID.com.example.foo", bytes: 80)
        try home.makeDir("Library/Application Scripts/com.example.foo", bytes: 90)

        let found = await leftovers(app())
        let byID = Dictionary(grouping: found, by: \.locationID)
        #expect(Set(byID.keys) == [
            "caches", "logs", "webkit", "httpstorages", "saved-state", "launch-agents",
            "app-support", "containers", "group-containers", "app-scripts",
        ])
        #expect(byID["caches"]?.first?.safety == .regenerable)
        #expect(byID["logs"]?.first?.safety == .regenerable)
        #expect(byID["saved-state"]?.first?.safety == .regenerable)
        #expect(byID["launch-agents"]?.first?.safety == .regenerable)
        #expect(byID["app-support"]?.first?.safety == .userData)
        #expect(byID["containers"]?.first?.safety == .userData)
        #expect(byID["group-containers"]?.first?.safety == .userData)
        #expect(found.allSatisfy { $0.ownership == .bundleID })
        #expect(byID["caches"]?.first?.sizeBytes == 10)
    }

    @Test func groupContainerAcceptsTeamPrefixedName() async throws {
        let dir = try home.makeDir("Library/Group Containers/TEAMID123.com.example.foo", bytes: 8)
        let found = await leftovers(app())
        #expect(found.map(\.path) == [dir.path])
    }

    @Test func nameMatchIsLowConfidence() async throws {
        try home.makeDir("Library/Application Support/Foo", bytes: 11)
        try home.makeFile("Library/Logs/Foo", bytes: 12)
        let found = await leftovers(app())
        #expect(found.allSatisfy { $0.ownership == .appName })
        #expect(Set(found.map(\.locationID)) == ["app-support-name", "logs-name"])
    }

    @Test func dedupesSamePathByLocationIDOrder() async throws {
        // 名字恰好等于 Bundle ID:exact 先命中(app-support)后,低置信不再重复计入
        try home.makeDir("Library/Application Support/com.example.foo", bytes: 3)
        let found = await leftovers(app(name: "com.example.foo"))
        #expect(found.count == 1)
        #expect(found[0].locationID == "app-support")
        #expect(found[0].ownership == .bundleID)
    }

    @Test func excludesUserExclusionsAndHardProtectedPaths() async throws {
        let dir = try home.makeDir("Library/Caches/com.example.foo", bytes: 4)
        let found = await leftovers(app(), exclusions: [dir.path])
        #expect(found.isEmpty)
    }

    @Test func ignoresMissingLocations() async {
        #expect(await leftovers(app()).isEmpty)
    }

    @Test func scopeOnlyAllowsDirectChildrenOfKnownFolders() {
        let scope = LeftoverScope(home: home.url)
        let library = home.url.appendingPathComponent("Library").path
        #expect(scope.isAllowed("\(library)/Caches/com.example.foo"))
        #expect(scope.isAllowed("\(library)/Group Containers/TEAMID.com.example.foo"))
        #expect(!scope.isAllowed("\(library)/Preferences/com.example.foo.plist"))
        #expect(!scope.isAllowed("\(library)/Caches/com.example.foo/deep/file"))
        #expect(!scope.isAllowed(home.url.appendingPathComponent("Documents/x").path))
        #expect(!scope.isAllowed("relative/path"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter LeftoverLocatorTests`
Expected: FAIL(编译错误:`cannot find 'LeftoverLocator' / 'LeftoverScope' in scope`)。

- [ ] **Step 3: 实现作用域白名单**

`Sources/UninstallKit/LeftoverScope.swift`:

```swift
import Foundation
import CleanKit

/// 二期作用域白名单:关联数据只允许落在「~/Library + 位置表目录」的直接子项。
/// 定位器本身只按位置表构造路径;本类型是执行前对提交通道的最后一道形状校验。
public struct LeftoverScope: Sendable {
    let library: String              // 已归一化、小写
    let allowedParents: Set<String>  // 已归一化、小写

    public init(home: URL) {
        let lib = ProtectionStore.normalize(home.appendingPathComponent("Library").path).lowercased()
        self.library = lib
        self.allowedParents = Set(LeftoverLocations.all.map {
            ProtectionStore.normalize("\(lib)/\($0.folder)").lowercased()
        })
    }

    public func isAllowed(_ path: String) -> Bool {
        let normalized = ProtectionStore.normalize(path).lowercased()
        guard normalized.hasPrefix(library + "/") else { return false }
        let parent = (normalized as NSString).deletingLastPathComponent
        return allowedParents.contains(parent)
    }
}
```

- [ ] **Step 4: 实现定位器**

`Sources/UninstallKit/LeftoverLocator.swift`:

```swift
import Foundation
import CleanKit

/// 按位置表为单个应用定位关联数据。每条结果都经过:
/// 存在性 → isDenied(硬保护+用户排除) → 作用域白名单;同路径按位置 id 序第一条胜出。
public struct LeftoverLocator: LeftoverLocating {
    let home: URL
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager
    let scope: LeftoverScope

    public init(home: URL, fm: FileManager = .default) {
        self.home = home
        self.fm = fm
        self.scope = LeftoverScope(home: home)
    }

    public func leftovers(for app: InstalledApp, exclusions: [String]) async -> [AppLeftover] {
        let protection = ProtectionStore(userExclusions: exclusions)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        var out: [AppLeftover] = []
        var seen = Set<String>()

        for location in LeftoverLocations.all.sorted(by: { $0.id < $1.id }) {
            if Task.isCancelled { break }
            let dir = library.appendingPathComponent(location.folder, isDirectory: true)
            let candidates: [URL]
            switch location.match {
            case .exact:
                candidates = [dir.appendingPathComponent(app.bundleID)]
            case .exactSuffixed(let suffix):
                candidates = [dir.appendingPathComponent(app.bundleID + suffix)]
            case .groupContainer:
                let entries = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
                candidates = entries.filter {
                    $0.lastPathComponent == app.bundleID
                        || $0.lastPathComponent.hasSuffix("." + app.bundleID)
                }
            case .appName:
                candidates = [dir.appendingPathComponent(app.name)]
            }
            for candidate in candidates {
                guard let leftover = makeLeftover(candidate, location: location,
                                                  protection: protection) else { continue }
                guard seen.insert(leftover.path).inserted else { continue }
                out.append(leftover)
            }
        }
        return out
    }

    private func makeLeftover(_ url: URL, location: LeftoverLocation,
                              protection: ProtectionStore) -> AppLeftover? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let path = ProtectionStore.normalize(url.path)
        guard !protection.isDenied(path), scope.isAllowed(path) else { return nil }
        return AppLeftover(path: path,
                           sizeBytes: FileSize.bytes(at: url, fm: fm),
                           safety: location.safety,
                           ownership: location.match == .appName ? .appName : .bundleID,
                           locationID: location.id)
    }
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `Scripts/test.sh --filter LeftoverLocatorTests`
Expected: PASS(7 tests)。

- [ ] **Step 6: 提交**

```bash
git add Sources/UninstallKit/LeftoverScope.swift Sources/UninstallKit/LeftoverLocator.swift Tests/UninstallKitTests/LeftoverLocatorTests.swift
git commit -m "feat(UninstallKit): 关联数据定位与作用域白名单(硬保护/排除/越界三重过滤)"
```

---

### Task 6: 孤儿残留扫描

**Files:**
- Create: `Sources/UninstallKit/OrphanScanner.swift`
- Create: `Tests/UninstallKitTests/OrphanScannerTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/UninstallKitTests/OrphanScannerTests.swift`:

```swift
import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class OrphanScannerTests {
    let home = TempHome()

    struct Resolver: InstalledBundleResolving {
        var resolvable: Set<String> = []
        func isResolvable(_ bundleID: String) async -> Bool { resolvable.contains(bundleID) }
    }

    func scan(installedIDs: Set<String> = [], installedNames: Set<String> = [],
              resolver: Resolver = Resolver(), exclusions: [String] = []) async -> OrphanScanResult {
        let scanner = OrphanScanner(home: home.url, resolver: resolver)
        return await scanner.scan(installedBundleIDs: installedIDs,
                                  installedAppNames: installedNames,
                                  exclusions: exclusions,
                                  progress: { _ in })
    }

    @Test func highConfidenceOrphanWhenBundleIDNotInstalled() async throws {
        let caches = try home.makeDir("Library/Caches/com.gone.app", bytes: 10)
        let support = try home.makeDir("Library/Application Support/com.gone.app", bytes: 20)
        let result = await scan(installedIDs: ["com.alive.app"])

        let paths = Set(result.orphans.map(\.path))
        #expect(paths == [caches.path, support.path])
        let byPath = Dictionary(uniqueKeysWithValues: result.orphans.map { ($0.path, $0) })
        #expect(byPath[caches.path]?.safety == .regenerable)
        #expect(byPath[caches.path]?.ownership == .bundleID)
        #expect(byPath[support.path]?.safety == .userData)
    }

    @Test func installedAppsAreNotOrphans() async throws {
        try home.makeDir("Library/Caches/com.alive.app", bytes: 1)
        let result = await scan(installedIDs: ["com.alive.app"])
        #expect(result.orphans.isEmpty)
    }

    @Test func launchServicesResolvableIsNotOrphan() async throws {
        try home.makeDir("Library/Caches/com.installed.elsewhere", bytes: 1)
        let result = await scan(resolver: Resolver(resolvable: ["com.installed.elsewhere"]))
        #expect(result.orphans.isEmpty)
    }

    @Test func appleBundleIDsAreNeverOrphans() async throws {
        try home.makeDir("Library/Caches/com.apple.Safari", bytes: 1)
        let result = await scan()
        #expect(result.orphans.isEmpty)
    }

    @Test func suffixLocationsStripSuffix() async throws {
        let saved = try home.makeDir("Library/Saved Application State/com.gone.app.savedState", bytes: 2)
        let plist = try home.makeFile("Library/LaunchAgents/com.gone.app.plist", bytes: 3)
        let result = await scan(installedIDs: ["com.gone.app"])   // 已安装 → 两者都不算孤儿
        #expect(result.orphans.isEmpty)

        let result2 = await scan()
        #expect(Set(result2.orphans.map(\.path)) == [saved.path, plist.path])
    }

    @Test func lowConfidenceForNonReverseDNSNames() async throws {
        let support = try home.makeDir("Library/Application Support/Some Old App", bytes: 4)
        let logs = try home.makeDir("Library/Logs/Some Old App", bytes: 5)
        let result = await scan(installedNames: ["Something Else"])
        let byPath = Dictionary(uniqueKeysWithValues: result.orphans.map { ($0.path, $0) })
        #expect(byPath[support.path]?.ownership == .appName)
        #expect(byPath[logs.path]?.ownership == .appName)
        #expect(byPath[logs.path]?.safety == .regenerable)
    }

    @Test func nameMatchingInstalledAppIsNotLowConfidenceOrphan() async throws {
        try home.makeDir("Library/Application Support/Still Here", bytes: 1)
        let result = await scan(installedNames: ["Still Here"])
        #expect(result.orphans.isEmpty)
    }

    @Test func groupContainerWithTeamPrefixChecksSuffixID() async throws {
        try home.makeDir("Library/Group Containers/TEAMID.com.alive.app", bytes: 1)
        let result = await scan(installedIDs: ["com.alive.app"])
        #expect(result.orphans.isEmpty)
    }

    @Test func exclusionsAreHonored() async throws {
        let dir = try home.makeDir("Library/Caches/com.gone.app", bytes: 1)
        let result = await scan(exclusions: [dir.path])
        #expect(result.orphans.isEmpty)
    }

    @Test func missingLocationsAreNotFailuresAndProgressCompletes() async throws {
        final class Box: @unchecked Sendable { var last: OrphanScanProgress? }
        let box = Box()
        let scanner = OrphanScanner(home: home.url, resolver: Resolver())
        let result = await scanner.scan(installedBundleIDs: [], installedAppNames: [], exclusions: []) {
            box.last = $0
        }
        #expect(result.failedLocationIDs.isEmpty)
        #expect(box.last?.completedLocations == LeftoverLocations.all.count)
        #expect(box.last?.totalLocations == LeftoverLocations.all.count)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter OrphanScannerTests`
Expected: FAIL(编译错误:`cannot find 'OrphanScanner' in scope`)。

- [ ] **Step 3: 实现**

`Sources/UninstallKit/OrphanScanner.swift`:

```swift
import Foundation
import CleanKit

/// 孤儿残留扫描:只扫位置表内的一级子项。
/// 高置信 = 反向域名形状且 Bundle ID 未安装(目录枚举 ∪ LaunchServices 均查不到);
/// 低置信 = Application Support / Logs 下非反向域名、且不等于任何已安装应用名。
public struct OrphanScanner: OrphanScanning {
    let home: URL
    let resolver: InstalledBundleResolving
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager
    let scope: LeftoverScope

    public init(home: URL, resolver: InstalledBundleResolving, fm: FileManager = .default) {
        self.home = home
        self.resolver = resolver
        self.fm = fm
        self.scope = LeftoverScope(home: home)
    }

    public func scan(installedBundleIDs: Set<String>,
                     installedAppNames: Set<String>,
                     exclusions: [String],
                     progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult {
        let protection = ProtectionStore(userExclusions: exclusions)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let installedNames = Set(installedAppNames.map(Self.normalizedName))
        var orphans: [AppLeftover] = []
        var seen = Set<String>()
        var failed = Set<String>()
        let locations = LeftoverLocations.all.sorted(by: { $0.id < $1.id })

        for (index, location) in locations.enumerated() {
            if Task.isCancelled { break }
            defer {
                progress(OrphanScanProgress(completedLocations: index + 1,
                                            totalLocations: locations.count))
            }
            let dir = library.appendingPathComponent(location.folder, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) { continue }
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [])
            } catch {
                failed.insert(location.id)
                continue
            }
            for entry in entries {
                if Task.isCancelled { break }
                let path = ProtectionStore.normalize(entry.path)
                guard !protection.isDenied(path), scope.isAllowed(path) else { continue }
                switch location.match {
                case .appName:
                    guard let leftover = makeLowConfidence(entry, location: location,
                                                           installedNames: installedNames),
                          seen.insert(leftover.path).inserted else { continue }
                    orphans.append(leftover)
                case .exact, .exactSuffixed, .groupContainer:
                    guard let id = Self.bundleID(fromName: entry.lastPathComponent, match: location.match),
                          !id.lowercased().hasPrefix("com.apple.") else { continue }
                    let candidates = location.match == .groupContainer ? Self.candidateIDs(id) : [id]
                    // 组容器可带 TEAMID 前缀:任一候选属于 Apple 即视为系统数据
                    if candidates.contains(where: { $0.lowercased().hasPrefix("com.apple.") }) { continue }
                    if candidates.contains(where: { installedBundleIDs.contains($0) }) { continue }
                    var resolvable = false
                    for candidate in candidates {
                        if await resolver.isResolvable(candidate) { resolvable = true; break }
                    }
                    guard !resolvable else { continue }
                    let leftover = AppLeftover(
                        path: path,
                        sizeBytes: FileSize.bytes(at: entry, fm: fm),
                        safety: location.safety,
                        ownership: .bundleID,
                        locationID: location.id
                    )
                    guard seen.insert(leftover.path).inserted else { continue }
                    orphans.append(leftover)
                }
            }
        }
        return OrphanScanResult(orphans: orphans, failedLocationIDs: failed)
    }

    private func makeLowConfidence(_ entry: URL, location: LeftoverLocation,
                                   installedNames: Set<String>) -> AppLeftover? {
        let name = entry.lastPathComponent
        guard !Self.isReverseDNS(name) else { return nil }
        guard !installedNames.contains(Self.normalizedName(name)) else { return nil }
        return AppLeftover(path: ProtectionStore.normalize(entry.path),
                           sizeBytes: FileSize.bytes(at: entry, fm: fm),
                           safety: location.safety,
                           ownership: .appName,
                           locationID: location.id)
    }

    /// 按位置类型从目录名还原候选 Bundle ID。
    static func bundleID(fromName name: String, match: LeftoverLocation.Match) -> String? {
        switch match {
        case .exact, .groupContainer:
            return isReverseDNS(name) ? name : nil
        case .exactSuffixed(let suffix):
            guard name.hasSuffix(suffix) else { return nil }
            let id = String(name.dropLast(suffix.count))
            return isReverseDNS(id) ? id : nil
        case .appName:
            return nil
        }
    }

    /// 反向域名形状:≥2 段、每段仅 ASCII 字母/数字/-/_、非空。
    static func isReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }

    /// 组容器可能是 TEAMID.<id>:逐个点后后缀都当作候选(任一已安装即不算孤儿)。
    static func candidateIDs(_ name: String) -> [String] {
        var out = [name]
        var remaining = Substring(name)
        while let dot = remaining.firstIndex(of: ".") {
            remaining = remaining[remaining.index(after: dot)...]
            if !remaining.isEmpty { out.append(String(remaining)) }
        }
        return out
    }

    /// 名称归一:小写、去首尾空白、去 .app 后缀。
    static func normalizedName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".app") { s = String(s.dropLast(4)) }
        return s
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter OrphanScannerTests`
Expected: PASS(10 tests)。

- [ ] **Step 5: 提交**

```bash
git add Sources/UninstallKit/OrphanScanner.swift Tests/UninstallKitTests/OrphanScannerTests.swift
git commit -m "feat(UninstallKit): 孤儿扫描——反向域名精确判定与低置信名称分区"
```

---

### Task 7: 生产适配器与装配

**Files:**
- Create: `Sources/AppCore/UninstallServices.swift`
- Create: `Tests/AppCoreTests/UninstallServicesTests.swift`

- [ ] **Step 1: 先写测试**

`Tests/AppCoreTests/UninstallServicesTests.swift`:

```swift
import Testing
import Foundation
import AppKit
import UninstallKit
@testable import AppCore

@Suite @MainActor
final class UninstallServicesTests {
    @Test func factoryWiresOrphanScanForTempHome() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let home = base.appendingPathComponent("raccoon-services-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/com.gone.app"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let services = UninstallServices.make(home: home)
        let scan = await services.orphans.scan(installedBundleIDs: [], installedAppNames: [],
                                               exclusions: [], progress: { _ in })
        #expect(scan.orphans.map(\.path)
            == [home.appendingPathComponent("Library/Caches/com.gone.app").path])
    }

    @Test func runningCheckerReportsCurrentProcesses() {
        // Finder 常驻;若环境无 Finder 也不得崩溃(只验证 API 形状)
        _ = NSRunningAppChecker().isRunning(bundleID: "com.apple.finder")
        #expect(true)
    }
}
```

> 注意:本测试只走孤儿扫描,不扫真实 `/Applications`(生产装配的应用根不可注入到测试目录,扫描真实盘只读也无断言价值)。

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter UninstallServicesTests`
Expected: FAIL(编译错误:`cannot find 'UninstallServices' in scope`)。

- [ ] **Step 3: 实现**

`Sources/AppCore/UninstallServices.swift`:

```swift
import Foundation
import AppKit
import CleanKit
import UninstallKit

/// 运行中判定:NSRunningApplication 的类方法线程安全,无需主线程。
public struct NSRunningAppChecker: RunningAppChecking {
    public init() {}
    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// LaunchServices 侧:NSWorkspace 是 @MainActor 隔离的,故整体收在主线程;
/// 协议方法是 async,调用方 await 时自动切换。
@MainActor
public struct WorkspaceBundleResolver: InstalledBundleResolving {
    public init() {}
    public func isResolvable(_ bundleID: String) async -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

/// 生产装配:主目录可注入(测试传临时目录)。
public enum UninstallServices {
    @MainActor
    public static func make(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
        -> (discovery: AppDiscovering, locator: LeftoverLocating, orphans: OrphanScanning) {
        let roots = [URL(fileURLWithPath: "/Applications"),
                     home.appendingPathComponent("Applications", isDirectory: true)]
        return (AppDiscovery(appRoots: roots, running: NSRunningAppChecker()),
                LeftoverLocator(home: home),
                OrphanScanner(home: home, resolver: WorkspaceBundleResolver()))
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter UninstallServicesTests`
Expected: PASS(2 tests)。

- [ ] **Step 5: 提交**

```bash
git add Sources/AppCore/UninstallServices.swift Tests/AppCoreTests/UninstallServicesTests.swift
git commit -m "feat(AppCore): 卸载模块生产适配器——NSWorkspace/NSRunningApplication 与装配"
```

---

### Task 8: UninstallViewModel——发现、详情、卸载流

**Files:**
- Create: `Sources/AppCore/UninstallViewModel.swift`
- Create: `Tests/AppCoreTests/UninstallTestSupport.swift`
- Create: `Tests/AppCoreTests/UninstallViewModelTests.swift`

- [ ] **Step 1: 写测试支撑与失败测试**

`Tests/AppCoreTests/UninstallTestSupport.swift`:

```swift
import Foundation
import CleanKit
import UninstallKit
@testable import AppCore

struct FakeAppDiscovering: AppDiscovering {
    var result: AppDiscoveryResult
    func discover(exclusions: [String],
                  progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult {
        progress(AppDiscoveryProgress(enumeratedCount: result.apps.count))
        return result
    }
}

struct FakeLeftoverLocating: LeftoverLocating {
    var map: [String: [AppLeftover]]
    func leftovers(for app: InstalledApp, exclusions: [String]) async -> [AppLeftover] {
        map[app.bundleID] ?? []
    }
}

struct FakeOrphanScanning: OrphanScanning {
    var result: OrphanScanResult
    func scan(installedBundleIDs: Set<String>, installedAppNames: Set<String>,
              exclusions: [String],
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult {
        progress(OrphanScanProgress(completedLocations: LeftoverLocations.all.count,
                                    totalLocations: LeftoverLocations.all.count))
        return result
    }
}

func makeTestApp(bundleID: String = "com.example.foo", name: String = "Foo",
                 home: URL, size: Int64 = 100, running: Bool = false) -> InstalledApp {
    InstalledApp(bundleID: bundleID, name: name, version: "1.0",
                 appPath: home.appendingPathComponent("Applications/\(name).app").path,
                 sizeBytes: size, isRunning: running)
}

func leftover(_ relative: String, home: URL, size: Int64 = 10,
              safety: LeftoverSafety = .regenerable,
              ownership: LeftoverOwnership = .bundleID,
              locationID: String = "caches") -> AppLeftover {
    AppLeftover(path: home.appendingPathComponent("Library/\(relative)").path,
                sizeBytes: size, safety: safety,
                ownership: ownership, locationID: locationID)
}
```

`Tests/AppCoreTests/UninstallViewModelTests.swift`:

```swift
import Testing
import Foundation
import CleanKit
import UninstallKit
@testable import AppCore

@Suite @MainActor
final class UninstallViewModelTests {
    let home: URL
    let history: JSONHistoryStore

    init() {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raccoon-uvm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        history = JSONHistoryStore(directory: home)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func makeVM(apps: [InstalledApp] = [], leftovers: [String: [AppLeftover]] = [:],
                orphans: OrphanScanResult = .init(orphans: [], failedLocationIDs: []),
                trash: TrashServicing = MockTrash(outcome: .trashed)) -> UninstallViewModel {
        UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: apps, unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: leftovers),
            orphanScanner: FakeOrphanScanning(result: orphans),
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history,
            trash: trash,
            home: home)
    }

    @Test func discoveryTransitionsToListAndFilters() async {
        let a = makeTestApp(bundleID: "com.example.alpha", name: "Alpha", home: home)
        let b = makeTestApp(bundleID: "com.example.beta", name: "Beta", home: home)
        let vm = makeVM(apps: [a, b])
        #expect(vm.phase == .discovering)

        vm.startDiscovery()
        await vm.discoveryTask?.value
        #expect(vm.phase == .list)
        #expect(vm.apps.count == 2)

        vm.searchText = "bet"
        #expect(vm.filteredApps.map(\.bundleID) == ["com.example.beta"])
        vm.searchText = "com.example.alpha"
        #expect(vm.filteredApps.map(\.bundleID) == ["com.example.alpha"])
        vm.searchText = ""
        #expect(vm.filteredApps.count == 2)
    }

    @Test func openDetailDefaultsToRegenerableExactOnly() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        let user = leftover("Application Support/com.example.foo", home: home,
                            safety: .userData, locationID: "app-support")
        let lowRegen = leftover("Logs/Foo", home: home, safety: .regenerable,
                                ownership: .appName, locationID: "logs-name")
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen, user, lowRegen]])

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app)
        await vm.leftoverTask?.value

        #expect(vm.detailAppID == "com.example.foo")
        #expect(vm.leftovers.count == 3)
        #expect(vm.selectedLeftoverPaths == [regen.path])   // 低置信即便可再生也不默认勾选
    }

    @Test func uninstallSubmitsBundleAndSelectedLeftovers() async throws {
        let app = makeTestApp(home: home, size: 100)
        let regen = leftover("Caches/com.example.foo", home: home, size: 10)
        let user = leftover("Application Support/com.example.foo", home: home, size: 20,
                            safety: .userData, locationID: "app-support")
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen, user]], trash: trash)

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall()
        #expect(vm.confirmFlow == .apps)
        vm.uninstall()
        #expect(vm.cleanState == .cleaning)
        await vm.cleanTask?.value

        let calls = await trash.calls
        #expect(calls == [app.appPath, regen.path])          // 用户数据默认未勾选
        guard case .report(let report) = vm.cleanState else { Issue.record("应为 report"); return }
        #expect(report.freedBytes == 110)
        #expect(vm.apps.isEmpty)                             // 本体已清理 → 移出列表
        #expect(vm.detailAppID == nil)
        #expect(try history.loadAll().count == 1)
        #expect(vm.lastCleanup?.freedBytes == 110)
    }

    @Test func skippedBundleKeepsAppAndCleanedLeftoversConverge() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen]],
                        trash: MockTrash(outcome: .trashed, skippedFor: [app.appPath]))
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall()
        await vm.cleanTask?.value

        #expect(vm.apps.map(\.bundleID) == ["com.example.foo"])   // 本体被跳过 → 留列表
        #expect(vm.leftovers.isEmpty)                            // 关联数据已进废纸篓 → 收敛
        #expect(vm.selectedLeftoverPaths.isEmpty)
        guard case .report(let report) = vm.cleanState else { Issue.record(); return }
        #expect(report.skipped.map(\.path) == [app.appPath])
        #expect(report.freedBytes == 10)
    }

    @Test func returnFromReportGoesBackToList() async {
        let app = makeTestApp(home: home)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": []])
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall(); await vm.cleanTask?.value
        vm.returnFromReport()
        #expect(vm.cleanState == nil)
        #expect(vm.phase == .list)
        #expect(vm.detailAppID == nil)
    }

    // 安全锚点:上游若塞入越界路径,提交前必须被作用域白名单剔除
    @Test func scopeWhitelistDropsRoguePaths() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen]], trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        let rogue = home.appendingPathComponent("Library/Preferences/com.example.foo.plist").path
        vm.selectedLeftoverPaths.insert(rogue)
        vm.requestUninstall(); vm.uninstall()
        await vm.cleanTask?.value
        let calls = await trash.calls
        #expect(calls == [app.appPath, regen.path])
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter UninstallViewModelTests`
Expected: FAIL(编译错误:`cannot find 'UninstallViewModel' in scope`)。

- [ ] **Step 3: 实现**

`Sources/AppCore/UninstallViewModel.swift`:

```swift
import Foundation
import Observation
import CleanKit
import UninstallKit
import os

@MainActor
@Observable
public final class UninstallViewModel {
    public enum Phase: Equatable { case discovering, list, failed(String) }
    public enum OrphanPhase: Equatable { case idle, scanning, results }
    public enum CleanState: Equatable { case cleaning, report(CleanReport) }
    public enum CleanFlow: String, Equatable, Sendable, Identifiable {
        case apps, orphans
        public var id: String { rawValue }
    }
    public enum Tab: String, CaseIterable, Identifiable {
        case apps, orphans
        public var id: String { rawValue }
    }

    public private(set) var phase: Phase = .discovering
    public private(set) var apps: [InstalledApp] = []
    public private(set) var unreadableCount = 0
    public private(set) var discoveryProgress = AppDiscoveryProgress(enumeratedCount: 0)
    public var searchText = ""
    public var detailAppID: String?
    public var tab: Tab = .apps

    public private(set) var leftovers: [AppLeftover] = []
    public var selectedLeftoverPaths: Set<String> = []

    public private(set) var orphanPhase: OrphanPhase = .idle
    public private(set) var orphans: [AppLeftover] = []
    public var selectedOrphanPaths: Set<String> = []
    public private(set) var orphanProgress = OrphanScanProgress(completedLocations: 0, totalLocations: 0)
    public private(set) var failedLocationIDs: Set<String> = []

    public private(set) var cleanState: CleanState?
    public private(set) var cleanFlow: CleanFlow?
    public private(set) var cleanProgress = CleanProgress(done: 0, total: 0)
    public private(set) var lastCleanup: CleanReport?
    public var confirmFlow: CleanFlow?

    public let exclusions: ExclusionsStore
    public let history: HistoryStoring
    public let trash: TrashServicing
    let discovery: AppDiscovering
    let locator: LeftoverLocating
    let orphanScanner: OrphanScanning
    let scope: LeftoverScope

    var discoveryTask: Task<Void, Never>?
    var leftoverTask: Task<Void, Never>?
    var orphanTask: Task<Void, Never>?
    var cleanTask: Task<Void, Never>?
    private var hasDiscovered = false

    public init(discovery: AppDiscovering, locator: LeftoverLocating, orphanScanner: OrphanScanning,
                exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService(),
                home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.discovery = discovery
        self.locator = locator
        self.orphanScanner = orphanScanner
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
        self.scope = LeftoverScope(home: home)
    }

    // MARK: - 发现

    public func startDiscovery(force: Bool = false) {
        if !force { guard !hasDiscovered else { return } }
        guard discoveryTask == nil else { return }
        hasDiscovered = true
        phase = .discovering
        apps = []; unreadableCount = 0
        detailAppID = nil; leftovers = []; selectedLeftoverPaths = []
        discoveryProgress = AppDiscoveryProgress(enumeratedCount: 0)
        let exclusionsSnapshot = exclusions.exclusions
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.discovery.discover(exclusions: exclusionsSnapshot) { [weak self] p in
                    Task { @MainActor [weak self] in self?.discoveryProgress = p }
                }
                guard !Task.isCancelled else { return }
                self.apps = result.apps
                self.unreadableCount = result.unreadableCount
                self.phase = .list
            } catch is CancellationError {
                self.phase = .list
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
            self.discoveryTask = nil
        }
    }

    public var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    public var focusedApp: InstalledApp? {
        guard let detailAppID else { return nil }
        return apps.first { $0.bundleID == detailAppID }
    }

    // MARK: - 详情与勾选

    public func openDetail(_ app: InstalledApp) {
        detailAppID = app.bundleID
        leftovers = []
        selectedLeftoverPaths = []
        leftoverTask?.cancel()
        let exclusionsSnapshot = exclusions.exclusions
        leftoverTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.locator.leftovers(for: app, exclusions: exclusionsSnapshot)
            guard !Task.isCancelled else { return }
            self.leftovers = items
            self.selectedLeftoverPaths = Set(items
                .filter { $0.ownership == .bundleID && $0.safety == .regenerable }
                .map(\.path))
        }
    }

    public var selectedLeftoverItems: [AppLeftover] {
        leftovers.filter { selectedLeftoverPaths.contains($0.path) }
    }

    public func toggleLeftover(_ path: String) {
        if selectedLeftoverPaths.contains(path) { selectedLeftoverPaths.remove(path) }
        else { selectedLeftoverPaths.insert(path) }
    }

    public func selectAllLeftovers() { selectedLeftoverPaths = Set(leftovers.map(\.path)) }
    public func selectNoneLeftovers() { selectedLeftoverPaths = [] }

    /// 卸载提交口径:本体固定 + 已勾选且通过作用域白名单的关联数据。
    public var uninstallItems: [CleanItem] {
        guard let app = focusedApp else { return [] }
        let chosen = selectedLeftoverItems
            .filter { scope.isAllowed($0.path) }
            .map { CleanItem(path: $0.path, sizeBytes: $0.sizeBytes) }
        return [CleanItem(path: app.appPath, sizeBytes: app.sizeBytes)] + chosen
    }

    public var uninstallBytes: Int64 { uninstallItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    // MARK: - 卸载执行

    public func requestUninstall() {
        guard cleanState == nil, !uninstallItems.isEmpty else { return }
        confirmFlow = .apps
    }

    public func cancelConfirm() { confirmFlow = nil }

    public func uninstall() {
        guard confirmFlow == .apps else { return }
        let items = uninstallItems
        guard !items.isEmpty else { return }
        runClean(items, flow: .apps)
    }

    private func runClean(_ items: [CleanItem], flow: CleanFlow) {
        confirmFlow = nil
        cleanState = .cleaning
        cleanFlow = flow
        cleanProgress = CleanProgress(done: 0, total: items.count)
        // 清理时重建保护层(取此刻最新排除清单),与扫描/定位处的实例有意分离,语义须一致
        let protection = ProtectionStore(userExclusions: exclusions.exclusions)
        let executor = CleanExecutor(trash: trash, protection: protection)
        cleanTask = Task { [weak self, history] in
            let report = await executor.clean(items) { done, total in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = CleanProgress(done: done, total: total)
                }
            }
            do { try history.append(report) }
            catch {
                Logger(subsystem: "com.raccooncleaner.Raccoon", category: "history")
                    .error("history append failed: \(String(describing: error))")
            }
            self?.applyCleanOutcome(report, submitted: items, flow: flow)
        }
    }

    /// 与一期同名口径:已清理 = 提交路径 − skipped 路径;跳过项仍在磁盘,必须留在清单里。
    private func applyCleanOutcome(_ report: CleanReport, submitted: [CleanItem], flow: CleanFlow) {
        let gone = Set(submitted.map(\.path)).subtracting(report.skipped.map(\.path))
        switch flow {
        case .apps:
            if let app = focusedApp, gone.contains(app.appPath) {
                apps.removeAll { $0.bundleID == app.bundleID }
                detailAppID = nil
                leftovers = []
                selectedLeftoverPaths = []
            } else {
                leftovers.removeAll { gone.contains($0.path) }
                selectedLeftoverPaths.subtract(gone)
            }
        case .orphans:
            orphans.removeAll { gone.contains($0.path) }
            selectedOrphanPaths.subtract(gone)
        }
        loadLastCleanup()
        cleanState = .report(report)
    }

    public func returnFromReport() {
        guard case .report = cleanState else { return }
        cleanState = nil
        if cleanFlow == .apps { detailAppID = nil }
    }

    public var remainingBytes: Int64 {
        if cleanFlow == .apps {
            return leftovers.reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        if cleanFlow == .orphans {
            return orphans.reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        return 0
    }

    public var remainingCount: Int {
        if cleanFlow == .apps { return leftovers.count }
        if cleanFlow == .orphans { return orphans.count }
        return 0
    }

    public func loadLastCleanup() {
        lastCleanup = (try? history.loadAll())?.max { $0.date < $1.date }
    }
}
```

> 注:孤儿扫描相关成员(`scanOrphans()` 等)在 Task 9 补齐;本任务先让卸载流可编译、可测。

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter UninstallViewModelTests`
Expected: PASS(6 tests)。

- [ ] **Step 5: 提交**

```bash
git add Sources/AppCore/UninstallViewModel.swift Tests/AppCoreTests/UninstallTestSupport.swift Tests/AppCoreTests/UninstallViewModelTests.swift
git commit -m "feat(AppCore): 卸载页状态机——发现、详情分级默认勾选、卸载与收敛"
```

---

### Task 9: UninstallViewModel——孤儿残留流

**Files:**
- Modify: `Sources/AppCore/UninstallViewModel.swift`
- Modify: `Tests/AppCoreTests/UninstallViewModelTests.swift`

- [ ] **Step 1: 追加失败测试**

在 `UninstallViewModelTests` 类内追加:

```swift
    @Test func orphanScanDefaultsToHighConfidenceRegenerable() async {
        let highRegen = leftover("Caches/com.gone.app", home: home)
        let highUser = leftover("Application Support/com.gone.app", home: home,
                                safety: .userData, locationID: "app-support")
        let low = leftover("Application Support/Old App", home: home, safety: .userData,
                           ownership: .appName, locationID: "app-support-name")
        let vm = makeVM(orphans: .init(orphans: [highRegen, highUser, low], failedLocationIDs: ["containers"]))

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans()
        #expect(vm.orphanPhase == .scanning)
        await vm.orphanTask?.value

        #expect(vm.orphanPhase == .results)
        #expect(vm.orphans.count == 3)
        #expect(vm.selectedOrphanPaths == [highRegen.path])
        #expect(vm.failedLocationIDs == ["containers"])
        #expect(vm.orphanProgress.totalLocations > 0)
    }

    @Test func cleanOrphansConvergesOnlyCleanedSubset() async {
        let a = leftover("Caches/com.a.app", home: home)
        let b = leftover("Caches/com.b.app", home: home)
        let trash = MockTrash(outcome: .trashed, skippedFor: [b.path])
        let vm = makeVM(orphans: .init(orphans: [a, b], failedLocationIDs: []), trash: trash)

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans(); await vm.orphanTask?.value
        vm.selectedOrphanPaths = [a.path, b.path]
        vm.requestCleanOrphans()
        #expect(vm.confirmFlow == .orphans)
        vm.cleanOrphans()
        await vm.cleanTask?.value

        #expect(vm.orphans.map(\.path) == [b.path])   // 跳过的仍在磁盘
        #expect(vm.selectedOrphanPaths == [b.path])
        guard case .report = vm.cleanState else { Issue.record("应为 report"); return }
        #expect(vm.remainingCount == 1)
        vm.returnFromReport()
        #expect(vm.orphanPhase == .results)
        #expect(vm.cleanState == nil)
    }

    @Test func cancelOrphanScanReturnsToIdle() async {
        let vm = makeVM()
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans()
        vm.cancelOrphanScan()
        #expect(vm.orphanPhase == .idle)
        await vm.orphanTask?.value
        #expect(vm.orphanPhase == .idle)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter UninstallViewModelTests`
Expected: FAIL(编译错误:`value of type 'UninstallViewModel' has no member 'scanOrphans'` 等)。

- [ ] **Step 3: 在视图模型内补齐孤儿流**

在 `UninstallViewModel` 的 `returnFromReport()` 之后追加:

```swift
    // MARK: - 孤儿残留

    public var selectedOrphanItems: [AppLeftover] {
        orphans.filter { selectedOrphanPaths.contains($0.path) }
    }

    public func toggleOrphan(_ path: String) {
        if selectedOrphanPaths.contains(path) { selectedOrphanPaths.remove(path) }
        else { selectedOrphanPaths.insert(path) }
    }

    public func selectAllOrphans() { selectedOrphanPaths = Set(orphans.map(\.path)) }
    public func selectNoneOrphans() { selectedOrphanPaths = [] }

    public func scanOrphans() {
        guard orphanPhase != .scanning else { return }
        orphanPhase = .scanning
        orphans = []; selectedOrphanPaths = []; failedLocationIDs = []
        orphanProgress = OrphanScanProgress(completedLocations: 0,
                                            totalLocations: LeftoverLocations.all.count)
        let ids = Set(apps.map(\.bundleID))
        let names = Set(apps.map(\.name))
        let exclusionsSnapshot = exclusions.exclusions
        orphanTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.orphanScanner.scan(
                installedBundleIDs: ids,
                installedAppNames: names,
                exclusions: exclusionsSnapshot
            ) { [weak self] p in
                Task { @MainActor [weak self] in self?.orphanProgress = p }
            }
            guard !Task.isCancelled else { return }
            self.orphans = result.orphans.sorted { $0.sizeBytes > $1.sizeBytes }
            self.selectedOrphanPaths = Set(self.orphans
                .filter { $0.ownership == .bundleID && $0.safety == .regenerable }
                .map(\.path))
            self.failedLocationIDs = result.failedLocationIDs
            self.orphanPhase = .results
        }
    }

    public func cancelOrphanScan() {
        orphanTask?.cancel()
        orphanPhase = .idle
    }

    public func requestCleanOrphans() {
        guard cleanState == nil, !orphanCleanItems.isEmpty else { return }
        confirmFlow = .orphans
    }

    public func cleanOrphans() {
        guard confirmFlow == .orphans else { return }
        let items = orphanCleanItems
        guard !items.isEmpty else { return }
        runClean(items, flow: .orphans)
    }

    private var orphanCleanItems: [CleanItem] {
        selectedOrphanItems
            .filter { scope.isAllowed($0.path) }
            .map { CleanItem(path: $0.path, sizeBytes: $0.sizeBytes) }
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter UninstallViewModelTests`
Expected: PASS(9 tests)。

- [ ] **Step 5: 全量回归**

Run: `Scripts/test.sh`
Expected: 全绿(原 81 + 新增用例)。

- [ ] **Step 6: 提交**

```bash
git add Sources/AppCore/UninstallViewModel.swift Tests/AppCoreTests/UninstallViewModelTests.swift
git commit -m "feat(AppCore): 孤儿残留流——扫描、默认勾选、取消与收敛"
```

---

### Task 10: 抽出共用报告视图(一期行为不变)

**Files:**
- Create: `Sources/Raccoon/CleanReportView.swift`
- Modify: `Sources/Raccoon/ReportView.swift`

- [ ] **Step 1: 写共用视图**

`Sources/Raccoon/CleanReportView.swift`:

```swift
import SwiftUI
import CleanKit

/// 共用清理报告页(一期清理 / 卸载 / 残留清理三个入口同一形态)。
/// 有剩余项时「返回列表」是主按钮;全部清完时「再扫一次」是主按钮(与一期一致)。
struct CleanReportView: View {
    let report: CleanReport
    let remainingCount: Int
    let remainingBytes: Int64
    let onBack: (() -> Void)?
    let onRescan: (() -> Void)?

    func reasonText(_ code: String) -> String {
        let key = "reason.\(code)"
        let value = loc(key)
        return value == key ? loc("reason.other") : value
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text(loc("report.done")).font(.title2).bold()
            // freed 口径:仅统计成功移入废纸篓的字节;vanished(应用抢先删)与快照不计入
            Text(loc("report.freed", byteText(report.freedBytes))).monospacedDigit()
            Text(loc("report.trashed", report.trashedCount)).monospacedDigit().foregroundStyle(.secondary)
            if report.vanishedCount > 0 {
                Text(loc("report.vanished", report.vanishedCount)).monospacedDigit().foregroundStyle(.secondary)
            }
            if report.snapshotCount > 0 {
                Text(loc("report.snapshots", report.snapshotCount)).monospacedDigit().foregroundStyle(.secondary)
            }
            if !report.skipped.isEmpty {
                DisclosureGroup(loc("report.skipped", report.skipped.count)) {
                    ForEach(report.skipped, id: \.path) { item in
                        HStack {
                            Text(item.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(reasonText(item.reason)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
            // 部分清理后剩余项仍在结果里,必须说出来:否则用户只能靠「再扫一次」重新发现它们
            if remainingCount > 0 {
                Text(loc("report.remaining", remainingCount, byteText(remainingBytes)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                // 还有剩余项时回列表是主路径(不必重扫即可接着清);全部清完时只剩再扫一次
                if remainingCount > 0 {
                    if let onBack {
                        Button(loc("report.backToList")) { onBack() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let onRescan {
                        Button(loc("report.again")) { onRescan() }
                    }
                } else if let onRescan {
                    Button(loc("report.again")) { onRescan() }
                        .buttonStyle(.borderedProminent)
                } else if let onBack {
                    Button(loc("report.backToList")) { onBack() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: 一期报告页改为使用共用视图**

完整替换 `Sources/Raccoon/ReportView.swift`:

```swift
import SwiftUI
import CleanKit
import AppCore

struct ReportView: View {
    let report: CleanReport
    let vm: ScanViewModel

    var body: some View {
        CleanReportView(
            report: report,
            remainingCount: vm.hits.count,
            remainingBytes: vm.remainingBytes,
            onBack: { vm.returnToResults() },
            onRescan: { vm.dismissReport(); vm.startScan() })
    }
}
```

- [ ] **Step 3: 构建并回归一期行为**

Run:

```bash
swift build
Scripts/test.sh
```

Expected: 构建成功;测试全绿(行为无变化)。

- [ ] **Step 4: 提交**

```bash
git add Sources/Raccoon/CleanReportView.swift Sources/Raccoon/ReportView.swift
git commit -m "refactor(Raccoon): 抽出共用清理报告视图,一期行为不变"
```

---

### Task 11: 卸载模块 UI(列表/详情/残留/确认)与文案

**Files:**
- Create: `Sources/Raccoon/UninstallHomeView.swift`
- Create: `Sources/Raccoon/AppDetailView.swift`
- Create: `Sources/Raccoon/OrphanScanView.swift`
- Create: `Sources/Raccoon/UninstallConfirmView.swift`
- Modify: `Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/Raccoon/Resources/en.lproj/Localizable.strings`

> 本任务只新增视图与文案,不接线 RootView;四个视图文件可独立编译(`LeftoverRow`/`LeftoverGroup` 在 `AppDetailView.swift` 内定义,同 target 可见)。

- [ ] **Step 1: 加中英文案(两份键集必须 1:1)**

在 `zh-Hans` 文件末尾追加:

```strings
"uninstall.tab.apps" = "应用";
"uninstall.tab.orphans" = "残留";
"uninstall.searchPlaceholder" = "搜索应用";
"uninstall.discovering" = "正在查找应用…";
"uninstall.discovered" = "已发现 %d 个应用";
"uninstall.empty" = "没有找到应用";
"uninstall.unreadable" = "%d 个应用无法识别，已跳过";
"uninstall.failed" = "查找应用失败：%@";
"uninstall.group.bundle" = "应用本体";
"uninstall.bundleFixed" = "应用本体固定包含，不可取消";
"uninstall.group.regenerable" = "可再生的关联数据";
"uninstall.group.userData" = "需确认的关联数据";
"uninstall.group.unconfirmed" = "未确认归属";
"uninstall.tag.unconfirmed" = "未确认";
"uninstall.noLeftovers" = "没有发现关联数据";
"uninstall.version" = "版本 %@";
"uninstall.button" = "卸载…";
"uninstall.confirm.title" = "确认卸载";
"uninstall.confirm.button" = "卸载并移入废纸篓";
"uninstall.confirm.userDataSection" = "以下数据可能包含你的文件或登录状态：";
"orphans.hint" = "查找已卸载应用留下的数据目录。只扫描已知位置；文档、偏好设置等受保护位置不在范围内。";
"orphans.scan" = "扫描残留…";
"orphans.scanning" = "正在扫描残留…（%d/%d 个位置）";
"orphans.empty" = "没有发现残留";
"orphans.group.confirmed" = "高置信残留";
"orphans.group.unconfirmed" = "未确认归属";
"orphans.failedLocations" = "部分位置未能扫描：%@";
"orphans.clean" = "清理残留…";
"orphans.clean.do" = "清理并移入废纸篓";
"orphans.confirm.title" = "确认清理残留";
"orphans.defaultUncheckedHint" = "未确认归属的项默认不勾选，请确认后再选择";
```

在 `en` 文件末尾追加对应键:

```strings
"uninstall.tab.apps" = "Applications";
"uninstall.tab.orphans" = "Leftovers";
"uninstall.searchPlaceholder" = "Search applications";
"uninstall.discovering" = "Looking for applications…";
"uninstall.discovered" = "%d applications found";
"uninstall.empty" = "No applications found";
"uninstall.unreadable" = "%d applications could not be read and were skipped";
"uninstall.failed" = "Failed to load applications: %@";
"uninstall.group.bundle" = "Application";
"uninstall.bundleFixed" = "The application itself is always included";
"uninstall.group.regenerable" = "Regenerable data";
"uninstall.group.userData" = "Data that needs your review";
"uninstall.group.unconfirmed" = "Unconfirmed ownership";
"uninstall.tag.unconfirmed" = "Unconfirmed";
"uninstall.noLeftovers" = "No associated data found";
"uninstall.version" = "Version %@";
"uninstall.button" = "Uninstall…";
"uninstall.confirm.title" = "Confirm Uninstall";
"uninstall.confirm.button" = "Uninstall and Move to Trash";
"uninstall.confirm.userDataSection" = "The following data may contain your documents or sign-in state:";
"orphans.hint" = "Find data left behind by removed applications. Only known locations are scanned; protected places such as Documents and Preferences are out of scope.";
"orphans.scan" = "Scan for Leftovers…";
"orphans.scanning" = "Scanning for leftovers… (%d/%d locations)";
"orphans.empty" = "No leftovers found";
"orphans.group.confirmed" = "Confirmed leftovers";
"orphans.group.unconfirmed" = "Unconfirmed ownership";
"orphans.failedLocations" = "Some locations could not be scanned: %@";
"orphans.clean" = "Clean Leftovers…";
"orphans.clean.do" = "Clean and Move to Trash";
"orphans.confirm.title" = "Confirm Leftover Cleanup";
"orphans.defaultUncheckedHint" = "Items with unconfirmed ownership stay unchecked. Review before selecting.";
```

> 复用既有键:`detail.appRunning`(运行中标签)、`detail.cautious`(需确认数据标签)、`detail.selectAll` / `detail.selectNone`、`detail.selected`、`common.cancel`、`common.clean`、`home.retry`。

- [ ] **Step 2: 写卸载主页与应用列表**

`Sources/Raccoon/UninstallHomeView.swift`:

```swift
import SwiftUI
import AppCore
import UninstallKit

struct UninstallHomeView: View {
    @Bindable var vm: UninstallViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let cleanState = vm.cleanState {
                    cleanContent(cleanState)
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $vm.tab) {
                            Text(loc("uninstall.tab.apps")).tag(UninstallViewModel.Tab.apps)
                            Text(loc("uninstall.tab.orphans")).tag(UninstallViewModel.Tab.orphans)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(12)
                        Divider()
                        switch vm.tab {
                        case .apps: appsPane
                        case .orphans: OrphanScanView(vm: vm)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.uninstall"))
            .onAppear { vm.startDiscovery() }
            .navigationDestination(item: $vm.detailAppID) { id in
                if let app = vm.apps.first(where: { $0.bundleID == id }) {
                    AppDetailView(vm: vm, app: app)
                }
            }
        }
        .sheet(item: $vm.confirmFlow) { flow in
            UninstallConfirmView(vm: vm, flow: flow)
        }
    }

    @ViewBuilder
    var appsPane: some View {
        switch vm.phase {
        case .discovering:
            VStack(spacing: 12) {
                ProgressView()
                Text(loc("uninstall.discovering")).foregroundStyle(.secondary)
                Text(loc("uninstall.discovered", vm.discoveryProgress.enumeratedCount))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(.yellow)
                Text(loc("uninstall.failed", message)).multilineTextAlignment(.center)
                Button(loc("home.retry")) { vm.startDiscovery(force: true) }
            }
        case .list:
            VStack(spacing: 0) {
                TextField(loc("uninstall.searchPlaceholder"), text: $vm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                if vm.filteredApps.isEmpty {
                    Text(loc("uninstall.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.filteredApps) { app in
                            AppRowView(app: app)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.openDetail(app) }
                        }
                    }
                }
                if vm.unreadableCount > 0 {
                    Text(loc("uninstall.unreadable", vm.unreadableCount))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    func cleanContent(_ state: UninstallViewModel.CleanState) -> some View {
        switch state {
        case .cleaning:
            VStack(spacing: 12) {
                ProgressView(value: Double(vm.cleanProgress.done),
                             total: Double(max(vm.cleanProgress.total, 1)))
                    .frame(maxWidth: 320)
                Text(loc("common.clean")).foregroundStyle(.secondary)
            }
        case .report(let report):
            CleanReportView(
                report: report,
                remainingCount: vm.remainingCount,
                remainingBytes: vm.remainingBytes,
                onBack: { vm.returnFromReport() },
                onRescan: {
                    let flow = vm.cleanFlow
                    vm.returnFromReport()
                    if flow == .orphans { vm.scanOrphans() }
                    else { vm.startDiscovery(force: true) }
                })
        }
    }
}

struct AppRowView: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: app.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.version.map { loc("uninstall.version", $0) } ?? app.bundleID)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.isRunning { TagView(text: loc("detail.appRunning"), color: .yellow) }
            Text(byteText(app.sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
```

- [ ] **Step 3: 写应用详情页(含可复用行/分组类型)**

`Sources/Raccoon/AppDetailView.swift`:

```swift
import SwiftUI
import AppCore
import UninstallKit

struct AppDetailView: View {
    @Bindable var vm: UninstallViewModel
    let app: InstalledApp

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    HStack(spacing: 10) {
                        AppIconView(bundleID: app.bundleID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.version.map { loc("uninstall.version", $0) } ?? app.bundleID)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.isRunning { TagView(text: loc("detail.appRunning"), color: .yellow) }
                        Text(byteText(app.sizeBytes))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Label(loc("uninstall.bundleFixed"), systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text(loc("uninstall.group.bundle"))
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            LeftoverRow(item: item,
                                        selected: vm.selectedLeftoverPaths.contains(item.path)) {
                                vm.toggleLeftover(item.path)
                            }
                        }
                    } header: {
                        Text(loc(group.titleKey))
                    }
                }

                if vm.leftovers.isEmpty {
                    Section {
                        Text(loc("uninstall.noLeftovers")).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            bottomBar
        }
        .navigationTitle(app.name)
        .toolbar {
            Button(loc("detail.selectAll")) { vm.selectAllLeftovers() }
            Button(loc("detail.selectNone")) { vm.selectNoneLeftovers() }
        }
    }

    var groups: [LeftoverGroup] {
        let exact = vm.leftovers.filter { $0.ownership == .bundleID }
        let unconfirmed = vm.leftovers.filter { $0.ownership == .appName }
        var out: [LeftoverGroup] = []
        let regenerable = exact.filter { $0.safety == .regenerable }
        let userData = exact.filter { $0.safety == .userData }
        if !regenerable.isEmpty {
            out.append(.init(id: "regen", titleKey: "uninstall.group.regenerable", items: regenerable))
        }
        if !userData.isEmpty {
            out.append(.init(id: "user", titleKey: "uninstall.group.userData", items: userData))
        }
        if !unconfirmed.isEmpty {
            out.append(.init(id: "unconfirmed", titleKey: "uninstall.group.unconfirmed", items: unconfirmed))
        }
        return out
    }

    var bottomBar: some View {
        HStack {
            // N/X 均含应用本体:本体固定随卸载一起提交,数字必须与提交范围一致
            Text(loc("detail.selected",
                     vm.selectedLeftoverItems.count + 1,
                     byteText(app.sizeBytes + vm.selectedLeftoverItems.reduce(Int64(0)) { $0 + $1.sizeBytes })))
                .monospacedDigit()
            Spacer()
            Button(loc("uninstall.button")) { vm.requestUninstall() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.cleanState != nil)
        }
        .padding(12)
    }
}

struct LeftoverGroup: Identifiable {
    let id: String
    let titleKey: String
    let items: [AppLeftover]
}

struct LeftoverRow: View {
    let item: AppLeftover
    let selected: Bool
    let onToggle: () -> Void

    var title: String { item.path.split(separator: "/").last.map(String.init) ?? item.path }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(String(), isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .labelsHidden()
                .accessibilityLabel(item.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(item.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.ownership == .appName {
                TagView(text: loc("uninstall.tag.unconfirmed"), color: .orange)
            } else if item.safety == .userData {
                TagView(text: loc("detail.cautious"), color: .orange)
            }
            Text(byteText(item.sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}
```

- [ ] **Step 4: 写残留页**

`Sources/Raccoon/OrphanScanView.swift`:

```swift
import SwiftUI
import AppCore
import UninstallKit

struct OrphanScanView: View {
    @Bindable var vm: UninstallViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch vm.orphanPhase {
            case .idle:
                VStack(spacing: 16) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 40)).foregroundStyle(.tint)
                    Text(loc("orphans.hint"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    Button(loc("orphans.scan")) { vm.scanOrphans() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:
                VStack(spacing: 12) {
                    ProgressView(
                        value: Double(vm.orphanProgress.completedLocations),
                        total: Double(max(vm.orphanProgress.totalLocations, 1)))
                        .frame(maxWidth: 320)
                    Text(loc("orphans.scanning",
                             vm.orphanProgress.completedLocations,
                             vm.orphanProgress.totalLocations))
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button(loc("common.cancel")) { vm.cancelOrphanScan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .results:
                results
            }
        }
    }

    var results: some View {
        VStack(spacing: 0) {
            if vm.orphans.isEmpty {
                Text(loc("orphans.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                LeftoverRow(item: item,
                                            selected: vm.selectedOrphanPaths.contains(item.path)) {
                                    vm.toggleOrphan(item.path)
                                }
                            }
                        } header: {
                            Text(loc(group.titleKey))
                        }
                    }
                }
            }
            if !vm.failedLocationIDs.isEmpty {
                Text(loc("orphans.failedLocations", vm.failedLocationIDs.sorted().joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Divider()
            bottomBar
        }
        .toolbar {
            Button(loc("detail.selectAll")) { vm.selectAllOrphans() }
            Button(loc("detail.selectNone")) { vm.selectNoneOrphans() }
        }
    }

    var groups: [LeftoverGroup] {
        let confirmed = vm.orphans.filter { $0.ownership == .bundleID }
        let unconfirmed = vm.orphans.filter { $0.ownership == .appName }
        var out: [LeftoverGroup] = []
        if !confirmed.isEmpty {
            out.append(.init(id: "confirmed", titleKey: "orphans.group.confirmed", items: confirmed))
        }
        if !unconfirmed.isEmpty {
            out.append(.init(id: "unconfirmed", titleKey: "orphans.group.unconfirmed", items: unconfirmed))
        }
        return out
    }

    var bottomBar: some View {
        HStack {
            Text(loc("detail.selected",
                     vm.selectedOrphanItems.count,
                     byteText(vm.selectedOrphanItems.reduce(Int64(0)) { $0 + $1.sizeBytes })))
                .monospacedDigit()
            if vm.selectedOrphanItems.contains(where: { $0.ownership == .appName }) {
                Text(loc("orphans.defaultUncheckedHint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc("orphans.clean")) { vm.requestCleanOrphans() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedOrphanItems.isEmpty || vm.cleanState != nil)
        }
        .padding(12)
    }
}
```

- [ ] **Step 5: 写确认弹窗**

`Sources/Raccoon/UninstallConfirmView.swift`:

```swift
import SwiftUI
import AppCore
import UninstallKit

struct UninstallConfirmView: View {
    let vm: UninstallViewModel
    let flow: UninstallViewModel.CleanFlow

    var pickedItems: [AppLeftover] {
        flow == .apps ? vm.selectedLeftoverItems : vm.selectedOrphanItems
    }
    var bundleCount: Int { flow == .apps ? 1 : 0 }
    var bundleBytes: Int64 { flow == .apps ? (vm.focusedApp?.sizeBytes ?? 0) : 0 }
    var totalCount: Int { pickedItems.count + bundleCount }
    var totalBytes: Int64 { pickedItems.reduce(bundleBytes) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc(flow == .apps ? "uninstall.confirm.title" : "orphans.confirm.title"))
                .font(.title3).bold()
            Text(loc("detail.selected", totalCount, byteText(totalBytes)))
                .monospacedDigit()

            if flow == .apps, let app = vm.focusedApp, app.isRunning {
                Label(loc("confirm.runningWarning"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }

            let userData = pickedItems.filter { $0.safety == .userData }
            if !userData.isEmpty {
                Divider()
                Text(loc("uninstall.confirm.userDataSection"))
                    .font(.headline).foregroundStyle(.orange)
                ForEach(userData) { item in
                    Text(item.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            // 删除前最后一道 UI 防线:默认键(⏎)给取消,卸载/清理仅点按触发
            HStack {
                Spacer()
                Button(loc("common.cancel")) { vm.cancelConfirm() }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
                Button(loc(flow == .apps ? "uninstall.confirm.button" : "orphans.clean.do")) {
                    if flow == .apps { vm.uninstall() } else { vm.cleanOrphans() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
```

- [ ] **Step 6: 构建 + 键集一致性**

Run:

```bash
swift build
diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
     <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
```

Expected: 构建成功(新视图未被引用也能编译);`diff` 无输出。

- [ ] **Step 7: 提交**

```bash
git add Sources/Raccoon/UninstallHomeView.swift Sources/Raccoon/AppDetailView.swift \
        Sources/Raccoon/OrphanScanView.swift Sources/Raccoon/UninstallConfirmView.swift \
        Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings \
        Sources/Raccoon/Resources/en.lproj/Localizable.strings
git commit -m "feat(Raccoon): 卸载模块 UI——应用列表/详情、残留页、确认弹窗与文案"
```

---

### Task 12: 启用侧边栏「卸载」模块

**Files:**
- Modify: `Sources/Raccoon/RootView.swift`

- [ ] **Step 1: 完整替换 RootView**

`Sources/Raccoon/RootView.swift`:

```swift
import SwiftUI
import AppCore
import CleanKit

enum Module: String, CaseIterable, Identifiable {
    case cleanup, uninstall, aiCleanup, diskAnalysis, monitor
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .cleanup: "sparkles"
        case .uninstall: "shippingbox"
        case .aiCleanup: "brain"
        case .diskAnalysis: "chart.pie.fill"
        case .monitor: "gauge.with.needle"
        }
    }
    static var availableCases: [Module] { [.cleanup, .uninstall] }
    static var comingSoonCases: [Module] { allCases.filter { !availableCases.contains($0) } }
}

struct RootView: View {
    let exclusions: ExclusionsStore
    // 手写 @State 展开(本机 CLT 工具链缺 libSwiftUIMacros.dylib,见 RaccoonApp.swift 注释)。
    private var _vm: State<ScanViewModel>
    private var _uvm: State<UninstallViewModel>
    private var _selection: State<Module>

    var vm: ScanViewModel {
        get { _vm.wrappedValue }
        nonmutating set { _vm.wrappedValue = newValue }
    }
    var uvm: UninstallViewModel {
        get { _uvm.wrappedValue }
        nonmutating set { _uvm.wrappedValue = newValue }
    }
    var selection: Module {
        get { _selection.wrappedValue }
        nonmutating set { _selection.wrappedValue = newValue }
    }

    @MainActor
    init(exclusions: ExclusionsStore) {
        self.exclusions = exclusions
        let history = JSONHistoryStore()
        let services = UninstallServices.make()
        _vm = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                exclusions: exclusions,
                                                history: history))
        _uvm = State(wrappedValue: UninstallViewModel(discovery: services.discovery,
                                                      locator: services.locator,
                                                      orphanScanner: services.orphans,
                                                      exclusions: exclusions,
                                                      history: history))
        _selection = State(wrappedValue: .cleanup)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: _selection.projectedValue) {
                Section {
                    ForEach(Module.availableCases) { module in
                        Label(loc("module.\(module.rawValue)"), systemImage: module.icon)
                            .tag(module)
                    }
                }
                Section(loc("sidebar.comingSoon")) {
                    ForEach(Module.comingSoonCases) { module in
                        Label(loc("module.\(module.rawValue)"), systemImage: module.icon)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(loc("app.name"))
        } detail: {
            // detail 按选择切换;两个模块各自持有状态机,互不干扰
            switch selection {
            case .uninstall:
                UninstallHomeView(vm: uvm)
            default:
                CleanupHomeView(vm: vm)
                    .onAppear { vm.loadLastCleanup() }
            }
        }
    }
}
```

- [ ] **Step 2: 构建 + 全量测试 + 键集一致性**

Run:

```bash
swift build
Scripts/test.sh
diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
     <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
```

Expected: 构建成功;测试全绿;`diff` 无输出。

- [ ] **Step 3: 提交**

```bash
git add Sources/Raccoon/RootView.swift
git commit -m "feat(Raccoon): 启用侧边栏卸载模块"
```

---

### Task 13: 一期 polish——清理进度接线与 history 上限

**Files:**
- Modify: `Sources/AppCore/ScanViewModel.swift`
- Modify: `Sources/Raccoon/CleanupHomeView.swift`
- Modify: `Sources/CleanKit/CleanReport.swift`
- Modify: `Tests/AppCoreTests/ScanViewModelTests.swift`
- Modify: `Tests/CleanKitTests/HistoryStoreTests.swift`

- [ ] **Step 1: 写失败测试**

`HistoryStoreTests` 类内追加:

```swift
    @Test func keepsOnlyLatest200Reports() throws {
        let dir = makeDir()
        let store = JSONHistoryStore(directory: dir)
        for i in 0..<205 {
            try store.append(CleanReport(date: Date(timeIntervalSince1970: Double(i)),
                                         freedBytes: Int64(i), trashedCount: 1,
                                         vanishedCount: 0, skipped: []))
        }
        let all = try store.loadAll()
        #expect(all.count == 200)
        #expect(all.first?.freedBytes == 5)    // 最早的 5 条被裁剪
        #expect(all.last?.freedBytes == 204)
    }
```

`ScanViewModelTests` 类内追加:

```swift
    // polish:清理进度按 executor 回调回投(已处理/总数)
    @Test func cleanSelected_reportsProgress() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20)],
            summaries: [], permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        #expect(vm.cleanProgress == CleanProgress(done: 0, total: 0))
        vm.cleanSelected()
        #expect(vm.cleanProgress.total == 2)
        await vm.cleanTask?.value
        #expect(vm.cleanProgress == CleanProgress(done: 2, total: 2))
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter HistoryStoreTests`(预期红:205 条未裁剪)
Run: `Scripts/test.sh --filter ScanViewModelTests`(预期红:无 `cleanProgress`)

- [ ] **Step 3: 实现 history 上限**

`Sources/CleanKit/CleanReport.swift` 的 `append` 内,在 `all.append(report)` 后加:

```swift
            // 二期起卸载/残留清理也写同一历史,写入频率上升;保留最近 200 条,防无限增长。
            if all.count > 200 { all.removeFirst(all.count - 200) }
```

- [ ] **Step 4: 接线清理进度**

`ScanViewModel` 增加属性(与 `progress` 相邻):

```swift
    public private(set) var cleanProgress = CleanProgress(done: 0, total: 0)
```

`cleanSelected()` 中,在 `phase = .cleaning` 之后加:

```swift
        cleanProgress = CleanProgress(done: 0, total: items.count)
```

并把 `let report = await executor.clean(items)` 改为:

```swift
            let report = await executor.clean(items) { done, total in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = CleanProgress(done: done, total: total)
                }
            }
```

`CleanupHomeView` 的 `.cleaning` 分支改为:

```swift
                case .cleaning:
                    VStack(spacing: 12) {
                        ProgressView(value: Double(vm.cleanProgress.done),
                                     total: Double(max(vm.cleanProgress.total, 1)))
                            .frame(maxWidth: 320)
                        Text(loc("common.clean")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
```

- [ ] **Step 5: 跑测试确认通过**

Run: `Scripts/test.sh`
Expected: 全绿。

- [ ] **Step 6: 提交**

```bash
git add Sources/AppCore/ScanViewModel.swift Sources/Raccoon/CleanupHomeView.swift \
        Sources/CleanKit/CleanReport.swift Tests/AppCoreTests/ScanViewModelTests.swift \
        Tests/CleanKitTests/HistoryStoreTests.swift
git commit -m "feat(polish): 清理进度确定化接线 + history 保留最近 200 条"
```

---

### Task 14: 文档与 QA 清单

**Files:**
- Modify: `README.md`
- Create: `docs/superpowers/qa/phase2-qa-checklist.md`
- Modify: `docs/superpowers/plans/2026-10-17-raccoon-phase2.md`(勾选进度可选)

- [ ] **Step 1: 跑全量、记录实际用例数**

Run: `Scripts/test.sh`
Expected: 全绿;记录输出末尾 `Test run with <N> tests in <M> suites passed`。后续文档中的数字必须用这个实测值,**不得沿用旧数字**。

- [ ] **Step 2: 更新 README**

按当前 README 结构做最小修改(先 `git diff README.md` 看用户既有改动,保留之):

1. 功能列表加入二期两条:
   - 应用卸载:应用本体 + 分级关联数据一起预览,默认只勾可再生数据
   - 孤儿残留:已卸载应用留在 `~/Library` 的已知位置数据,高置信/未确认归属分组
2. 路线图里「二期」状态由「规划」改为「已实现(待人工 QA)」;「三期」保持规划。
3. 测试段落:`Scripts/test.sh # 全量测试(<N> 用例)`,数字用 Step 1 实测值。
4. 已知限制补一句:`~/Library/Preferences` 与 `~/Library/Cookies` 因一期硬保护整棵覆盖,二期不列出;系统级 `/Library` 残留与任何提权留待三期。

- [ ] **Step 3: 写二期 QA 清单(诚实标注)**

`docs/superpowers/qa/phase2-qa-checklist.md`,按一期清单格式,至少覆盖:

- 自动核验 ✅(证据 = `Scripts/test.sh` 全绿 + CI 绿):
  - 应用发现:Apple 应用排除、一层子目录、同 ID 去重、符号链接越界跳过
  - 分级默认勾选:可再生勾、用户数据不勾、未确认归属不勾
  - 卸载提交 = 本体 + 已勾选;本体被跳过时应用留列表
  - 孤儿默认勾选 = 高置信 + 可再生;跳过项收敛留在结果里
  - 作用域白名单:越界路径不进提交(用例 `scopeWhitelistDropsRoguePaths`)
  - `Preferences`/`Cookies` 硬保护事实断言
- 待人工 ⏳(必须真机,禁止标满足):
  - 卸载一个真实测试应用:本体与勾选数据都出现在废纸篓,可放回;用户数据默认未勾
  - 卸载后列表即时移除;被跳过项留在列表并显示原因
  - 残留扫描在真机发现真实无主残留,分组正确
  - 应用运行中标识与确认弹窗警告
  - 中英切换、浅/深色下新页面无破版
  - 空态/搜索/长路径截断
- 混合项需分列人工/自动两半,不得笼统标 ✅。

- [ ] **Step 4: 提交(含 README 既有格式化改动,并在提交信息注明)**

```bash
git add README.md docs/superpowers/qa/phase2-qa-checklist.md docs/superpowers/plans/2026-10-17-raccoon-phase2.md
git commit -m "docs: 二期文档与 QA 清单(实测用例数);同时纳入 README 既有格式化改动"
```

---

### Task 15: 整体验证与终审

- [ ] **Step 1: 全量验证**

```bash
swift build
Scripts/test.sh
diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
     <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
git status --short
```

Expected: 构建成功;测试全绿;键集 diff 无输出;工作区干净。

- [ ] **Step 2: 安全自查(逐条 grep,贴出结果)**

```bash
grep -rn "removeItem\|unlink" Sources
grep -rn "trashItem" Sources
grep -rn "NSHomeDirectory()" Sources/UninstallKit || true
```

Expected:
- 第一条预期输出**仅 1 行**:`Sources/CleanKit/TrashService.swift:18` 的注释「唯一删除动作:移入废纸篓。绝不 unlink。」,属预期命中;无任何实现调用;`removeItem` 零命中。`removeItem`/`unlink` 的实现调用必须为零。
- `Sources/UninstallKit` 内无删除实现;`trashItem` 唯一实现仍在 `Sources/CleanKit/TrashService.swift:21`。
- `Sources/UninstallKit` 内无 `NSHomeDirectory()`(根目录全部注入;`grep` 无输出)。
- 本地快照清理沿用一期 `tmutil deletelocalsnapshots` 例外,不属于文件删除实现。

- [ ] **Step 3: 终审**

派发一轮独立代码审查(范围:`git diff main...HEAD`),重点:
- 四道门在二期路径上是否都有落点(扫描过滤、executor 复核、分级默认值、trash-only);
- 状态收敛是否覆盖「本体被跳过」「关联数据部分被跳过」「孤儿部分被跳过」;
- L10n 键集 1:1 与全角标点;
- 无越权/提权路径。

- [ ] **Step 4: 收尾汇报**

向用户汇报:实现摘要、测试与构建实测结果、QA 清单中仍待人工的项、以及是否合并/push(等用户指令,勿擅自推送)。

---

## 附:任务依赖顺序

```
Task 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15
```

Task 13 与 8/9 互不冲突,可在 12 之后任意时点执行;Task 14 的用例数必须取自最终全量运行。

## 执行记录(2026-10-17,feat/phase2)

Task 1–13 已完成并通过逐任务规格审 + 质量审;Task 14 文档/QA 由本次提交补齐,Task 15 终审随后完成。当前全量 **183/183** 绿(UninstallKit 66 / ScanKit 40 / CleanKit 27 / AppCore 50),中英 L10n 各 94 键 1:1(键集 diff 为空)。

### 实现期偏差与加固(均经双审确认)

- Task 4:测试夹具按实际 API 调整;补齐原始形态排除、兄弟前缀、根去重/进度用例。
- Task 5:`LeftoverLocator` 增加单一路径组件校验与精确父目录不变量(防 `../` 穿越伪造 safety);排除匹配同时检查原始与解析形态;`LeftoverScope.isLocationContained` 防祖先符号链接把枚举带出 `~/Library`。
- Task 6:目录枚举改为 path 版 + `appendingPathComponent`;安装集合、resolver 查询与后缀匹配统一大小写折叠;Apple 前缀按 ID 与候选双形态检查。
- Task 7:生产装配测试不扫真实 `/Applications`;补充 resolver/checker 用例。
- Task 8:清理后收敛改为无条件差集(`gone = submitted − skipped`);取消发现复位 `hasDiscovered` 且可重试;`runClean` 重入守卫;清理开始即 `detailAppID = nil` 并快照应用本体传给 `applyCleanOutcome`,新增 `lastUninstallBundleRemoved`。
- Task 9:`scanOrphans` 前置守卫 `phase == .list && cleanState == nil`;扫描代数令牌过滤 stale 进度/结果;`defer` 只清当前代数的任务句柄;`cancelOrphanScan`/`cleanOrphans` 守卫;scope 白名单与已安装集合透传均有安全锚点测试。
- Task 10/11:`CleanReportView` 增加可选 `onScanOrphans`(仅 apps、本体已删且有剩余时出现);`reasonText` private、装饰图标 accessibilityHidden;残留页扫描按钮在发现完成前禁用并给出说明/重试;失败位置显示目录名;未确认提示条件改为存在即显示。
- Task 11:确认弹窗取消键改为 `.defaultAction` + `.onExitCommand`(同按钮叠加双 `keyboardShortcut` 实测两键均失效);Task 13 同步修复一期 `ConfirmCleanView`。
- Task 12/13:detail switch 改显式 case,新增模块由编译器强制接线;`JSONHistoryStore` 保留最近 200 条;一期清理进度经 `CleanExecutor` 回调回投(`ScanViewModel.swift` 的 `cleanProgress`)。

### 顺延/可选

- 真机 QA:见 `docs/superpowers/qa/phase2-qa-checklist.md`(自动 10 项、待人工 8 项、混合 5 项)。
- 可选测试强化:一期清理进度中间态(3 项 + 门控 trash,断言中途 `done == 1`);二期清理进度中间态同法补齐;`HistoryStoreTests` 临时目录清理。
- 已知缺口:二期清理进度无专测断言中间态;确认弹窗 Return/Esc 快捷键与 `LeftoverRow` 双触发需真机验证,详见 QA 清单「已知测试缺口」。

Task 14 文档已按文档审修订;文档按第二轮质量审修订了 15.4 的 grep 证据、M3 权限恢复与空态条件、§14 措辞,并同步 Task 15 安全自查预期。后续补修 M3 的权限记录顺序(`efc4dd8`)。

### Task 15 终验结果(2026-10-17)

- **全量验证**:`swift build` 成功;`Scripts/test.sh` **183/183 全绿**(UninstallKit 66 / ScanKit 40 / CleanKit 27 / AppCore 50);L10n 键集 **94:94**,diff 为空;提交前工作区干净。
- **安全自查**:`grep -rn "removeItem\|unlink" Sources` 仅命中 `Sources/CleanKit/TrashService.swift:18` 注释(无实现调用,`removeItem` 零命中);`trashItem` 唯一实现在 `TrashService.swift:21`;`Sources/UninstallKit` 无 `NSHomeDirectory()`;无 AuthorizationExecute/SMJobBless/sudo/NSAppleScript 等提权模式。
- **整体终审**(独立审查 `git diff main...HEAD`):无 Critical、无越界删除、无提权、无 trash-only 破口;四道门与收敛主链路成立。发现 1 条 Important(详情页关联数据无加载态,假空态且确认项数可漂移)及若干 Minor。
- **修复**:`c9ae1ff` 增加 `isLoadingLeftovers` + 提交快照、报告页返回入口、Group Containers 大小写折叠、`scanOrphans` 的 `hasDiscovered` 守卫、详情路径展示、位置目录符号链接最严分级;新增 8 个测试。终审者复验 **REVIEW: ✅ 可合并**,余项为低可达性防御性缺口,已记入 QA 清单「已知测试缺口」。
- **未做**:真机人工 QA(见 QA 清单 M1–M8/H1–H5)。
- **合并与 CI**:已快进合并到 `main` 并推送(`827c3c0`);`main` CI run `39017706933` 实测绿(构建/测试/L10n 键集)。`feat/phase2` 分支本身未单独跑 CI。

