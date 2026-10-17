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
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/com.gone.app"),
            withIntermediateDirectories: true)

        let services = UninstallServices.make(home: home)
        let scan = await services.orphans.scan(installedBundleIDs: [], installedAppNames: [],
                                               exclusions: [], progress: { _ in })
        #expect(scan.orphans.map(\.path)
            == [home.appendingPathComponent("Library/Caches/com.gone.app").path])
    }

    @Test func factoryWiresLocatorForTempHome() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let home = base.appendingPathComponent("raccoon-services-\(UUID().uuidString)")
        let caches = home.appendingPathComponent("Library/Caches/com.gone.app")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let services = UninstallServices.make(home: home)
        let app = InstalledApp(bundleID: "com.gone.app", name: "Gone", version: nil,
                               appPath: home.appendingPathComponent("Applications/Gone.app").path,
                               sizeBytes: 0, isRunning: false)
        let found = await services.locator.leftovers(for: app, exclusions: [])
        #expect(found.map(\.path) == [caches.path])
    }

    @Test func runningCheckerMatchesSystemQuery() {
        let checker = NSRunningAppChecker()
        #expect(checker.isRunning(bundleID: "com.raccoon.nonexistent.\(UUID().uuidString)") == false)
        #expect(checker.isRunning(bundleID: "com.apple.finder")
            == !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty)
    }
}
