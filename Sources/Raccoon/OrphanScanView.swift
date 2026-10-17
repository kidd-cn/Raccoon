import SwiftUI
import AppCore
import UninstallKit

struct OrphanScanView: View {
    @Bindable var vm: UninstallViewModel

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
                Text(loc("orphans.failedLocations", vm.failedLocationIDs.sorted().joined(separator: ", ")))
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
            if vm.selectedOrphanItems.contains(where: { $0.ownership == .appName }) {
                Text(loc("orphans.defaultUncheckedHint"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(loc("orphans.clean")) { vm.requestCleanOrphans() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedOrphanItems.isEmpty || vm.cleanState != nil)
        }
        .padding(12)
    }
}
