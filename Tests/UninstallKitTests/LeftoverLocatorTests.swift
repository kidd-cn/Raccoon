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

    // 组容器目录名与 Bundle ID 大小写不一致时仍须命中(与孤儿扫描侧口径一致)。
    @Test func groupContainerMatchIsCaseInsensitive() async throws {
        let dir = try home.makeDir("Library/Group Containers/TEAMID.COM.EXAMPLE.FOO", bytes: 8)
        let found = await leftovers(app())
        #expect(found.map(\.path) == [dir.path])
        #expect(found.first?.locationID == "group-containers")
        #expect(found.first?.safety == .userData)
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

    @Test func rejectsBundleIDPathTraversalAcrossLocations() async throws {
        try home.makeDir("Library/Containers/com.victim.app", bytes: 1)
        let found = await leftovers(app(bundleID: "../Containers/com.victim.app"))
        #expect(found.isEmpty)   // 否则会被标成 caches/regenerable 默认勾选
    }

    @Test func rejectsAppNamePathTraversalAcrossLocations() async throws {
        try home.makeDir("Library/Containers/com.victim.app", bytes: 1)
        let found = await leftovers(app(name: "../Containers/com.victim.app"))
        #expect(found.isEmpty)
    }

    @Test func dedupesCaseVariantsPointingToSameEntry() async throws {
        try home.makeDir("Library/Application Support/com.example.foo", bytes: 3)
        let found = await leftovers(app(name: "COM.EXAMPLE.FOO"))
        #expect(found.count == 1)   // 大小写不敏感卷上同一物理目录只出一次
    }

    @Test func honorsResolvedFormExclusionUnderInternalSymlink() async throws {
        // 祖先链接仍在 Library 内,隔离「解析形态排除」;若只查原始形态,排除不生效
        let real = try home.makeDir("Library/RealCaches/com.example.foo", bytes: 7)
        try home.makeDir("Library/Logs/other", bytes: 0)          // 确保 Library 存在
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches"),
            withDestinationURL: home.url.appendingPathComponent("Library/RealCaches"))
        let resolvedCandidate = real.path
        let found = await leftovers(app(), exclusions: [resolvedCandidate])
        #expect(found.isEmpty)
    }

    @Test func skipsLocationWhoseResolvedDirEscapesLibrary() async throws {
        let outside = try home.makeDir("outside-target", bytes: 0)
        try home.makeDir("outside-target/com.example.foo", bytes: 5)
        try home.makeDir("Library/Logs/other", bytes: 0)          // 确保 Library 存在
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches"),
            withDestinationURL: outside)
        let found = await leftovers(app())
        #expect(found.isEmpty)
    }

    @Test func libraryItselfBeingSymlinkStillLocates() async throws {
        // ~/Library 本身是链接(指向库内真实目录):resolvedLibrary 必须解析后再比较,
        // 否则所有位置都被 isLocationContained 跳过,关联数据静默为空。
        try home.makeDir("real-library/Caches/com.example.foo", bytes: 6)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library"),
            withDestinationURL: home.url.appendingPathComponent("real-library"))
        let found = await leftovers(app())
        // 结果路径保持原始(未解析)形态——trash 的是该可删除路径;物理目标经链接可达。
        let expected = home.url.appendingPathComponent("Library/Caches/com.example.foo").path
        #expect(found.map(\.path) == [expected])
        #expect(found.first?.locationID == "caches")
    }

    // Caches 槽位被链到用户数据目录:分级必须取解析目标位置表中最严格的 safety,
    // 否则 userData 会被当成 regenerable 默认勾选。
    @Test func cachesSymlinkedToUserDataFolderGradesAsUserData() async throws {
        try home.makeDir("Library/Application Support/com.example.foo", bytes: 30)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches"),
            withDestinationURL: home.url.appendingPathComponent("Library/Application Support"))

        let found = await leftovers(app())
        let viaCaches = found.first { $0.locationID == "caches" }
        #expect(viaCaches?.safety == .userData)
        // 同一物理目录经 Application Support 槽位也能命中,两条路径字符串各自保留。
        #expect(found.contains { $0.locationID == "app-support" })
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
