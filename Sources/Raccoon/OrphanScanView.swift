import SwiftUI
import AppCore
import UninstallKit

struct OrphanScanView: View {
    let vm: UninstallViewModel

    var body: some View {
        VStack(spacing: 0) {
            switch vm.orphanPhase {
            case .idle:
                VStack(spacing: 16) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 40)).foregroundStyle(.tint)
                    Text(loc("orphans.hint"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    Button(loc("orphans.scan")) { vm.scanOrphans() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(vm.phase != .list)
                    scanAvailabilityNote
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:
                VStack(spacing: 12) {
                    ProgressView(
                        value: Double(vm.orphanProgress.completedLocations),
                        total: Double(max(vm.orphanProgress.totalLocations, 1)))
                        .frame(maxWidth: 320)
                    Text(loc("orphans.scanning",
                             vm.orphanProgress.completedLocations,
                             vm.orphanProgress.totalLocations))
                        .monospacedDigit().foregroundStyle(.secondary)
                    Button(loc("common.cancel")) { vm.cancelOrphanScan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .results:
                results
            }
        }
    }

    /// 扫描按钮被禁用时给出原因与出口:发现中显示进度文案,失败时提供重试。
    @ViewBuilder
    private var scanAvailabilityNote: some View {
        switch vm.phase {
        case .discovering:
            Text(loc("uninstall.discovering"))
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(loc("uninstall.failed", message))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(loc("home.retry")) { vm.startDiscovery(force: true) }
            }
        case .list:
            EmptyView()
        }
    }

    /// 失败位置按目录名展示;未知 id 时回退到 id 本身。
    private var failedLocationNames: String {
        let names = vm.failedLocationIDs.compactMap { id in
            LeftoverLocations.all.first { $0.id == id }?.folder
        }
        guard !names.isEmpty else {
            return vm.failedLocationIDs.sorted().joined(separator: ", ")
        }
        return Array(Set(names)).sorted().joined(separator: ", ")
    }

    var results: some View {
        VStack(spacing: 0) {
            if vm.orphans.isEmpty {
                Text(loc("orphans.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                LeftoverRow(item: item,
                                            selected: vm.selectedOrphanPaths.contains(item.path)) {
                                    vm.toggleOrphan(item.path)
                                }
                            }
                        } header: {
                            Text(loc(group.titleKey))
                        }
                    }
                }
            }
            if !vm.failedLocationIDs.isEmpty {
                Text(loc("orphans.failedLocations", failedLocationNames))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            Divider()
            bottomBar
        }
        .toolbar {
            Button(loc("detail.selectAll")) { vm.selectAllOrphans() }
            Button(loc("detail.selectNone")) { vm.selectNoneOrphans() }
        }
    }

    var groups: [LeftoverGroup] {
        let confirmed = vm.orphans.filter { $0.ownership == .bundleID }
        let unconfirmed = vm.orphans.filter { $0.ownership == .appName }
        var out: [LeftoverGroup] = []
        if !confirmed.isEmpty {
            out.append(.init(id: "confirmed", titleKey: "orphans.group.confirmed", items: confirmed))
        }
        if !unconfirmed.isEmpty {
            out.append(.init(id: "unconfirmed", titleKey: "orphans.group.unconfirmed", items: unconfirmed))
        }
        return out
    }

    var bottomBar: some View {
        HStack {
            Text(loc("detail.selected",
                     vm.selectedOrphanItems.count,
                     byteText(vm.selectedOrphanItems.reduce(Int64(0)) { $0 + $1.sizeBytes })))
                .monospacedDigit()
            if vm.orphans.contains(where: { $0.ownership == .appName }) {
                Text(loc("orphans.defaultUncheckedHint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(loc("orphans.clean")) { vm.requestCleanOrphans() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedOrphanItems.isEmpty || vm.cleanState != nil)
        }
        .padding(12)
    }
}
