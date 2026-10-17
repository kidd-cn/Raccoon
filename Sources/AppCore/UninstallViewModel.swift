import Foundation
import Observation
import CleanKit
import UninstallKit
import os

@MainActor
@Observable
public final class UninstallViewModel {
    public enum Phase: Equatable { case discovering, list, failed(String) }
    public enum OrphanPhase: Equatable { case idle, scanning, results }
    public enum CleanState: Equatable { case cleaning, report(CleanReport) }
    public enum CleanFlow: String, Equatable, Sendable, Identifiable {
        case apps, orphans
        public var id: String { rawValue }
    }
    public enum Tab: String, CaseIterable, Identifiable {
        case apps, orphans
        public var id: String { rawValue }
    }

    public private(set) var phase: Phase = .discovering
    public private(set) var apps: [InstalledApp] = []
    public private(set) var unreadableCount = 0
    public private(set) var discoveryProgress = AppDiscoveryProgress(enumeratedCount: 0)
    public var searchText = ""
    public var detailAppID: String?
    public var tab: Tab = .apps

    public private(set) var leftovers: [AppLeftover] = []
    public var selectedLeftoverPaths: Set<String> = []

    public private(set) var orphanPhase: OrphanPhase = .idle
    public private(set) var orphans: [AppLeftover] = []
    public var selectedOrphanPaths: Set<String> = []
    public private(set) var orphanProgress = OrphanScanProgress(completedLocations: 0, totalLocations: 0)
    public private(set) var failedLocationIDs: Set<String> = []

    public private(set) var cleanState: CleanState?
    public private(set) var cleanFlow: CleanFlow?
    public private(set) var cleanProgress = CleanProgress(done: 0, total: 0)
    public private(set) var lastCleanup: CleanReport?
    public var confirmFlow: CleanFlow?

    public let exclusions: ExclusionsStore
    public let history: HistoryStoring
    public let trash: TrashServicing
    let discovery: AppDiscovering
    let locator: LeftoverLocating
    let orphanScanner: OrphanScanning
    let scope: LeftoverScope

    var discoveryTask: Task<Void, Never>?
    var leftoverTask: Task<Void, Never>?
    var orphanTask: Task<Void, Never>?
    var cleanTask: Task<Void, Never>?
    private var hasDiscovered = false
    private var orphanScanGeneration = 0

    public init(discovery: AppDiscovering, locator: LeftoverLocating, orphanScanner: OrphanScanning,
                exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService(),
                home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.discovery = discovery
        self.locator = locator
        self.orphanScanner = orphanScanner
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
        self.scope = LeftoverScope(home: home)
    }

    // MARK: - 发现

