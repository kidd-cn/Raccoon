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
        let alpha = try home.makeApp("Alpha", bundleID: "com.example.alpha", inRoot: root)
        // 一层子目录与更深层都必须相对应用根构造,否则测不到「最多一层」的边界。
        let sub = try home.makeDir("Applications/Utilities")
        try home.makeApp("Beta", bundleID: "com.example.beta", inRoot: sub)
        let deep = try home.makeDir("Applications/Deep/More")
        try home.makeApp("Gamma", bundleID: "com.example.gamma", inRoot: deep)

        let result = try await discover(roots: [root])
        #expect(Set(result.apps.map(\.bundleID)) == ["com.example.alpha", "com.example.beta"])
        #expect(result.unreadableCount == 0)
        #expect(result.apps[0].sizeBytes == FileSize.bytes(at: alpha))
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

    @Test func followsSymlinkedRoot() async throws {
        let root = try home.appRoot()
        let app = try home.makeApp("Foo", bundleID: "com.example.foo", inRoot: root)
        let link = home.url.appendingPathComponent("LinkedApplications")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        let result = try await discover(roots: [link])
        #expect(result.apps.map(\.bundleID) == ["com.example.foo"])
        #expect(result.apps[0].appPath == app.resolvingSymlinksInPath().path)
    }

    @Test func ignoresPlainFileApp() async throws {
        let root = try home.appRoot()
        try home.makeFile("Applications/File.app", bytes: 10)

        let result = try await discover(roots: [root])
        #expect(result.apps.isEmpty)
        #expect(result.unreadableCount == 0)   // 文件型 .app 不是「无法识别的应用」
    }

    @Test func skipsAppleBundleIDsCaseInsensitivelyAndCountsEmptyIDUnreadable() async throws {
        let root = try home.appRoot()
        try home.makeApp("Caps", bundleID: "COM.APPLE.Caps", inRoot: root)
        try home.makeApp("EmptyID", bundleID: "", inRoot: root)

        let result = try await discover(roots: [root])
        #expect(result.apps.isEmpty)
        #expect(result.unreadableCount == 1)
    }

    @Test func recognizesUppercaseAppExtension() async throws {
        let root = try home.appRoot()
        let lower = try home.makeApp("Upper", bundleID: "com.example.upper", inRoot: root)
        try FileManager.default.moveItem(
            at: lower, to: root.appendingPathComponent("Upper.APP"))

        let result = try await discover(roots: [root])
        #expect(result.apps.map(\.bundleID) == ["com.example.upper"])
    }

    @Test func doesNotDescendIntoNestedAppBundles() async throws {
        let root = try home.appRoot()
        try home.makeApp("Good", bundleID: "com.example.good", inRoot: root)
        try home.makeApp("Helper", bundleID: "com.example.helper",
                         inRoot: root.appendingPathComponent("Good.app/Contents/MacOS"))

        let result = try await discover(roots: [root])
        #expect(result.apps.map(\.bundleID) == ["com.example.good"])
        #expect(result.unreadableCount == 0)
    }

    @Test func sortsAcrossRootsNumericallyAndTiesByBundleID() async throws {
        let rootA = try home.appRoot("RootA")
        let rootB = try home.appRoot("RootB")
        try home.makeApp("Zeta", bundleID: "com.example.zeta", inRoot: rootA)
        try home.makeApp("Alpha", bundleID: "com.example.alpha", inRoot: rootB)
        // 无排序时枚举顺序为 [Zeta, Alpha]。
        let acrossRoots = try await discover(roots: [rootA, rootB])
        #expect(acrossRoots.apps.map(\.name) == ["Alpha", "Zeta"])

        let numbers = try home.appRoot("Numbers")
        try home.makeApp("File 10", bundleID: "com.example.file10", inRoot: numbers)
        try home.makeApp("File 2", bundleID: "com.example.file2", inRoot: numbers)
        let numeric = try await discover(roots: [numbers])
        #expect(numeric.apps.map(\.name) == ["File 2", "File 10"])

        // 同名时以 Bundle ID 为二级键(否则保留根顺序 zzz 在前)。
        let tieA = try home.appRoot("TieA")
        let tieB = try home.appRoot("TieB")
        try home.makeApp("Same", bundleID: "com.example.zzz", inRoot: tieA)
        try home.makeApp("Same", bundleID: "com.example.aaa", inRoot: tieB)
        let tied = try await discover(roots: [tieA, tieB])
        #expect(tied.apps.map(\.bundleID) == ["com.example.aaa", "com.example.zzz"])
    }

    @Test func appliesRawPathExclusion() async throws {
        let root = try home.appRoot()
        let plain = try home.makeApp("Plain", bundleID: "com.example.plain", inRoot: root)

        let result = try await discover(roots: [root], exclusions: [plain.path])
        #expect(result.apps.isEmpty)
    }

    @Test func appliesResolvedPathExclusionToSymlinkedApp() async throws {
        let root = try home.appRoot()
        // Real.app 是普通目录但名字以 .app 结尾:作为候选处理、不会下钻,
        // 因此其中的真实应用只能经 Excluded.app 符号链接被发现。
        let real = try home.makeApp("Excluded", bundleID: "com.example.excluded",
                                    inRoot: root.appendingPathComponent("Real.app"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Excluded.app"), withDestinationURL: real)

        // 排除项是解析后路径;候选的原始路径(root/Excluded.app)不匹配,
        // 必须解析后再问一次才能拦住。
        let result = try await discover(roots: [root], exclusions: [real.path])
        #expect(result.apps.isEmpty)
    }

    @Test func appliesRawPathExclusionToSymlinkedApp() async throws {
        let root = try home.appRoot()
        // 目标放在名为 .app 的普通容器目录里,不会被一层规则下钻枚举。
        let target = try home.makeApp("Target", bundleID: "com.example.target",
                                      inRoot: root.appendingPathComponent("Container.app"))
        let link = root.appendingPathComponent("Excluded.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        // 排除项写作链接路径(原始形态);解析路径是 Container.app/Target.app,不匹配。
        let result = try await discover(roots: [root], exclusions: [link.path])
        #expect(result.apps.isEmpty)
    }

    @Test func isUnderRejectsSiblingPrefix() {
        #expect(!AppDiscovery.isUnder("/Applications2/Foo.app", rootPath: "/Applications"))
        #expect(AppDiscovery.isUnder("/Applications/Foo.app", rootPath: "/Applications"))
    }

    @Test func dedupesAliasedRootsAndProgressCountsCandidates() async throws {
        let root = try home.appRoot("Applications")
        try home.makeApp("A", bundleID: "com.example.a", inRoot: root)
        try home.makeApp("B", bundleID: "com.example.b", inRoot: root)
        try home.makeApp("Safari", bundleID: "com.apple.Safari", inRoot: root)   // 被过滤项也应计数
        let alias = home.url.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        final class Box: @unchecked Sendable { var last = 0 }
        let box = Box()
        _ = try await AppDiscovery(appRoots: [root, alias], running: Running())
            .discover(exclusions: []) { box.last = $0.enumeratedCount }
        #expect(box.last == 3)   // 去重后只枚举一次;未去重为 6;进度含被过滤的 Apple 应用
    }

    @Test func throwsOnCancellation() async throws {
        let root = try home.appRoot()
        for index in 0..<20 {
            try home.makeApp("App\(index)", bundleID: "com.example.app\(index)", inRoot: root)
        }
        let discovery = AppDiscovery(appRoots: [root], running: Running())
        let task = Task { try await discovery.discover(exclusions: []) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
