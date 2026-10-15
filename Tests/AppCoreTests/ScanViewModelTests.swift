import Testing
import Foundation
import CleanKit
import ScanKit
@testable import AppCore

@Suite @MainActor
final class ScanViewModelTests {
    let dir: URL

    init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory() + "raccoon-vm-\(UUID().uuidString)")
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeVM(service: ScanServicing, trash: TrashServicing) -> ScanViewModel {
        ScanViewModel(service: service,
                      exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!),
                      history: JSONHistoryStore(directory: dir),
                      trash: trash)
    }

    func hit(_ path: String, _ size: Int64, safety: SafetyLevel = .safe,
             running: Bool = false, category: RuleCategory = .system) -> ScanHit {
        ScanHit(ruleID: "r", category: category, safety: safety, path: path, sizeBytes: size,
                isDirectory: false, bundleID: nil, appName: nil, isAppRunning: running,
                action: .trash, snapshotDate: nil)
    }

    @Test func testScanFlow_stateMachineAndDefaultSelection() async {
        let svc = FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20, safety: .cautious), hit("/c", 30, running: true)],
            summaries: [.init(category: .system, totalBytes: 60, hitCount: 3)],
            permissionSkippedCount: 1, truncatedRuleIDs: [], excludedCount: 0))
        let vm = makeVM(service: svc, trash: MockTrash(outcome: .trashed))

        #expect(vm.phase == .idle)
        vm.startScan()
        await vm.task?.value
        #expect(vm.phase == .completed)
        // 默认只勾选 safe 且未运行
        #expect(vm.selectedPaths == ["/a"])
        #expect(vm.summaries.count == 1)
        #expect(vm.permissionSkippedCount == 1)

        vm.toggle("/b")
        #expect(vm.selectedBytes == 30)
        vm.uncheckCautiousAndRunning()
        #expect(vm.selectedPaths == ["/a"])

        vm.cancelScan()   // 已完成,不应改变状态
        #expect(vm.phase == .completed)
    }

    @Test func testScanError_transitionsToFailed() async {
        let vm = makeVM(service: FailingScanService(), trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        guard case .failed = vm.phase else { Issue.record("应为 failed,实际 \(String(describing: vm.phase))"); return }
    }

    @Test func testCleanSelected_reportsWritesHistory_andDismiss() async throws {
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 100)], summaries: [], permissionSkippedCount: 0,
            truncatedRuleIDs: [], excludedCount: 0)), trash: trash)
        vm.startScan()
        await vm.task?.value
        vm.cleanSelected()
        await vm.cleanTask?.value

        guard case .report(let report) = vm.phase else { Issue.record("应为 report"); return }
        #expect(report.freedBytes == 100)
        #expect(report.trashedCount == 1)
        let calls = await trash.calls
        #expect(calls == ["/a"])
        let saved = try vm.history.loadAll()
        #expect(saved.count == 1)

        vm.loadLastCleanup()
        #expect(vm.lastCleanup?.freedBytes == 100)

        vm.dismissReport()
        #expect(vm.phase == .idle)
        #expect(vm.hits.isEmpty)
        #expect(vm.selectedPaths.isEmpty)
    }

    @Test func testCleanSelected_skipsProtectedAtExecutorLevel() async throws {
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("\(NSHomeDirectory())/Documents/secret", 500)], summaries: [],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)), trash: trash)
        vm.startScan()
        await vm.task?.value
        // 模拟上游漏拦:手工把受保护路径塞进勾选集
        vm.selectedPaths = ["\(NSHomeDirectory())/Documents/secret"]
        vm.cleanSelected()
        await vm.cleanTask?.value
        let calls = await trash.calls
        #expect(calls.isEmpty, "受保护路径绝不允许进入废纸篓")
        guard case .report(let report) = vm.phase else { Issue.record(); return }
        #expect(report.skipped.first?.reason == "protected")
    }

    // 质量 #1:清理不可重入(.report 态二次 cleanSelected 应被守卫挡下)
    @Test func cleanSelected_reentrancyGuarded() async {
        let trash = MockTrash(outcome: .trashed)
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 100)], summaries: [], permissionSkippedCount: 0,
            truncatedRuleIDs: [], excludedCount: 0)), trash: trash)
        vm.startScan()
        await vm.task?.value
        vm.cleanSelected()
        await vm.cleanTask?.value
        vm.cleanSelected()                 // .report 态重入:守卫应挡下
        await vm.cleanTask?.value
        let calls = await trash.calls
        #expect(calls == ["/a"])           // 仅一次清理
        guard case .report = vm.phase else { Issue.record("应仍在 report"); return }
    }

    // 质量 Important:categoryInFocus 跨阶段残留会在下次完成态自动推入旧明细页,须复位
    @Test func startScan_resetsCategoryInFocus() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 100)], summaries: [], permissionSkippedCount: 0,
            truncatedRuleIDs: [], excludedCount: 0)), trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        vm.categoryInFocus = .system      // 模拟明细页在栈上时的残留
        vm.startScan()
        await vm.task?.value
        #expect(vm.categoryInFocus == nil)
    }
}

struct FailingScanService: ScanServicing {
    struct Boom: Error {}
    func scan(exclusions: [String], progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        throw Boom()
    }
}
