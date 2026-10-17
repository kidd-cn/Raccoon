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

    // 用户报障:明细页底栏原用全局口径,进每类数字相同(128 项 · 10.61GB)且与工具栏
    // 「全选/全不选」(按类)范围不一致。本类口径须自成一档,全局口径仍服务清理动作。
    @Test func selectedScope_perCategoryAndGlobal() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10, category: .system),
                   hit("/b", 20, category: .dev),
                   hit("/c", 30, category: .dev)],
            summaries: [], permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value

        // 全局口径:三项皆 safe,默认全选(清理按钮作用范围)
        #expect(vm.selectedItems.count == 3)
        #expect(vm.selectedBytes == 60)
        // 本类口径:与工具栏 selectAll/selectNone(in:) 同范围(底栏主数字)
        #expect(vm.selectedCount(in: .system) == 1)
        #expect(vm.selectedBytes(in: .system) == 10)
        #expect(vm.selectedCount(in: .dev) == 2)
        #expect(vm.selectedBytes(in: .dev) == 50)
        #expect(vm.selectedCount(in: .cautious) == 0)
        #expect(vm.selectedBytes(in: .cautious) == 0)

        // 本类全不选只影响本类,全局随之减少
        vm.selectNone(in: .dev)
        #expect(vm.selectedCount(in: .dev) == 0)
        #expect(vm.selectedCount(in: .system) == 1)
        #expect(vm.selectedBytes == 10)

        // 本类口径随单项 toggle 同步
        vm.toggle("/b")
        #expect(vm.selectedCount(in: .dev) == 1)
        #expect(vm.selectedBytes(in: .dev) == 20)
        #expect(vm.selectedBytes == 30)
    }

    // 用户报障:执行清理后状态不更新——「所清理的文件目录没有更新,已选项中数据大小也没有更新」。
    // 两条根因:1) categoryInFocus 未复位 → item 导航由绑定驱动,明细页留在栈上(报告页根本不可见);
    // 2) hits/selectedPaths/summaries 未随废纸篓事实收敛 → 列表仍列已清理条目、底栏仍报旧字节。
    @Test func cleanSelected_convergesStateAndYieldsDetailPage() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20, category: .dev)],
            summaries: [.init(category: .system, totalBytes: 10, hitCount: 1),
                        .init(category: .dev, totalBytes: 20, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        vm.categoryInFocus = .system        // 清理只能从明细页发起,故此处置非 nil
        #expect(vm.selectedBytes == 30)

        vm.cleanSelected()
        #expect(vm.categoryInFocus == nil)  // 明细页即刻让位:用户看到 .cleaning/.report,而非旧列表
        await vm.cleanTask?.value

        guard case .report = vm.phase else { Issue.record("应为 report"); return }
        #expect(vm.hits.isEmpty)            // 已进废纸篓的条目不再出现在列表
        #expect(vm.selectedPaths.isEmpty)
        #expect(vm.selectedBytes == 0)      // 底栏数字随事实归零
        #expect(vm.summaries.isEmpty)
        #expect(vm.lastCleanup?.freedBytes == 30)   // 主页「上次清理释放 X」即刻更新,不必等重启
    }

    // 反向钉死:被跳过的项仍在磁盘上,绝不能一并从列表/选择集/汇总里消失
    @Test func cleanSelected_keepsSkippedItemsInListAndSelection() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10)],
            summaries: [.init(category: .system, totalBytes: 10, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .skipped(reason: "no-permission")))
        vm.startScan()
        await vm.task?.value
        vm.cleanSelected()
        await vm.cleanTask?.value

        #expect(vm.hits.map(\.path) == ["/a"])
        #expect(vm.selectedPaths == ["/a"])
        #expect(vm.selectedBytes == 10)
        #expect(vm.summaries == [.init(category: .system, totalBytes: 10, hitCount: 1)])
    }

    // 混合轮:只收敛被清理的那部分。「整体清空」能蒙过上面两测,本测将其钉死
    @Test func cleanSelected_prunesOnlyCleanedSubset() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20, category: .dev)],
            summaries: [.init(category: .system, totalBytes: 10, hitCount: 1),
                        .init(category: .dev, totalBytes: 20, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .trashed, skippedFor: ["/b"]))
        vm.startScan()
        await vm.task?.value
        vm.cleanSelected()
        await vm.cleanTask?.value

        guard case .report(let report) = vm.phase else { Issue.record("应为 report"); return }
        #expect(report.trashedCount == 1)
        #expect(report.skipped.map(\.path) == ["/b"])
        #expect(vm.hits.map(\.path) == ["/b"])     // 被跳过者留在列表,已清理者收敛
        #expect(vm.selectedPaths == ["/b"])
        #expect(vm.selectedBytes == 20)
        #expect(vm.summaries == [.init(category: .dev, totalBytes: 20, hitCount: 1)])
    }

    // 用户要求:部分选择后清理——保留未清理项、删除已清理项,且**不必重扫**即可继续处理剩余项。
    // 原缺陷:收敛后的 hits 无任何 UI 路径可达(报告页只有「再扫一次」→ 全量重置),剩余项等于被丢弃。
    @Test func cleanSelected_partialSelectionKeepsRemainingAndReturnsToList() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20, category: .dev), hit("/c", 30, category: .apps)],
            summaries: [.init(category: .system, totalBytes: 10, hitCount: 1),
                        .init(category: .dev, totalBytes: 20, hitCount: 1),
                        .init(category: .apps, totalBytes: 30, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        vm.toggle("/c")                     // 部分选择:取消 /c
        #expect(vm.selectedPaths == ["/a", "/b"])

        vm.cleanSelected()
        await vm.cleanTask?.value

        guard case .report(let report) = vm.phase else { Issue.record("应为 report"); return }
        #expect(report.trashedCount == 2)
        #expect(vm.hits.map(\.path) == ["/c"])                      // 未清理项保留
        #expect(vm.selectedPaths.isEmpty)                           // 已清理项离开选择集
        #expect(vm.remainingBytes == 30)                            // 报告页据此告知「还有 N 项未清理」
        #expect(vm.summaries == [.init(category: .apps, totalBytes: 30, hitCount: 1)])

        vm.returnToResults()
        #expect(vm.phase == .completed)                             // 回列表,不重扫
        #expect(vm.hits.map(\.path) == ["/c"])                      // 剩余项仍在,可直接接着清
        #expect(vm.categoryInFocus == nil)
    }

    // 守卫:仅报告态可回列表(idle/scanning/completed 调用不得改变状态机)
    @Test func returnToResults_guardedOutsideReport() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10)], summaries: [], permissionSkippedCount: 0,
            truncatedRuleIDs: [], excludedCount: 0)), trash: MockTrash(outcome: .trashed))
        #expect(vm.phase == .idle)
        vm.returnToResults()
        #expect(vm.phase == .idle)

        vm.startScan()
        await vm.task?.value
        vm.returnToResults()                // completed 态:明细页已是入口,无需也不应改动
        #expect(vm.phase == .completed)
    }

    // polish:清理进度按 executor 回调回投(已处理/总数)
    @Test func cleanSelected_reportsProgress() async {
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/a", 10), hit("/b", 20)],
            summaries: [], permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        #expect(vm.cleanProgress == CleanProgress(done: 0, total: 0))
        vm.cleanSelected()
        #expect(vm.cleanProgress.total == 2)
        await vm.cleanTask?.value
        #expect(vm.cleanProgress == CleanProgress(done: 2, total: 2))
    }
}

struct FailingScanService: ScanServicing {
    struct Boom: Error {}
    func scan(exclusions: [String], progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        throw Boom()
    }
}
