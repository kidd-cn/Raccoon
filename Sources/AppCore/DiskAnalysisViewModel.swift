import Foundation
import Observation
import DiskKit
import CleanKit

/// 磁盘分析列表的一行:树节点本身,或尾部聚合的「其余 N 项」。
public struct DisplayRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case item(DiskNode)
        case others(count: Int, bytes: Int64)   // 聚合行
    }
    public let id: String          // item → node.path;others → "__others__"
    public let kind: Kind
    public init(id: String, kind: Kind) { self.id = id; self.kind = kind }
}

@MainActor
@Observable
public final class DiskAnalysisViewModel {
    public enum Phase: Equatable { case idle, scanning, completed, cleaning, report(CleanReport), failed(String) }

    public private(set) var phase: Phase = .idle
    public private(set) var root: DiskNode?
    public private(set) var progress: DiskScanProgress?
    public private(set) var cleanProgress = CleanProgress(done: 0, total: 0)
    public private(set) var lastCleanup: CleanReport?
    public var selectedPaths: Set<String> = []
    public var confirmPresented = false
    public private(set) var drillPath: [DiskNode] = []     // [0] = root;面包屑
    public let scanner: DiskScanner
    public let exclusions: ExclusionsStore
    public let history: HistoryStoring
    public let trash: TrashServicing

    // 供测试等待(内部可见)
    var task: Task<Void, Never>?

    public init(scanner: DiskScanner, exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService()) {
        self.scanner = scanner
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
    }

    public func startScan(rootPath: String = NSHomeDirectory()) {
        guard phase != .scanning && phase != .cleaning else { return }
        phase = .scanning
        root = nil; progress = nil; selectedPaths = []; drillPath = []
        confirmPresented = false
        // 先标准化路径(展开 ~、去 ..、去尾斜杠);相对路径保持相对,交给扫描器判 invalidRoot。
        let normalized = ProtectionStore.normalize(rootPath)
        task = Task { [weak self] in await self?.runScan(rootPath: normalized) }
    }

    private func runScan(rootPath: String) async {
        do {
            let node = try await scanner.scan(root: rootPath) { [weak self] p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            root = node
            drillPath = [node]
            phase = .completed
        } catch is CancellationError {
            root = nil; progress = nil; drillPath = []
            phase = .idle
        } catch {
            root = nil; progress = nil; drillPath = []
            phase = .failed(error.localizedDescription)
        }
    }

    public func cancelScan() { task?.cancel() }

    public func drill(into node: DiskNode) {
        guard node.isDirectory else { return }
        drillPath.append(node)
    }

    public func drillTo(depth: Int) {
        guard depth >= 0, depth < drillPath.count else { return }
        drillPath = Array(drillPath.prefix(depth + 1))
    }

    public var canSelectRoot: Bool { false }

    /// 勾选门禁:根不可选;containsProtected 节点不可选。
    private func canSelect(_ node: DiskNode) -> Bool {
        node.path != root?.path && !node.containsProtected
    }

    public func toggle(_ path: String) {
        guard let root else { return }
        guard path != root.path else { return }
        guard let node = findNode(path, in: root), canSelect(node) else { return }

        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
            return
        }
        // 已有祖先被勾选 → no-op
        guard !hasSelectedAncestor(path) else { return }
        selectedPaths.insert(path)
        if node.isDirectory {
            // 勾选目录时移除其所有子孙路径
            selectedPaths.subtract(descendantPaths(of: node))
        }
    }

