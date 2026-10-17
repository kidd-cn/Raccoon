import Testing
import Foundation
import CleanKit
import UninstallKit
@testable import AppCore

@Suite @MainActor
final class UninstallViewModelTests {
    let home: URL
    let history: JSONHistoryStore

    init() {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("raccoon-uvm-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        history = JSONHistoryStore(directory: home)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func makeVM(apps: [InstalledApp] = [], leftovers: [String: [AppLeftover]] = [:],
                orphans: OrphanScanResult = .init(orphans: [], failedLocationIDs: []),
                trash: TrashServicing = MockTrash(outcome: .trashed)) -> UninstallViewModel {
        UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: apps, unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: leftovers),
            orphanScanner: FakeOrphanScanning(result: orphans),
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history,
            trash: trash,
            home: home)
    }

    @Test func discoveryTransitionsToListAndFilters() async {
        let a = makeTestApp(bundleID: "com.example.alpha", name: "Alpha", home: home)
        let b = makeTestApp(bundleID: "com.example.beta", name: "Beta", home: home)
        let vm = makeVM(apps: [a, b])
        #expect(vm.phase == .discovering)

        vm.startDiscovery()
        await vm.discoveryTask?.value
        #expect(vm.phase == .list)
        #expect(vm.apps.count == 2)

        vm.searchText = "bet"
        #expect(vm.filteredApps.map(\.bundleID) == ["com.example.beta"])
        vm.searchText = "com.example.alpha"
        #expect(vm.filteredApps.map(\.bundleID) == ["com.example.alpha"])
        vm.searchText = ""
        #expect(vm.filteredApps.count == 2)
    }

    @Test func openDetailDefaultsToRegenerableExactOnly() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        let user = leftover("Application Support/com.example.foo", home: home,
                            safety: .userData, locationID: "app-support")
        let lowRegen = leftover("Logs/Foo", home: home, safety: .regenerable,
                                ownership: .appName, locationID: "logs-name")
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen, user, lowRegen]])

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app)
        await vm.leftoverTask?.value

        #expect(vm.detailAppID == "com.example.foo")
        #expect(vm.leftovers.count == 3)
        #expect(vm.selectedLeftoverPaths == [regen.path])   // 低置信即便可再生也不默认勾选
    }

    @Test func uninstallSubmitsBundleAndSelectedLeftovers() async throws {
        let app = makeTestApp(home: home, size: 100)
        let regen = leftover("Caches/com.example.foo", home: home, size: 10)
        let user = leftover("Application Support/com.example.foo", home: home, size: 20,
                            safety: .userData, locationID: "app-support")
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen, user]], trash: trash)

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall()
        #expect(vm.confirmFlow == .apps)
        vm.uninstall()
        #expect(vm.cleanState == .cleaning)
        await vm.cleanTask?.value

        let calls = await trash.calls
        #expect(calls == [app.appPath, regen.path])          // 用户数据默认未勾选
        guard case .report(let report) = vm.cleanState else { Issue.record("应为 report"); return }
        #expect(report.freedBytes == 110)
        #expect(vm.apps.isEmpty)                             // 本体已清理 → 移出列表
        #expect(vm.detailAppID == nil)
        #expect(try history.loadAll().count == 1)
        #expect(vm.lastCleanup?.freedBytes == 110)
    }

    @Test func skippedBundleKeepsAppAndCleanedLeftoversConverge() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen]],
                        trash: MockTrash(outcome: .trashed, skippedFor: [app.appPath]))
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall()
        await vm.cleanTask?.value

        #expect(vm.apps.map(\.bundleID) == ["com.example.foo"])   // 本体被跳过 → 留列表
        #expect(vm.leftovers.isEmpty)                            // 关联数据已进废纸篓 → 收敛
        #expect(vm.selectedLeftoverPaths.isEmpty)
        guard case .report(let report) = vm.cleanState else { Issue.record(); return }
        #expect(report.skipped.map(\.path) == [app.appPath])
        #expect(report.freedBytes == 10)
    }

    @Test func returnFromReportGoesBackToList() async {
        let app = makeTestApp(home: home)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": []])
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall(); await vm.cleanTask?.value
        vm.returnFromReport()
        #expect(vm.cleanState == nil)
        #expect(vm.phase == .list)
        #expect(vm.detailAppID == nil)
    }

    // 选择集混入 leftovers 之外的路径不会被提交;作用域白名单本身由下一条用例钉住。
    @Test func scopeWhitelistDropsRoguePaths() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen]], trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        let rogue = home.appendingPathComponent("Library/Preferences/com.example.foo.plist").path
        vm.selectedLeftoverPaths.insert(rogue)
        vm.requestUninstall(); vm.uninstall()
        await vm.cleanTask?.value
        let calls = await trash.calls
        #expect(calls == [app.appPath, regen.path])
    }

    // 安全锚点(不空覆盖):定位器/Fake 返回越界项时,默认勾选会选中它们;
    // 提交前必须由 uninstallItems 的 scope 白名单剔除,而非依赖 selectedLeftoverItems
    // 先按 leftovers 过滤的副作用。
    @Test func scopeWhitelistDropsRogueLocatorItems() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home)
        // 模拟上游(定位器/Fake)返回越界项:默认勾选会选中它们,提交前必须被 scope 剔除
        let roguePrefs = AppLeftover(
            path: home.appendingPathComponent("Library/Preferences/com.example.foo.plist").path,
            sizeBytes: 5, safety: .regenerable, ownership: .bundleID, locationID: "caches")
        let rogueOutside = AppLeftover(
            path: home.appendingPathComponent("Documents/com.example.foo").path,
            sizeBytes: 6, safety: .regenerable, ownership: .bundleID, locationID: "caches")
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen, roguePrefs, rogueOutside]],
                        trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        #expect(vm.selectedLeftoverPaths == [regen.path, roguePrefs.path, rogueOutside.path])
        vm.requestUninstall(); vm.uninstall()
        await vm.cleanTask?.value
        #expect(await trash.calls == [app.appPath, regen.path])
    }

    // 收敛不变量:本体已清理时,未勾选的 userData 仍在磁盘,必须留在剩余项里。
    @Test func appRemovedKeepsUnselectedUserDataAsRemaining() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home, size: 10)
        let user = leftover("Application Support/com.example.foo", home: home, size: 20,
                            safety: .userData, locationID: "app-support")
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen, user]], trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall(); await vm.cleanTask?.value

        #expect(vm.apps.isEmpty)
        #expect(vm.leftovers.map(\.path) == [user.path])   // 未勾选 userData 仍在磁盘
        #expect(vm.remainingCount == 1)
        #expect(vm.remainingBytes == 20)
        guard case .report(let report) = vm.cleanState else { Issue.record(); return }
        #expect(report.skipped.isEmpty)
    }

    // 收敛不变量:本体已清理时,已提交但 skipped 的关联数据仍在磁盘,必须留在剩余项里。
    @Test func appRemovedKeepsSkippedLeftover() async {
        let app = makeTestApp(home: home)
        let regen = leftover("Caches/com.example.foo", home: home, size: 10)
        let trash = MockTrash(outcome: .trashed, skippedFor: [regen.path])
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": [regen]], trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall(); await vm.cleanTask?.value

        #expect(vm.apps.isEmpty)
        #expect(vm.leftovers.map(\.path) == [regen.path])
        #expect(vm.selectedLeftoverPaths == [regen.path])
        #expect(vm.remainingCount == 1)
    }

    // 取消发现后 task 句柄必须复位,且 hasDiscovered 必须复位——否则后续非 force
    // startDiscovery 会被短路,根本没有真正重跑(用调用计数钉住)。
    @Test func cancelledDiscoveryResetsTaskAndAllowsRetry() async {
        let counter = CallCounter()
        let vm = UninstallViewModel(
            discovery: CancelFirstDiscovering(counter: counter),
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: FakeOrphanScanning(result: .init(orphans: [], failedLocationIDs: [])),
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history, trash: MockTrash(outcome: .trashed), home: home)

        vm.startDiscovery()
        await vm.discoveryTask?.value
        #expect(await counter.count == 1)
        #expect(vm.discoveryTask == nil)
        #expect(vm.phase == .list)

        vm.startDiscovery()          // 必须真的重跑(而不是被 hasDiscovered 短路)
        await vm.discoveryTask?.value
        #expect(await counter.count == 2)
        #expect(vm.phase == .list)
    }

    @Test func returnFromReportIsGuardedOutsideReport() {
        let vm = makeVM()
        vm.returnFromReport()
        #expect(vm.cleanState == nil)
        #expect(vm.phase == .discovering)
    }

    @Test func startDiscoveryIsIdempotentWithoutForce() async {
        final class CountingDiscovering: AppDiscovering, @unchecked Sendable {
            private(set) var calls = 0
            let result: AppDiscoveryResult
            init(result: AppDiscoveryResult) { self.result = result }
            func discover(exclusions: [String],
                          progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult {
                calls += 1
                return result
            }
        }
        let discovery = CountingDiscovering(result: .init(apps: [], unreadableCount: 0))
        let vm = UninstallViewModel(
            discovery: discovery,
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: FakeOrphanScanning(result: .init(orphans: [], failedLocationIDs: [])),
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history, trash: MockTrash(outcome: .trashed), home: home)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.startDiscovery(); await vm.discoveryTask?.value
        #expect(discovery.calls == 1)
        vm.startDiscovery(force: true); await vm.discoveryTask?.value
        #expect(discovery.calls == 2)
    }

    @Test func uninstallIsGuardedWhileCleaning() async {
        let app = makeTestApp(home: home)
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(apps: [app], leftovers: ["com.example.foo": []], trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.openDetail(app); await vm.leftoverTask?.value
        vm.requestUninstall(); vm.uninstall()
        #expect(vm.cleanState == .cleaning)
        vm.confirmFlow = .apps          // 程序化重入面
        vm.uninstall()                  // 必须被 cleanState 守卫挡住
        await vm.cleanTask?.value
        #expect(await trash.calls == [app.appPath])
    }

    // lastCleanup 取历史中日期最新的一条(CleanReport 构造允许指定日期)。
    @Test func loadLastCleanupPicksNewest() throws {
        let older = CleanReport(date: Date(timeIntervalSince1970: 100),
                                freedBytes: 1, trashedCount: 1, vanishedCount: 0, skipped: [])
        let newer = CleanReport(date: Date(timeIntervalSince1970: 200),
                                freedBytes: 2, trashedCount: 2, vanishedCount: 0, skipped: [])
        try history.append(older)
        try history.append(newer)
        let vm = makeVM()
        vm.loadLastCleanup()
        #expect(vm.lastCleanup?.freedBytes == 2)
    }

    // MARK: - 孤儿残留流

    @Test func orphanScanDefaultsToHighConfidenceRegenerable() async {
        let highRegen = leftover("Caches/com.gone.app", home: home, size: 30)
        let highUser = leftover("Application Support/com.gone.app", home: home, size: 20,
                                safety: .userData, locationID: "app-support")
        let low = leftover("Application Support/Old App", home: home, size: 10,
                           safety: .userData, ownership: .appName, locationID: "app-support-name")
        // 低置信 + 可再生:去掉 ownership == .bundleID 条件后会被误勾,钉住该负例。
        let lowRegen = leftover("Caches/Old App", home: home, size: 5,
                                safety: .regenerable, ownership: .appName,
                                locationID: "app-support-name")
        // 输入刻意按 size 升序:扫描结果必须按大小降序重排。
        let vm = makeVM(orphans: .init(orphans: [lowRegen, low, highUser, highRegen],
                                       failedLocationIDs: ["containers"]))

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans()
        #expect(vm.orphanPhase == .scanning)
        await vm.orphanTask?.value

        #expect(vm.orphanPhase == .results)
        #expect(vm.orphans.count == 4)
        #expect(vm.orphans.map(\.path) == [highRegen.path, highUser.path, low.path, lowRegen.path])
        #expect(vm.selectedOrphanPaths == [highRegen.path])
        #expect(vm.failedLocationIDs == ["containers"])
        #expect(vm.orphanProgress.totalLocations > 0)
    }

    @Test func cleanOrphansConvergesOnlyCleanedSubset() async {
        let a = leftover("Caches/com.a.app", home: home)
        let b = leftover("Caches/com.b.app", home: home)
        let trash = MockTrash(outcome: .trashed, skippedFor: [b.path])
        let vm = makeVM(orphans: .init(orphans: [a, b], failedLocationIDs: []), trash: trash)

        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans(); await vm.orphanTask?.value
        vm.selectedOrphanPaths = [a.path, b.path]
        vm.requestCleanOrphans()
        #expect(vm.confirmFlow == .orphans)
        vm.cleanOrphans()
        await vm.cleanTask?.value

        #expect(vm.orphans.map(\.path) == [b.path])   // 跳过的仍在磁盘
        #expect(vm.selectedOrphanPaths == [b.path])
        guard case .report = vm.cleanState else { Issue.record("应为 report"); return }
        #expect(vm.remainingCount == 1)
        vm.returnFromReport()
        #expect(vm.orphanPhase == .results)
        #expect(vm.cleanState == nil)
    }

    @Test func cancelOrphanScanReturnsToIdle() async {
        let vm = makeVM()
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans()
        vm.cancelOrphanScan()
        #expect(vm.orphanPhase == .idle)
        await vm.orphanTask?.value
        #expect(vm.orphanPhase == .idle)
    }

    // 与卸载流对称:越界项即便被默认勾选/手工选中,提交前必须被作用域白名单剔除。
    @Test func orphanCleanDropsRogueLocatorItems() async {
        let good = leftover("Caches/com.gone.app", home: home)
        let roguePrefs = AppLeftover(
            path: home.appendingPathComponent("Library/Preferences/com.gone.app.plist").path,
            sizeBytes: 5, safety: .regenerable, ownership: .bundleID, locationID: "caches")
        let rogueOutside = AppLeftover(
            path: home.appendingPathComponent("Documents/com.gone.app").path,
            sizeBytes: 6, safety: .regenerable, ownership: .bundleID, locationID: "caches")
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(orphans: .init(orphans: [good, roguePrefs, rogueOutside], failedLocationIDs: []),
                        trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans(); await vm.orphanTask?.value
        #expect(vm.selectedOrphanPaths == [good.path, roguePrefs.path, rogueOutside.path])
        vm.requestCleanOrphans(); vm.cleanOrphans(); await vm.cleanTask?.value
        #expect(await trash.calls == [good.path])
    }

    // 安全锚点:扫描必须带发现阶段的已安装集合,否则已安装应用的可再生残留会被误判为孤儿。
    @Test func orphanScanPassesInstalledSetsFromDiscovery() async {
        let app = makeTestApp(bundleID: "com.example.foo", name: "Foo", home: home)
        let scanner = RecordingOrphanScanner(result: .init(orphans: [], failedLocationIDs: []))
        let excluded = home.appendingPathComponent("Library/Caches/keep").path
        let exclusions = ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!)
        exclusions.add(excluded)
        let vm = UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: [app], unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: scanner,
            exclusions: exclusions,
            history: history, trash: MockTrash(outcome: .trashed), home: home)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans(); await vm.orphanTask?.value
        #expect(scanner.recordedIDs == ["com.example.foo"])
        #expect(scanner.recordedNames == ["Foo"])
        #expect(scanner.recordedExclusions == [excluded])
    }

    // 发现未完成时扫描会拿空已安装集合,已安装应用的可再生残留会被误判孤儿并默认勾选。
    @Test func scanOrphansIsNoOpBeforeDiscoveryCompletes() async {
        let scanner = RecordingOrphanScanner(
            result: .init(orphans: [leftover("Caches/com.gone.app", home: home)],
                          failedLocationIDs: []))
        let vm = UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: [], unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: scanner,
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history, trash: MockTrash(outcome: .trashed), home: home)
        vm.startDiscovery()
        #expect(vm.phase == .discovering)
        vm.scanOrphans()                       // 发现未完成:必须 no-op
        await vm.discoveryTask?.value
        #expect(scanner.scanCount == 0)
        #expect(vm.orphanPhase == .idle)
    }

    // 取消后仍在途的进度回调不得覆盖已复位/新一轮扫描的进度。
    @Test(.timeLimit(.minutes(1))) func staleProgressAfterCancelIsIgnored() async {
        let scanner = GatedOrphanScanner(result: .init(orphans: [], failedLocationIDs: []))
        let vm = UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: [], unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: scanner,
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history, trash: MockTrash(outcome: .trashed), home: home)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans()
        await scanner.gate.waitUntilStarted()
        let task = vm.orphanTask
        vm.cancelOrphanScan()
        #expect(vm.orphanPhase == .idle)
        #expect(vm.orphanProgress.completedLocations == 0)
        await scanner.gate.release()           // 放行后 scan 会在取消之后回调 progress(5/8)
        await task?.value
        await Task.yield()
        await Task.yield()
        #expect(vm.orphanPhase == .idle)
        #expect(vm.orphanProgress.completedLocations == 0)   // 5 未被写入
    }

    @Test(.timeLimit(.minutes(1))) func scanOrphansIsNoOpWhileScanning() async {
        let orphan = leftover("Caches/com.gone.app", home: home)
        let scanner = GatedOrphanScanner(result: .init(orphans: [orphan], failedLocationIDs: []))
        let vm = UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: [], unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: scanner,
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history, trash: MockTrash(outcome: .trashed), home: home)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans()
        await scanner.gate.waitUntilStarted()
        let task = vm.orphanTask
        vm.scanOrphans()                       // .scanning:no-op
        #expect(vm.orphanPhase == .scanning)
        await scanner.gate.release()
        await task?.value
        #expect(scanner.scanCount == 1)
        #expect(vm.orphans.map(\.path) == [orphan.path])
        #expect(vm.orphanPhase == .results)
    }

    // 取消 A 后在途收尾不得清掉新一轮 B 的句柄,否则 B 无法被取消。
    @Test(.timeLimit(.minutes(1))) func staleTaskCleanupDoesNotClearNewerScanHandle() async {
        let scanner = MultiGatedOrphanScanner(
            result: .init(orphans: [leftover("Caches/com.a.app", home: home)],
                          failedLocationIDs: []))
        let vm = UninstallViewModel(
            discovery: FakeAppDiscovering(result: .init(apps: [], unreadableCount: 0)),
            locator: FakeLeftoverLocating(map: [:]),
            orphanScanner: scanner,
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "uvm-\(UUID().uuidString)")!),
            history: history, trash: MockTrash(outcome: .trashed), home: home)
        vm.startDiscovery(); await vm.discoveryTask?.value

        vm.scanOrphans()                                   // A
        await scanner.gate.waitUntilStarted(index: 1)
        let a = vm.orphanTask
        #expect(a != nil)

        vm.cancelOrphanScan()                              // 取消 A
        vm.scanOrphans()                                   // B
        await scanner.gate.waitUntilStarted(index: 2)
        #expect(vm.orphanTask != nil)
        #expect(vm.orphanPhase == .scanning)

        await scanner.gate.release(index: 1)               // 只放行 A
        await a?.value
        #expect(vm.orphanTask != nil)                       // 修复前被 A 的 defer 置 nil

        let b = vm.orphanTask
        vm.cancelOrphanScan()                              // 必须能取消 B
        #expect(vm.orphanPhase == .idle)
        await scanner.gate.release(index: 2)               // 放行 B 收尾,避免悬挂
        await b?.value
        #expect(await scanner.gate.calls == 2)
        #expect(vm.orphanPhase == .idle)                    // B 的结果不落地
    }

    @Test func cleanOrphansIsGuardedWhileCleaning() async {
        let a = leftover("Caches/com.a.app", home: home)
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(orphans: .init(orphans: [a], failedLocationIDs: []), trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans(); await vm.orphanTask?.value
        vm.selectedOrphanPaths = [a.path]
        vm.requestCleanOrphans(); vm.cleanOrphans()
        #expect(vm.cleanState == .cleaning)
        vm.confirmFlow = .orphans            // 程序化重入面
        vm.cleanOrphans()                    // 必须被 cleanState 守卫挡住
        await vm.cleanTask?.value
        #expect(await trash.calls == [a.path])
    }

    // 对称收敛:未勾选的孤儿仍在磁盘,清理后必须留在剩余项里。
    @Test func unselectedOrphanRemainsAfterClean() async {
        let a = leftover("Caches/com.a.app", home: home, size: 10)
        let b = leftover("Caches/com.b.app", home: home, size: 20)
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(orphans: .init(orphans: [a, b], failedLocationIDs: []), trash: trash)
        vm.startDiscovery(); await vm.discoveryTask?.value
        vm.scanOrphans(); await vm.orphanTask?.value
        vm.selectedOrphanPaths = [a.path]
        vm.requestCleanOrphans(); vm.cleanOrphans(); await vm.cleanTask?.value
        #expect(vm.orphans.map(\.path) == [b.path])
        #expect(vm.selectedOrphanPaths.isEmpty)
        #expect(vm.remainingCount == 1)
        #expect(vm.remainingBytes == 20)
    }
}

