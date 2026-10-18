import Testing
import Foundation
import CleanKit
import LaunchKit
@testable import AppCore

/// 假体 trash:把文件移到测试自建的 trash 目录(绝不真删),从而让 disable 后的重扫
/// 观察到条目消失;同时记录调用路径,供「受保护项零触达」断言。
private actor MovingTrash: TrashServicing {
    let trashDirectory: String
    private(set) var calls: [String] = []

    init(trashDirectory: String) { self.trashDirectory = trashDirectory }

    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        let dest = (trashDirectory as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        try? FileManager.default.createDirectory(atPath: trashDirectory, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(atPath: path, toPath: dest)
        return .trashed
    }
}

/// 可控闸门 trash:第一次触达后挂起,直到测试显式 open——用于验证 in-flight 重入守卫。
private actor GatedLaunchTrash: TrashServicing {
    private(set) var calls: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        if !isOpen {
            await withCheckedContinuation { waiters.append($0) }
        }
        return .trashed
    }
}

@Suite @MainActor
final class LaunchItemsViewModelTests {
    let root: URL
    let userDir: URL
    let systemDir: URL
    let trashDir: URL
    let defaultsSuite: String
    let exclusions: ExclusionsStore
    let history: JSONHistoryStore

    init() {
        root = URL(fileURLWithPath: NSTemporaryDirectory() + "raccoon-livm-\(UUID().uuidString)")
        userDir = root.appendingPathComponent("user")
        systemDir = root.appendingPathComponent("system")
        trashDir = root.appendingPathComponent("trash")
        defaultsSuite = "livm-\(UUID().uuidString)"
        exclusions = ExclusionsStore(defaults: UserDefaults(suiteName: defaultsSuite)!)
        history = JSONHistoryStore(directory: root.appendingPathComponent("history"))
    }

    deinit {
        // 夹具清理是 removeItem 的唯一测试例外:仅清自建临时目录。
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
    }

    /// 写入最小合法 plist(Label 可选,缺失用于验证「无 Label」展示字段)。
    @discardableResult
    private func writePlist(into dir: URL, name: String, label: String?) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let labelXML = label.map { "<key>Label</key><string>\($0)</string>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>\(labelXML)<key>RunAtLoad</key><true/></dict></plist>
        """
        try Data(xml.utf8).write(to: url)
        return url
    }

    private func makeVM(hardRoots: [String] = [],
                        trash: TrashServicing? = nil) -> LaunchItemsViewModel {
        let store = LaunchItemStore(
            trash: trash ?? MovingTrash(trashDirectory: trashDir.path),
            protection: ProtectionStore(hardRoots: hardRoots,
                                        userExclusions: exclusions.exclusions))
        let scanner = LaunchItemScanner(userAgentsDirectory: userDir.path,
                                        systemDirectories: [systemDir.path])
        return LaunchItemsViewModel(scanner: scanner, store: store,
                                    exclusions: exclusions, history: history)
    }

    // MARK: - 用例

    @Test func loadFillsUserAndSystemLists() async throws {
        try writePlist(into: userDir, name: "broken-label.plist", label: nil)
        try writePlist(into: userDir, name: "com.test.alpha.plist", label: "com.test.alpha")
        try writePlist(into: systemDir, name: "com.sys.daemon.plist", label: "com.sys.daemon")
        let vm = makeVM()

        await vm.load()

        #expect(vm.userRows.map(\.item.fileName) == ["broken-label.plist", "com.test.alpha.plist"])
        #expect(vm.userRows[0].item.label == nil)
        #expect(vm.userRows[1].item.label == "com.test.alpha")
        #expect(vm.userRows.allSatisfy { !$0.denied })
        #expect(vm.systemItems.map(\.fileName) == ["com.sys.daemon.plist"])
    }

    @Test func deniedRowDisableIsNoOp() async throws {
        let path = try writePlist(into: userDir, name: "com.test.hard.plist",
                                  label: "com.test.hard").path
        let trash = MovingTrash(trashDirectory: trashDir.path)
        let vm = makeVM(hardRoots: [userDir.path], trash: trash)
        await vm.load()
        let row = try #require(vm.userRows.first)
        #expect(row.denied)

        await vm.disable(row)

        let calls = await trash.calls
        #expect(calls.isEmpty)
        #expect(vm.lastReport == nil)
        // 文件仍在原处(毫无副作用)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test func normalDisableRemovesRowAndRecordsHistory() async throws {
        let path = try writePlist(into: userDir, name: "com.test.normal.plist",
                                  label: "com.test.normal").path
        let trash = MovingTrash(trashDirectory: trashDir.path)
        let vm = makeVM(trash: trash)
        await vm.load()
        let row = try #require(vm.userRows.first)

        await vm.disable(row)

        let calls = await trash.calls
        #expect(calls == [path])
        #expect(vm.userRows.isEmpty)
        let report = try #require(vm.lastReport)
        #expect(report.source == "launch-items")
        #expect(report.trashedCount == 1)
        let stored = try history.loadAll()
        #expect(stored.count == 1)
        #expect(stored.first?.source == "launch-items")
    }

    @Test func excludeMarksRowDenied() async throws {
        let path = try writePlist(into: userDir, name: "com.test.exclude.plist",
                                  label: "com.test.exclude").path
        let vm = makeVM()
        await vm.load()
        let row = try #require(vm.userRows.first)
        #expect(!row.denied)

        vm.exclude(row)

        #expect(vm.userRows.first?.denied == true)
        #expect(exclusions.exclusions == [path])
    }

    /// in-flight 守卫:第一次禁用挂在假体上时,第二次调用必须直接返回、不再触达假体。
    @Test func reentrantDisableIsIgnoredWhileOneInFlight() async throws {
        try writePlist(into: userDir, name: "com.test.gated.plist", label: "com.test.gated")
        let trash = GatedLaunchTrash()
        let vm = makeVM(trash: trash)
        await vm.load()
        let row = try #require(vm.userRows.first)

        let first = Task { await vm.disable(row) }
        // 等第一次调用进入假体(此后它会挂在闸门上)
        while await trash.calls.isEmpty {
            await Task.yield()
        }
        #expect(vm.isDisabling)

        await vm.disable(row)          // 重入:必须 no-op
        let during = await trash.calls
        #expect(during.count == 1)

        await trash.open()
        await first.value
        let after = await trash.calls
        #expect(after.count == 1)
        #expect(!vm.isDisabling)
    }

    /// 实时排除:init 之后新增的排除必须对后续 load 与 disable 门禁同时生效
    /// (注入 store 的 ProtectionStore 是构造期快照,VM 不得直接复用该快照)。
    @Test func loadAndDisableUseLiveExclusionsAddedAfterInit() async throws {
        let path = try writePlist(into: userDir, name: "com.test.live.plist",
                                  label: "com.test.live").path
        let trash = MovingTrash(trashDirectory: trashDir.path)
        let vm = makeVM(trash: trash)
        exclusions.add(path)          // init 之后的排除

        await vm.load()
        let row = try #require(vm.userRows.first)
        #expect(row.denied)

        // 即便拿一条 denied 快照为 false 的旧行,实时 protection 仍须拦截触达。
        let stale = LaunchItemsViewModel.Row(item: row.item, denied: false)
        await vm.disable(stale)

        let calls = await trash.calls
        #expect(calls.isEmpty)
        #expect(vm.lastReport == nil)
    }
}
