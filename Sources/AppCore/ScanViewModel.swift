import Foundation
import Observation
import ScanKit
import CleanKit
import os

@MainActor
@Observable
public final class ScanViewModel {
    public enum Phase: Equatable {
        case idle, scanning, completed, cleaning
        case report(CleanReport)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var hits: [ScanHit] = []
    public private(set) var summaries: [CategorySummary] = []
    public private(set) var progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
    public private(set) var permissionSkippedCount = 0
    public private(set) var truncatedRuleIDs: Set<String> = []
    public private(set) var excludedCount = 0
    public private(set) var lastCleanup: CleanReport?

    public var selectedPaths: Set<String> = []
    public var categoryInFocus: RuleCategory?
    public var confirmPresented = false

    public let service: ScanServicing
    public let exclusions: ExclusionsStore
    public let history: HistoryStoring
    // 废纸篓服务可注入:生产用默认真实服务;测试注入 Mock,保证测试绝不触碰真实文件系统
    // (否则硬编码真实服务会对不存在的 /a 真调 trashItem → .vanished → trashedCount 断言必红)
    public let trash: TrashServicing

    // 供测试等待(内部可见)
    var task: Task<Void, Never>?
    var cleanTask: Task<Void, Never>?

    public init(service: ScanServicing, exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService()) {
        self.service = service
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
    }

    public func startScan() {
        guard phase != .scanning && phase != .cleaning else { return }
        phase = .scanning
        hits = []; summaries = []; selectedPaths = []; categoryInFocus = nil
        permissionSkippedCount = 0; truncatedRuleIDs = []; excludedCount = 0
        progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
        task = Task { [weak self] in await self?.runScan() }
    }

    private func runScan() async {
        do {
            let result = try await service.scan(exclusions: exclusions.exclusions) { [weak self] p in
                Task { @MainActor [weak self] in self?.progress = p }
            }
            hits = result.hits.sorted { $0.sizeBytes > $1.sizeBytes }
            summaries = result.summaries
            permissionSkippedCount = result.permissionSkippedCount
            truncatedRuleIDs = result.truncatedRuleIDs
            excludedCount = result.excludedCount
            selectedPaths = Set(hits.filter { $0.safety == .safe && !$0.isAppRunning }.map(\.path))
            phase = .completed
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    public func cancelScan() { task?.cancel() }

    public var selectedItems: [ScanHit] { hits.filter { selectedPaths.contains($0.path) } }
    public var selectedBytes: Int64 { selectedItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    // 本类口径:与工具栏 selectAll/selectNone(in:) 同范围,供明细页底栏主数字。
    // 全局口径(上方 selectedItems/selectedBytes)服务清理动作——清理始终作用于全部已选,
    // 两口径在底栏并列展示,勿互相替代(否则底栏与工具栏范围不一致,用户读到的是别类的量)。
    public func selectedItems(in category: RuleCategory) -> [ScanHit] {
        selectedItems.filter { $0.category == category }
    }
    public func selectedCount(in category: RuleCategory) -> Int { selectedItems(in: category).count }
    public func selectedBytes(in category: RuleCategory) -> Int64 {
        selectedItems(in: category).reduce(Int64(0)) { $0 + $1.sizeBytes }
    }

    public func toggle(_ path: String) {
        if selectedPaths.contains(path) { selectedPaths.remove(path) } else { selectedPaths.insert(path) }
    }

    public func selectAll(in category: RuleCategory?) {
        for h in hits where category == nil || h.category == category { selectedPaths.insert(h.path) }
    }

    public func selectNone(in category: RuleCategory?) {
        for h in hits where category == nil || h.category == category { selectedPaths.remove(h.path) }
    }

    public func uncheckCautiousAndRunning() {
        for h in hits where h.safety == .cautious || h.isAppRunning { selectedPaths.remove(h.path) }
    }

    public func cleanSelected() {
        guard phase == .completed else { return }   // 状态机不变量:仅 completed 态可发起清理,防 .cleaning/.report 重入
        let items = selectedItems.map(\.cleanItem)
        guard !items.isEmpty else { return }
        phase = .cleaning
        confirmPresented = false
        // 清理时重建保护层(取此刻最新排除清单)——与扫描时的实例有意分离,两处语义须一致
        let protection = ProtectionStore(userExclusions: exclusions.exclusions)
        let executor = CleanExecutor(trash: trash, protection: protection)
        cleanTask = Task { [weak self, history] in
            // Task 创建于 @MainActor 方法,闭包继承主 actor 隔离:此处的 phase/history 均在主线程触达
            let report = await executor.clean(items)
            do { try history.append(report) }
            catch {
                Logger(subsystem: "com.raccooncleaner.Raccoon", category: "history")
                    .error("history append failed: \(String(describing: error))")
            }
            self?.phase = .report(report)
        }
    }

    public func loadLastCleanup() {
        lastCleanup = (try? history.loadAll())?.max { $0.date < $1.date }
    }

    public func dismissReport() {
        phase = .idle
        hits = []; summaries = []; selectedPaths = []; categoryInFocus = nil
        permissionSkippedCount = 0; truncatedRuleIDs = []; excludedCount = 0
        progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
    }
}
