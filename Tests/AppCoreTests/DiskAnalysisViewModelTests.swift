import Testing
import Foundation
import CleanKit
import DiskKit
@testable import AppCore

// MARK: - 夹具(临时目录自建树,deinit 用 removeItem 自清——夹具清理是唯一允许的 removeItem 例外)

/// 测试用 HistoryStoring 假实现:本任务 ViewModel 不清理,故 append 为空实现。
struct FakeHistory: HistoryStoring {
    let reports: [CleanReport]
    init(_ reports: [CleanReport] = []) { self.reports = reports }
    func append(_ report: CleanReport) throws {}
    func loadAll() throws -> [CleanReport] { reports }
}

/// 记录写入历史(验证 cleanSelected 完成后入库与 source 透传)。HistoryStoring 为同步协议,
/// 用锁保护可变状态而非 actor(actor 隔离会与同步协议需求交叉导致并发错误)。
final class RecordingHistory: HistoryStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CleanReport] = []
    var appended: [CleanReport] { lock.withLock { stored } }
    func append(_ report: CleanReport) throws { lock.withLock { stored.append(report) } }
    func loadAll() throws -> [CleanReport] { lock.withLock { stored } }
}

/// 可在扫描后按路径路由结果的假 trash(跳过/消失用例:结果路径依赖扫描产出的规范路径)。
actor RoutedTrash: TrashServicing {
    private var outcomes: [String: TrashOutcome] = [:]
    private(set) var calls: [String] = []
    func route(_ path: String, to outcome: TrashOutcome) { outcomes[path] = outcome }
    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        return outcomes[path] ?? .trashed
    }
}

@Suite @MainActor
final class DiskAnalysisViewModelTests {
    let dir: URL
    let defaultsSuite: String