    public var currentChildren: [DiskNode] {
        (drillPath.last?.children ?? []).sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 聚合规则:子项降序;最多 120 个 item 行;其余(含低于父级总量 0.3% 的尾部小项)
    /// 收进末尾一行 others;若 others 只剩 1 项则取消聚合,该 1 项照常作为 item 行。
    public var displayRows: [DisplayRow] {
        let maxCount = 120
        let minFraction = 0.003
        guard let parent = drillPath.last else { return [] }
        let children = parent.children.sorted { $0.sizeBytes > $1.sizeBytes }
        guard !children.isEmpty else { return [] }
        let total = children.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let threshold = Double(total) * minFraction

        var kept: [DiskNode] = []
        var others: [DiskNode] = []
        for (index, child) in children.enumerated() {
            let belowMin = Double(child.sizeBytes) < threshold
            if index < maxCount && !belowMin {
                kept.append(child)
            } else {
                others.append(child)
            }
        }
        if others.count == 1 {
            kept.append(others[0])
            others = []
        }

        var rows = kept.map { DisplayRow(id: $0.path, kind: .item($0)) }
        if !others.isEmpty {
            let bytes = others.reduce(Int64(0)) { $0 + $1.sizeBytes }
            rows.append(DisplayRow(id: "__others__", kind: .others(count: others.count, bytes: bytes)))
        }
        return rows
    }

    /// 树内被勾选的最上层节点,深度优先序。
    public var selectedNodes: [DiskNode] {
        guard let root else { return [] }
        var result: [DiskNode] = []
        func visit(_ node: DiskNode) {
            if selectedPaths.contains(node.path) {
                result.append(node)
                return   // 勾选的是最上层:不再深入其子孙
            }
            for child in node.children { visit(child) }
        }
        visit(root)
        return result
    }

    public var selectedBytes: Int64 { selectedNodes.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    /// 存活树除根外节点数。
    public var remainingCount: Int {
        guard let root else { return 0 }
        func count(_ node: DiskNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
        return count(root) - 1
    }

    /// 存活树除根外体量合计(目录体量口径 = 子树文件之和,故即根体量)。
    public var remainingBytes: Int64 { root?.sizeBytes ?? 0 }

    public func loadLastCleanup() {
        lastCleanup = (try? history.loadAll())?.max { $0.date < $1.date }
    }

    // MARK: - 清理编排

    /// 以 selectedNodes(最上层)构造清理项,经 CleanExecutor 逐项进废纸篓;完成后就地更新树并写入历史。
    public func cleanSelected() {
        guard phase == .completed, root != nil else { return }
        let items = selectedNodes.map { CleanItem(path: $0.path, sizeBytes: $0.sizeBytes, action: .trash) }
        guard !items.isEmpty else { return }
        phase = .cleaning
        cleanProgress = CleanProgress(done: 0, total: items.count)
        // 与卸载页同构:清理时取扫描器同款保护层,删除引擎仍做最后一道 isDenied 兜底。
        let executor = CleanExecutor(trash: trash, protection: scanner.protection)
        task = Task { [weak self] in
            await self?.runClean(items: items, executor: executor)
        }
    }

    private func runClean(items: [CleanItem], executor: CleanExecutor) async {
        let report = await executor.clean(items, onProgress: { [weak self] done, total in
            Task { @MainActor [weak self] in
                self?.cleanProgress = CleanProgress(done: done, total: total)
            }
        }, source: "disk-analysis")
        applyCleanOutcome(report, submitted: items)
        try? history.append(report)
        lastCleanup = report
        phase = .report(report)
    }

    /// 清理后就地更新树:trashed/vanished(非 skipped)节点移除、体量差值上溯全部祖先;
    /// skipped 节点保留且保持勾选;selectedPaths 收敛到存活节点。
    private func applyCleanOutcome(_ report: CleanReport, submitted: [CleanItem]) {
        let gone = Set(submitted.map(\.path)).subtracting(report.skipped.map(\.path))
        if let current = root {
            root = removeGone(from: current, gone: gone)
        }
        if let newRoot = root {
            selectedPaths = selectedPaths.filter { findNode($0, in: newRoot) != nil }
        } else {
            selectedPaths = []
        }
    }

    /// 从报告页回到结果页,保留更新后的树。
    public func returnToResults() {
        guard case .report = phase else { return }
        pruneDrillPath()
        phase = .completed
    }

    /// 关闭报告,同样回到结果页;若当前下钻末节点已被删除,回退到最近的存活祖先。
    public func dismissReport() {
        guard case .report = phase else { return }
        pruneDrillPath()
        phase = .completed
    }

    // MARK: - 私有帮手

    private func findNode(_ path: String, in node: DiskNode) -> DiskNode? {
        if node.path == path { return node }
        for child in node.children {
            if let found = findNode(path, in: child) { return found }
        }
        return nil
    }

    private func hasSelectedAncestor(_ path: String) -> Bool {
        selectedPaths.contains { ancestor in
            ancestor != path && path.hasPrefix(ancestor + "/")
        }
    }

    private func descendantPaths(of node: DiskNode) -> Set<String> {
        var result = Set<String>()
        for child in node.children {
            result.insert(child.path)
            result.formUnion(descendantPaths(of: child))
        }
        return result
    }

    /// 移除 gone 路径对应的节点;返回 nil 表示该节点自身被移除。
    /// 目录体量 = 存活子节点体量之和,差值随递归自然上溯至全部祖先。
    private func removeGone(from node: DiskNode, gone: Set<String>) -> DiskNode? {
        if gone.contains(node.path) { return nil }
        guard !node.children.isEmpty else { return node }
        let kept = node.children.compactMap { removeGone(from: $0, gone: gone) }
        let newSize = kept.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let containsProtected = scanner.protection.isDenied(node.path)
            || kept.contains(where: \.containsProtected)
        return DiskNode(path: node.path, name: node.name, sizeBytes: newSize,
                        isDirectory: node.isDirectory, children: kept,
                        isDeniedTruncated: node.isDeniedTruncated,
                        containsProtected: containsProtected)
    }

    /// 面包屑回退:保留自根起的存活前缀,遇首个被删节点即止(其子孙一并消失)。
    private func pruneDrillPath() {
        guard let newRoot = root else { drillPath = []; return }
        var pruned: [DiskNode] = []
        for node in drillPath {
            if let alive = findNode(node.path, in: newRoot) {
                pruned.append(alive)
            } else {
                break
            }
        }
        drillPath = pruned.isEmpty ? [newRoot] : pruned
    }
}
