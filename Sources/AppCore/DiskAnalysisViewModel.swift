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
}