actor CallCounter {
    private(set) var count = 0
    func increment() -> Int { count += 1; return count }
}

struct CancelFirstDiscovering: AppDiscovering {
    let counter: CallCounter
    func discover(exclusions: [String],
                  progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult {
        let n = await counter.increment()
        if n == 1 { _ = withUnsafeCurrentTask { $0?.cancel() } }
        return AppDiscoveryResult(apps: [], unreadableCount: 0)
    }
}

final class RecordingOrphanScanner: OrphanScanning, @unchecked Sendable {
    let result: OrphanScanResult
    private(set) var scanCount = 0
    private(set) var recordedIDs: Set<String> = []
    private(set) var recordedNames: Set<String> = []
    private(set) var recordedExclusions: [String] = []
    init(result: OrphanScanResult) { self.result = result }
    func scan(installedBundleIDs: Set<String>, installedAppNames: Set<String>,
              exclusions: [String],
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult {
        scanCount += 1
        recordedIDs = installedBundleIDs
        recordedNames = installedAppNames
        recordedExclusions = exclusions
        progress(OrphanScanProgress(completedLocations: LeftoverLocations.all.count,
                                    totalLocations: LeftoverLocations.all.count))
        return result
    }
}

/// 让扫描器在 scan 内挂起,测试可精确控制「取消发生在进度回调之前」的时序。
actor ScanGate {
    private var isStarted = false
    private var isReleased = false
    private var resumeScans: [CheckedContinuation<Void, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        isStarted = true
        let waiters = startedWaiters
        startedWaiters = []
        for waiter in waiters { waiter.resume() }
        if isReleased { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if isReleased { continuation.resume() } else { resumeScans.append(continuation) }
        }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for continuation in resumeScans { continuation.resume() }
        resumeScans = []
    }
}

final class GatedOrphanScanner: OrphanScanning, @unchecked Sendable {
    let result: OrphanScanResult
    let gate = ScanGate()
    private(set) var scanCount = 0
    init(result: OrphanScanResult) { self.result = result }
    func scan(installedBundleIDs: Set<String>, installedAppNames: Set<String>,
              exclusions: [String],
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult {
        scanCount += 1
        await gate.enter()
        progress(OrphanScanProgress(completedLocations: 5, totalLocations: 8))
        return result
    }
}

/// 按调用序号独立放行的 gate:用于「旧任务收尾 vs 新任务在途」的交错场景。
actor MultiScanGate {
    private(set) var calls = 0
    private var started: Set<Int> = []
    private var startedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var resumeScans: [Int: CheckedContinuation<Void, Never>] = [:]

    func nextIndex() -> Int {
        calls += 1
        return calls
    }

    func enter(index: Int) async {
        started.insert(index)
        if let waiter = startedWaiters.removeValue(forKey: index) { waiter.resume() }
        if released.contains(index) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released.contains(index) { continuation.resume() }
            else { resumeScans[index] = continuation }
        }
    }

    func waitUntilStarted(index: Int) async {
        if started.contains(index) { return }
        await withCheckedContinuation { continuation in
            startedWaiters[index] = continuation
        }
    }

    func release(index: Int) {
        released.insert(index)
        resumeScans.removeValue(forKey: index)?.resume()
    }
}

final class MultiGatedOrphanScanner: OrphanScanning, @unchecked Sendable {
    let result: OrphanScanResult
    let gate = MultiScanGate()
    init(result: OrphanScanResult) { self.result = result }
    func scan(installedBundleIDs: Set<String>, installedAppNames: Set<String>,
              exclusions: [String],
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult {
        let index = await gate.nextIndex()
        await gate.enter(index: index)
        progress(OrphanScanProgress(completedLocations: index, totalLocations: 8))
        return result
    }
}