    public func startDiscovery(force: Bool = false) {
        if !force { guard !hasDiscovered else { return } }
        guard discoveryTask == nil else { return }
        hasDiscovered = true
        phase = .discovering
        apps = []; unreadableCount = 0
        detailAppID = nil; leftovers = []; selectedLeftoverPaths = []
        discoveryProgress = AppDiscoveryProgress(enumeratedCount: 0)
        let exclusionsSnapshot = exclusions.exclusions
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.discoveryTask = nil }
            do {
                let result = try await self.discovery.discover(exclusions: exclusionsSnapshot) { [weak self] p in
                    Task { @MainActor [weak self] in self?.discoveryProgress = p }
                }
                guard !Task.isCancelled else {
                    self.hasDiscovered = false
                    self.phase = .list
                    return
                }
                self.apps = result.apps
                self.unreadableCount = result.unreadableCount
                self.phase = .list
            } catch is CancellationError {
                self.hasDiscovered = false
                self.phase = .list
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    public var filteredApps: [InstalledApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    public var focusedApp: InstalledApp? {
        guard let detailAppID else { return nil }
        return apps.first { $0.bundleID == detailAppID }
    }

    // MARK: - 详情与勾选

    public func openDetail(_ app: InstalledApp) {
        detailAppID = app.bundleID
        leftovers = []
        selectedLeftoverPaths = []
        leftoverTask?.cancel()
        let exclusionsSnapshot = exclusions.exclusions
        leftoverTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.locator.leftovers(for: app, exclusions: exclusionsSnapshot)
            guard !Task.isCancelled else { return }
            self.leftovers = items
            self.selectedLeftoverPaths = Set(items
                .filter { $0.ownership == .bundleID && $0.safety == .regenerable }
                .map(\.path))
        }
    }

    public var selectedLeftoverItems: [AppLeftover] {
        leftovers.filter { selectedLeftoverPaths.contains($0.path) }
    }

    public func toggleLeftover(_ path: String) {
        if selectedLeftoverPaths.contains(path) { selectedLeftoverPaths.remove(path) }
        else { selectedLeftoverPaths.insert(path) }
    }

    public func selectAllLeftovers() { selectedLeftoverPaths = Set(leftovers.map(\.path)) }
    public func selectNoneLeftovers() { selectedLeftoverPaths = [] }

    /// 卸载提交口径:本体固定 + 已勾选且通过作用域白名单的关联数据。
    public var uninstallItems: [CleanItem] {
        guard let app = focusedApp else { return [] }
        let chosen = selectedLeftoverItems
            .filter { scope.isAllowed($0.path) }
            .map { CleanItem(path: $0.path, sizeBytes: $0.sizeBytes) }
        return [CleanItem(path: app.appPath, sizeBytes: app.sizeBytes)] + chosen
    }

    public var uninstallBytes: Int64 { uninstallItems.reduce(Int64(0)) { $0 + $1.sizeBytes } }

    // MARK: - 卸载执行

    public func requestUninstall() {
        guard cleanState == nil, !uninstallItems.isEmpty else { return }
        confirmFlow = .apps
    }

    public func cancelConfirm() { confirmFlow = nil }

    public func uninstall() {
        guard cleanState == nil else { return }
        guard confirmFlow == .apps else { return }
        let items = uninstallItems
        guard !items.isEmpty else { return }
        runClean(items, flow: .apps)
    }

    private func runClean(_ items: [CleanItem], flow: CleanFlow) {
        guard cleanState == nil else { return }
        confirmFlow = nil
        cleanState = .cleaning
        cleanFlow = flow
        cleanProgress = CleanProgress(done: 0, total: items.count)
        // 清理时重建保护层(取此刻最新排除清单),与扫描/定位处的实例有意分离,语义须一致
        let protection = ProtectionStore(userExclusions: exclusions.exclusions)
        let executor = CleanExecutor(trash: trash, protection: protection)
        cleanTask = Task { [weak self, history] in
            guard let self else { return }
            let report = await executor.clean(items) { [weak self] done, total in
                Task { @MainActor [weak self] in
                    self?.cleanProgress = CleanProgress(done: done, total: total)
                }
            }
            do { try history.append(report) }
            catch {
                Logger(subsystem: "com.raccooncleaner.Raccoon", category: "history")
                    .error("history append failed: \(String(describing: error))")
            }
            self.applyCleanOutcome(report, submitted: items, flow: flow)
        }
    }

    /// 与一期同名口径:已清理 = 提交路径 − skipped 路径;跳过项仍在磁盘,必须留在清单里。
    private func applyCleanOutcome(_ report: CleanReport, submitted: [CleanItem], flow: CleanFlow) {
        let gone = Set(submitted.map(\.path)).subtracting(report.skipped.map(\.path))
        switch flow {
        case .apps:
            if let app = focusedApp, gone.contains(app.appPath) {
                apps.removeAll { $0.bundleID == app.bundleID }
                detailAppID = nil
            }
            // 本体是否已清理都只按 gone 差集收敛:未勾选的 userData 与已提交但 skipped
            // 的关联数据仍在磁盘,必须留在剩余项里(已清理项移出、跳过项保留)。
            leftovers.removeAll { gone.contains($0.path) }
            selectedLeftoverPaths.subtract(gone)
        case .orphans:
            orphans.removeAll { gone.contains($0.path) }
            selectedOrphanPaths.subtract(gone)
        }
        loadLastCleanup()
        cleanState = .report(report)
    }

    public func returnFromReport() {
        guard case .report = cleanState else { return }
        cleanState = nil
        if cleanFlow == .apps { detailAppID = nil }
    }

    // MARK: - 孤儿残留

    public var selectedOrphanItems: [AppLeftover] {
        orphans.filter { selectedOrphanPaths.contains($0.path) }
    }

    public func toggleOrphan(_ path: String) {
        if selectedOrphanPaths.contains(path) { selectedOrphanPaths.remove(path) }
        else { selectedOrphanPaths.insert(path) }
    }

    public func selectAllOrphans() { selectedOrphanPaths = Set(orphans.map(\.path)) }
    public func selectNoneOrphans() { selectedOrphanPaths = [] }

    public func scanOrphans() {
        // 发现未完成时 apps 为空,已安装应用的可再生残留会被误判为孤儿并默认勾选;
        // .list 是发现完成后的稳定态(详情态与列表态并存,不影响该判定)。
        guard phase == .list, cleanState == nil, orphanPhase != .scanning else { return }
        orphanScanGeneration &+= 1
        let gen = orphanScanGeneration
        orphanPhase = .scanning
        orphans = []; selectedOrphanPaths = []; failedLocationIDs = []
        orphanProgress = OrphanScanProgress(completedLocations: 0,
                                            totalLocations: LeftoverLocations.all.count)
        let ids = Set(apps.map(\.bundleID))
        let names = Set(apps.map(\.name))
        let exclusionsSnapshot = exclusions.exclusions
        orphanTask = Task { [weak self] in
            guard let self else { return }
            defer { self.orphanTask = nil }
            let result = await self.orphanScanner.scan(
                installedBundleIDs: ids,
                installedAppNames: names,
                exclusions: exclusionsSnapshot
            ) { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self, gen == self.orphanScanGeneration else { return }
                    self.orphanProgress = p
                }
            }
            // 取消或新一轮扫描都会推进代数:旧任务的结果与进度一律丢弃。
            guard gen == self.orphanScanGeneration, !Task.isCancelled else { return }
            self.orphans = result.orphans.sorted { $0.sizeBytes > $1.sizeBytes }
            self.selectedOrphanPaths = Set(self.orphans
                .filter { $0.ownership == .bundleID && $0.safety == .regenerable }
                .map(\.path))
            self.failedLocationIDs = result.failedLocationIDs
            self.orphanPhase = .results
        }
    }

