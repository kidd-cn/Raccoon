import Foundation
import Testing
import CleanKit
@testable import ScanKit

@Suite final class ScanEngineTests {
    var root: String!

    init() { root = ScanFixtures.makeTree() }
    deinit { ScanFixtures.remove(root) }

    func engine(protection: ProtectionStore = ProtectionStore(),
                running: Set<String> = [],
                limit: Int = 500_000) -> ScanEngine {
        ScanEngine(deps: .init(protection: protection,
                               runningBundleIDs: { running },
                               snapshots: MockSnapshots(),
                               itemLimitPerRule: limit))
    }

    // MARK: 默认模式(根的一级子项 = 删除单元)

    @Test func defaultMode_childrenAreHits_withDeepSize() async throws {
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let hits = result.hits
        #expect(hits.count == 3)   // com.google.Chrome / com.spotify.client / stray.log
        let chrome = try #require(hits.first { $0.path.hasSuffix("com.google.Chrome") })
        #expect(chrome.sizeBytes == 300)
        #expect(chrome.isDirectory)
        #expect(chrome.ruleID == "c")
        #expect(chrome.category == .system)
        #expect(chrome.safety == .safe)
        #expect(chrome.action == .trash)
    }

    @Test func defaultMode_excludeMatchesLastComponent() async throws {
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches", exclude: ["com.spotify.client", "*.log"])])
        #expect(result.hits.map(\.path).sorted() == [root + "/Caches/com.google.Chrome"])
        #expect(result.excludedCount == 2)
    }

    @Test func defaultMode_userExclusionFiltersHit() async throws {
        let protection = ProtectionStore(userExclusions: [root + "/Caches/com.google.Chrome"])
        let result = try await engine(protection: protection).scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        #expect(result.hits.count == 2)
        #expect(result.excludedCount == 1)
    }

    @Test func defaultMode_runningAppFlagged() async throws {
        let result = try await engine(running: ["com.google.Chrome"]).scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let chrome = try #require(result.hits.first { $0.bundleID == "com.google.Chrome" })
        #expect(chrome.isAppRunning)
        let spotify = try #require(result.hits.first { $0.path.hasSuffix("com.spotify.client") })
        #expect(!spotify.isAppRunning)
    }

