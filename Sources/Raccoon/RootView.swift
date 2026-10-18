import SwiftUI
import ScanKit
import AppCore
import CleanKit
import DiskKit

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
    static var availableCases: [Module] { [.cleanup, .uninstall, .aiCleanup, .diskAnalysis] }
    static var comingSoonCases: [Module] { allCases.filter { !availableCases.contains($0) } }
}

struct RootView: View {
    let exclusions: ExclusionsStore
    // 手写 @State 展开(本机 CLT 工具链缺 libSwiftUIMacros.dylib,见 RaccoonApp.swift 注释)。
    private var _vm: State<ScanViewModel>
    private var _uvm: State<UninstallViewModel>
    private var _aiVM: State<ScanViewModel>
    private var _diskVM: State<DiskAnalysisViewModel>
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
        // 磁盘分析:扫描时用最新排除清单构建保护层(与 AppScanService 同口径),共享同一 history。
        _diskVM = State(wrappedValue: DiskAnalysisViewModel(
            scanner: DiskScanner(protection: ProtectionStore(userExclusions: exclusions.exclusions)),
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
                Section(loc("sidebar.comingSoon")) {
                    ForEach(Module.comingSoonCases) { module in
                        Label(loc("module.\(module.rawValue)"), systemImage: module.icon)
                            .foregroundStyle(.tertiary)
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
            case .cleanup, .monitor:
                // monitor 仍为侧边栏占位;显式列全:新增枚举 case 时由编译器强制更新。
                CleanupHomeView(vm: vm)
                    .onAppear { vm.loadLastCleanup() }
            }
        }
    }
}
