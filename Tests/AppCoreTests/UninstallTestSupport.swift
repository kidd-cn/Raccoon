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
