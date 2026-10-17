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
    public private(set) var cleanProgress = CleanProgress(done: 0, total: 0)
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
    // 类别过滤:主清理页 = 全集去 .ai,AI 页 = [.ai];nil = 不过滤(测试与回归用)。
    // 两页共用同一引擎,凭此参数互不相混——AI 条目与 AI 类别卡片在主页面绝口不提,反之亦然;
    // Task 5 接线两页(接线落地前 RootView 仍传 nil)。
    public let categoryFilter: Set<RuleCategory>?

    // 供测试等待(内部可见)
    var task: Task<Void, Never>?
    var cleanTask: Task<Void, Never>?

    public init(service: ScanServicing, exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService(),
                categoryFilter: Set<RuleCategory>? = nil) {
        self.service = service
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
        self.categoryFilter = categoryFilter
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
            // 按页过滤后重算汇总而非截 result.summaries:与 applyCleanOutcome 的重算同源同口径
            // (CategorySummary.aggregate);filter 为 nil 时与引擎输出等价。
            let filtered = categoryFilter.map { f in result.hits.filter { f.contains($0.category) } } ?? result.hits
            hits = filtered.sorted { $0.sizeBytes > $1.sizeBytes }
            summaries = CategorySummary.aggregate(hits)
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
    /// 清理后仍在列表里的条目合计(未清理 + 被跳过):报告页据此告知「还有 N 项未清理」,
    /// 与 freedBytes(已清理)相对,两数相加即清理前的全量。
    public var remainingBytes: Int64 { hits.reduce(Int64(0)) { $0 + $1.sizeBytes } }

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
        cleanProgress = CleanProgress(done: 0, total: items.count)
        confirmPresented = false
        // 明细页即刻让位(item 导航由绑定驱动,不复位则明细页一直留在栈上,清理完成后
        // 用户仍盯着旧列表——所见正是已进废纸篓的条目与旧字节数):用户报障「执行清理后
        // 状态不更新」。与 startScan/dismissReport 同源复位,见 CleanupHomeView 导航契约注释。
        categoryInFocus = nil
        // 清理时重建保护层(取此刻最新排除清单)——与扫描时的实例有意分离,两处语义须一致
        let protection = ProtectionStore(userExclusions: exclusions.exclusions)
        let executor = CleanExecutor(trash: trash, protection: protection)
        cleanTask = Task { [weak self, history] in
            // Task 创建于 @MainActor 方法,闭包继承主 actor 隔离:此处的 phase/history 均在主线程触达
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
            self.applyCleanOutcome(report, submittedPaths: items.map(\.path))
        }
    }

    /// 清理后置:让 in-memory 状态与磁盘事实一致。
    /// 每个提交项的结果恰为「入废纸篓 / 已被应用删除 / 快照已清 / 被跳过」四者之一,
    /// 故「提交过且未进 skipped」即已不在磁盘上,须同时离开 hits、类别汇总与选择集——
    /// 否则明细页仍列出刚清理的文件、底栏仍报旧字节(用户报障:清理后状态不更新)。
    /// 反向同理:skipped 项(受保护、无权限、快照失败)仍在磁盘上,必须留在列表里可再次处理。
    private func applyCleanOutcome(_ report: CleanReport, submittedPaths: [String]) {
        let gone = Set(submittedPaths).subtracting(report.skipped.map(\.path))
        if !gone.isEmpty {
            hits.removeAll { gone.contains($0.path) }
            // selectedPaths 只做差集,不重建:勾选状态属用户意志,清理不该顺手改它
            selectedPaths.subtract(gone)
            summaries = CategorySummary.aggregate(hits)
        }
        loadLastCleanup()   // 主页「上次清理释放 X」即刻反映本次结果,不必等重启
        phase = .report(report)
    }

    public func loadLastCleanup() {
        lastCleanup = (try? history.loadAll())?.max { $0.date < $1.date }
    }

    /// 报告态返回结果列表(保留清理后的 hits/summaries/选择集)。
    /// 部分清理后剩余项仍在 hits 里,不应强迫用户重扫才能接着清;报告页据此提供主入口。
    /// 仅报告态可达:idle/scanning/completed 下已是或即将是结果列表本身,调用无意义。
    public func returnToResults() {
        guard case .report = phase else { return }
        categoryInFocus = nil      // 防残留(同 startScan/dismissReport/cleanSelected,见 CleanupHomeView 导航契约)
        phase = .completed
    }

    public func dismissReport() {
        phase = .idle
        hits = []; summaries = []; selectedPaths = []; categoryInFocus = nil
        permissionSkippedCount = 0; truncatedRuleIDs = []; excludedCount = 0
        progress = ScanProgress(rulesDone: 0, rulesTotal: 0, hitsFound: 0, bytesFound: 0)
    }
}