    @Test func defaultMode_tildeExpansion() async throws {
        // ~ 展开正确性:用真实 ~/Library/Logs 目录存在与否都应安全返回(0 条或若干条,不抛错)
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "l", path: "~/Library/Logs_nonexistent")])
        #expect(result.hits.count == 0)
    }

    @Test func defaultMode_missingRootYieldsEmpty() async throws {
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "x", path: root + "/nope")])
        #expect(result.hits.count == 0)
        #expect(result.permissionSkippedCount == 0)   // 缺失 ≠ 无权限
        let include = try await engine().scan(
            rules: [ScanFixtures.rule(id: "y", path: root + "/nope", include: ["*.log"])])
        #expect(include.hits.isEmpty)
        #expect(include.permissionSkippedCount == 0)  // include 模式同序
    }

    @Test func defaultMode_symlinkChildNotBlownUp() async throws {
        let target = root + "/Caches/com.google.Chrome"
        try FileManager.default.createSymbolicLink(atPath: root + "/Caches/loop", withDestinationPath: target)
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let loop = try #require(result.hits.first { $0.path.hasSuffix("/loop") })
        #expect(loop.sizeBytes == 0)   // 符号链接按 0 计,不深入目标
    }

    @Test func defaultMode_itemLimitTruncates() async throws {
        let result = try await engine(limit: 2).scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        #expect(result.hits.count == 2)
        #expect(result.truncatedRuleIDs == Set(["c"]))   // truncatedRuleIDs 是 Set<String>
    }

    @Test func progress_eventsPerRule() async throws {
        let log = ScanFixtures.ProgressLog()
        _ = try await engine().scan(rules: [
            ScanFixtures.rule(id: "a", path: root + "/Caches"),
            ScanFixtures.rule(id: "b", path: root + "/Logs"),
        ]) { log.append($0) }
        let events = log.events
        #expect(events.count == 2)
        #expect(events.last?.rulesDone == 2)
        #expect(events.last?.rulesTotal == 2)
    }

    @Test func summaries_aggregatedByCategory() async throws {
        let result = try await engine().scan(rules: [
            ScanFixtures.rule(id: "c", path: root + "/Caches"),
            ScanFixtures.rule(id: "l", path: root + "/Logs", category: .dev),
        ])
        #expect(result.summaries.count == 2)
        let system = try #require(result.summaries.first { $0.category == .system })
        #expect(system.totalBytes == 360)
        #expect(system.hitCount == 3)
    }

    // MARK: include 模式(文件名 glob 白名单)

    @Test func includeMode_dsStoreAcrossTree() async throws {
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "ds", path: root, include: [".DS_Store"])])
        #expect(result.hits.count == 2)
        #expect(result.hits.reduce(0) { $0 + $1.sizeBytes } == 10)
        #expect(result.hits.allSatisfy { !$0.isDirectory })
    }

    @Test func includeMode_protectionSkipsSubtree() async throws {
        let protection = ProtectionStore(userExclusions: [root + "/nested/deep"])
        let result = try await engine(protection: protection).scan(
            rules: [ScanFixtures.rule(id: "ds", path: root, include: [".DS_Store"])])
        #expect(result.hits.count == 1)          // 仅 nested/.DS_Store
        #expect(result.excludedCount == 1)
    }

    @Test func includeMode_directoryHitsGlob_installedInstallerStyle() async throws {
        // 模拟 /Applications 安装器规则:目录命中 glob → 整目录为一个删除单元
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Install macOS Test.app/Contents", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 15).write(to: URL(fileURLWithPath: root + "/Install macOS Test.app/Contents/PkgInfo"))
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "inst", path: root, include: ["Install macOS *.app"])])
        #expect(result.hits.count == 1)
        let hit = try #require(result.hits.first)
        #expect(hit.isDirectory)
        #expect(hit.sizeBytes == 15)
    }

    // MARK: 权限与取消

    @Test func defaultMode_unreadableChildCountedSkipped() async throws {
        try #require(geteuid() != 0, "root 下权限测试无意义")
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Caches/locked", withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root + "/Caches/locked")
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/Caches/locked") }
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        #expect(!result.hits.contains { $0.path.hasSuffix("/locked") })
        #expect(result.permissionSkippedCount == 1)
    }

    @Test func cancellation_throws() async {
        // Task 的 @Sendable 闭包不能捕获非 Sendable 的套件实例(self):
        // 先把 Sendable 的 engine 与路径提升为局部值再进闭包(语义不变)。
        let eng = engine()
        let caches = root + "/Caches"
        let task = Task { try await eng.scan(rules: [ScanFixtures.rule(id: "c", path: caches)]) }
        task.cancel()
        do { _ = try await task.value; Issue.record("应抛 CancellationError") }
        catch is CancellationError {}
        catch { Issue.record("意外错误:\(error)") }
    }

    // MARK: 快照规则

    @Test func snapshotRule_producesHitsFromLister() async throws {
        let rule = CleanupRule(id: "snap", category: .cautious, safety: .cautious, path: "~",
                               include: nil, exclude: nil, action: .tmutilThin, description: nil, tool: nil)
        let e = ScanEngine(deps: .init(protection: ProtectionStore(), runningBundleIDs: { [] },
                                       snapshots: MockSnapshots(listed: ["2026-10-13-120000", "2026-10-12-090000"])))
        let result = try await e.scan(rules: [rule])
        #expect(result.hits.count == 2)
        let first = try #require(result.hits.first)
        #expect(first.path == "tmutil://2026-10-13-120000")
        #expect(first.action == .tmutilThin)
        #expect(first.cleanItem.action == .tmutilThin(date: "2026-10-13-120000"))
        #expect(first.category == .cautious)
        #expect(first.tool == nil)   // 快照规则不归属任何 AI 工具
    }

    // Task 7 质量 Minor 1:悬空符号链接是清理目标,应 0 字节收录,不落 permissionSkipped
    @Test func defaultMode_danglingSymlinkIsZeroByteHit() async throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/Caches/dangling",
                                                   withDestinationPath: root + "/Caches/nowhere")
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let dangling = try #require(result.hits.first { $0.path.hasSuffix("/dangling") })
        #expect(dangling.sizeBytes == 0)
        #expect(!dangling.isDirectory)
        #expect(result.permissionSkippedCount == 0)
    }

    // 质量 #5:规则根本身不可读 → 显式计数(默认与 include 两模式对称)
    @Test func rootUnreadableCountedSkipped_bothModes() async throws {
        try #require(geteuid() != 0, "root 下权限测试无意义")
        let fm = FileManager.default
        let lockedRoot = root + "/LockedRoot"
        try fm.createDirectory(atPath: lockedRoot, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedRoot)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedRoot) }
        let def = try await engine().scan(rules: [ScanFixtures.rule(id: "d", path: lockedRoot)])
        #expect(def.permissionSkippedCount == 1)
        #expect(def.hits.isEmpty)
        let inc = try await engine().scan(
            rules: [ScanFixtures.rule(id: "i", path: lockedRoot, include: ["*.log"])])
        #expect(inc.permissionSkippedCount == 1)
        #expect(inc.hits.isEmpty)
    }

    // 质量 #1:include 模式悬空符号链接 → 0 字节命中,不落 permissionSkipped
    @Test func includeMode_danglingSymlinkIsZeroByteHit() async throws {
        try FileManager.default.createSymbolicLink(atPath: root + "/nested/.DS_Store.link",
                                                   withDestinationPath: root + "/nested/nowhere")
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "ds", path: root, include: [".DS_Store*"])])
        let link = try #require(result.hits.first { $0.path.hasSuffix(".DS_Store.link") })
        #expect(link.sizeBytes == 0)
        #expect(!link.isDirectory)
        #expect(result.permissionSkippedCount == 0)
    }

    // 三期:rule.tool 必须随命中透传到 ScanHit,AI 页按它分组;缺省为 nil
    @Test func engineCarriesRuleToolIntoHits() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory() + "raccoon-tool-\(UUID().uuidString)")
            .resolvingSymlinksInPath().path   // /var 是 /private/var 的符号链接,先解引用
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/with/sub", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 64).write(to: URL(fileURLWithPath: root + "/with/sub/f"))
        try fm.createDirectory(atPath: root + "/without/sub", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 32).write(to: URL(fileURLWithPath: root + "/without/sub/f"))
        try fm.createDirectory(atPath: root + "/app/Cache", withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 16).write(to: URL(fileURLWithPath: root + "/app/Cache/blob"))
        defer { try? fm.removeItem(atPath: root) }
        let rules = [
            ScanFixtures.rule(id: "with-tool", path: root + "/with", tool: "cursor"),
            ScanFixtures.rule(id: "no-tool", path: root + "/without"),
            ScanFixtures.rule(id: "inc-tool", path: root + "/app", include: ["Cache"], tool: "claude-desktop"),
        ]
        let result = try await ScanEngine(deps: .init(protection: ProtectionStore())).scan(rules: rules)
        let byRule = Dictionary(grouping: result.hits, by: \.ruleID)
        #expect(byRule["with-tool"]?.allSatisfy { $0.tool == "cursor" } == true)
        #expect(byRule["no-tool"]?.allSatisfy { $0.tool == nil } == true)
        #expect(byRule["inc-tool"]?.allSatisfy { $0.tool == "claude-desktop" } == true)   // include 模式同样透传
    }
}
