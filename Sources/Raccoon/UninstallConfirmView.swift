import SwiftUI
import AppCore
import UninstallKit

struct UninstallConfirmView: View {
    let vm: UninstallViewModel
    let flow: UninstallViewModel.CleanFlow

    var pickedItems: [AppLeftover] {
        flow == .apps ? vm.selectedLeftoverItems : vm.selectedOrphanItems
    }
    var bundleCount: Int { flow == .apps ? 1 : 0 }
    var bundleBytes: Int64 { flow == .apps ? (vm.focusedApp?.sizeBytes ?? 0) : 0 }
    var totalCount: Int { pickedItems.count + bundleCount }
    var totalBytes: Int64 { pickedItems.reduce(bundleBytes) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc(flow == .apps ? "uninstall.confirm.title" : "orphans.confirm.title"))
                .font(.title3).bold()
            Text(loc("detail.selected", totalCount, byteText(totalBytes)))
                .monospacedDigit()

            if flow == .apps, let app = vm.focusedApp, app.isRunning {
                Label(loc("confirm.runningWarning"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }

            let userData = pickedItems.filter { $0.safety == .userData }
            if !userData.isEmpty {
                Divider()
                Text(loc("uninstall.confirm.userDataSection"))
                    .font(.headline).foregroundStyle(.orange)
                ForEach(userData) { item in
                    Text(item.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            // 删除前最后一道 UI 防线:⏎ 给取消、Esc 也给取消;卸载/清理仅点按触发
            HStack {
                Spacer()
                Button(loc("common.cancel")) { vm.cancelConfirm() }
                    .keyboardShortcut(.defaultAction)
                Button(loc(flow == .apps ? "uninstall.confirm.button" : "orphans.clean.do")) {
                    if flow == .apps { vm.uninstall() } else { vm.cleanOrphans() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onExitCommand { vm.cancelConfirm() }
        .padding(20)
        .frame(width: 480)
    }
}
