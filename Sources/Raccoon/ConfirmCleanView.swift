import SwiftUI
import ScanKit
import AppCore

struct ConfirmCleanView: View {
    let vm: ScanViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("confirm.title")).font(.title3).bold()
            Text(loc("detail.selected", vm.selectedPaths.count, byteText(vm.selectedBytes)))
                .monospacedDigit()

            if vm.selectedItems.contains(where: \.isAppRunning) {
                Label(loc("confirm.runningWarning"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
            }

            let cautious = vm.selectedItems.filter { $0.safety == .cautious }
            if !cautious.isEmpty {
                Divider()
                Text(loc("confirm.cautiousSection"))
                    .font(.headline).foregroundStyle(.orange)
                ForEach(cautious) { item in
                    Text(item.path)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

        // 删除前最后一道 UI 防线:默认键(⏎)给取消,清理仅点按触发;
        // 实际防护在执行链(扫描过滤 + executor 删除前 isDenied),本弹窗防的是误操作
            HStack {
                Spacer()
                Button(loc("common.cancel")) { vm.confirmPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)   // 破坏性确认的默认键给取消(HIG 惯例,⏎=安全侧)
                Button(loc("common.moveToTrash")) { vm.cleanSelected() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