    init() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory() + "raccoon-davm-\(UUID().uuidString)")
        defaultsSuite = "davm-\(UUID().uuidString)"
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    func makeVM(hardRoots: [String] = [], userExclusions: [String] = [],
                history: HistoryStoring? = nil,
                trash: TrashServicing? = nil) -> DiskAnalysisViewModel {
        DiskAnalysisViewModel(
            scanner: DiskScanner(protection: ProtectionStore(hardRoots: hardRoots,
                                                             userExclusions: userExclusions)),
            exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: defaultsSuite)!),
            history: history ?? FakeHistory(),
            trash: trash ?? MockTrash(outcome: .trashed))
    }

    /// 写入相对文件(自动建父目录);体量由磁盘块占用决定,断言只做相对关系。
    @discardableResult
    func write(_ rel: String, _ bytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// 3 层树夹具:root/a.txt、root/d1/b.txt、root/d2/c.txt、root/d2/d3/d.txt。
    /// 节点共 8(root、a.txt、d1、d1/b.txt、d2、d2/c.txt、d2/d3、d2/d3/d.txt)。
    @discardableResult
    func makeTree() throws -> URL {
        try write("a.txt", 100)
        try write("d1/b.txt", 200)
        try write("d2/c.txt", 300)
        try write("d2/d3/d.txt", 400)
        return dir
    }

    @Test func scanLifecycleIdleToCompleted() async throws {
        try write("sub/a.txt", 1_000)
        try write("sub/b.txt", 2_000)
        let vm = makeVM()
        #expect(vm.phase == .idle)

        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        #expect(vm.phase == .completed)
        let root = try #require(vm.root)
        #expect(vm.drillPath == [root])
        #expect(vm.currentChildren.map(\.name) == ["sub"])
        #expect(vm.progress != nil)
    }

    @Test func cancelDiscardsAndReturnsIdle() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<2_000 {
            try Data(count: 8).write(to: dir.appendingPathComponent("f\(i)"))
        }
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        vm.cancelScan()
        await vm.task?.value

        #expect(vm.phase == .idle)
        #expect(vm.root == nil)
    }

    @Test func failedRootGoesToFailed() async {
        let vm = makeVM()
        vm.startScan(rootPath: "relative")
        await vm.task?.value

        guard case .failed = vm.phase else {
            Issue.record("应为 failed,实际 \(String(describing: vm.phase))")
            return
        }
        #expect(vm.root == nil)
    }

    @Test func drillAndBreadcrumb() async throws {
        try write("big/inner.txt", 100_000)
        try write("small/inner.txt", 100)
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let children = vm.currentChildren
        #expect(children.count == 2)
        let sizes = children.map(\.sizeBytes)
        #expect(sizes == sizes.sorted(by: >), "currentChildren 应降序")

        let big = try #require(children.first { $0.name == "big" })
        vm.drill(into: big)
        #expect(vm.drillPath.count == 2)
        #expect(vm.drillPath.last?.name == "big")
        #expect(vm.currentChildren.map(\.name) == ["inner.txt"])

        vm.drillTo(depth: 0)
        #expect(vm.drillPath == [root])
    }

    @Test func displayRowsAggregatesTail() async throws {
        let case125 = dir.appendingPathComponent("case125", isDirectory: true)
        try FileManager.default.createDirectory(at: case125, withIntermediateDirectories: true)
        for i in 0..<125 {
            try Data(repeating: 0x41, count: 100).write(to: case125.appendingPathComponent("f\(i)"))
        }

        let vm = makeVM()
        vm.startScan(rootPath: case125.path)
        await vm.task?.value

        let rows = vm.displayRows
        #expect(rows.count == 121)
        guard case .others(let count, _) = rows.last?.kind else {
            Issue.record("末行应为 others 聚合行")
            return
        }
        #expect(count == 5)
        #expect(rows.last?.id == "__others__")

        // 121 个子项:聚合后 others 只剩 1 项 → 取消聚合,无 others 行
        let case121 = dir.appendingPathComponent("case121", isDirectory: true)
        try FileManager.default.createDirectory(at: case121, withIntermediateDirectories: true)
        for i in 0..<121 {
            try Data(repeating: 0x41, count: 100).write(to: case121.appendingPathComponent("f\(i)"))
        }
        vm.startScan(rootPath: case121.path)
        await vm.task?.value

        let rows2 = vm.displayRows
        #expect(rows2.count == 121)
        #expect(!rows2.contains { $0.id == "__others__" })
    }

    @Test func toggleGates() async throws {
        try write("subdir/a.txt", 100)
        try write("subdir/b.txt", 200)
        try write("protected/inner.txt", 300)

        let vm = makeVM(hardRoots: ["\(dir.path)/protected"])
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let subdir = try #require(root.children.first { $0.name == "subdir" })
        let fileA = try #require(subdir.children.first { $0.name == "a.txt" })
        let protected = try #require(root.children.first { $0.name == "protected" })

        // root no-op
        vm.toggle(root.path)
        #expect(vm.selectedPaths.isEmpty)

        // containsProtected no-op
        vm.toggle(protected.path)
        #expect(vm.selectedPaths.isEmpty)

        // 勾选目录移除子孙路径:先勾子文件,再勾目录 → 子孙路径被移除
        vm.toggle(fileA.path)
        #expect(vm.selectedPaths == [fileA.path])
        vm.toggle(subdir.path)
        #expect(vm.selectedPaths == [subdir.path])

        // 祖先已勾选时后代 no-op
        vm.toggle(fileA.path)
        #expect(vm.selectedPaths == [subdir.path])
    }

    @Test func exclusionsAddedAfterInitAreHonored() async throws {
        // 独立 defaults suite,避免污染类级 defaultsSuite;结束移除持久域。
        let suite = "davm-excl-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = ExclusionsStore(defaults: defaults)

        try write("plain/a.txt", 100)
        try write("excluded/b.txt", 200)

        // init 时排除为空;init 后再 add → 校验扫描按当前清单实时重建保护层(而非 init 快照)
        let vm = DiskAnalysisViewModel(
            scanner: DiskScanner(protection: ProtectionStore(hardRoots: [], userExclusions: [])),
            exclusions: store,
            history: FakeHistory(),
            trash: MockTrash(outcome: .trashed))
        store.add(ProtectionStore.normalize(dir.appendingPathComponent("excluded").path))

        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let excluded = try #require(root.children.first { $0.name == "excluded" })
        #expect(excluded.containsProtected)

        vm.toggle(excluded.path)
        #expect(!vm.selectedPaths.contains(excluded.path))

        defaults.removePersistentDomain(forName: suite)
    }

    @Test func selectionSurvivesDrill() async throws {
        try write("top/sub/inner.txt", 1_000)
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let top = try #require(root.children.first { $0.name == "top" })
        let sub = try #require(top.children.first { $0.name == "sub" })
        let inner = try #require(sub.children.first { $0.name == "inner.txt" })

        vm.toggle(inner.path)
        #expect(vm.selectedPaths == [inner.path])
        #expect(vm.selectedNodes.map(\.path) == [inner.path])
        #expect(vm.selectedBytes > 0)

        vm.drill(into: top)
        #expect(vm.drillPath.count == 2)
        #expect(vm.selectedPaths == [inner.path])
        #expect(vm.selectedNodes.map(\.path) == [inner.path])

        vm.drillTo(depth: 0)
        #expect(vm.selectedPaths == [inner.path])
    }

    @Test func defaultsUnselected() async throws {
        try write("a.txt", 100)
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        #expect(vm.selectedPaths.isEmpty)
        #expect(vm.selectedNodes.isEmpty)
        #expect(vm.selectedBytes == 0)
        #expect(vm.canSelectRoot == false)
    }

    @Test func remainingCountsWholeTree() async throws {
        try makeTree()
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        #expect(vm.remainingCount == 7)
        #expect(vm.remainingBytes == vm.root?.sizeBytes)
    }

    @Test func cleanSelectedTrashesTopmostSelection() async throws {
        try makeTree()
        let trash = MockTrash(outcome: .trashed)
        let history = RecordingHistory()
        let vm = makeVM(history: history, trash: trash)
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let d2 = try #require(root.children.first { $0.name == "d2" })
        vm.toggle(d2.path)
        #expect(vm.selectedNodes.map(\.path) == [d2.path])

        vm.cleanSelected()
        await vm.task?.value

        // 只 trash 最上层目录,不 trash 其子孙
        let calls = await trash.calls
        #expect(calls == [d2.path])

        guard case .report(let report) = vm.phase else {
            Issue.record("清理后应进入 report 态")
            return
        }
        #expect(report.source == "disk-analysis")
        #expect(vm.lastCleanup?.source == "disk-analysis")
        #expect(history.appended.map(\.source) == ["disk-analysis"])
    }

    @Test func inPlaceUpdateRemovesAndPropagates() async throws {
        try makeTree()
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let d2 = try #require(root.children.first { $0.name == "d2" })
        let d3 = try #require(d2.children.first { $0.name == "d3" })
        let rootBefore = root.sizeBytes
        let d2Before = d2.sizeBytes
        let d3Before = d3.sizeBytes

        vm.toggle(d3.path)
        vm.cleanSelected()
        await vm.task?.value

        let root2 = try #require(vm.root)
        #expect(root2.children.map(\.name).sorted() == ["a.txt", "d1", "d2"])
        let d2After = try #require(root2.children.first { $0.name == "d2" })
        #expect(d2After.children.map(\.name) == ["c.txt"])
        #expect(d2After.sizeBytes == d2Before - d3Before)
        #expect(root2.sizeBytes == rootBefore - d3Before)
        #expect(vm.remainingBytes == rootBefore - d3Before)
        #expect(!vm.selectedPaths.contains(d3.path))
    }

    @Test func skippedStaysSelectedAndInTree() async throws {
        try makeTree()
        let trash = RoutedTrash()
        let vm = makeVM(trash: trash)
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let a = try #require(root.children.first { $0.name == "a.txt" })
        let rootBefore = root.sizeBytes

        vm.toggle(a.path)
        await trash.route(a.path, to: .skipped(reason: "no-permission"))

        vm.cleanSelected()
        await vm.task?.value

        let root2 = try #require(vm.root)
        #expect(root2.children.map(\.name).sorted() == ["a.txt", "d1", "d2"])
        #expect(root2.sizeBytes == rootBefore)
        #expect(vm.selectedPaths == [a.path])
        guard case .report(let report) = vm.phase else {
            Issue.record("清理后应进入 report 态")
            return
        }
        #expect(report.trashedCount == 0)
        #expect(report.skipped.map(\.path) == [a.path])
    }

    @Test func vanishedNotCountedAsFreed() async throws {
        try makeTree()
        let trash = RoutedTrash()
        let vm = makeVM(trash: trash)
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let d2 = try #require(root.children.first { $0.name == "d2" })
        let d3 = try #require(d2.children.first { $0.name == "d3" })

        vm.toggle(d3.path)
        await trash.route(d3.path, to: .vanished)

        vm.cleanSelected()
        await vm.task?.value

        guard case .report(let report) = vm.phase else {
            Issue.record("清理后应进入 report 态")
            return
        }
        #expect(report.freedBytes == 0)
        #expect(report.vanishedCount == 1)

        let root2 = try #require(vm.root)
        let d2After = try #require(root2.children.first { $0.name == "d2" })
        #expect(!d2After.children.contains { $0.name == "d3" })
        #expect(!vm.selectedPaths.contains(d3.path))
    }

    @Test func drillPathFallsBackToSurvivingAncestor() async throws {
        try makeTree()
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let d2 = try #require(root.children.first { $0.name == "d2" })
        let d3 = try #require(d2.children.first { $0.name == "d3" })
        vm.drill(into: d2)
        vm.drill(into: d3)
        #expect(vm.drillPath.map(\.name) == [root.name, "d2", "d3"])

        vm.toggle(d3.path)
        vm.cleanSelected()
        await vm.task?.value

        vm.dismissReport()
        #expect(vm.phase == .completed)
        #expect(vm.drillPath.map(\.name) == [root.name, "d2"])

        let root2 = try #require(vm.root)
        let d2After = try #require(root2.children.first { $0.name == "d2" })
        #expect(d2After.children.map(\.name) == ["c.txt"])
    }

    @Test func returnToResultsAndDismiss() async throws {
        try makeTree()
        let vm = makeVM()
        vm.startScan(rootPath: dir.path)
        await vm.task?.value

        let root = try #require(vm.root)
        let a = try #require(root.children.first { $0.name == "a.txt" })

        // returnToResults:回到 completed 且保留更新后的树(a.txt 已移除)
        vm.toggle(a.path)
        vm.cleanSelected()
        await vm.task?.value
        guard case .report = vm.phase else {
            Issue.record("第一次清理后应为 report 态")
            return
        }
        vm.returnToResults()
        #expect(vm.phase == .completed)
        let root1 = try #require(vm.root)
        #expect(!root1.children.contains { $0.name == "a.txt" })

        // dismissReport:回到 completed 且保留更新后的树(d1 已移除)
        let d1 = try #require(root1.children.first { $0.name == "d1" })
        vm.toggle(d1.path)
        vm.cleanSelected()
        await vm.task?.value
        guard case .report = vm.phase else {
            Issue.record("第二次清理后应为 report 态")
            return
        }
        vm.dismissReport()
        #expect(vm.phase == .completed)
        let root2 = try #require(vm.root)
        #expect(!root2.children.contains { $0.name == "d1" })
    }
}
