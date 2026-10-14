# Raccoon 一期(应用骨架 + 核心清理)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付 macOS 清理应用 Raccoon 一期:侧边栏骨架 + 声明式规则库扫描 + 四道安全门 + 预览确认后移入废纸篓。

**Architecture:** 单个 SwiftPM 包,4 个 target 分层:`CleanKit`(保护/删除/快照)← `ScanKit`(规则库/扫描引擎)← `AppCore`(ViewModel/服务装配)← `Raccoon`(SwiftUI 界面)。核心层不 import SwiftUI,全部可单测。开发机仅有 Command Line Tools(Swift 6.4),用 `swift build / test / run` 开发,`Scripts/bundle-app.sh` 组装 .app。

**Tech Stack:** Swift 6(strict concurrency)、SwiftUI、Foundation、AppKit(仅 NSWorkspace/NSOpenPanel)、swift-testing。零第三方依赖。

> **测试框架环境适配(执行期确认):** 本机仅有 Command Line Tools(Swift 6.4),**没有 XCTest**。计划中出现的 XCTest 代码一律按此映射翻译执行:`import XCTest` → `import Testing`;`final class X: XCTestCase` → `@Suite final class X`(有 setUp/tearDown 时用 `init`/`deinit` 对应);`func testX()` → `@Test func X()`;`XCTAssertEqual(a,b)` → `#expect(a == b)`;`XCTAssertTrue/False` → `#expect(...)`/`#expect(!...)`;`XCTAssertNil/NotNil` → `#expect(x == nil)`/`#expect(x != nil)`;`try XCTUnwrap(x)` → `try #require(x)`;`XCTFail("m")` → `Issue.record("m")`;`try XCTSkipIf(c)` → `try #require(!c)`。Task 1 已验证此映射可用。另:`final class X: XCTestCase` 默认**串行**执行,而 swift-testing 的 `@Suite` 默认**并行**——凡共享文件系统状态(如 $HOME 内符号链接、套件 init 清扫)的套件必须加 `.serialized`(写作 `@Suite(.serialized) final class X`),避免跨测试竞态(Task 5 复审发现)。

> **运行测试一律用 `Scripts/test.sh`**(内部为 `swift test -Xswiftc -load-plugin-library -Xswiftc <CLT 的 libTestingMacros.dylib>`,参数透传):本机 CLT 把 `libTestingMacros.dylib` 放在编译器不扫描的 `plugins/testing/` 子目录,裸 `swift test` 确定性报 `plugin for module 'TestingMacros' not found`(Task 1 代码质量审查发现并验证)。计划中所有 `swift test ...` 命令均按 `Scripts/test.sh ...` 执行。

**规格:** `docs/superpowers/specs/2026-10-13-raccoon-phase1-design.md`(实现中与规格冲突时以规格为准,并回头修订计划)

---

## 文件结构总览

```
Package.swift                     # 工具链 6.4,macOS 14,4 target + 3 test target
Sources/
  CleanKit/
    ProtectionStore.swift         # 硬保护根 + 用户排除,组件级前缀匹配,规则作用域校验
    TrashService.swift            # TrashOutcome/TrashServicing/FileManagerTrashService + CleanAction/CleanItem/CleanExecutor
    CleanReport.swift             # CleanReport/SkippedItem/HistoryStoring/JSONHistoryStore
    SnapshotCleaner.swift         # SnapshotCleanerServicing + TmutilSnapshotCleaner(tmutil 封装与解析)
    SystemIntegration.swift       # RunningAppDetecting/WorkspaceRunningAppDetector + AppIdentityResolver
  ScanKit/
    RuleModels.swift              # RuleCategory/SafetyLevel/RuleAction/LocalizedText/CleanupRule/RulePack
    RuleStore.swift               # RuleStoreError/LoadedRules/RuleStore(加载+校验)
    ScanModels.swift              # ScanHit/CategorySummary/ScanProgress/ScanResult/ScanServicing
    ScanEngine.swift              # ScanEngine + Dependencies(并行遍历、include/exclude、保护过滤、聚合)
    Resources/rules.json          # 首发规则库(~24 条)
  AppCore/
    ExclusionsStore.swift         # 用户排除持久化(@MainActor @Observable)
    AppScanService.swift          # ScanServicing 生产实现(装配 RuleStore+Engine+Detector)
    ScanViewModel.swift           # 状态机 idle→scanning→completed→cleaning→report/failed + 勾选逻辑
  Raccoon/
    RaccoonApp.swift              # @main、WindowGroup + Settings scene、组合根
    L10n.swift                    # loc() 助手
    RootView.swift                # NavigationSplitView 侧边栏 + 模块枚举(禁用模块"即将推出")
    CleanupHomeView.swift         # 清理主页:状态切换 idle/scanning/completed/failed + 类别卡片
    DetailListView.swift          # 明细列表:行、勾选、工具栏、底部栏、AppIconView
    ConfirmCleanView.swift        # 确认弹窗(cautious 分区 + 运行中警告)
    ReportView.swift              # 完成报告
    SettingsView.swift            # 设置:排除清单 + 关于
    Resources/
      zh-Hans.lproj/Localizable.strings
      en.lproj/Localizable.strings
Tests/
  CleanKitTests/ProtectionStoreTests.swift, TrashServiceTests.swift, CleanExecutorTests.swift,
                CleanReportTests.swift, SnapshotCleanerTests.swift, SystemIntegrationTests.swift
  ScanKitTests/RuleStoreTests.swift, BundledRulesTests.swift, ScanEngineTests.swift, ScanFixtures.swift
  AppCoreTests/ExclusionsStoreTests.swift, ScanViewModelTests.swift
Scripts/
  bundle-app.sh                   # swift build + 组装 build/Raccoon.app + adhoc 签名
  Info.plist                      # App bundle 描述
  make-icon.swift                 # 占位图标(🦝 渲染为 AppIcon.png,可选)
README.md  LICENSE
```

**约定:** 所有命令在仓库根目录执行;每个 Task 结束必须 `swift test` 全绿再 commit;测试里凡操作文件系统的用 `NSTemporaryDirectory()` 下独立目录并在 tearDown 清理。

---

### Task 1: SwiftPM 骨架

**Files:**
- Create: `Package.swift`
- Create: `Sources/CleanKit/CleanKit.swift`(占位)、`Sources/ScanKit/ScanKit.swift`(占位)、`Sources/AppCore/AppCore.swift`(占位)
- Create: `Sources/Raccoon/RaccoonApp.swift`(最小可运行 App)
- Create: `Tests/CleanKitTests/SmokeTests.swift`、`Tests/ScanKitTests/SmokeTests.swift`、`Tests/AppCoreTests/SmokeTests.swift`

- [ ] **Step 1: 写 Package.swift**

```swift
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
```

注意:`ScanKit/Resources/`、`Raccoon/Resources/` 目录必须存在(各放一个占位文件,后续 Task 填充),否则 `.process` 报错。

- [ ] **Step 2: 建目录与占位文件**

```bash
mkdir -p Sources/CleanKit Sources/ScanKit/Resources Sources/AppCore Sources/Raccoon/Resources/zh-Hans.lproj Sources/Raccoon/Resources/en.lproj \
         Tests/CleanKitTests Tests/ScanKitTests Tests/AppCoreTests Scripts build
touch Sources/ScanKit/Resources/.keep
echo '' > Sources/CleanKit/CleanKit.swift
echo '' > Sources/ScanKit/ScanKit.swift
echo '' > Sources/AppCore/AppCore.swift
printf '{}\n' > Sources/Raccoon/Resources/zh-Hans.lproj/.keep && printf '{}\n' > Sources/Raccoon/Resources/en.lproj/.keep
```

- [ ] **Step 3: 最小 App 入口**

`Sources/Raccoon/RaccoonApp.swift`:

```swift
import SwiftUI

@main
struct RaccoonApp: App {
    var body: some Scene {
        WindowGroup { Text("Raccoon") }
    }
}
```

冒烟测试(每个 `Tests/*/SmokeTests.swift` 同构,以 CleanKit 为例):

```swift
import XCTest
@testable import CleanKit

final class SmokeTests: XCTestCase {
    func testPackageCompiles() { XCTAssertTrue(true) }
}
```

- [ ] **Step 4: 构建并测试**

Run: `swift build && swift test`
Expected: `Build complete!` / `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: SwiftPM 骨架(4 target + 3 test target)"
```

---

### Task 2: CleanKit · ProtectionStore

**Files:**
- Create: `Sources/CleanKit/ProtectionStore.swift`
- Test: `Tests/CleanKitTests/ProtectionStoreTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/CleanKitTests/ProtectionStoreTests.swift`:

```swift
import XCTest
@testable import CleanKit

final class ProtectionStoreTests: XCTestCase {
    let home = NSHomeDirectory()

    func testComponentPrefixMatch_notStringPrefix() {
        let s = ProtectionStore(hardRoots: ["\(home)/Library"], userExclusions: [])
        XCTAssertFalse(s.isHardProtected("\(home)/Library2/Caches"))   // 字符串前缀陷阱
        XCTAssertTrue(s.isHardProtected("\(home)/Library/Preferences/x.plist"))
        XCTAssertTrue(s.isHardProtected("\(home)/Library"))
    }

    func testDefaultHardRoots_coverUserContentAndLibraryKeys() {
        let s = ProtectionStore()
        XCTAssertTrue(s.isHardProtected("\(home)/Desktop/a.txt"))
        XCTAssertTrue(s.isHardProtected("\(home)/Documents"))
        XCTAssertTrue(s.isHardProtected("\(home)/Library/Keychains"))
        XCTAssertTrue(s.isHardProtected("\(home)/Library/Suggestions"))
        // 明确不在清单内(合法清理目标)
        XCTAssertFalse(s.isHardProtected("\(home)/Library/Caches/com.google.Chrome"))
        XCTAssertFalse(s.isHardProtected("\(home)/Library/Application Support/MobileSync/Backup"))
    }

    func testUserExclusion_denyAndMerge() {
        let s = ProtectionStore(userExclusions: ["/var/folders/keep-me"])
        XCTAssertTrue(s.isUserExcluded("/var/folders/keep-me/sub"))
        XCTAssertFalse(s.isHardProtected("/var/folders/keep-me"))
        XCTAssertTrue(s.isDenied("/var/folders/keep-me/sub"))
        XCTAssertFalse(s.isDenied("/var/folders/other"))
    }

    func testNormalize_tildeAndTrailingSlashAndDotDot() {
        let s = ProtectionStore(userExclusions: ["~/Library/Caches/"])
        XCTAssertTrue(s.isUserExcluded("\(home)/Library/Caches/com.a"))
        XCTAssertTrue(s.isUserExcluded("\(home)/Library/Caches/../Caches/com.b"))
    }

    // —— 规则作用域与冲突校验(供 RuleStore 复用)——

    func testIsAllowedRuleRoot() {
        XCTAssertTrue(ProtectionStore.isAllowedRuleRoot("\(home)/Library/Caches"))
        XCTAssertTrue(ProtectionStore.isAllowedRuleRoot("~", include: [".DS_Store"]))  // 主目录仅在有 include 时允许
        XCTAssertFalse(ProtectionStore.isAllowedRuleRoot("~"))                          // 裸主目录禁止
        XCTAssertTrue(ProtectionStore.isAllowedRuleRoot("/Applications", include: ["Install macOS *.app"]))
        XCTAssertFalse(ProtectionStore.isAllowedRuleRoot("/Applications"))
        XCTAssertTrue(ProtectionStore.isAllowedRuleRoot("/Applications/Install macOS Sonoma.app"))
        XCTAssertFalse(ProtectionStore.isAllowedRuleRoot("/Applications/Xcode.app"))
        XCTAssertFalse(ProtectionStore.isAllowedRuleRoot("/usr/local/share"))
        XCTAssertFalse(ProtectionStore.isAllowedRuleRoot("\(home)/../otheruser"))
    }

    func testRulePathConflictsWithProtection() {
        let roots = ["\(home)/Documents", "\(home)/Library/Preferences"]
        XCTAssertTrue(ProtectionStore.rulePathConflictsWithProtection("\(home)/Documents", hardRoots: roots))          // 等于
        XCTAssertTrue(ProtectionStore.rulePathConflictsWithProtection("\(home)/Documents/projects", hardRoots: roots)) // 位于其下
        XCTAssertTrue(ProtectionStore.rulePathConflictsWithProtection("\(home)/Library", hardRoots: roots))            // 是保护根的祖先
        XCTAssertFalse(ProtectionStore.rulePathConflictsWithProtection("\(home)/Library", hardRoots: roots, include: [".DS_Store"])) // 祖先+include 白名单放行(§5.3 system.ds-store 依赖;命中级过滤兜底)
        XCTAssertFalse(ProtectionStore.rulePathConflictsWithProtection("\(home)/Library/Caches", hardRoots: roots))
    }

    func testSecurityRegression_rulePointingAtProtectedRootIsConflict() {
        // 恶意规则:指向用户内容目录 → 引擎层判冲突(RuleStore 据此拒绝该条)
        let s = ProtectionStore()
        for evil in ["\(home)/Desktop", "\(home)/Downloads", "\(home)/Library/Preferences"] {
            XCTAssertTrue(ProtectionStore.rulePathConflictsWithProtection(evil, hardRoots: s.hardRoots), evil)
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter ProtectionStoreTests`
Expected: 编译错误 `cannot find 'ProtectionStore' in scope`

- [ ] **Step 3: 实现**

`Sources/CleanKit/ProtectionStore.swift`:

```swift
import Foundation

/// 硬保护 + 用户排除。扫描过滤与删除前校验两处调用(纵深防御)。
public struct ProtectionStore: Sendable {
    /// 硬保护根:组件级前缀匹配,命中即拒绝删除与展示。
    public let hardRoots: [String]
    /// 用户排除:组件级前缀匹配。
    public let userExclusions: [String]

    public init(hardRoots: [String]? = nil, userExclusions: [String] = []) {
        self.hardRoots = hardRoots ?? ProtectionStore.defaultHardRoots()
        self.userExclusions = userExclusions
    }

    static func defaultHardRoots() -> [String] {
        let home = NSHomeDirectory()
        let content = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
        let libraryKeys = ["Mail", "Keychains", "Preferences", "Cookies", "Accounts", "Safari", "Suggestions"]
        return content.map { "\(home)/\($0)" } + libraryKeys.map { "\(home)/Library/\($0)" }
    }

    public func isHardProtected(_ path: String) -> Bool { Self.isUnder(path, anyOf: hardRoots) }
    public func isUserExcluded(_ path: String) -> Bool { Self.isUnder(path, anyOf: userExclusions) }
    public func isDenied(_ path: String) -> Bool { isHardProtected(path) || isUserExcluded(path) }

    /// 展开路径 组件级前缀:path == root 或 path 位于 root 之下。
    static func isUnder(_ path: String, anyOf roots: [String]) -> Bool {
        let comps = normalize(path).split(separator: "/").map(String.init)
        return roots.contains { root in
            let rc = normalize(root).split(separator: "/").map(String.init)
            guard rc.count <= comps.count else { return false }
            return Array(comps.prefix(rc.count)) == rc
        }
    }

    /// 展开 ~、解析 ..、去尾斜杠。
    public static func normalize(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 规则根白名单:主目录内(主目录本身仅当带 include 时允许),或
    /// `/Applications` 限定安装器匹配,或 `/Applications/Install macOS *.app` 直指。
    public static func isAllowedRuleRoot(_ path: String, include: [String]? = nil) -> Bool {
        let std = normalize(path)
        let home = normalize(NSHomeDirectory())
        if std == home { return !(include ?? []).isEmpty }
        if std.hasPrefix(home + "/") { return true }
        if std == "/Applications" {
            return (include ?? []).contains { fnmatch($0, "Install macOS Sonoma.app", 0) == 0 }
        }
        let comps = std.split(separator: "/").map(String.init)
        return comps.count == 2 && comps[0] == "Applications"
            && comps[1].hasPrefix("Install macOS ") && comps[1].hasSuffix(".app")
    }

    /// 规则根不得等于、位于硬保护根之内;不得为硬保护根的祖先——除非带 include 白名单。
    /// (修订:Task 6 预检发现规格 §5.2"不得包含"与 §5.3 system.ds-store(根为主目录,
    /// 是一切硬保护根的祖先)矛盾;按计划头部裁决规则以规格 §5.3 为准——祖先方向仅在
    /// include 非空时豁免,硬保护内容仍由扫描命中级过滤 + 删除前 isDenied 兜底,规则级
    /// 校验是防呆 lint,不是安全边界。等于/位于其下方向无条件冲突,include 也救不了。)
    public static func rulePathConflictsWithProtection(_ path: String, hardRoots: [String], include: [String]? = nil) -> Bool {
        let comps = foldedComponents(of: path)
        let ancestorAllowed = !(include ?? []).isEmpty
        return hardRoots.contains { root in
            let rc = foldedComponents(of: root)
            if comps.isEmpty || rc.isEmpty { return true }
            if Array(comps.prefix(rc.count)) == rc { return true }                // 等于/位于其下:一律冲突
            if Array(rc.prefix(comps.count)) == comps { return !ancestorAllowed } // 祖先:无 include 才冲突
            return false
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `Scripts/test.sh --filter ProtectionStoreTests`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(CleanKit): 硬保护与用户排除(组件级前缀匹配)+ 规则作用域校验"
```

