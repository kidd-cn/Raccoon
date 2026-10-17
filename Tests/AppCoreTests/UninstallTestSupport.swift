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

/// 按调用序号独立放行的定位门:用于验证详情加载态,以及切换应用后旧任务不写回。
actor LocatorGate {
    private var calls = 0
    private var started: Set<Int> = []
    private var released: Set<Int> = []
    private var startedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var resumeWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func nextIndex() -> Int {
        calls += 1
        return calls
    }

    func enter(index: Int) async {
        started.insert(index)
        for waiter in startedWaiters.removeValue(forKey: index) ?? [] { waiter.resume() }
        if released.contains(index) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released.contains(index) { continuation.resume() }
            else { resumeWaiters[index] = continuation }
        }
    }

    func waitUntilStarted(index: Int) async {
        if started.contains(index) { return }
        await withCheckedContinuation { continuation in
            startedWaiters[index, default: []].append(continuation)
        }
    }

    func release(index: Int) {
        released.insert(index)
        resumeWaiters.removeValue(forKey: index)?.resume()
    }
}

final class GatedLeftoverLocating: LeftoverLocating, @unchecked Sendable {
    let map: [String: [AppLeftover]]
    let gate = LocatorGate()
    init(map: [String: [AppLeftover]]) { self.map = map }
    func leftovers(for app: InstalledApp, exclusions: [String]) async -> [AppLeftover] {
        let index = await gate.nextIndex()
        await gate.enter(index: index)
        return map[app.bundleID] ?? []
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