    public func cancelOrphanScan() {
        guard orphanPhase == .scanning else { return }
        orphanScanGeneration &+= 1
        orphanTask?.cancel()
        orphanPhase = .idle
    }

    public func requestCleanOrphans() {
        guard cleanState == nil, !orphanCleanItems.isEmpty else { return }
        confirmFlow = .orphans
    }

    public func cleanOrphans() {
        guard cleanState == nil, confirmFlow == .orphans else { return }
        let items = orphanCleanItems
        guard !items.isEmpty else { return }
        runClean(items, flow: .orphans)
    }

    private var orphanCleanItems: [CleanItem] {
        selectedOrphanItems
            .filter { scope.isAllowed($0.path) }
            .map { CleanItem(path: $0.path, sizeBytes: $0.sizeBytes) }
    }

    public var remainingBytes: Int64 {
        if cleanFlow == .apps {
            return leftovers.reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        if cleanFlow == .orphans {
            return orphans.reduce(Int64(0)) { $0 + $1.sizeBytes }
        }
        return 0
    }

    public var remainingCount: Int {
        if cleanFlow == .apps { return leftovers.count }
        if cleanFlow == .orphans { return orphans.count }
        return 0
    }

    public func loadLastCleanup() {
        lastCleanup = (try? history.loadAll())?.max { $0.date < $1.date }
    }
}
