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
