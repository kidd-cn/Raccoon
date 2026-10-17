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

    @Test func skipsLocationWhoseResolvedDirEscapesLibrary() async throws {
        let outside = try home.makeDir("outside-target", bytes: 0)
        try home.makeDir("outside-target/com.gone.app", bytes: 5)
        // 仅需确保 ~/Library 存在;不能用 Logs/other 之类非反向域名占位,
        // 否则会被 logs-name 低置信位置正常识别为孤儿,干扰本测试的唯一断言。
        try home.makeDir("Library", bytes: 0)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches"),
            withDestinationURL: outside)
        let result = await scan()
        #expect(result.orphans.isEmpty)
    }

    @Test func scansThroughInternalLocationSymlink() async throws {
        // Caches 指向库内真实目录:路径枚举应穿透并扫描,而不是静默跳过
        try home.makeDir("Library/RealCaches/com.gone.app", bytes: 6)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches"),
            withDestinationURL: home.url.appendingPathComponent("Library/RealCaches"))
        let result = await scan()
        #expect(result.orphans.map(\.path) == [home.url.appendingPathComponent("Library/Caches/com.gone.app").path])
    }

    // 位置槽位被链到用户数据目录时,孤儿分级同样取解析目标位置表中最严格的 safety。
    @Test func locationSymlinkToUserDataFolderGradesOrphanAsUserData() async throws {
        try home.makeDir("Library/Application Support/com.gone.app", bytes: 5)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches"),
            withDestinationURL: home.url.appendingPathComponent("Library/Application Support"))
        let result = await scan()
        let viaCaches = result.orphans.first { $0.locationID == "caches" }
        #expect(viaCaches?.safety == .userData)
    }

    @Test func honorsResolvedFormExclusionForSymlinkedEntry() async throws {
        let target = try home.makeDir("Library/RealCaches/com.gone.app", bytes: 6)
        try home.makeDir("Library/Caches", bytes: 0)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("Library/Caches/com.gone.app"),
            withDestinationURL: target)
        let result = await scan(exclusions: [target.path])
        #expect(result.orphans.isEmpty)
    }

    @Test func installedBundleIDMatchingIsCaseInsensitive() async throws {
        // `seen` 去重在当前位置表下不可达,保留作未来位置表重叠时的防御。
        try home.makeDir("Library/Caches/com.gone.app", bytes: 1)
        let first = await scan()
        #expect(first.orphans.count == 1)
        // 已安装集合大小写变体必须匹配磁盘上的 Bundle ID,否则已安装应用的残留会被
        // 误判为孤儿并获得 regenerable 默认勾选。
        let again = await scan(installedIDs: ["COM.GONE.APP"])
        #expect(again.orphans.isEmpty)
    }

    @Test func installedBundleIDCaseVariantIsNotOrphan() async throws {
        try home.makeDir("Library/Caches/com.alive.app", bytes: 1)
        let result = await scan(installedIDs: ["COM.ALIVE.APP"])
        #expect(result.orphans.isEmpty)
    }

    @Test func installedBundleIDMatchingFoldsDiskNameCase() async throws {
        // 磁盘名大写、已安装集合小写:候选侧也必须折叠
        try home.makeDir("Library/Caches/COM.ALIVE.APP", bytes: 1)
        let result = await scan(installedIDs: ["com.alive.app"])
        #expect(result.orphans.isEmpty)
    }

    @Test func resolverLowercaseProbePreventsOrphanForUppercaseName() async throws {
        // 目录名大写,LaunchServices 只认小写形态时也不得列为孤儿
        try home.makeDir("Library/Caches/COM.ALIVE.APP", bytes: 1)
        let result = await scan(resolver: Resolver(resolvable: ["com.alive.app"]))
        #expect(result.orphans.isEmpty)
    }

    @Test func suffixMatchingIsCaseInsensitive() async throws {
        let saved = try home.makeDir("Library/Saved Application State/com.gone.app.SAVEDSTATE", bytes: 2)
        let plist = try home.makeFile("Library/LaunchAgents/com.gone.app.PLIST", bytes: 3)
        let result = await scan()
        #expect(Set(result.orphans.map(\.path)) == [saved.path, plist.path])
    }

    @Test func teamPrefixedAppleGroupContainerIsNotOrphan() async throws {
        try home.makeDir("Library/Group Containers/TEAMID.com.apple.Safari", bytes: 1)
        let result = await scan()
        #expect(result.orphans.isEmpty)
    }

    @Test func installedNameWithAppSuffixIsNotLowConfidenceOrphan() async throws {
        try home.makeDir("Library/Application Support/Foo", bytes: 1)
        let result = await scan(installedNames: ["Foo.app"])
        #expect(result.orphans.isEmpty)
    }

    @Test func recordsFailedLocationWhenEnumerationFails() async throws {
        try home.makeFile("Library/Caches", bytes: 1)   // 位置目录是普通文件 → 枚举抛错
        final class Box: @unchecked Sendable { var last: OrphanScanProgress? }
        let box = Box()
        let scanner = OrphanScanner(home: home.url, resolver: Resolver())
        let result = await scanner.scan(installedBundleIDs: [], installedAppNames: [], exclusions: []) {
            box.last = $0
        }
        #expect(result.failedLocationIDs == ["caches"])
        #expect(result.orphans.isEmpty)
        #expect(box.last?.completedLocations == LeftoverLocations.all.count)
    }
}