---

### Task 3: CleanKit · TrashService + CleanExecutor

**Files:**
- Create: `Sources/CleanKit/TrashService.swift`
- Test: `Tests/CleanKitTests/TrashServiceTests.swift`、`Tests/CleanKitTests/CleanExecutorTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/CleanKitTests/TrashServiceTests.swift`:

```swift
import XCTest
@testable import CleanKit

final class TrashServiceTests: XCTestCase {
    // 纯映射逻辑:错误码 → 结果三态
    func testMapError_threeOutcomes() {
        let vanished = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        guard case .vanished = TrashService.map(error: vanished) else { return XCTFail() }
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        guard case .skipped(let reason) = TrashService.map(error: denied), reason == "no-permission" else { return XCTFail() }
        let other = NSError(domain: NSPOSIXErrorDomain, code: 16)   // EBUSY
        guard case .skipped = TrashService.map(error: other) else { return XCTFail() }
    }

    // 真实 trash:临时文件 → 原位置消失(进入用户废纸篓,手动核对可恢复)
    func testFileManagerTrashService_trashesTempFile() async {
        let path = NSTemporaryDirectory() + "raccoon-trash-\(UUID().uuidString).txt"
        try! Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let outcome = await FileManagerTrashService().trash(path)
        XCTAssertEqual(outcome, .trashed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testFileManagerTrashService_vanishedForMissing() async {
        let outcome = await FileManagerTrashService().trash("/nonexistent/raccoon/xx")
        XCTAssertEqual(outcome, .vanished)
    }
}
```

`Tests/CleanKitTests/CleanExecutorTests.swift`:

```swift
import XCTest
@testable import CleanKit

actor MockTrash: TrashServicing {
    let outcome: TrashOutcome
    let vanishedFor: Set<String>   // 指定路径强制返回 .vanished(模拟文件已消失)
    private(set) var calls: [String] = []
    init(outcome: TrashOutcome, vanishedFor: [String] = []) {
        self.outcome = outcome
        self.vanishedFor = Set(vanishedFor)
    }
    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        return vanishedFor.contains(path) ? .vanished : outcome
    }
}

actor MockSnapshots: SnapshotCleanerServicing {
    let listed: [String]
    private(set) var deleted: [String] = []
    init(listed: [String] = []) { self.listed = listed }
    func listSnapshots() -> [String] { listed }
    func deleteSnapshot(_ date: String) -> Bool { deleted.append(date); return true }
}

final class CleanExecutorTests: XCTestCase {
    var dir: String!
    override func setUp() { dir = NSTemporaryDirectory() + "raccoon-exec-\(UUID().uuidString)" }
    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
        try? FileManager.default.removeItem(atPath: dir)
    }

    func item(_ path: String, size: Int64 = 10, action: CleanAction = .trash) -> CleanItem {
        CleanItem(path: path, sizeBytes: size, action: action)
    }

    func testClean_aggregatesReport_andSkipsProtected() async {
        let trash = MockTrash(outcome: .trashed, vanishedFor: ["/nonexistent/x"])
        let protection = ProtectionStore(userExclusions: [dir + "/excluded"])
        let exec = CleanExecutor(trash: trash, protection: protection, snapshots: MockSnapshots())
        let report = await exec.clean([
            item(dir + "/a", size: 100),
            item(dir + "/excluded", size: 200),          // 用户排除 → 引擎兜底拦截
            item("/nonexistent/x", size: 5),             // vanished
            item(dir + "/snapshot", action: .tmutilThin(date: "2026-10-13-120000")),
        ])
        XCTAssertEqual(report.trashedCount, 1)
        XCTAssertEqual(report.freedBytes, 100)
        XCTAssertEqual(report.vanishedCount, 1)
        XCTAssertEqual(report.snapshotCount, 1)
        XCTAssertEqual(report.skipped.map(\.path), [dir + "/excluded"])
        let calls = await trash.calls
        XCTAssertEqual(calls, [dir + "/a", "/nonexistent/x"])
    }

    func testClean_securityRegression_neverTrashesProtectedEvenIfInjected() async {
        // 纵深防御:即便上游把受保护路径塞进清理列表,执行器仍拦截
        let trash = MockTrash(outcome: .trashed)
        let exec = CleanExecutor(trash: trash, protection: ProtectionStore(), snapshots: MockSnapshots())
        let report = await exec.clean([item("\(NSHomeDirectory())/Documents/thesis.docx", size: 999)])
        XCTAssertEqual(report.trashedCount, 0)
        XCTAssertEqual(report.skipped.count, 1)
        let calls = await trash.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testClean_progressReportsEachItem() async {
        let exec = CleanExecutor(trash: MockTrash(outcome: .trashed), protection: ProtectionStore(), snapshots: MockSnapshots())
        var seen: [(Int, Int)] = []
        _ = await exec.clean([item("a"), item("b"), item("c")]) { done, total in seen.append((done, total)) }
        XCTAssertEqual(seen, [(1, 3), (2, 3), (3, 3)])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter 'TrashServiceTests|CleanExecutorTests'`
Expected: 编译错误(类型未定义)

- [ ] **Step 3: 实现**

`Sources/CleanKit/TrashService.swift`:

```swift
import Foundation

public enum TrashOutcome: Equatable, Sendable {
    case trashed
    case vanished
    case skipped(reason: String)   // 稳定代码:"no-permission" / "other"
}

public protocol TrashServicing: Sendable {
    func trash(_ path: String) async -> TrashOutcome
}

public struct FileManagerTrashService: TrashServicing {
    let fm: FileManager
    public init(fm: FileManager = .default) { self.fm = fm }

    /// 唯一删除动作:移入废纸篓。绝不 unlink。
    public func trash(_ path: String) async -> TrashOutcome {
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return .trashed
        } catch {
            return TrashService.map(error: error as NSError)
        }
    }
}

public enum TrashService {
    public static func map(error: NSError) -> TrashOutcome {
        guard error.domain == NSCocoaErrorDomain else { return .skipped(reason: "other") }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .vanished
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .skipped(reason: "no-permission")
        default:
            return .skipped(reason: "other")
        }
    }
}

public enum CleanAction: Equatable, Sendable {
    case trash
    case tmutilThin(date: String?)
}

public struct CleanItem: Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let action: CleanAction
    public init(path: String, sizeBytes: Int64, action: CleanAction = .trash) {
        self.path = path; self.sizeBytes = sizeBytes; self.action = action
    }
}

public struct CleanExecutor: Sendable {
    let trash: TrashServicing
    let protection: ProtectionStore
    let snapshots: SnapshotCleanerServicing

    public init(trash: TrashServicing, protection: ProtectionStore, snapshots: SnapshotCleanerServicing = TmutilSnapshotCleaner()) {
        self.trash = trash; self.protection = protection; self.snapshots = snapshots
    }

    /// 逐项执行;任何单项失败不中断整批。
    public func clean(_ items: [CleanItem], onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> CleanReport {
        var freed: Int64 = 0, trashed = 0, vanished = 0, snapshotCount = 0
        var skipped: [SkippedItem] = []
        for (i, item) in items.enumerated() {
            // 纵深防御:删除前最后一道硬保护校验
            if item.action == .trash && protection.isDenied(item.path) {
                skipped.append(SkippedItem(path: item.path, reason: "protected"))
                onProgress?(i + 1, items.count); continue
            }
            switch item.action {
            case .trash:
                switch await trash.trash(item.path) {
                case .trashed: trashed += 1; freed += item.sizeBytes
                case .vanished: vanished += 1
                case .skipped(let reason): skipped.append(SkippedItem(path: item.path, reason: reason))
                }
            case .tmutilThin(let date):
                if let date, await snapshots.deleteSnapshot(date) { snapshotCount += 1 }
                else { skipped.append(SkippedItem(path: item.path, reason: "snapshot-failed")) }
            }
            onProgress?(i + 1, items.count)
        }
        return CleanReport(freedBytes: freed, trashedCount: trashed, vanishedCount: vanished,
                           snapshotCount: snapshotCount, skipped: skipped)
    }
}
```

- [ ] **Step 4: 补 SnapshotCleaner 与报告(测试先行已在上面,先加最小类型让本 Task 编译通过)**

`Sources/CleanKit/SnapshotCleaner.swift`(本 Task 先实现解析纯函数,`CleanReport` 占位于下一文件):

```swift
import Foundation

public protocol SnapshotCleanerServicing: Sendable {
    /// 返回快照日期串,形如 "2026-10-13-120000"
    func listSnapshots() async -> [String]
    @discardableResult func deleteSnapshot(_ date: String) async -> Bool
}

public struct TmutilSnapshotCleaner: SnapshotCleanerServicing {
    public init() {}

    public func listSnapshots() async -> [String] {
        Self.run(["listlocalsnapshots", "/"])
            .split(separator: "\n")
            .compactMap { Self.parseSnapshotDate(String($0)) }
    }

    public func deleteSnapshot(_ date: String) async -> Bool {
        let out = Self.run(["deletelocalsnapshots", date])
        return out.localizedCaseInsensitiveContains("deleted")
    }

    /// 纯函数,单测覆盖:"com.apple.TimeMachine.2026-10-13-120000.local" → "2026-10-13-120000"
    public static func parseSnapshotDate(_ line: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }

    static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
```

`Sources/CleanKit/CleanReport.swift`:

```swift
import Foundation

public struct SkippedItem: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct CleanReport: Codable, Equatable, Sendable {
    public let date: Date
    public let freedBytes: Int64
    public let trashedCount: Int
    public let vanishedCount: Int
    public let snapshotCount: Int
    public let skipped: [SkippedItem]
    public init(date: Date = Date(), freedBytes: Int64, trashedCount: Int,
                vanishedCount: Int, snapshotCount: Int = 0, skipped: [SkippedItem]) {
        self.date = date; self.freedBytes = freedBytes; self.trashedCount = trashedCount
        self.vanishedCount = vanishedCount; self.snapshotCount = snapshotCount; self.skipped = skipped
    }
}

public protocol HistoryStoring: Sendable {
    func append(_ report: CleanReport) throws
    func loadAll() throws -> [CleanReport]
}

/// ~/Library/Application Support/Raccoon/history.json(测试可注入目录)
public struct JSONHistoryStore: HistoryStoring {
    let url: URL
    let fm: FileManager

    public init(directory: URL? = nil, fm: FileManager = .default) {
        self.fm = fm
        let dir = directory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Raccoon", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("history.json")
    }

    public func append(_ report: CleanReport) throws {
        var all = (try? loadAll()) ?? []
        all.append(report)
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: .atomic)
    }

    public func loadAll() throws -> [CleanReport] {
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CleanReport].self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `Scripts/test.sh --filter 'TrashServiceTests|CleanExecutorTests'`
Expected: `Executed 6 tests, with 0 failures`(注意:`testFileManagerTrashService_trashesTempFile` 会向你的废纸篓放入一个临时文件,属预期)

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(CleanKit): 废纸篓服务 + 清理执行器(纵深防御)+ 报告/历史 + tmutil 快照解析"
```

---

### Task 4: CleanKit · SnapshotCleaner 测试 + SystemIntegration(运行中检测/AppIdentity)

**Files:**
- Test: `Tests/CleanKitTests/SnapshotCleanerTests.swift`、`Tests/CleanKitTests/SystemIntegrationTests.swift`
- Modify: `Sources/CleanKit/SnapshotCleaner.swift`(仅一处:`run(_:)` 返回 `(stdout, terminationStatus)`,`deleteSnapshot` 改以退出码 0 为成功主信号——审查 M1;其余不动)
- Create: `Sources/CleanKit/SystemIntegration.swift`

- [ ] **Step 1: 写失败测试**

`Tests/CleanKitTests/SnapshotCleanerTests.swift`:

```swift
import XCTest
@testable import CleanKit

final class SnapshotCleanerTests: XCTestCase {
    func testParseSnapshotDate() {
        XCTAssertEqual(TmutilSnapshotCleaner.parseSnapshotDate("com.apple.TimeMachine.2026-10-13-120000.local"), "2026-10-13-120000")
        XCTAssertNil(TmutilSnapshotCleaner.parseSnapshotDate("Snapshots for /:"))
        XCTAssertNil(TmutilSnapshotCleaner.parseSnapshotDate("com.apple.TimeMachine..local"))
    }

    // M1 回归:删除不存在的快照,tmutil exit 70 → false(以退出码判定,真实子进程集成测试)
    func testDeleteSnapshot_bogusDateReturnsFalse() async {
        let ok = await TmutilSnapshotCleaner().deleteSnapshot("2000-01-01-000000")
        XCTAssertFalse(ok)
    }
}
```

`Tests/CleanKitTests/SystemIntegrationTests.swift`:

```swift
import XCTest
@testable import CleanKit

final class SystemIntegrationTests: XCTestCase {
    // —— bundle id 路径段提取(纯函数)——
    func testBundleIDComponent() {
        func bid(_ p: String) -> String? { AppIdentityResolver.bundleIDComponent(in: p) }
        XCTAssertEqual(bid("/Users/x/Library/Caches/com.google.Chrome/Cache"), "com.google.Chrome")
        XCTAssertEqual(bid("/x/com.tinyspeck.slackmacgap"), "com.tinyspeck.slackmacgap")
        XCTAssertNil(bid("/Users/x/Library/Caches/Google/Chrome"))       // 无 bundle-id 段
        XCTAssertNil(bid("/x/Cache"))                                     // 单段
        XCTAssertNil(bid("/x/a..b"))                                      // 空段非法
        XCTAssertNil(bid("/x/com.apple.calc$$"))                          // 非法字符
    }

    @MainActor
    func testAppName_knownInstalledApp() {
        let name = AppIdentityResolver().appName(for: "com.apple.Safari")
        XCTAssertNotNil(name)                    // Safari 必装
        XCTAssertFalse(name?.isEmpty ?? true)
    }

    @MainActor
    func testAppName_unknownFallsBackToNil() {
        XCTAssertNil(AppIdentityResolver().appName(for: "com.raccoon.notexist"))
    }

    @MainActor
    func testWorkspaceDetector_returnsSet() {
        let ids = WorkspaceRunningAppDetector().runningBundleIDs()
        _ = ids.contains("anything")             // 能取到集合即可(运行中应用数不定)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter 'SnapshotCleanerTests|SystemIntegrationTests'`
Expected: 编译错误(`appName(for:)` 未定义)

- [ ] **Step 3: 实现**

**先做(SnapshotCleaner M1 修复)**:`run(_ args: [String]) -> String` 改为 `run(_ args: [String]) -> (String, Int32)`(返回 stdout 与 terminationStatus;spawn 失败返回 `("", -1)`),`standardError` 保持 `FileHandle.nullDevice`;`listSnapshots` 取 `let (out, _)` 只用输出;`deleteSnapshot` 改为 `let (_, status) = ...; return status == 0`(tmutil 删除失败 exit 70,废弃字符串启发式判定)。

`Sources/CleanKit/SystemIntegration.swift`:

```swift
import AppKit

@MainActor
public protocol RunningAppDetecting: Sendable {
    func runningBundleIDs() -> Set<String>
}

/// NSWorkspace 是 @MainActor 隔离的(Swift 6 严格并发),检测器整体收在主线程;
/// ScanEngine 在扫描开始时通过 async 闭包取一次快照。
@MainActor
public struct WorkspaceRunningAppDetector: RunningAppDetecting {
    public init() {}
    public func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

public struct AppIdentityResolver: Sendable {
    public init() {}

    /// 纯函数:路径中最后一个形如 com.xxx.yyy 的完整路径段。
    public static func bundleIDComponent(in path: String) -> String? {
        for comp in path.split(separator: "/").reversed() {
            let s = String(comp)
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)   // 空段非法:"a..b" → nil
            if parts.count >= 2, parts.allSatisfy({
                !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            }) {
                return s
            }
        }
        return nil
    }

    /// bundle id → 应用名:先运行中应用(localizedName),再已安装应用(bundle 文件名);查不到返回 nil。
    @MainActor
    public func appName(for bundleID: String) -> String? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }
}
```

(说明:`bundleIDComponent` 必须为 `public static`,ScanEngine 在 ScanKit 模块中按命中路径调用它;`appName(for:)` 标 `@MainActor`,由引擎在扫描收尾时在主线程批量调用一次,避免逐项跨线程。)

- [ ] **Step 4: 运行确认通过**

Run: `Scripts/test.sh --filter 'SnapshotCleanerTests|SystemIntegrationTests'`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 全量测试 + Commit**

Run: `Scripts/test.sh`
Expected: 全绿

```bash
git add -A && git commit -m "feat(CleanKit): 运行中应用检测 + AppIdentity 解析,快照解析测试"
```

---

### Task 5: ScanKit · 规则模型 + RuleStore

**Files:**
- Create: `Sources/ScanKit/RuleModels.swift`、`Sources/ScanKit/RuleStore.swift`
- Test: `Tests/ScanKitTests/RuleStoreTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/ScanKitTests/RuleStoreTests.swift`:

```swift
import XCTest
import CleanKit
@testable import ScanKit

final class RuleStoreTests: XCTestCase {
    // 修订(Task 5 规格+质量审查):suite 开始时清扫历史残留的 raccoon-test-alias-*,
    // 跨 run 自愈、不积累(进程内 removeItem 偶发失败,根因未查明;按质量审查定级 Minor,
    // 采用自愈方案而非 Issue.record,避免环境性红测)
    override func setUp() {
        super.setUp()
        let home = NSHomeDirectory()
        if let stale = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for f in stale where f.hasPrefix("raccoon-test-alias-") {
                try? FileManager.default.removeItem(atPath: home + "/" + f)
            }
        }
    }

    func load(_ json: String) throws -> LoadedRules {
        let store = RuleStore(protection: ProtectionStore())
        return try store.load(data: Data(json.utf8))
    }

    func testLoad_validPack() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Caches"},
          {"id":"b","category":"cautious","safety":"cautious","path":"~/Library/Application Support/MobileSync/Backup"}
        ]}
        """)
        XCTAssertEqual(lr.rules.map(\.id), ["a", "b"])
        XCTAssertTrue(lr.rejected.isEmpty)
        XCTAssertTrue(lr.warnings.isEmpty)
    }

    func testLoad_unsupportedVersion() {
        XCTAssertThrowsError(try load(#"{"version":2,"rules":[]}"#)) { error in
            guard case RuleStoreError.unsupportedVersion(2) = error else { return XCTFail("\(error)") }
        }
    }

    func testLoad_decodingFailure() {
        XCTAssertThrowsError(try load("not json")) { error in
            guard case RuleStoreError.decodingFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testLoad_duplicateIDRejected_ruleKept() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Logs"},
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Caches"}
        ]}
        """)
        XCTAssertEqual(lr.rules.count, 1)
        XCTAssertEqual(lr.rules.first?.path, "~/Library/Logs")   // 先到先得
        XCTAssertEqual(lr.rejected.count, 1)
        XCTAssertTrue(lr.rejected[0].contains("重复 id"))
    }

    func testLoad_cautiousCategoryRequiresCautiousSafety() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"bad","category":"cautious","safety":"safe","path":"~/Library/Caches/x"}
        ]}
        """)
        XCTAssertTrue(lr.rules.isEmpty)
        XCTAssertEqual(lr.rejected.count, 1)
    }

    func testLoad_tmutilThinRequiresCautious() throws {
        // 修订(Task 5 质量审查 #1):断言原因字符串锁定走的是 tmutil-thin 分支——
        // 反事实验证:若该分支被删,规则误入 trash 路径,会以"超出允许作用域"拒绝,
        // 规则数相同但原因不同,无原因断言则测试不具判别力
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"snap","category":"system","safety":"safe","path":"~","action":"tmutil-thin"}
        ]}
        """)
        XCTAssertTrue(lr.rules.isEmpty)
        XCTAssertEqual(lr.rejected.count, 1)
        XCTAssertTrue(lr.rejected[0].contains("tmutil-thin 仅允许"), "\(lr.rejected)")
        // 正例:tmutil-thin 跳过 path 作用域/保护校验(不参与文件遍历),cautious 即可加载
        let ok = try load("""
        {"version":1,"rules":[
          {"id":"snap-ok","category":"apps","safety":"cautious","path":"/usr","action":"tmutil-thin"}
        ]}
        """)
        XCTAssertEqual(ok.rules.count, 1)
        XCTAssertTrue(ok.rejected.isEmpty, "\(ok.rejected)")
    }

    func testLoad_securityRegression_ruleAtProtectedPathRejected() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"evil","category":"system","safety":"safe","path":"~/Documents"},
          {"id":"evil2","category":"system","safety":"safe","path":"~/Library/Preferences"},
          {"id":"good","category":"system","safety":"safe","path":"~/Library/Logs"}
        ]}
        """)
        XCTAssertEqual(lr.rules.map(\.id), ["good"])
        XCTAssertEqual(lr.rejected.count, 2)
    }

    func testLoad_outOfScopeRejected() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"sys","category":"system","safety":"safe","path":"/Library"},
          {"id":"usr","category":"system","safety":"safe","path":"/usr/local"}
        ]}
        """)
        XCTAssertTrue(lr.rules.isEmpty)
        XCTAssertEqual(lr.rejected.count, 2)
    }

    func testLoad_overlapWarns() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Caches"},
          {"id":"b","category":"system","safety":"safe","path":"~/Library/Caches/"}
        ]}
        """)
        XCTAssertEqual(lr.rules.count, 2)                 // 允许,仅告警
        XCTAssertEqual(lr.warnings.count, 1)              // 尾斜杠归一化后视为同路径
    }

    // 修订(Task 6 预检):重叠告警只比较 trash 规则;快照规则 path:"~" 不与 ds-store 误报
    func testLoad_overlapIgnoresTmutilThinRules() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~","include":[".DS_Store"]},
          {"id":"b","category":"cautious","safety":"cautious","path":"~/","action":"tmutil-thin"}
        ]}
        """)
        XCTAssertEqual(lr.rules.count, 2)
        XCTAssertTrue(lr.warnings.isEmpty, "\(lr.warnings)")
    }

    // 修订(Task 6 预检,§5.3):主目录(硬保护根的祖先)+ include 白名单 → 可加载
    func testLoad_ancestorRootWithIncludeLoads() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"ds","category":"system","safety":"safe","path":"~","include":[".DS_Store"]}
        ]}
        """)
        XCTAssertEqual(lr.rules.count, 1)
        XCTAssertTrue(lr.rejected.isEmpty, "\(lr.rejected)")
    }

    // 祖先根无 include(整目录扫荡,如 ~/Library)仍拒绝
    func testLoad_libraryRootWithoutIncludeRejected() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"sweep","category":"system","safety":"safe","path":"~/Library"}
        ]}
        """)
        XCTAssertTrue(lr.rules.isEmpty)
        XCTAssertEqual(lr.rejected.count, 1)
        XCTAssertTrue(lr.rejected[0].contains("硬保护冲突"))
    }

    // I1 回归:主目录内符号链接别名指进硬保护根 → 解析形态冲突校验整条拒绝
    func testLoad_symlinkAliasToProtectedRejected() throws {
        let alias = NSHomeDirectory() + "/raccoon-test-alias-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: NSHomeDirectory() + "/Library/Preferences")
        defer { try? FileManager.default.removeItem(atPath: alias) }
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"sneaky","category":"system","safety":"safe","path":"\(alias)"}
        ]}
        """)
        XCTAssertTrue(lr.rules.isEmpty)
        XCTAssertEqual(lr.rejected.count, 1)
        XCTAssertTrue(lr.rejected[0].contains("硬保护冲突"))   // 锁定:解析形态的冲突校验拦截
    }

    // I1 回归:主目录内别名解析后逃出主目录 → 解析形态作用域校验拒绝
    func testLoad_symlinkEscapingHomeRejected() throws {
        let alias = NSHomeDirectory() + "/raccoon-test-alias-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: "/usr")
        defer { try? FileManager.default.removeItem(atPath: alias) }
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"escape","category":"system","safety":"safe","path":"\(alias)"}
        ]}
        """)
        XCTAssertTrue(lr.rules.isEmpty)
        XCTAssertEqual(lr.rejected.count, 1)
        XCTAssertTrue(lr.rejected[0].contains("超出允许作用域"))   // 锁定:解析形态的作用域校验拦截
    }

    func testEffectiveAction_defaultsToTrash() throws {
        let lr = try load("""
        {"version":1,"rules":[{"id":"a","category":"system","safety":"safe","path":"~/Library/Logs"}]}
        """)
        XCTAssertEqual(lr.rules[0].effectiveAction, .trash)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter RuleStoreTests`
Expected: 编译错误(类型未定义)

- [ ] **Step 3: 实现 RuleModels**

`Sources/ScanKit/RuleModels.swift`:

```swift
import Foundation

public enum RuleCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, dev, apps, cautious
    public var id: String { rawValue }
}

public enum SafetyLevel: String, Codable, Sendable {
    case safe, cautious
}

public enum RuleAction: String, Codable, Sendable {
    case trash
    case tmutilThin = "tmutil-thin"
}

public struct LocalizedText: Codable, Equatable, Sendable {
    public let zhHans: String?
    public let en: String?
    enum CodingKeys: String, CodingKey { case zhHans = "zh-Hans", en }
    public init(zhHans: String?, en: String?) { self.zhHans = zhHans; self.en = en }
    public func text(prefersChinese: Bool) -> String {
        prefersChinese ? (zhHans ?? en ?? "") : (en ?? zhHans ?? "")
    }
}

public struct CleanupRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: RuleCategory
    public let safety: SafetyLevel
    public let path: String
    public let include: [String]?
    public let exclude: [String]?
    public let action: RuleAction?
    public let description: LocalizedText?

    public var effectiveAction: RuleAction { action ?? .trash }
}

public struct RulePack: Codable, Sendable {
    public let version: Int
    public let rules: [CleanupRule]
}
```

- [ ] **Step 4: 实现 RuleStore**

`Sources/ScanKit/RuleStore.swift`:

```swift
import Foundation
import CleanKit

public enum RuleStoreError: Error, Equatable, Sendable {
    case fileNotFound
    case unsupportedVersion(Int)
    case decodingFailed(String)
}

public struct LoadedRules: Sendable {
    public let rules: [CleanupRule]
    public let warnings: [String]     // 如规则根重叠
    public let rejected: [String]     // "id: 原因",单条拒绝,绝不静默
}

public struct RuleStore: Sendable {
    let protection: ProtectionStore
    public init(protection: ProtectionStore = ProtectionStore()) { self.protection = protection }

    /// 整体解码/版本错误抛异常;单条规则错误进 rejected,其余照常加载。
    public func load(data: Data) throws -> LoadedRules {
        let pack: RulePack
        do { pack = try JSONDecoder().decode(RulePack.self, from: data) }
        catch { throw RuleStoreError.decodingFailed(error.localizedDescription) }
        guard pack.version == 1 else { throw RuleStoreError.unsupportedVersion(pack.version) }

        var valid: [CleanupRule] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for rule in pack.rules {
            if seen.contains(rule.id) {
                rejected.append("\(rule.id): 重复 id"); continue
            }
            if let problem = Self.validate(rule, protection: protection) {
                rejected.append("\(rule.id): \(problem)"); continue
            }
            seen.insert(rule.id)
            valid.append(rule)
        }

        // 修订(Task 6 预检):重叠告警只比较文件遍历(trash)规则——tmutil-thin 不产生
        // 文件条目,无"重复展示"问题;且快照规则的天然写法就是 path:"~",不该与 ds-store 误报
        let comparable = valid.filter { $0.effectiveAction == .trash }
        var warnings: [String] = []
        for i in comparable.indices {
            for j in comparable.indices where j > i {
                if ProtectionStore.normalize(comparable[i].path) == ProtectionStore.normalize(comparable[j].path) {
                    warnings.append("规则根重叠: \(comparable[i].id) / \(comparable[j].id)")
                }
            }
        }
        return LoadedRules(rules: valid, warnings: warnings, rejected: rejected)
    }

    static func validate(_ rule: CleanupRule, protection: ProtectionStore) -> String? {
        if rule.category == .cautious && rule.safety != .cautious {
            return "category=cautious 要求 safety=cautious"
        }
        guard rule.effectiveAction == .trash else {
            // tmutil-thin:不参与文件遍历,仅要求 cautious
            return rule.safety == .cautious ? nil : "tmutil-thin 仅允许 cautious 规则"
        }
        let std = ProtectionStore.normalize(rule.path)
        // I1(Task 2 审查):符号链接别名按解析前后双形态校验——别名指进硬保护根、或解析后逃出主目录,都整条拒绝
        let resolved = ProtectionStore.normalize((std as NSString).resolvingSymlinksInPath)
        guard ProtectionStore.isAllowedRuleRoot(std, include: rule.include),
              ProtectionStore.isAllowedRuleRoot(resolved, include: rule.include) else {
            return "规则根超出允许作用域: \(rule.path)"
        }
        if ProtectionStore.rulePathConflictsWithProtection(std, hardRoots: protection.hardRoots, include: rule.include)
            || ProtectionStore.rulePathConflictsWithProtection(resolved, hardRoots: protection.hardRoots, include: rule.include) {
            return "规则根与硬保护冲突: \(rule.path)"
        }
        return nil
    }

    public func loadBundled(bundle: Bundle = .module) throws -> LoadedRules {
        guard let url = bundle.url(forResource: "rules", withExtension: "json") else {
            throw RuleStoreError.fileNotFound
        }
        return try load(data: try Data(contentsOf: url))
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `Scripts/test.sh --filter RuleStoreTests`
Expected: `Executed 15 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(ScanKit): 规则模型 + RuleStore(逐条校验/重叠告警/作用域与硬保护冲突拦截)"
```

### Task 6: rules.json 首发规则库

**Files:**
- Create: `Sources/ScanKit/Resources/rules.json`
- Test: `Tests/ScanKitTests/BundledRulesTests.swift`
- Delete: `Sources/ScanKit/Resources/.keep`

- [ ] **Step 1: 写失败测试**

`Tests/ScanKitTests/BundledRulesTests.swift`:

```swift
import XCTest
import CleanKit
@testable import ScanKit

final class BundledRulesTests: XCTestCase {
    func testBundledRules_loadClean() throws {
        let lr = try RuleStore().loadBundled()
        XCTAssertGreaterThanOrEqual(lr.rules.count, 20)
        XCTAssertTrue(lr.rejected.isEmpty, "内置规则必须全部合法: \(lr.rejected)")
        XCTAssertTrue(lr.warnings.isEmpty, "内置规则不允许根重叠: \(lr.warnings)")
    }

    func testBundledRules_coversAllCategories_andHasLocalizedDescriptions() throws {
        let lr = try RuleStore().loadBundled()
        let cats = Set(lr.rules.map(\.category))
        XCTAssertEqual(cats, Set(RuleCategory.allCases))
        for rule in lr.rules {
            XCTAssertNotNil(rule.description?.zhHans, "\(rule.id) 缺中文描述")
            XCTAssertNotNil(rule.description?.en, "\(rule.id) 缺英文描述")
        }
    }

