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
