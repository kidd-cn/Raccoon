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
        // 一层子目录与更深层都必须相对应用根构造,否则测不到「最多一层」的边界。
        let sub = try home.makeDir("Applications/Utilities")
        try home.makeApp("Beta", bundleID: "com.example.beta", inRoot: sub)
        let deep = try home.makeDir("Applications/Deep/More")
        try home.makeApp("Gamma", bundleID: "com.example.gamma", inRoot: deep)

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
