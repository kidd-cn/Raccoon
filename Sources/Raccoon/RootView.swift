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
    static var availableCases: [Module] { [.cleanup] }
    static var comingSoonCases: [Module] { [.uninstall, .aiCleanup, .diskAnalysis, .monitor] }
}

struct RootView: View {
    let exclusions: ExclusionsStore
    // 手写 @State 展开(本机 CLT 工具链缺 libSwiftUIMacros.dylib,见 RaccoonApp.swift 注释)。
    private var _vm: State<ScanViewModel>
    private var _selection: State<Module>

    var vm: ScanViewModel {
        get { _vm.wrappedValue }
        nonmutating set { _vm.wrappedValue = newValue }
    }
    var selection: Module {
        get { _selection.wrappedValue }
        nonmutating set { _selection.wrappedValue = newValue }
    }

    init(exclusions: ExclusionsStore) {
        self.exclusions = exclusions
        _vm = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                exclusions: exclusions,
                                                history: JSONHistoryStore()))
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
            CleanupHomeView(vm: vm)
                .onAppear { vm.loadLastCleanup() }
        }
    }
}
