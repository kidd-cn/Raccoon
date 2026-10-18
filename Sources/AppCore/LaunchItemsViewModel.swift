import Foundation
import Observation
import CleanKit
import LaunchKit

/// 启动项管理页的状态机:扫描结果、保护门判定、禁用编排与排除登记。
///
/// **实时排除**:注入的 `LaunchItemStore` 在其构造时把 `ProtectionStore` 快照进值里,
/// 之后 `ExclusionsStore.add` 新增的排除对它不可见。因此这里每次 `load()`/判定/`disable()`
/// 都用「store 的基础 hardRoots + exclusions 当前值」重建 ProtectionStore 与 store
/// (与 DiskAnalysisViewModel.effectiveProtection 同口径)。选这个方案而不是额外收一个
/// hardRoots 参数:hardRoots 只有一份来源(注入 store),不会出现两处配置漂移。
@MainActor
@Observable
public final class LaunchItemsViewModel {
    /// 用户级列表一行:条目快照 + 当前保护门判定(UI 只读,避免每帧重算)。
    public struct Row: Equatable, Identifiable, Sendable {
        public let item: LaunchItem
        public let denied: Bool
        public var id: String { item.id }

        public init(item: LaunchItem, denied: Bool) {
            self.item = item
            self.denied = denied
        }
    }

    public private(set) var userRows: [Row] = []
    public private(set) var systemItems: [LaunchItem] = []
    /// 最近一次成功移入废纸篓的报告;展示后由 dismissReport() 清空。
    public private(set) var lastReport: CleanReport?
    /// 最近一次禁用失败原因(成功或未操作时为 nil),供页面给出最低限度反馈。
    public private(set) var lastError: String?

    private let scanner: LaunchItemScanner
    private let store: LaunchItemStore
    private let exclusions: ExclusionsStore
    private let history: HistoryStoring

    public init(scanner: LaunchItemScanner, store: LaunchItemStore,
                exclusions: ExclusionsStore, history: HistoryStoring) {
        self.scanner = scanner
        self.store = store
        self.exclusions = exclusions
        self.history = history
    }

    /// hardRoots 取注入 store 的配置基线;userExclusions 每次按 exclusions 当前值实时重建。
    private var effectiveProtection: ProtectionStore {
        ProtectionStore(hardRoots: store.protection.hardRoots,
                        userExclusions: exclusions.exclusions)
    }

    public func load() async {
        reload()
    }

    /// 扫描是同步文件枚举;async 接口留给调用方统一 await(与其它 VM 一致)。
    private func reload() {
        let listing = scanner.scan()
        let protection = effectiveProtection
        userRows = listing.userItems.map { Row(item: $0, denied: protection.isDenied($0.path)) }
        systemItems = listing.systemItems
    }

    /// 禁用一行:denied 快照直接 no-op;否则用实时保护层重建 store 再编排,
    /// 成功后记历史并重扫(条目消失),失败只记录原因、不伪造报告。
    public func disable(_ row: Row) async {
        guard !row.denied else { return }
        let protection = effectiveProtection
        // load 之后新增的排除也必须拦住:重建后的 store 会在门禁处短路,零触达文件系统。
        guard !protection.isDenied(row.item.path) else {
            reload()
            return
        }
        let liveStore = LaunchItemStore(trash: store.trash, protection: protection)
        switch await liveStore.disable(row.item) {
        case .trashed(let report):
            try? history.append(report)
            lastReport = report
            lastError = nil
            reload()
        case .denied:
            // 门禁在扫描与触达之间被收紧:以实时清单刷新 UI,不产生报告。
            reload()
        case .failed(let reason):
            lastError = reason
        }
    }

    /// 登记用户排除并立即刷新 denied 判定(exclusions 为共享单一来源,不复制清单)。
    public func exclude(_ row: Row) {
        exclusions.add(row.item.path)
        let protection = effectiveProtection
        userRows = userRows.map { Row(item: $0.item, denied: protection.isDenied($0.item.path)) }
    }

    public func dismissReport() {
        lastReport = nil
    }
}
