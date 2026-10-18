import SwiftUI
import ScanKit
import AppCore
import CleanKit
import DiskKit
import LaunchKit

enum Module: String, CaseIterable, Identifiable {
    case cleanup, uninstall, aiCleanup, diskAnalysis, monitor
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .cleanup: "sparkles"
        case .uninstall: "shippingbox"
        case .aiCleanup: "brain"
        case .diskAnalysis: "chart.pie.fill"
        case .monitor: "gauge.with.needle"
        }
    }
    static var availableCases: [Module] { [.cleanup, .uninstall, .aiCleanup, .diskAnalysis, .monitor] }
    static var comingSoonCases: [Module] { allCases.filter { !availableCases.contains($0) } }
}

struct RootView: View {
    let exclusions: ExclusionsStore
    // 手写 @State 展开(本机 CLT 工具链缺 libSwiftUIMacros.dylib,见 RaccoonApp.swift 注释)。
    private var _vm: State<ScanViewModel>
    private var _uvm: State<UninstallViewModel>
    private var _aiVM: State<ScanViewModel>
    private var _diskVM: State<DiskAnalysisViewModel>
    private var _monitorVM: State<MonitorViewModel>
    private var _launchItemsVM: State<LaunchItemsViewModel>
    private var _selection: State<Module>

    var vm: ScanViewModel {
        get { _vm.wrappedValue }
        nonmutating set { _vm.wrappedValue = newValue }
    }
    var aiVM: ScanViewModel {
        get { _aiVM.wrappedValue }
        nonmutating set { _aiVM.wrappedValue = newValue }
    }
    var uvm: UninstallViewModel {
        get { _uvm.wrappedValue }
        nonmutating set { _uvm.wrappedValue = newValue }
    }
    var selection: Module {
        get { _selection.wrappedValue }
        nonmutating set { _selection.wrappedValue = newValue }
    }
    var diskVM: DiskAnalysisViewModel {
        get { _diskVM.wrappedValue }
        nonmutating set { _diskVM.wrappedValue = newValue }
    }
    var monitorVM: MonitorViewModel {
        get { _monitorVM.wrappedValue }
        nonmutating set { _monitorVM.wrappedValue = newValue }
    }
    var launchItemsVM: LaunchItemsViewModel {
        get { _launchItemsVM.wrappedValue }
        nonmutating set { _launchItemsVM.wrappedValue = newValue }
    }

    @MainActor
    init(exclusions: ExclusionsStore) {
        self.exclusions = exclusions
        let history = JSONHistoryStore()
        let services = UninstallServices.make()
        // 主清理页过滤 = 全集去 .ai;AI 页 = [.ai](spec D3:两页互不见对方类别,互不共享状态)
        _vm = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                exclusions: exclusions,
                                                history: history,
                                                categoryFilter: Set(RuleCategory.allCases).subtracting([.ai])))
        _aiVM = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                  exclusions: exclusions,
                                                  history: history,
                                                  categoryFilter: [.ai]))
        _uvm = State(wrappedValue: UninstallViewModel(discovery: services.discovery,
                                                      locator: services.locator,
                                                      orphanScanner: services.orphans,
                                                      exclusions: exclusions,
                                                      history: history))
        // 磁盘分析:scanner 仅作 hardRoots 来源;userExclusions 由 VM 在扫描/清理时按当前
        // 排除清单实时重建(与 AppScanService 同口径),共享同一 history。
        _diskVM = State(wrappedValue: DiskAnalysisViewModel(
            scanner: DiskScanner(protection: ProtectionStore(userExclusions: exclusions.exclusions)),
            exclusions: exclusions,
            history: history))
        // 监控:只读采样,start 由 MonitorHomeView 的 .task 触发;不在此处建循环。
        _monitorVM = State(wrappedValue: MonitorViewModel(sampler: LiveSystemSampler()))
        // 启动项:store 的 protection 仅是构造期基线;VM 每次 load/disable 会按
        // exclusions 当前值实时重建(见 LaunchItemsViewModel 注释)。
        let launchStore = LaunchItemStore(
            trash: FileManagerTrashService(),
            protection: ProtectionStore(userExclusions: exclusions.exclusions))
        _launchItemsVM = State(wrappedValue: LaunchItemsViewModel(
            scanner: LaunchItemScanner(),
            store: launchStore,
            exclusions: exclusions,
            history: history))
        _selection = State(wrappedValue: .cleanup)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: _selection.projectedValue) {
                Section {
                    ForEach(Module.availableCases) { module in
                        Label(loc("module.\(module.rawValue)"), systemImage: module.icon)
                            .tag(module)
                    }
                }
                // 全部模块启用后该组为空:空 Section 仍会渲染列头,故整组隐藏
                if !Module.comingSoonCases.isEmpty {
                    Section(loc("sidebar.comingSoon")) {
                        ForEach(Module.comingSoonCases) { module in
                            Label(loc("module.\(module.rawValue)"), systemImage: module.icon)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(loc("app.name"))
        } detail: {
            // detail 按选择切换;三个模块各自持有状态机,互不干扰
            switch selection {
            case .uninstall:
                UninstallHomeView(vm: uvm)
            case .aiCleanup:
                AICleanupHomeView(vm: aiVM)
                    .onAppear { aiVM.loadLastCleanup() }
            case .diskAnalysis:
                DiskAnalysisHomeView(vm: diskVM)
            case .monitor:
                // 跨模块跳转(建议卡/工具入口)通过回调改选中项,复用侧边栏导航
                MonitorHomeView(vm: monitorVM, launchItemsVM: launchItemsVM) { module in
                    selection = module
                }
            case .cleanup:
                // 显式列全:新增枚举 case 时由编译器强制更新。
                CleanupHomeView(vm: vm)
                    .onAppear { vm.loadLastCleanup() }
            }
        }
    }
}
