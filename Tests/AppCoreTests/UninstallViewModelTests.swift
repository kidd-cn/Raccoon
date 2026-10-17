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

    // 安全锚点:上游若塞入越界路径,提交前必须被作用域白名单剔除
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
}
