import SwiftUI
import AppCore
import UninstallKit

struct UninstallHomeView: View {
    @Bindable var vm: UninstallViewModel

    var body: some View {
        NavigationStack {
            Group {
                if let cleanState = vm.cleanState {
                    cleanContent(cleanState)
                } else {
                    VStack(spacing: 0) {
                        Picker("", selection: $vm.tab) {
                            Text(loc("uninstall.tab.apps")).tag(UninstallViewModel.Tab.apps)
                            Text(loc("uninstall.tab.orphans")).tag(UninstallViewModel.Tab.orphans)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(12)
                        Divider()
                        switch vm.tab {
                        case .apps: appsPane
                        case .orphans: OrphanScanView(vm: vm)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.uninstall"))
            .onAppear { vm.startDiscovery() }
            .navigationDestination(item: $vm.detailAppID) { id in
                if let app = vm.apps.first(where: { $0.bundleID == id }) {
                    AppDetailView(vm: vm, app: app)
                }
            }
        }
        // 确认卡片经独立 NSWindow 呈现(ConfirmWindowPresenter):本机上 sheet 与
        // overlay 均无法可见地盖在 navigationDestination 推入的详情页上。
        // onChange 在此视图已证实会随 confirmFlow 变化触发(body 重渲染有日志佐证)。
        .onChange(of: vm.confirmFlow) {
            ConfirmWindowPresenter.sync(confirmFlow: vm.confirmFlow, vm: vm)
        }
    }

    /// 内嵌确认卡片已由 ConfirmWindowPresenter 的独立窗口替代。

    @ViewBuilder
    var appsPane: some View {
        switch vm.phase {
        case .discovering:
            VStack(spacing: 12) {
                ProgressView()
                Text(loc("uninstall.discovering")).foregroundStyle(.secondary)
                Text(loc("uninstall.discovered", vm.discoveryProgress.enumeratedCount))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundStyle(.yellow)
                Text(loc("uninstall.failed", message)).multilineTextAlignment(.center)
                Button(loc("home.retry")) { vm.startDiscovery(force: true) }
            }
        case .list:
            VStack(spacing: 0) {
                TextField(loc("uninstall.searchPlaceholder"), text: $vm.searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(12)
                if vm.filteredApps.isEmpty {
                    Text(loc("uninstall.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.filteredApps) { app in
                            AppRowView(app: app)
                                .contentShape(Rectangle())
                                .onTapGesture { vm.openDetail(app) }
                        }
                    }
                }
                if vm.unreadableCount > 0 {
                    Text(loc("uninstall.unreadable", vm.unreadableCount))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
        }
    }

    @ViewBuilder
    func cleanContent(_ state: UninstallViewModel.CleanState) -> some View {
        switch state {
        case .cleaning:
            VStack(spacing: 12) {
                ProgressView(value: Double(vm.cleanProgress.done),
                             total: Double(max(vm.cleanProgress.total, 1)))
                    .frame(maxWidth: 320)
                Text(loc("common.clean")).foregroundStyle(.secondary)
            }
        case .report(let report):
            CleanReportView(
                report: report,
                remainingCount: vm.remainingCount,
                remainingBytes: vm.remainingBytes,
                onBack: { vm.returnFromReport() },
                onRescan: {
                    let flow = vm.cleanFlow
                    vm.returnFromReport()
                    if flow == .orphans { vm.scanOrphans() }
                    else { vm.startDiscovery(force: true) }
                },
                onScanOrphans: scanOrphansFromReportAction)
        }
    }

    /// 应用本体已删但仍有未清理/被跳过的关联数据时,这些数据已无人归属,
    /// 正确续作是扫孤儿。报告页直接给出该入口,避免用户回到列表后无从下手。
    private var scanOrphansFromReportAction: (() -> Void)? {
        guard vm.cleanFlow == .apps, vm.remainingCount > 0, vm.lastUninstallBundleRemoved else { return nil }
        return {
            vm.returnFromReport()
            vm.tab = .orphans
            vm.scanOrphans()
        }
    }
}

struct AppRowView: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: app.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text(app.version.map { loc("uninstall.version", $0) } ?? app.bundleID)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if app.isRunning { TagView(text: loc("detail.appRunning"), color: .yellow) }
            Text(byteText(app.sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}