    func testBundledRules_keyRulesPresent() throws {
        let lr = try RuleStore().loadBundled()
        let ids = Set(lr.rules.map(\.id))
        for expected in ["system.user-caches", "system.ds-store", "dev.xcode-deriveddata",
                         "apps.chrome-cache", "apps.wechat-cache", "cautious.ios-backups",
                         "cautious.macos-installers", "cautious.tm-snapshots"] {
            XCTAssertTrue(ids.contains(expected), "缺少关键规则 \(expected)")
        }
    }

    func testBundledRules_cautiousCategoryImpliesCautiousSafety() throws {
        let lr = try RuleStore().loadBundled()
        // §5.1 约束:category=cautious 要求 safety=cautious(与 RuleStore.validate 同向)。
        // 反向不成立——dev/apps 类别也允许 safety=cautious(规格 §5.3:Xcode Archives、
        // CoreSimulator、~/.cache 归 dev,微信缓存归 apps);默认不勾选由 safety 驱动,
        // 与类别卡片归属无关,故不断言 safety→category。
        for rule in lr.rules where rule.category == .cautious {
            XCTAssertEqual(rule.safety, .cautious, "\(rule.id) cautious 类别规则必须 safety=cautious")
        }
    }

    // exclude ↔ 子规则一致性:凡无 include 的 trash 规则(默认模式按根的一级子项
    // 整体作删除单元),若另一规则根位于其下,则相对首段组件必须出现在该祖先规则
    // 的 exclude 中——否则两项同选时同一目录被计入两次,释放量虚高。
    func testBundledRules_subRuleExcludedFromAncestorRule() throws {
        let lr = try RuleStore().loadBundled()
        let traversal = lr.rules.filter { $0.effectiveAction == .trash && ($0.include ?? []).isEmpty }
        for a in traversal {
            let aComps = ProtectionStore.normalize(a.path).split(separator: "/").map(String.init)
            for b in traversal where b.id != a.id {
                let bComps = ProtectionStore.normalize(b.path).split(separator: "/").map(String.init)
                guard bComps.count > aComps.count, Array(bComps.prefix(aComps.count)) == aComps else { continue }
                let firstRel = bComps[aComps.count]
                XCTAssertTrue(a.exclude?.contains(firstRel) == true,
                              "\(b.id) 位于 \(a.id) 之下但首段 \(firstRel) 不在其 exclude 中,将双重计数")
            }
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter BundledRulesTests`
Expected: FAIL `fileNotFound`

- [ ] **Step 3: 写 rules.json**

`Sources/ScanKit/Resources/rules.json`(`~` 由加载时归一化展开;`exclude` 匹配路径末段):

```json
{
  "version": 1,
  "rules": [
    {"id": "system.user-caches", "category": "system", "safety": "safe",
     "path": "~/Library/Caches",
     "exclude": ["Google", "Microsoft Edge", "BraveSoftware", "Firefox", "com.spotify.client", "com.tinyspeck.slackmacgap", "pip", "Homebrew", "org.swift.swiftpm", "CocoaPods"],
     "description": {"zh-Hans": "应用缓存总目录(浏览器与包管理缓存已单独归类),删除后由各应用自动重建", "en": "App cache root (browsers & package managers categorized separately); apps rebuild it automatically"}},
    {"id": "system.user-logs", "category": "system", "safety": "safe",
     "path": "~/Library/Logs", "exclude": ["DiagnosticReports"],
     "description": {"zh-Hans": "应用日志文件(崩溃报告单独归类)", "en": "Application logs (crash reports categorized separately)"}},
    {"id": "system.crash-reports", "category": "system", "safety": "safe",
     "path": "~/Library/Logs/DiagnosticReports",
     "description": {"zh-Hans": "应用崩溃报告(.ips),排查问题后才有用", "en": "Crash reports (.ips), only useful while debugging"}},
    {"id": "system.ds-store", "category": "system", "safety": "safe",
     "path": "~", "include": [".DS_Store"],
     "description": {"zh-Hans": "Finder 生成的目录视图缓存文件,删除无副作用,会自动重建", "en": "Finder view-cache files; harmless, recreated automatically"}},
    {"id": "dev.xcode-deriveddata", "category": "dev", "safety": "safe",
     "path": "~/Library/Developer/Xcode/DerivedData",
     "description": {"zh-Hans": "Xcode 编译产物与索引,删除后首次编译会变慢", "en": "Xcode build artifacts & index; first build after cleanup is slower"}},
    {"id": "dev.xcode-devicesupport", "category": "dev", "safety": "safe",
     "path": "~/Library/Developer/Xcode/iOS DeviceSupport",
     "description": {"zh-Hans": "iOS 设备调试符号,连真机时重新生成", "en": "iOS device symbols; regenerated when a device is connected"}},
    {"id": "dev.xcode-archives", "category": "dev", "safety": "cautious",
     "path": "~/Library/Developer/Xcode/Archives",
     "description": {"zh-Hans": "历史 App 归档(ipa),上传 App Store 前有用,确认不再需要再删", "en": "Archived app builds (.ipa); useful before App Store uploads; review before deleting"}},
    {"id": "dev.simulator-devices", "category": "dev", "safety": "cautious",
     "path": "~/Library/Developer/CoreSimulator/Devices",
     "description": {"zh-Hans": "iOS 模拟器设备数据,删除后模拟器恢复出厂状态", "en": "Simulator device data; simulators reset to a clean state"}},
    {"id": "dev.npm-cache", "category": "dev", "safety": "safe",
     "path": "~/.npm/_cacache",
     "description": {"zh-Hans": "npm 包缓存,npm 自动重新下载", "en": "npm package cache; re-downloaded automatically"}},
    {"id": "dev.pip-cache", "category": "dev", "safety": "safe",
     "path": "~/Library/Caches/pip",
     "description": {"zh-Hans": "pip 包缓存", "en": "pip package cache"}},
    {"id": "dev.gradle-caches", "category": "dev", "safety": "safe",
     "path": "~/.gradle/caches",
     "description": {"zh-Hans": "Gradle 依赖与构建缓存,首次构建会变慢", "en": "Gradle dependency & build caches; first build after cleanup is slower"}},
    {"id": "dev.homebrew-cache", "category": "dev", "safety": "safe",
     "path": "~/Library/Caches/Homebrew",
     "description": {"zh-Hans": "Homebrew 下载缓存", "en": "Homebrew download cache"}},
    {"id": "dev.swiftpm-cache", "category": "dev", "safety": "safe",
     "path": "~/Library/Caches/org.swift.swiftpm",
     "description": {"zh-Hans": "SwiftPM 编译清单缓存", "en": "SwiftPM manifest caches"}},
    {"id": "dev.cocoapods-cache", "category": "dev", "safety": "safe",
     "path": "~/Library/Caches/CocoaPods",
     "description": {"zh-Hans": "CocoaPods 包缓存", "en": "CocoaPods package cache"}},
    {"id": "dev.dot-cache", "category": "dev", "safety": "cautious",
     "path": "~/.cache",
     "description": {"zh-Hans": "unix 风格缓存目录(uv/puppeteer 等),个别工具也放数据,请核对后清理", "en": "Unix-style cache dir (uv/puppeteer etc.); some tools also store data here, review first"}},
    {"id": "apps.chrome-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Caches/Google/Chrome",
     "description": {"zh-Hans": "Chrome 浏览器缓存(不含密码、历史、书签)", "en": "Chrome browser cache (no passwords, history or bookmarks)"}},
    {"id": "apps.edge-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Caches/Microsoft Edge",
     "description": {"zh-Hans": "Edge 浏览器缓存", "en": "Edge browser cache"}},
    {"id": "apps.brave-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Caches/BraveSoftware/Brave-Browser",
     "description": {"zh-Hans": "Brave 浏览器缓存", "en": "Brave browser cache"}},
    {"id": "apps.firefox-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Caches/Firefox",
     "description": {"zh-Hans": "Firefox 浏览器缓存", "en": "Firefox browser cache"}},
    {"id": "apps.spotify-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Caches/com.spotify.client",
     "description": {"zh-Hans": "Spotify 流媒体缓存,重新播放时重新下载", "en": "Spotify streaming cache; re-downloaded on playback"}},
    {"id": "apps.slack-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Caches/com.tinyspeck.slackmacgap",
     "description": {"zh-Hans": "Slack 缓存", "en": "Slack cache"}},
    {"id": "apps.vscode-cache", "category": "apps", "safety": "safe",
     "path": "~/Library/Application Support/Code/Cache",
     "description": {"zh-Hans": "VS Code 运行时缓存", "en": "VS Code runtime caches"}},
    {"id": "apps.vscode-cacheddata", "category": "apps", "safety": "safe",
     "path": "~/Library/Application Support/Code/CachedData",
     "description": {"zh-Hans": "VS Code 扩展宿主缓存", "en": "VS Code extension-host caches"}},
    {"id": "apps.wechat-cache", "category": "apps", "safety": "cautious",
     "path": "~/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches",
     "description": {"zh-Hans": "微信缓存(聊天记录不在本目录,但请先退出微信)", "en": "WeChat cache (chat history lives elsewhere, but quit WeChat first)"}},
    {"id": "cautious.ios-backups", "category": "cautious", "safety": "cautious",
     "path": "~/Library/Application Support/MobileSync/Backup",
     "description": {"zh-Hans": "iPhone/iPad 整机备份,删除后无法恢复旧备份", "en": "iPhone/iPad device backups; deleted backups cannot be restored"}},
    {"id": "cautious.macos-installers", "category": "cautious", "safety": "cautious",
     "path": "/Applications", "include": ["Install macOS *.app"],
     "description": {"zh-Hans": "macOS 系统安装器(通常 12GB+)", "en": "macOS installers (usually 12GB+)"}},
    {"id": "cautious.tm-snapshots", "category": "cautious", "safety": "cautious",
     "path": "~/", "action": "tmutil-thin",
     "description": {"zh-Hans": "本地 Time Machine 快照,清理后 24 小时内的本地还原点将减少", "en": "Local Time Machine snapshots; local restore points within 24h are reduced"}}
  ]
}
```

- [ ] **Step 4: 删除占位文件,运行确认通过**

```bash
rm Sources/ScanKit/Resources/.keep
swift test --filter BundledRulesTests
```

Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(ScanKit): 首发规则库 27 条(四类,含排除与 tmutil-thin)"
```

---

### Task 7: ScanKit · ScanModels + ScanEngine 默认模式

**Files:**
- Create: `Sources/ScanKit/ScanModels.swift`、`Sources/ScanKit/ScanEngine.swift`
- Test: `Tests/ScanKitTests/ScanFixtures.swift`、`Tests/ScanKitTests/ScanEngineTests.swift`

- [ ] **Step 1: 写 fixture 与失败测试**

`Tests/ScanKitTests/ScanFixtures.swift`:

```swift
import Foundation

enum ScanFixtures {
    /// 构造固定目录树,返回根路径
    static func makeTree() -> String {
        let root = NSTemporaryDirectory() + "raccoon-scan-\(UUID().uuidString)"
        let fm = FileManager.default
        func mkdir(_ rel: String) { try? fm.createDirectory(atPath: root + "/" + rel, withIntermediateDirectories: true) }
        func write(_ rel: String, _ bytes: Int) {
            try? Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: root + "/" + rel))
        }
        mkdir("Caches/com.google.Chrome/Cache")
        write("Caches/com.google.Chrome/Cache/f1", 100)
        write("Caches/com.google.Chrome/Cache/f2", 200)
        mkdir("Caches/com.spotify.client")
        write("Caches/com.spotify.client/data", 50)
        write("Caches/stray.log", 10)
        mkdir("Logs/app"); write("Logs/app/a.log", 30)
        mkdir("nested/deep"); write("nested/.DS_Store", 3); write("nested/deep/.DS_Store", 7)
        return root
    }

    static func remove(_ root: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
        try? FileManager.default.removeItem(atPath: root)
    }

    static func rule(id: String, path: String, category: RuleCategory = .system,
                     safety: SafetyLevel = .safe, include: [String]? = nil,
                     exclude: [String]? = nil) -> CleanupRule {
        CleanupRule(id: id, category: category, safety: safety, path: path,
                    include: include, exclude: exclude, action: nil, description: nil)
    }

    /// 进度事件累积器:Swift 6 禁止在 @Sendable 闭包里捕获可变局部变量,
    /// 测试用它收集进度回调(progress 回调实际在调用方任务串行触发,锁仅为类型合规兜底)。
    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScanProgress] = []
        func append(_ p: ScanProgress) { lock.lock(); defer { lock.unlock() }; items.append(p) }
        var events: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
```

`Tests/ScanKitTests/ScanEngineTests.swift`(本 Task 只写默认模式部分):

```swift
import XCTest
import CleanKit
@testable import ScanKit

final class ScanEngineTests: XCTestCase {
    var root: String!

    override func setUp() { root = ScanFixtures.makeTree() }
    override func tearDown() { ScanFixtures.remove(root) }

    func engine(protection: ProtectionStore = ProtectionStore(),
                running: Set<String> = [],
                limit: Int = 500_000) -> ScanEngine {
        ScanEngine(deps: .init(protection: protection,
                               runningBundleIDs: { running },
                               snapshots: MockSnapshots(),
                               itemLimitPerRule: limit))
    }

    // MARK: 默认模式(根的一级子项 = 删除单元)

    func testDefaultMode_childrenAreHits_withDeepSize() async throws {
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let hits = result.hits
        XCTAssertEqual(hits.count, 3)   // com.google.Chrome / com.spotify.client / stray.log
        let chrome = try XCTUnwrap(hits.first { $0.path.hasSuffix("com.google.Chrome") })
        XCTAssertEqual(chrome.sizeBytes, 300)
        XCTAssertTrue(chrome.isDirectory)
        XCTAssertEqual(chrome.ruleID, "c")
        XCTAssertEqual(chrome.category, .system)
        XCTAssertEqual(chrome.safety, .safe)
        XCTAssertEqual(chrome.action, .trash)
    }

    func testDefaultMode_excludeMatchesLastComponent() async throws {
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches", exclude: ["com.spotify.client", "*.log"])])
        XCTAssertEqual(result.hits.map(\.path).sorted(), [root + "/Caches/com.google.Chrome"])
        XCTAssertEqual(result.excludedCount, 2)
    }

    func testDefaultMode_userExclusionFiltersHit() async throws {
        let protection = ProtectionStore(userExclusions: [root + "/Caches/com.google.Chrome"])
        let result = try await engine(protection: protection).scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(result.excludedCount, 1)
    }

    func testDefaultMode_runningAppFlagged() async throws {
        let result = try await engine(running: ["com.google.Chrome"]).scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let chrome = try XCTUnwrap(result.hits.first { $0.bundleID == "com.google.Chrome" })
        XCTAssertTrue(chrome.isAppRunning)
        let spotify = try XCTUnwrap(result.hits.first { $0.path.hasSuffix("com.spotify.client") })
        XCTAssertFalse(spotify.isAppRunning)
    }

    func testDefaultMode_tildeExpansion() async throws {
        // ~ 展开正确性:用真实 ~/Library/Logs 目录存在与否都应安全返回(0 条或若干条,不抛错)
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "l", path: "~/Library/Logs_nonexistent")])
        XCTAssertEqual(result.hits.count, 0)
    }

    func testDefaultMode_missingRootYieldsEmpty() async throws {
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "x", path: root + "/nope")])
        XCTAssertEqual(result.hits.count, 0)
    }

    func testDefaultMode_symlinkChildNotBlownUp() async throws {
        let target = root + "/Caches/com.google.Chrome"
        try FileManager.default.createSymbolicLink(atPath: root + "/Caches/loop", withDestinationPath: target)
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let loop = try XCTUnwrap(result.hits.first { $0.path.hasSuffix("/loop") })
        XCTAssertEqual(loop.sizeBytes, 0)   // 符号链接按 0 计,不深入目标
    }

    func testDefaultMode_itemLimitTruncates() async throws {
        let result = try await engine(limit: 2).scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(result.truncatedRuleIDs, Set(["c"]))   // truncatedRuleIDs 是 Set<String>
    }

    func testProgress_eventsPerRule() async throws {
        let log = ScanFixtures.ProgressLog()
        _ = try await engine().scan(rules: [
            ScanFixtures.rule(id: "a", path: root + "/Caches"),
            ScanFixtures.rule(id: "b", path: root + "/Logs"),
        ]) { log.append($0) }
        let events = log.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.rulesDone, 2)
        XCTAssertEqual(events.last?.rulesTotal, 2)
    }

    func testSummaries_aggregatedByCategory() async throws {
        let result = try await engine().scan(rules: [
            ScanFixtures.rule(id: "c", path: root + "/Caches"),
            ScanFixtures.rule(id: "l", path: root + "/Logs", category: .dev),
        ])
        XCTAssertEqual(result.summaries.count, 2)
        let system = try XCTUnwrap(result.summaries.first { $0.category == .system })
        XCTAssertEqual(system.totalBytes, 360)
        XCTAssertEqual(system.hitCount, 3)
    }
}
```

同时把 Task 3 的 `MockSnapshots` 从 `CleanExecutorTests.swift` 移到共享位置——将 actor 定义剪切到新文件 `Tests/CleanKitTests/Mocks.swift` 顶部并在 `CleanKitTests` target 用法不变;ScanKitTests 需要 a 的同款,在 `Tests/ScanKitTests/` 下新建 `Mocks.swift`:

```swift
import CleanKit

actor MockSnapshots: SnapshotCleanerServicing {
    let listed: [String]
    private(set) var deleted: [String] = []
    init(listed: [String] = []) { self.listed = listed }
    func listSnapshots() -> [String] { listed }
    func deleteSnapshot(_ date: String) -> Bool { deleted.append(date); return true }
}
```

(CleanKitTests 侧的同名 actor 保留原处即可,两个 test target 各自独立编译。)

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter ScanEngineTests`
Expected: 编译错误(类型未定义)

- [ ] **Step 3: 实现 ScanModels**

`Sources/ScanKit/ScanModels.swift`:

```swift
import Foundation
import CleanKit

public struct ScanHit: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let ruleID: String
    public let category: RuleCategory
    public let safety: SafetyLevel
    public let path: String
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let bundleID: String?
    public let appName: String?
    public let isAppRunning: Bool
    public let action: RuleAction
    public let snapshotDate: String?

    public init(ruleID: String, category: RuleCategory, safety: SafetyLevel, path: String,
                sizeBytes: Int64, isDirectory: Bool = false, bundleID: String? = nil,
                appName: String? = nil, isAppRunning: Bool = false,
                action: RuleAction = .trash, snapshotDate: String? = nil) { /* 逐字段赋值 */ }

    public var cleanItem: CleanItem {
        CleanItem(path: path, sizeBytes: sizeBytes,
                  action: action == .tmutilThin ? .tmutilThin(date: snapshotDate) : .trash)
    }
}

public struct CategorySummary: Identifiable, Equatable, Sendable {
    public let category: RuleCategory
    public let totalBytes: Int64
    public let hitCount: Int
    public var id: RuleCategory { category }
    public init(category: RuleCategory, totalBytes: Int64, hitCount: Int) { /* 赋值 */ }
}

public struct ScanProgress: Equatable, Sendable {
    public let rulesDone: Int
    public let rulesTotal: Int
    public let hitsFound: Int
    public let bytesFound: Int64
    public init(rulesDone: Int, rulesTotal: Int, hitsFound: Int, bytesFound: Int64) { /* 赋值 */ }
}

public struct ScanResult: Sendable {
    public let hits: [ScanHit]
    public let summaries: [CategorySummary]
    public let permissionSkippedCount: Int
    public let truncatedRuleIDs: Set<String>
    public let excludedCount: Int
    public init(hits: [ScanHit], summaries: [CategorySummary], permissionSkippedCount: Int,
                truncatedRuleIDs: Set<String>, excludedCount: Int) { /* 赋值 */ }
}

public protocol ScanServicing: Sendable {
    func scan(exclusions: [String],
              progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult
}
```

(实现时把 `/* 赋值 */` 写成逐字段赋值;`isDirectory` 对目录为 true。)

- [ ] **Step 4: 实现 ScanEngine(默认模式 + 聚合,include 模式本 Task 返回空实现)**

`Sources/ScanKit/ScanEngine.swift`:

```swift
import Foundation
import CleanKit

public struct ScanEngine: Sendable {
    public struct Dependencies: @unchecked Sendable {
        // @unchecked:本机 SDK 的 FileManager 未标注 Sendable(官方文档保证共享实例线程安全);
        // 与 CleanKit/JSONHistoryStore 的 nonisolated(unsafe) 豁免同一先例。
        public let protection: ProtectionStore
        public let runningBundleIDs: @Sendable () async -> Set<String>
        public let snapshots: SnapshotCleanerServicing
        public let itemLimitPerRule: Int
        let fileManager: FileManager

        public init(protection: ProtectionStore,
                    runningBundleIDs: @escaping @Sendable () async -> Set<String> = { [] },
                    snapshots: SnapshotCleanerServicing = TmutilSnapshotCleaner(),
                    itemLimitPerRule: Int = 500_000,
                    fileManager: FileManager = .default) {
            self.protection = protection
            self.runningBundleIDs = runningBundleIDs
            self.snapshots = snapshots
            self.itemLimitPerRule = itemLimitPerRule
            self.fileManager = fileManager
        }
    }

    struct RuleOutcome: Sendable {
        var hits: [ScanHit] = []
        var permissionSkipped = 0
        var truncated = false
        var excluded = 0
    }

    let deps: Dependencies
    let identity: AppIdentityResolver

    public init(deps: Dependencies, identity: AppIdentityResolver = AppIdentityResolver()) {
        self.deps = deps; self.identity = identity
    }

    public func scan(rules: [CleanupRule],
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResult {
        let running = await deps.runningBundleIDs()
        let total = max(rules.count, 1)
        var done = 0
        var outcomes = [RuleOutcome?](repeating: nil, count: rules.count)

        try await withThrowingTaskGroup(of: (Int, RuleOutcome).self) { group in
            for (idx, rule) in rules.enumerated() {
                // include 全盘匹配(.DS_Store)属低优先级长任务
                let priority: TaskPriority = (rule.include?.isEmpty == false) ? .low : .userInitiated
                group.addTask(priority: priority) { (idx, try await self.walk(rule: rule, running: running)) }
            }
            for try await (idx, outcome) in group {
                outcomes[idx] = outcome
                done += 1
                let hits = outcomes.compactMap(\.self).flatMap(\.hits)
                progress(ScanProgress(rulesDone: done, rulesTotal: total,
                                      hitsFound: hits.count,
                                      bytesFound: hits.reduce(Int64(0)) { $0 + $1.sizeBytes }))
            }
        }

        // 应用名解析依赖 NSWorkspace(@MainActor):扫描收尾时在主线程批量补齐一次
        let rawHits = outcomes.compactMap(\.self).flatMap(\.hits)
        let hits = await MainActor.run { Self.resolveAppNames(rawHits, resolver: identity) }
        let byCat = Dictionary(grouping: hits, by: \.category)
        let summaries = RuleCategory.allCases.compactMap { cat -> CategorySummary? in
            guard let list = byCat[cat] else { return nil }
            return CategorySummary(category: cat,
                                   totalBytes: list.reduce(Int64(0)) { $0 + $1.sizeBytes },
                                   hitCount: list.count)
        }
        let truncated = Set(zip(rules, outcomes.compactMap(\.self)).filter { $0.1.truncated }.map(\.0.id))
        return ScanResult(hits: hits,
                          summaries: summaries,
                          permissionSkippedCount: outcomes.compactMap(\.self).reduce(0) { $0 + $1.permissionSkipped },
                          truncatedRuleIDs: truncated,
                          excludedCount: outcomes.compactMap(\.self).reduce(0) { $0 + $1.excluded })
    }

    func walk(rule: CleanupRule, running: Set<String>) async throws -> RuleOutcome {
        try Task.checkCancellation()
        guard rule.effectiveAction == .trash else { return await snapshotHits(rule: rule) }
        if let include = rule.include, !include.isEmpty {
            return try walkIncludeMode(rule: rule, include: include, running: running)   // Task 8 实现
        }
        return try await walkDefaultMode(rule: rule, running: running)
    }

    func snapshotHits(rule: CleanupRule) async -> RuleOutcome {
        // SnapshotCleanerServicing.listSnapshots 为 async(tmutil 子进程),
        // 此处必须 await;walk 调用点相应为 `return await snapshotHits(rule: rule)`。
        let hits = await deps.snapshots.listSnapshots()
        return RuleOutcome(hits: hits.map { date in
            ScanHit(ruleID: rule.id, category: rule.category, safety: rule.safety,
                    path: "tmutil://\(date)", sizeBytes: 0, isDirectory: false,
                    bundleID: nil, appName: nil, isAppRunning: false,
                    action: .tmutilThin, snapshotDate: date)
        })
    }

    // MARK: 默认模式:根的一级子项作为删除单元

    func walkDefaultMode(rule: CleanupRule, running: Set<String>) async throws -> RuleOutcome {
        var outcome = RuleOutcome()
        let rootPath = ProtectionStore.normalize(rule.path)
        let fm = deps.fileManager
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else { return outcome }

        let children = ((try? fm.contentsOfDirectory(atPath: rootPath)) ?? []).sorted()
        var count = 0
        for name in children {
            try Task.checkCancellation()
            count += 1
            if count > deps.itemLimitPerRule { outcome.truncated = true; break }

            let full = rootPath + "/" + name
            if deps.protection.isDenied(full) || Self.matchesAny(name, rule.exclude) {
                outcome.excluded += 1; continue
            }
            guard fm.isReadableFile(atPath: full) else { outcome.permissionSkipped += 1; continue }
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &childIsDir) else {
                outcome.permissionSkipped += 1; continue
            }
            // 符号链接:不深入目标,按 0 字节计(删除链接本身无害)
            let symlink = Self.isSymlink(full)
            let size = symlink ? 0 : Self.deepSize(path: full, fm: fm)
            let bid = AppIdentityResolver.bundleIDComponent(in: full)
            outcome.hits.append(ScanHit(ruleID: rule.id, category: rule.category, safety: rule.safety,
                                        path: full, sizeBytes: size, isDirectory: childIsDir.boolValue,
                                        bundleID: bid, appName: nil,
                                        isAppRunning: bid.map { running.contains($0) } ?? false,
                                        action: .trash, snapshotDate: nil))
        }
        return outcome
    }

    /// 收尾批量补齐 appName(NSWorkspace 限 MainActor)。Task 4 审查义务:NSWorkspace 查询
    /// 昂贵,必须先按 bundleID 去重再查、一次构建 [bundleID: name] 后回填,禁止逐 hit 查询。
    @MainActor
    static func resolveAppNames(_ hits: [ScanHit], resolver: AppIdentityResolver) -> [ScanHit] {
        let bundleIDs = Set(hits.compactMap(\.bundleID))
        guard !bundleIDs.isEmpty else { return hits }
        var names: [String: String] = [:]
        for bid in bundleIDs {
            if let n = resolver.appName(for: bid) { names[bid] = n }
        }
        return hits.map { hit in
            guard let bid = hit.bundleID, let name = names[bid], name != hit.appName else { return hit }
            return ScanHit(ruleID: hit.ruleID, category: hit.category, safety: hit.safety,
                           path: hit.path, sizeBytes: hit.sizeBytes, isDirectory: hit.isDirectory,
                           bundleID: hit.bundleID, appName: name, isAppRunning: hit.isAppRunning,
                           action: hit.action, snapshotDate: hit.snapshotDate)
        }
    }

    // MARK: 工具

    static func matchesAny(_ name: String, _ patterns: [String]?) -> Bool {
        guard let patterns, !patterns.isEmpty else { return false }
        return patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    /// 递归统计常规文件字节;不跟随目录符号链接。
    /// 根本身为常规文件时返回其自身大小(enumerator(atPath:) 对普通文件产出空序列,
    /// 一级子文件如 stray.log 须按自身字节计入聚合)。
    static func deepSize(path: String, fm: FileManager) -> Int64 {
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
           let n = attrs[.size] as? NSNumber {
            return n.int64Value
        }
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let rel = en.nextObject() as? String {
            let attrs = try? fm.attributesOfItem(atPath: path + "/" + rel)
            if let type = attrs?[.type] as? FileAttributeType, type == .typeRegular,
               let n = attrs?[.size] as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }
}
```

注意:`walk` 里引用的 `walkIncludeMode` 属于 Task 8,本 Task 编译需要占位——在 ScanEngine.swift 里加最小实现(带 `// Task 8 实现` 注释;Task 8 以完整实现替换):

```swift
    func walkIncludeMode(rule: CleanupRule, include: [String], running: Set<String>) throws -> RuleOutcome {
        // Task 8 实现:include 全盘匹配模式
        RuleOutcome()
    }
```

- [ ] **Step 5: 运行确认通过**

Run: `Scripts/test.sh --filter ScanEngineTests`
Expected: `Executed 10 tests, with 0 failures`

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(ScanKit): ScanEngine 默认模式(一级子项=删除单元)+ 聚合/进度/符号链接防御"
```

### Task 8: ScanEngine · include 模式 + 加固(权限/取消/快照集成)

**Files:**
- Modify: `Sources/ScanKit/ScanEngine.swift`(补 `walkIncludeMode`、`fileSize`)
- Test: `Tests/ScanKitTests/ScanEngineTests.swift`(追加)

**Task 7 质量审查义务(实现本 Task 时一并落实,逐项执行):**
1. **符号链接语义统一(walkDefaultMode)**:`isSymlink` 判定提前到 `isReadableFile`/`fileExists` 两个 guard **之前**(仍在 isDenied/exclude 之后);命中即按 0 字节、`isDirectory: false` 收录为 hit,不论目标是否存活——悬空链接可安全进废纸篓,是清理目标,不得计入 permissionSkipped。
2. **deepSize 不跟随符号链接**:主循环改用枚举器自带属性 `en.fileAttributes`(描述条目本身,符号链接为 typeSymlink 不计入),与顶层 0 字节策略一致;根为常规文件的早返回分支保留;注释同步修正。
3. **根不可读显式计数**:`contentsOfDirectory` 之前 `guard fm.isReadableFile(atPath: rootPath) else { outcome.permissionSkipped += 1; return outcome }`。
4. **截断对齐类型化**:`truncated` 改为 `zip(rules, outcomes)` + guard let,消除 compactMap 压缩导致的隐含对齐不变量:
   ```swift
   let truncated = Set(zip(rules, outcomes).compactMap { rule, outcome -> String? in
       guard let outcome, outcome.truncated else { return nil }
       return rule.id
   })
   ```
5. **匹配大小写不敏感**:`matchesAny` 的 `fnmatch` 加 `FNM_CASEFOLD`(与保护层"宁可多拦不可漏放"策略对齐;排除更多=展示更少,方向保守)。
6. **聚合按 path 去重**:scan() 收尾(appName 解析后、分类聚合前)`var seen = Set<String>(); let deduped = hits.filter { seen.insert($0.path).inserted }`,以 deduped 继续聚合与返回(include 模式落地后跨规则同路径是现实风险)。
7. **进度累计化**:消费循环维护 `totalHits`/`totalBytes` 运行总量,progress 用累计值,不再每事件重算全 outcomes。
8. (仅记录,不改)deepSize 同步阻塞协作线程——规模化后再桥接全局队列。

- [ ] **Step 1: 追加失败测试**

在 `Tests/ScanKitTests/ScanEngineTests.swift` 末尾追加:

```swift
    // MARK: include 模式(文件名 glob 白名单)

    func testIncludeMode_dsStoreAcrossTree() async throws {
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "ds", path: root, include: [".DS_Store"])])
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(result.hits.reduce(0) { $0 + $1.sizeBytes }, 10)
        XCTAssertTrue(result.hits.allSatisfy { !$0.isDirectory })
    }

    func testIncludeMode_protectionSkipsSubtree() async throws {
        let protection = ProtectionStore(userExclusions: [root + "/nested/deep"])
        let result = try await engine(protection: protection).scan(
            rules: [ScanFixtures.rule(id: "ds", path: root, include: [".DS_Store"])])
        XCTAssertEqual(result.hits.count, 1)          // 仅 nested/.DS_Store
        XCTAssertEqual(result.excludedCount, 1)
    }

    func testIncludeMode_directoryHitsGlob_installedInstallerStyle() async throws {
        // 模拟 /Applications 安装器规则:目录命中 glob → 整目录为一个删除单元
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Install macOS Test.app/Contents", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 15).write(to: URL(fileURLWithPath: root + "/Install macOS Test.app/Contents/PkgInfo"))
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "inst", path: root, include: ["Install macOS *.app"])])
        XCTAssertEqual(result.hits.count, 1)
        let hit = try XCTUnwrap(result.hits.first)
        XCTAssertTrue(hit.isDirectory)
        XCTAssertEqual(hit.sizeBytes, 15)
    }

    // MARK: 权限与取消

    func testDefaultMode_unreadableChildCountedSkipped() async throws {
        try XCTSkipIf(geteuid() == 0, "root 下权限测试无意义")
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Caches/locked", withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/Caches/locked")
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/Caches/locked") }
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        XCTAssertFalse(result.hits.contains { $0.path.hasSuffix("/locked") })
        XCTAssertEqual(result.permissionSkippedCount, 1)
    }

    func testCancellation_throws() async {
        let task = Task { try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("应抛 CancellationError") }
        catch is CancellationError {}
        catch { XCTFail("意外错误:\(error)") }
    }

    // MARK: 快照规则

    func testSnapshotRule_producesHitsFromLister() async throws {
        let rule = CleanupRule(id: "snap", category: .cautious, safety: .cautious, path: "~",
                               include: nil, exclude: nil, action: .tmutilThin, description: nil)
        let e = ScanEngine(deps: .init(protection: ProtectionStore(), runningBundleIDs: { [] },
                                       snapshots: MockSnapshots(listed: ["2026-10-13-120000", "2026-10-12-090000"])))
        let result = try await e.scan(rules: [rule])
        XCTAssertEqual(result.hits.count, 2)
        let first = try XCTUnwrap(result.hits.first)
        XCTAssertEqual(first.path, "tmutil://2026-10-13-120000")
        XCTAssertEqual(first.action, .tmutilThin)
        XCTAssertEqual(first.cleanItem.action, .tmutilThin(date: "2026-10-13-120000"))
        XCTAssertEqual(first.category, .cautious)
    }

    // Task 7 质量 Minor 1:悬空符号链接是清理目标,应 0 字节收录,不落 permissionSkipped
    func testDefaultMode_danglingSymlinkIsZeroByteHit() async throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/Caches/dangling",
                                                   withDestinationPath: root + "/Caches/nowhere")
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let dangling = try XCTUnwrap(result.hits.first { $0.path.hasSuffix("/dangling") })
        XCTAssertEqual(dangling.sizeBytes, 0)
        XCTAssertFalse(dangling.isDirectory)
        XCTAssertEqual(result.permissionSkippedCount, 0)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter ScanEngineTests`
Expected: 新增 7 个用例失败(include 模式返回空、快照/权限未接)
> **实际记录:**红 4 例(include×3 + 悬空链接×1);unreadableChild/cancellation/snapshot 3 例测的是 Task 7 已接好的路径,改造前即绿(回归守卫)——本行预期为任务文本算术错误,红→绿纪律对 4 个真正新增行为成立。cancellation 测试的 Task 闭包需先提升 Sendable 局部值再捕获(RegionIsolation),已授权。

- [ ] **Step 3: 实现 walkIncludeMode**

在 `Sources/ScanKit/ScanEngine.swift` 的 `walkDefaultMode` 之后追加,并在 `matchesAny` 附近补 `fileSize`:

```swift
    // MARK: include 模式:全树匹配文件名 glob;命中目录整体为删除单元

    func walkIncludeMode(rule: CleanupRule, include: [String], running: Set<String>) throws -> RuleOutcome {
        var outcome = RuleOutcome()
        let rootPath = ProtectionStore.normalize(rule.path)
        let fm = deps.fileManager
        guard let en = fm.enumerator(atPath: rootPath) else { return outcome }
        var count = 0
        while let rel = en.nextObject() as? String {
            try Task.checkCancellation()
            count += 1
            if count > deps.itemLimitPerRule { outcome.truncated = true; break }

            let full = rootPath + "/" + rel
            let name = (rel as NSString).lastPathComponent
            let symlink = Self.isSymlink(full)
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: full, isDirectory: &isDir)
            let dirAndNotSymlink = isDir.boolValue && !symlink

            if Self.matchesAny(name, include) {
                if deps.protection.isDenied(full) || Self.matchesAny(name, rule.exclude) {
                    outcome.excluded += 1
                    if dirAndNotSymlink { en.skipDescendants() }
                    continue
                }
                guard fm.isReadableFile(atPath: full) else { outcome.permissionSkipped += 1; continue }
                let size = dirAndNotSymlink ? Self.deepSize(path: full, fm: fm) : Self.fileSize(path: full, fm: fm)
                let bid = AppIdentityResolver.bundleIDComponent(in: full)
                outcome.hits.append(ScanHit(ruleID: rule.id, category: rule.category, safety: rule.safety,
                                            path: full, sizeBytes: size, isDirectory: dirAndNotSymlink,
                                            bundleID: bid, appName: nil,
                                            isAppRunning: bid.map { running.contains($0) } ?? false,
                                            action: .trash, snapshotDate: nil))
                if dirAndNotSymlink { en.skipDescendants() }   // 整目录删除,内部不再列举
                continue
            }
            // 未命中 glob 的目录:受保护则剪枝
            if dirAndNotSymlink && deps.protection.isDenied(full) {
                en.skipDescendants()
                outcome.excluded += 1
            }
        }
        return outcome
    }

    static func fileSize(path: String, fm: FileManager) -> Int64 {
        (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
    }
```

> **质量审查后已删除(31facf1):**上段代码中的 `fileSize` 助手与本节正文里的 `dirAndNotSymlink`/`fileSize` 取值路径已被整体替换——`attributesOfItem` 是 stat 语义(跟随符号链接),活链接命中 glob 会把目标大小计入释放量(虚高至 GB 级)。质量修复后 walkIncludeMode 统一用 `en.fileAttributes`(lstat 语义):typeSymbolicLink → 0 字节(分支位于 isReadableFile 之前,与默认模式义务 1 对称)、typeRegular → 条目自身 size、typeDirectory → deepSize、其余特殊条目 → 0。本节保留原文仅作历史记录,**以 31facf1 为准**。

- [ ] **Step 4: 运行确认通过(全量)**

Run: `Scripts/test.sh`
Expected: 全绿(ScanEngineTests 17 例;质量修复轮后为 **19 例**、全量 67 例,见下)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(ScanKit): include 全树匹配(目录命中即整目录)+ 权限跳过 + 取消 + 快照规则"
```

**质量修复轮记录(commit 31facf1,两阶段审查通过):**
1. 【Important】include 活链接 sizeBytes 报目标大小 → `en.fileAttributes` lstat 语义 + 符号链接 0 字节(见上方删除注)
2. 【Important】`rule.exclude` 无法剪目录子树(include `*.log` + exclude `node_modules` 场景)→ 未命中 glob 的目录剪枝条件加 `|| matchesAny(name, rule.exclude)`
3. 【Important】include 模式根不可读静默空返回 → 枚举前镜像默认模式 guard(义务字面仅限默认模式,按对称性裁决为修)
4. 【Minor】进度(去重前)与 ScanResult.hits(去重后)口径差 → 累加处注释标注
5. 【Minor】根不可读分支无测试 → 新增 `rootUnreadableCountedSkipped_bothModes`(两模式对称断言)+ `includeMode_danglingSymlinkIsZeroByteHit`(include 悬空链接钉)

---

### Task 9: AppCore · ExclusionsStore

**Files:**
- Create: `Sources/AppCore/ExclusionsStore.swift`
- Test: `Tests/AppCoreTests/ExclusionsStoreTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/AppCoreTests/ExclusionsStoreTests.swift`:

```swift
import XCTest
import CleanKit
@testable import AppCore

final class ExclusionsStoreTests: XCTestCase {
    var suite: String!
    var defaults: UserDefaults!

    override func setUp() {
        suite = "excl-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    @MainActor
    func testAddNormalizeDedupeAndPersist() {
        let store = ExclusionsStore(defaults: defaults)
        store.add("/tmp/foo/")
        XCTAssertEqual(store.exclusions, ["/tmp/foo"])           // 尾斜杠归一化
        store.add("/tmp/foo")                                     // 去重
        XCTAssertEqual(store.exclusions.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "userExclusions"), ["/tmp/foo"])   // 已持久化
    }

    @MainActor
    func testRemoveAndReload() {
        let store = ExclusionsStore(defaults: defaults)
        store.add("/tmp/a"); store.add("/tmp/b")
        store.remove("/tmp/a")
        XCTAssertEqual(store.exclusions, ["/tmp/b"])
        let reloaded = ExclusionsStore(defaults: defaults)        // 从 defaults 重载
        XCTAssertEqual(reloaded.exclusions, ["/tmp/b"])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter ExclusionsStoreTests`
Expected: 编译错误(类型未定义)

- [ ] **Step 3: 实现**

`Sources/AppCore/ExclusionsStore.swift`:

```swift
import Foundation
import CleanKit

@MainActor
@Observable
public final class ExclusionsStore {
    static let defaultsKey = "userExclusions"
    let defaults: UserDefaults
    public private(set) var exclusions: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.exclusions = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    public func add(_ path: String) {
        let normalized = ProtectionStore.normalize(path)
        guard !normalized.isEmpty, !exclusions.contains(normalized) else { return }
        exclusions.append(normalized)
        persist()
    }

    public func remove(_ path: String) {
        exclusions.removeAll { $0 == path }
        persist()
    }

    func persist() { defaults.set(exclusions, forKey: Self.defaultsKey) }
}
```

- [ ] **Step 4: 运行确认通过 + Commit**

Run: `Scripts/test.sh --filter ExclusionsStoreTests`
Expected: `Executed 2 tests, with 0 failures`

```bash
git add -A && git commit -m "feat(AppCore): 用户排除清单(@Observable + UserDefaults 持久化)"
```

---

### Task 10: AppCore · ScanViewModel + AppScanService

**Files:**
- Create: `Sources/AppCore/AppScanService.swift`、`Sources/AppCore/ScanViewModel.swift`
- Test: `Tests/AppCoreTests/TestSupport.swift`、`Tests/AppCoreTests/ScanViewModelTests.swift`

- [ ] **Step 1: 写失败测试**

`Tests/AppCoreTests/TestSupport.swift`:

```swift
import Foundation
import CleanKit
import ScanKit
@testable import AppCore

struct FakeScanService: ScanServicing {
    var result: ScanResult
    func scan(exclusions: [String],
              progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        progress(ScanProgress(rulesDone: 1, rulesTotal: 1,
                              hitsFound: result.hits.count,
                              bytesFound: result.hits.reduce(Int64(0)) { $0 + $1.sizeBytes }))
        return result
    }
}

actor MockTrash: TrashServicing {
    let outcome: TrashOutcome
    let vanishedFor: Set<String>   // 指定路径强制返回 .vanished(模拟文件已消失)
    private(set) var calls: [String] = []
    init(outcome: TrashOutcome, vanishedFor: [String] = []) {
        self.outcome = outcome
        self.vanishedFor = Set(vanishedFor)
    }
    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        return vanishedFor.contains(path) ? .vanished : outcome
    }
}
```

`Tests/AppCoreTests/ScanViewModelTests.swift`:

```swift
import XCTest
import CleanKit
import ScanKit
@testable import AppCore

@MainActor
final class ScanViewModelTests: XCTestCase {
    var dir: URL!
    override func setUp() { dir = URL(fileURLWithPath: NSTemporaryDirectory() + "raccoon-vm-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func makeVM(service: ScanServicing, trash: TrashServicing) -> ScanViewModel {
        ScanViewModel(service: service,
                      exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!),
                      history: JSONHistoryStore(directory: dir),
                      trash: trash)
    }

    func hit(_ path: String, size: Int64, safety: SafetyLevel = .safe,
             running: Bool = false, category: RuleCategory = .system) -> ScanHit {
        ScanHit(ruleID: "r", category: category, safety: safety, path: path, sizeBytes: size,
                isDirectory: false, bundleID: nil, appName: nil, isAppRunning: running,
                action: .trash, snapshotDate: nil)
    }

    func testScanFlow_stateMachineAndDefaultSelection() async {
        let svc = FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20, safety: .cautious), hit("/c", 30, running: true)],
            summaries: [.init(category: .system, totalBytes: 60, hitCount: 3)],
            permissionSkippedCount: 1, truncatedRuleIDs: [], excludedCount: 0))
        let vm = makeVM(service: svc, trash: MockTrash(outcome: .trashed))

        XCTAssertEqual(vm.phase, .idle)
        vm.startScan()
        await vm.task?.value
        XCTAssertEqual(vm.phase, .completed)
        // 默认只勾选 safe 且未运行
        XCTAssertEqual(vm.selectedPaths, ["/a"])
        XCTAssertEqual(vm.summaries.count, 1)
        XCTAssertEqual(vm.permissionSkippedCount, 1)

        vm.toggle("/b")
        XCTAssertEqual(vm.selectedBytes, 30)
        vm.uncheckCautiousAndRunning()
        XCTAssertEqual(vm.selectedPaths, ["/a"])

        vm.cancelScan()   // 已完成,不应改变状态
        XCTAssertEqual(vm.phase, .completed)
    }

    func testScanError_transitionsToFailed() async {
        struct Boom: Error {}
        let vm = makeVM(service: FailingScanService(), trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        guard case .failed = vm.phase else { return XCTFail("应为 failed,实际 \(vm.phase)") }
    }

    func testCleanSelected_reportsWritesHistory_andDismiss() async throws {
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 100)], summaries: [], permissionSkippedCount: 0,
            truncatedRuleIDs: [], excludedCount: 0)), trash: trash)
        vm.startScan()
        await vm.task?.value
        vm.cleanSelected()
        await vm.cleanTask?.value

        guard case .report(let report) = vm.phase else { return XCTFail("应为 report") }
        XCTAssertEqual(report.freedBytes, 100)
        XCTAssertEqual(report.trashedCount, 1)
        let calls = await trash.calls
        XCTAssertEqual(calls, ["/a"])
        let saved = try vm.history.loadAll()
        XCTAssertEqual(saved.count, 1)

        vm.loadLastCleanup()
        XCTAssertEqual(vm.lastCleanup?.freedBytes, 100)

        vm.dismissReport()
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertTrue(vm.hits.isEmpty)
        XCTAssertTrue(vm.selectedPaths.isEmpty)
    }

    func testCleanSelected_skipsProtectedAtExecutorLevel() async throws {
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("\(NSHomeDirectory())/Documents/secret", 500)], summaries: [],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)), trash: trash)
        vm.startScan()
        await vm.task?.value
        // 模拟上游漏拦:手工把受保护路径塞进勾选集
        vm.selectedPaths = ["\(NSHomeDirectory())/Documents/secret"]
        vm.cleanSelected()
        await vm.cleanTask?.value
        let calls = await trash.calls
        XCTAssertTrue(calls.isEmpty, "受保护路径绝不允许进入废纸篓")
        guard case .report(let report) = vm.phase else { return XCTFail() }
        XCTAssertEqual(report.skipped.first?.reason, "protected")
    }
}

struct FailingScanService: ScanServicing {
    struct Boom: Error {}
    func scan(exclusions: [String], progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        throw Boom()
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `Scripts/test.sh --filter ScanViewModelTests`
Expected: 编译错误(类型未定义)

- [ ] **Step 3: 实现 AppScanService**

`Sources/AppCore/AppScanService.swift`:

```swift
import Foundation
import ScanKit
import CleanKit

/// 生产装配:每次扫描用最新排除清单构建保护层。
public struct AppScanService: ScanServicing {
    public init() {}

    public func scan(exclusions: [String],
                     progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let protection = ProtectionStore(userExclusions: exclusions)
        let store = RuleStore(protection: protection)
        let engine = ScanEngine(deps: .init(
            protection: protection,
            runningBundleIDs: { await WorkspaceRunningAppDetector().runningBundleIDs() }
        ))
        let loaded = try store.loadBundled()
        return try await engine.scan(rules: loaded.rules, progress: progress)
    }
}
```

> **实现期修正(9e4802a,三处,均已追认):**
> 1. 上文 `runningBundleIDs` 闭包**必须带 `await`**:WorkspaceRunningAppDetector 是 `@MainActor`(NSWorkspace 要求),其方法虽同步声明,跨 actor 调用为隐式异步。本节原文无 await 编译失败——先前"去掉 await"的计划修复才是错的。
> 2. 测试 `hit` 助手声明为 `func hit(_ path: String, _ size: Int64, ...)`:原文 `size:` 标签与全部位置传参调用点矛盾,属任务文本笔误。
> 3. 测试方法须逐个加 `@Test`:本机 swift-testing 工具链无 @Test 发现 0 例。仓库既有套件均逐方法标注。

- [ ] **Step 4: 实现 ScanViewModel**

`Sources/AppCore/ScanViewModel.swift`:

```swift
import Foundation
import Observation
import ScanKit
import CleanKit

@MainActor
@Observable
public final class ScanViewModel {
    public enum Phase: Equatable {
        case idle, scanning, completed, cleaning
        case report(CleanReport)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var hits: [ScanHit] = []
    public private(set) var summaries: [CategorySummary] = []
    public private(set) var progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
    public private(set) var permissionSkippedCount = 0
    public private(set) var truncatedRuleIDs: Set<String> = []
    public private(set) var excludedCount = 0
    public private(set) var lastCleanup: CleanReport?

    public var selectedPaths: Set<String> = []
    public var categoryInFocus: RuleCategory?
    public var confirmPresented = false

    public let service: ScanServicing
    public let exclusions: ExclusionsStore
    public let history: HistoryStoring
    // 废纸篓服务可注入:生产用默认真实服务;测试注入 Mock,保证测试绝不触碰真实文件系统
    // (否则硬编码真实服务会对不存在的 /a 真调 trashItem → .vanished → trashedCount 断言必红)
    public let trash: TrashServicing

    // 供测试等待(内部可见)
    var task: Task<Void, Never>?
    var cleanTask: Task<Void, Never>?

    public init(service: ScanServicing, exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService()) {
        self.service = service
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
    }

    public func startScan() {
        guard phase != .scanning && phase != .cleaning else { return }
        phase = .scanning
        hits = []; summaries = []; selectedPaths = []
        progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
        task = Task { [weak self] in await self?.runScan() }
    }

    private func runScan() async {
        do {
            let result = try await service.scan(exclusions: exclusions.exclusions) { [weak self] p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            hits = result.hits.sorted { $0.sizeBytes > $1.sizeBytes }
            summaries = result.summaries
            permissionSkippedCount = result.permissionSkippedCount
            truncatedRuleIDs = result.truncatedRuleIDs
            excludedCount = result.excludedCount
            selectedPaths = Set(hits.filter { $0.safety == .safe && !$0.isAppRunning }.map(\.path))
            phase = .completed
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func cancelScan() { task?.cancel() }

    public var selectedItems: [ScanHit] { hits.filter { selectedPaths.contains($0.path) } }
    public var selectedBytes: Int64 { selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    public func toggle(_ path: String) {
        if selectedPaths.contains(path) { selectedPaths.remove(path) } else { selectedPaths.insert(path) }
    }

    public func selectAll(in category: RuleCategory?) {
        for h in hits where category == nil || h.category == category { selectedPaths.insert(h.path) }
    }

    public func selectNone(in category: RuleCategory?) {
        for h in hits where category == nil || h.category == category { selectedPaths.remove(h.path) }
    }

    public func uncheckCautiousAndRunning() {
        for h in hits where h.safety == .cautious || h.isAppRunning { selectedPaths.remove(h.path) }
    }

    public func cleanSelected() {
        let items = selectedItems.map(\.cleanItem)
        guard !items.isEmpty else { return }
        phase = .cleaning
        confirmPresented = false
        let protection = ProtectionStore(userExclusions: exclusions.exclusions)
        let executor = CleanExecutor(trash: trash, protection: protection)
        cleanTask = Task { [weak self, history] in
            let report = await executor.clean(items)
            try? history.append(report)
            await MainActor.run { [weak self] in self?.phase = .report(report) }
        }
    }

    public func loadLastCleanup() {
        lastCleanup = (try? history.loadAll())?.max { $0.date < $1.date }
    }

    public func dismissReport() {
        phase = .idle
        hits = []; summaries = []; selectedPaths = []
        progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
    }
}
```

- [ ] **Step 5: 运行确认通过(全量)+ Commit**

Run: `Scripts/test.sh`
Expected: 全绿

```bash
git add -A && git commit -m "feat(AppCore): ScanViewModel 状态机 + AppScanService 生产装配(含受保护路径注入回归测试)"
```

> **Task 10 实现与质量记录(控制器,审查全通过后追认):**
> - 实现 9e4802a:三处实现期修正(检测器闭包须 `await`(其 @MainActor,先前"去 await"的修正才错)/ `hit` 助手标签改位置参数 / 逐方法 `@Test`),73/73 绿,已追认于 9e30bfe。
> - 质量轮 Fix-first 6 项 + 1 钉测试,裁决全修,7567ccb 一次落地(74/74 绿):cleanSelected 加 `guard phase == .completed` 防重入(Important);cleanTask 去 MainActor.run(闭包继承主 actor 隔离);history.append 失败改 os.Logger 不再静默;startScan/dismissReport 重置块补三计数;MockTrash.vanishedFor 预留注释;ProtectionStore 清理侧构造意图注释;新增 `cleanSelected_reentrancyGuarded`。
> - 复审通过:7 项如实落地,安全钉测试(skipsProtectedAtExecutorLevel / testScanFlow)无回归。

---

### Task 11: App 骨架 · 入口 + 侧边栏 + L10n

**Files:**
- Modify: `Sources/Raccoon/RaccoonApp.swift`(替换)
- Create: `Sources/Raccoon/L10n.swift`、`Sources/Raccoon/RootView.swift`
- Create: `Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings`、`Sources/Raccoon/Resources/en.lproj/Localizable.strings`
- Delete: `Sources/Raccoon/Resources/zh-Hans.lproj/.keep`、`Sources/Raccoon/Resources/en.lproj/.keep`

本 Task 无单测(纯 UI),以构建 + `swift run` 人工目测验证。

- [ ] **Step 1: L10n 助手**

`Sources/Raccoon/L10n.swift`:

```swift
import Foundation

func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle.module, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: Bundle.module, comment: ""), arguments: args)
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
```

- [ ] **Step 2: 两份 Localizable.strings(全量键,后续 Task 直接使用)**

`Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings`:

```
"app.name" = "Raccoon 浣熊清理";
"module.cleanup" = "清理";
"module.uninstall" = "卸载";
"module.aiCleanup" = "AI 清理";
"module.diskAnalysis" = "磁盘分析";
"module.monitor" = "监控";
"sidebar.comingSoon" = "即将推出";
```

> **Key 命名修正(派发前,控制器):**侧边栏以 `loc("module.\(module.rawValue)")` 拼 key,`Module` 的 rawValue 为驼峰(`aiCleanup`/`diskAnalysis`),故这两个键必须驼峰;原文全小写系笔误(照抄查不到 key,侧边栏回退显示原始键名)。en 文件同步驼峰。
"common.scan" = "开始扫描";
"common.cancel" = "取消";
"common.close" = "关闭";
"common.clean" = "清理…";
"common.moveToTrash" = "移入废纸篓";
"home.startHint" = "扫描系统垃圾与应用缓存,先预览再删除。\n所有删除只进废纸篓,随时可恢复。";
"home.lastCleanup" = "上次清理释放 %@";
"home.neverCleaned" = "尚未清理过";
"home.scanning" = "正在扫描…(%d/%d 项规则)";
"home.found" = "已发现 %@";
"home.cancelHint" = "取消将丢弃本次扫描结果";
"home.failed" = "扫描失败:%@";
"home.retry" = "重试";
"home.permissionSkipped" = "%d 个位置因权限不足被跳过";
"home.partialScan" = "部分规则未完全扫描:%@";
"home.excludedNote" = "已按保护与排除清单跳过 %d 项";
"category.system" = "系统垃圾";
"category.dev" = "开发工具缓存";
"category.apps" = "应用缓存";
"category.cautious" = "谨慎清理";
"category.items" = "%d 项";
"detail.title" = "清理明细";
"detail.selectAll" = "全选";
"detail.selectNone" = "全不选";
"detail.uncheckCautious" = "取消谨慎项";
"detail.selected" = "已选 %d 项 · %@";
"detail.appRunning" = "应用运行中";
"detail.cautious" = "谨慎";
"detail.snapshot" = "本地快照 %@";
"detail.empty" = "该类别没有可清理项";
"confirm.title" = "确认清理";
"confirm.runningWarning" = "有应用正在运行,建议先退出相关应用再清理";
"confirm.cautiousSection" = "以下谨慎项将一并移入废纸篓:";
"report.done" = "清理完成";
"report.freed" = "本次释放 %@";
"report.trashed" = "%d 项已移入废纸篓";
"report.vanished" = "%d 项在清理前已被应用自动删除";
"report.snapshots" = "%d 个本地快照已清理";
"report.skipped" = "%d 项被跳过";
"report.again" = "再扫一次";
"settings.title" = "设置";
"settings.exclusions" = "排除清单";
"settings.exclusionsHint" = "这些路径将永不扫描、永不删除";
"settings.add" = "添加路径…";
"settings.about" = "关于";
"settings.aboutBody" = "Raccoon 浣熊清理 · 开源(MIT)\n所有删除仅移入废纸篓。";
"reason.protected" = "受保护路径";
"reason.no-permission" = "权限不足";
"reason.other" = "其他原因";
"reason.snapshot-failed" = "快照清理失败";
```

`Sources/Raccoon/Resources/en.lproj/Localizable.strings`(同键英文):

```
"app.name" = "Raccoon";
"module.cleanup" = "Cleanup";
"module.uninstall" = "Uninstall";
"module.aiCleanup" = "AI Cleanup";
"module.diskAnalysis" = "Disk Analysis";
"module.monitor" = "Monitor";
"sidebar.comingSoon" = "Coming soon";
"common.scan" = "Scan Now";
"common.cancel" = "Cancel";
"common.close" = "Close";
"common.clean" = "Clean…";
"common.moveToTrash" = "Move to Trash";
"home.startHint" = "Scan system junk and app caches; preview before deleting.\nDeletions go to Trash and are always recoverable.";
"home.lastCleanup" = "Last cleanup freed %@";
"home.neverCleaned" = "Never cleaned";
"home.scanning" = "Scanning… (%d/%d rules)";
"home.found" = "Found %@";
"home.cancelHint" = "Canceling discards this scan";
"home.failed" = "Scan failed: %@";
"home.retry" = "Retry";
"home.permissionSkipped" = "%d locations skipped due to permissions";
"home.partialScan" = "Partially scanned rules: %@";
"home.excludedNote" = "%d items skipped by protection & exclusions";
"category.system" = "System Junk";
"category.dev" = "Developer Caches";
"category.apps" = "App Caches";
"category.cautious" = "Caution Items";
"category.items" = "%d items";
"detail.title" = "Cleanup Details";
"detail.selectAll" = "Select All";
"detail.selectNone" = "Select None";
"detail.uncheckCautious" = "Uncheck Cautious";
"detail.selected" = "%d selected · %@";
"detail.appRunning" = "App running";
"detail.cautious" = "Caution";
"detail.snapshot" = "Local snapshot %@";
"detail.empty" = "Nothing to clean in this category";
"confirm.title" = "Confirm Cleanup";
"confirm.runningWarning" = "Some apps are running — consider quitting them first";
"confirm.cautiousSection" = "These caution items will also be moved to Trash:";
"report.done" = "Cleanup Complete";
"report.freed" = "Freed %@";
"report.trashed" = "%d items moved to Trash";
"report.vanished" = "%d items were already removed by their apps";
"report.snapshots" = "%d local snapshots deleted";
"report.skipped" = "%d items skipped";
"report.again" = "Scan Again";
"settings.title" = "Settings";
"settings.exclusions" = "Exclusions";
"settings.exclusionsHint" = "These paths are never scanned and never deleted";
"settings.add" = "Add Path…";
"settings.about" = "About";
"settings.aboutBody" = "Raccoon · open source (MIT)\nEverything deleted goes to the Trash only.";
"reason.protected" = "Protected path";
"reason.no-permission" = "No permission";
"reason.other" = "Other reason";
"reason.snapshot-failed" = "Snapshot cleanup failed";
```

- [ ] **Step 3: 替换 App 入口 + 侧边栏**

`Sources/Raccoon/RaccoonApp.swift`:

```swift
import SwiftUI
import AppCore

@main
struct RaccoonApp: App {
    @State private var exclusions: ExclusionsStore

    init() {
        _exclusions = State(initialValue: ExclusionsStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView(exclusions: exclusions)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowTitle(loc("app.name"))
        Settings {
            SettingsView(exclusions: exclusions)
        }
    }
}
```

(`SettingsView` 在 Task 15 创建,本 Task 先留占位文件 `Sources/Raccoon/SettingsView.swift`,内容为最小可编译实现,后续 Task 替换:

```swift
import SwiftUI
import AppCore

struct SettingsView: View {
    let exclusions: ExclusionsStore
    var body: some View { Text(loc("settings.title")) }
}
```
)

`Sources/Raccoon/RootView.swift`:

```swift
import SwiftUI
import AppCore

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
    static var availableCases: [Module] { [.cleanup] }
    static var comingSoonCases: [Module] { [.uninstall, .aiCleanup, .diskAnalysis, .monitor] }
}

struct RootView: View {
    let exclusions: ExclusionsStore
    @State private var vm: ScanViewModel
    @State private var selection: Module = .cleanup

    init(exclusions: ExclusionsStore) {
        self.exclusions = exclusions
        _vm = State(initialValue: ScanViewModel(service: AppScanService(),
                                                exclusions: exclusions,
                                                history: JSONHistoryStore()))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
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
            CleanupHomeView(vm: vm)
                .onAppear { vm.loadLastCleanup() }
        }
    }
}
```

(`CleanupHomeView` 本 Task 先用占位,Task 12 替换:在 `Sources/Raccoon/CleanupHomeView.swift` 写

```swift
import SwiftUI
import AppCore

struct CleanupHomeView: View {
    let vm: ScanViewModel
    var body: some View { Text(loc("module.cleanup")) }
}
```
)

- [ ] **Step 4: 构建并人工目测**

Run: `swift build && swift run &`
Expected: 窗口出现,侧边栏「清理」可选,其余四项灰显于"即将推出"分组。目测后 `kill %1`。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(Raccoon): 应用入口 + 侧边栏骨架 + 中英文本地化基线"
```

---

### Task 12: 清理主页(全状态 + 类别卡片)

**Files:**
- Modify: `Sources/Raccoon/CleanupHomeView.swift`(替换占位)

- [ ] **Step 1: 实现主页**

```swift
import SwiftUI
import ScanKit
import AppCore

struct CleanupHomeView: View {
    @Bindable var vm: ScanViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle: idleView
                case .scanning: scanningView
                case .completed: completedView
                case .cleaning:
                    ProgressView(loc("common.clean"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .report(let report): ReportView(report: report, vm: vm)
                case .failed(let message): failedView(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.cleanup"))
        }
    }

    var idleView: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(loc("home.startHint"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(loc("common.scan")) { vm.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if let last = vm.lastCleanup {
                Text(loc("home.lastCleanup", byteText(last.freedBytes)))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(loc("home.neverCleaned"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(loc("home.scanning", vm.progress.rulesDone, vm.progress.rulesTotal))
                .foregroundStyle(.secondary)
            Text(loc("home.found", byteText(vm.progress.bytesFound)))
                .font(.title3).bold().monospacedDigit()
            Button(loc("common.cancel")) { vm.cancelScan() }
            Text(loc("home.cancelHint")).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    var completedView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(vm.summaries) { summary in
                    CategoryCardView(summary: summary)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.categoryInFocus = summary.category }
                }
            }
            .padding(.bottom, 12)
            footerNotes
        }
        .navigationDestination(item: $vm.categoryInFocus) { category in
            DetailListView(vm: vm, category: category)
        }
    }

    @ViewBuilder
    var footerNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.permissionSkippedCount > 0 {
                Text(loc("home.permissionSkipped", vm.permissionSkippedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !vm.truncatedRuleIDs.isEmpty {
                Text(loc("home.partialScan", vm.truncatedRuleIDs.sorted().joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vm.excludedCount > 0 {
                Text(loc("home.excludedNote", vm.excludedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.yellow)
            Text(loc("home.failed", message)).multilineTextAlignment(.center)
            Button(loc("home.retry")) { vm.startScan() }
        }
    }
}

struct CategoryCardView: View {
    let summary: CategorySummary

    var isCautious: Bool { summary.category == .cautious }
    var icon: String {
        switch summary.category {
        case .system: "trash"
        case .dev: "hammer"
        case .apps: "app.badge"
        case .cautious: "exclamationmark.shield"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc("category.\(summary.category.rawValue)"), systemImage: icon)
                .font(.headline)
                .foregroundStyle(isCautious ? Color.orange : Color.primary)
            Text(byteText(summary.totalBytes))
                .font(.title2).bold().monospacedDigit()
            Text(loc("category.items", summary.hitCount))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(isCautious ? Color.orange.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCautious ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5))
        )
    }
}
```

(`DetailListView` 在 Task 13 实现,本 Task 先留占位文件 `Sources/Raccoon/DetailListView.swift`,内容为最小可编译实现,Task 13 替换:

```swift
import SwiftUI
import ScanKit
import AppCore

struct DetailListView: View {
    let vm: ScanViewModel
    let category: RuleCategory
    var body: some View { Text(loc("detail.title")) }
}
```
)

(`ReportView` 在 Task 14 实现,本 Task 同理留占位文件 `Sources/Raccoon/ReportView.swift`,Task 14 替换:

```swift
import SwiftUI
import CleanKit
import AppCore

struct ReportView: View {
    let report: CleanReport
    let vm: ScanViewModel
    var body: some View { Text(loc("report.done")) }
}
```
)

- [ ] **Step 2: 构建并人工目测**

Run: `swift run &`
Expected: 点「开始扫描」→ 进度页数字跳动 → 完成后出现类别卡片(cautious 橙色)。`kill %1`。

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(Raccoon): 清理主页四状态 + 类别卡片(cautious 橙色标识)"
```

---

### Task 13: 明细列表页

**Files:**
- Modify: `Sources/Raccoon/DetailListView.swift`(替换 Task 12 占位)

- [ ] **Step 1: 实现**

```swift
import SwiftUI
import AppKit
import ScanKit
import AppCore

struct DetailListView: View {
    @Bindable var vm: ScanViewModel
    let category: RuleCategory

    var hits: [ScanHit] { vm.hits.filter { $0.category == category } }

    var body: some View {
        VStack(spacing: 0) {
            if hits.isEmpty {
                Text(loc("detail.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hits) { hit in
                        DetailRow(hit: hit,
                                  selected: vm.selectedPaths.contains(hit.path)) { vm.toggle(hit.path) }
                    }
                }
            }
            Divider()
            bottomBar
        }
        .navigationTitle(loc("category.\(category.rawValue)"))
        .toolbar {
            Button(loc("detail.selectAll")) { vm.selectAll(in: category) }
            Button(loc("detail.selectNone")) { vm.selectNone(in: category) }
            Button(loc("detail.uncheckCautious")) { vm.uncheckCautiousAndRunning() }
        }
        .sheet(isPresented: $vm.confirmPresented) {
            ConfirmCleanView(vm: vm)
        }
    }

    var bottomBar: some View {
        HStack {
            Text(loc("detail.selected", vm.selectedPaths.count, byteText(vm.selectedBytes)))
                .monospacedDigit()
            Spacer()
            Button(loc("common.clean")) { vm.confirmPresented = true }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedPaths.isEmpty || vm.phase == .cleaning)
        }
        .padding(12)
    }
}

struct DetailRow: View {
    let hit: ScanHit
    let selected: Bool
    let onToggle: () -> Void

    var title: String {
        if hit.action == .tmutilThin, let date = hit.snapshotDate { return loc("detail.snapshot", date) }
        return hit.appName ?? hit.path.split(separator: "/").last.map(String.init) ?? hit.path
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(String(), isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .labelsHidden()
            AppIconView(bundleID: hit.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(hit.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hit.isAppRunning { TagView(loc("detail.appRunning"), color: .yellow) }
            if hit.safety == .cautious { TagView(loc("detail.cautious"), color: .orange) }
            Text(byteText(hit.sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

struct TagView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct AppIconView: View {
    let bundleID: String?
    var body: some View {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 26, height: 26)
        } else {
            Image(systemName: "folder")
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
        }
    }
}
```

(`ConfirmCleanView` 在 Task 14 实现,本 Task 先留占位文件 `Sources/Raccoon/ConfirmCleanView.swift`,内容为最小可编译实现,Task 14 替换:

```swift
import SwiftUI
import AppCore

struct ConfirmCleanView: View {
    let vm: ScanViewModel
    var body: some View { Text(loc("confirm.title")) }
}
```
)

- [ ] **Step 2: 构建并人工目测**

Run: `swift run &`
Expected: 扫描完成后点类别卡片 → 明细列表按大小降序、显示应用图标、路径中段截断、运行中应用黄色标签、cautious 橙色标签;底部已选联动;工具栏三个选择按钮生效。`kill %1`。`kill %1`。

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(Raccoon): 明细列表页(勾选/标签/图标/底部已选栏)"
```

---

### Task 14: 确认弹窗 + 完成报告

**Files:**
- Modify: `Sources/Raccoon/ConfirmCleanView.swift`(替换 Task 13 占位)、`Sources/Raccoon/ReportView.swift`(替换 Task 12 占位)

- [ ] **Step 1: 实现确认弹窗**

```swift
import SwiftUI
import ScanKit
import AppCore

struct ConfirmCleanView: View {
    let vm: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("confirm.title")).font(.title3).bold()
            Text(loc("detail.selected", vm.selectedPaths.count, byteText(vm.selectedBytes)))
                .monospacedDigit()

            if vm.selectedItems.contains(where: \.isAppRunning) {
                Label(loc("confirm.runningWarning"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }

            let cautious = vm.selectedItems.filter { $0.safety == .cautious }
            if !cautious.isEmpty {
                Divider()
                Text(loc("confirm.cautiousSection"))
                    .font(.headline).foregroundStyle(.orange)
                ForEach(cautious) { item in
                    Text(item.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            HStack {
                Spacer()
                Button(loc("common.cancel")) { vm.confirmPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(loc("common.moveToTrash")) { vm.cleanSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
```

- [ ] **Step 2: 实现完成报告**

```swift
import SwiftUI
import CleanKit
import AppCore

struct ReportView: View {
    let report: CleanReport
    let vm: ScanViewModel

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
            Text(loc("report.freed", byteText(report.freedBytes))).monospacedDigit()
            Text(loc("report.trashed", report.trashedCount)).foregroundStyle(.secondary)
            if report.vanishedCount > 0 {
                Text(loc("report.vanished", report.vanishedCount)).foregroundStyle(.secondary)
            }
            if report.snapshotCount > 0 {
                Text(loc("report.snapshots", report.snapshotCount)).foregroundStyle(.secondary)
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
            HStack {
                Button(loc("report.again")) {
                    vm.dismissReport()
                    vm.startScan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 3: 构建并人工目测(全程演练)**

Run: `swift run &`
Expected: 扫描 → 卡片 → 明细 → 勾选 → 「清理…」→ 确认弹窗(cautious 单独分区、运行中黄色警告)→「移入废纸篓」→ 报告页数字正确 → 「再扫一次」回到 idle。核对废纸篓确有对应项目且可放回。`kill %1`。

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(Raccoon): 确认弹窗(cautious 分区/运行中警告)+ 完成报告"
```

---

### Task 15: 设置页(排除清单 + 关于)

**Files:**
- Modify: `Sources/Raccoon/SettingsView.swift`(替换占位)

- [ ] **Step 1: 实现**

```swift
import SwiftUI
import AppKit
import AppCore

struct SettingsView: View {
    @Bindable var exclusions: ExclusionsStore

    var body: some View {
        TabView {
            ExclusionsPane(exclusions: exclusions)
                .tabItem { Label(loc("settings.exclusions"), systemImage: "hand.raised") }
            AboutPane()
                .tabItem { Label(loc("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 500, height: 340)
    }
}

struct ExclusionsPane: View {
    @Bindable var exclusions: ExclusionsStore

    var body: some View {
        VStack(spacing: 0) {
            Text(loc("settings.exclusionsHint"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 10)
            List {
                ForEach(exclusions.exclusions, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            exclusions.remove(path)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button(loc("settings.add")) { addPath() }
            }
            .padding(10)
        }
    }

    func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            exclusions.add(url.path)
        }
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(.tint)
            Text(loc("settings.aboutBody"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: 构建并人工目测**

Run: `swift run &`,菜单 Raccoon → 设置(Cmd+,)
Expected: 排除页可添加/删除路径;添加一个路径(如某个缓存目录)后重新扫描,该路径不出现在结果。`kill %1`。

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(Raccoon): 设置页(排除清单管理 + 关于)"
```

---

### Task 16: .app 组装脚本 + Info.plist + 占位图标

**Files:**
- Create: `Scripts/bundle-app.sh`、`Scripts/Info.plist`、`Scripts/make-icon.swift`

- [ ] **Step 1: Info.plist**

`Scripts/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Raccoon</string>
    <key>CFBundleDisplayName</key><string>Raccoon 浣熊清理</string>
    <key>CFBundleIdentifier</key><string>com.raccooncleaner.Raccoon</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Raccoon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
```

- [ ] **Step 2: 组装脚本**

`Scripts/bundle-app.sh`:

```bash
#!/bin/bash
# 组装 build/Raccoon.app:swift build → 拷贝二进制/资源 bundle → adhoc 签名
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

swift build -c "$CONFIG"

APP="build/Raccoon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Raccoon" "$APP/Contents/MacOS/Raccoon"
cp "Scripts/Info.plist" "$APP/Contents/Info.plist"

# SwiftPM 资源 bundle(rules.json、本地化)需与可执行文件同目录
find ".build/$CONFIG" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/MacOS/" \;

# 占位图标(若已生成;|| true 防 set -e 下条件短路误退脚本)
if [ -f "build/AppIcon.png" ]; then cp "build/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"; fi

codesign --force --sign - "$APP"
echo "✅ $APP"
```

```bash
chmod +x Scripts/bundle-app.sh
```

- [ ] **Step 3: 占位图标(可选但建议)**

`Scripts/make-icon.swift`:

```swift
// 用法:swift Scripts/make-icon.swift build/AppIcon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.systemBlue.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 180, yRadius: 180).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 620)]
NSAttributedString(string: "🦝", attributes: attrs)
    .draw(in: NSRect(x: 0, y: (size - 620) / 2 - 30, width: size, height: 700))
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("✅ \(out)")
```

```bash
mkdir -p build   # make-icon.swift 直接写 build/AppIcon.png,目录须先存在
swift Scripts/make-icon.swift build/AppIcon.png
```

- [ ] **Step 4: 组装并启动验证**

Run: `Scripts/bundle-app.sh && open build/Raccoon.app`
Expected: .app 正常启动,图标/名称正确;`codesign -dv build/Raccoon.app` 显示 `Signature=adhoc`。退出 App。

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "chore: .app 组装脚本 + Info.plist + 占位图标(adhoc 签名)"
```

---

### Task 17: README + LICENSE + 手动 QA + 验收核对

**Files:**
- Create: `README.md`、`LICENSE`

- [ ] **Step 1: LICENSE(MIT)**

标准 MIT 文本,版权行 `Copyright (c) 2026 Raccoon contributors`。

- [ ] **Step 2: README.md**

内容包含:项目简介(浣熊吉祥物、对标 Mole)、一期功能清单、**安全设计四道门**(硬保护/用户排除/安全分级/只进废纸篓)、构建运行方法(`swift build/test/run`、`Scripts/bundle-app.sh`)、规则库贡献指南(指向 `Sources/ScanKit/Resources/rules.json` 的 schema 说明)、路线图(六期表格,摘自规格 §2)、许可证。

- [ ] **Step 3: 全量测试**

Run: `Scripts/test.sh`
Expected: 全绿(约 45+ 用例)

- [ ] **Step 4: 手动 QA 清单(逐项核对,在本机真实执行)**

1. `swift run` 完整扫描真实机器,四类卡片都有合理数据(或空态正常)
2. cautious 类别默认全不勾选,橙色标识
3. 正在运行的应用(如 Chrome/微信)缓存项黄色"应用运行中"且默认不勾选
4. 明细勾选联动底部"已选 N 项 · X GB"
5. 清理后:报告数字与废纸篓项目数一致;从废纸篓放回一个文件验证可恢复
6. 设置页添加排除路径 → 重扫 → 该路径不出现
7. 扫描中点取消 → 回到 idle,无残留状态
8. 切换系统外观浅色/深色,界面正常
9. `open build/Raccoon.app` 后 `defaults write` 或系统语言切 English(或 `swift run` 前 `defaults write com.raccooncleaner.Raccoon AppleLanguages -array en`)→ 界面为英文;删除该偏好恢复中文
10. `~/Library/Application Support/Raccoon/history.json` 有清理记录,主页显示"上次清理释放 X"
11. 微信等容器路径确认:结果只出现 `…/Caches` 子目录,绝无聊天记录目录
12. 全程无崩溃、无卡死;扫描期间 UI 可响应(取消按钮可用)

- [ ] **Step 5: 验收核对(规格 §11)**

对照 `docs/superpowers/specs/2026-10-13-raccoon-phase1-design.md` §11 六条 Done 定义逐条核对,有缺口回补任务;全部满足后:

```bash
git add -A && git commit -m "docs: README/LICENSE,一期验收完成"
```

---

## 计划自审记录

- **规格覆盖**:§3 技术决策→T1/T11/T16;§5 规则库→T5/T6;§6.1 硬保护→T2(+T3 执行器兜底 +T10 注入回归);§6.2 排除→T9/T15;§6.3 分级与运行中→T7/T8/T10/T13;§6.4 废纸篓→T3;§7.1 扫描管线→T7/T8;§7.2 用户流程→T10–T14;§8 错误处理→T3(三态)/T7(权限/截断)/T8(取消);§9 测试策略各 Task 内嵌;§11 验收→T17。
- **已知取舍(实现时保持一致)**:1) `exclude` 仅匹配路径末段(规格"相对 glob"的 v1 简化);2) App 图标仅在能按 bundle id 定位已装/运行应用时显示,否则显示文件夹图标(规格"查不到则显示目录名"的落实);3) 快照项大小按 0 字节计,报告单列快照数。
- **Swift 6 严格并发适配(自审时修正,各 Task 已保持一致)**:swift-tools 6.4 默认 Swift 6 语言模式,`NSWorkspace` 为 @MainActor 隔离 —— 因此 ① `SnapshotCleanerServicing` 的方法为 `async`(actor mock 才能满足协议);② `WorkspaceRunningAppDetector` 与 `AppIdentityResolver.appName(for:)` 收在 `@MainActor`;③ 引擎的 `runningBundleIDs` 依赖注入为 `@Sendable () async -> Set<String>`,扫描开始时取一次快照;④ appName 在扫描收尾经 `MainActor.run` 一次性批量补齐,不逐项跨线程。
- **类型一致性**:核心类型(RuleStore/LoadedRules/ScanHit/CleanItem/CleanReport/ScanServicing 签名)已在各 Task 间交叉核对;`MockSnapshots`/`MockTrash` 在各 test target 内独立定义。


