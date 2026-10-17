import SwiftUI
import AppCore
import CleanKit

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
    static var availableCases: [Module] { [.cleanup, .uninstall] }
    static var comingSoonCases: [Module] { allCases.filter { !availableCases.contains($0) } }
}

struct RootView: View {
    let exclusions: ExclusionsStore
    // 手写 @State 展开(本机 CLT 工具链缺 libSwiftUIMacros.dylib,见 RaccoonApp.swift 注释)。
    private var _vm: State<ScanViewModel>
    private var _uvm: State<UninstallViewModel>
    private var _selection: State<Module>

    var vm: ScanViewModel {
        get { _vm.wrappedValue }
        nonmutating set { _vm.wrappedValue = newValue }
    }
    var uvm: UninstallViewModel {
        get { _uvm.wrappedValue }
        nonmutating set { _uvm.wrappedValue = newValue }
    }
    var selection: Module {
        get { _selection.wrappedValue }
        nonmutating set { _selection.wrappedValue = newValue }
    }

    @MainActor
    init(exclusions: ExclusionsStore) {
        self.exclusions = exclusions
        let history = JSONHistoryStore()
        let services = UninstallServices.make()
        _vm = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                exclusions: exclusions,
                                                history: history))
        _uvm = State(wrappedValue: UninstallViewModel(discovery: services.discovery,
                                                      locator: services.locator,
                                                      orphanScanner: services.orphans,
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
            // detail 按选择切换;两个模块各自持有状态机,互不干扰
            switch selection {
            case .uninstall:
                UninstallHomeView(vm: uvm)
            default:
                CleanupHomeView(vm: vm)
                    .onAppear { vm.loadLastCleanup() }
            }
        }
    }
}
