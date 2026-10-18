import SwiftUI
import AppCore
import DiskKit

/// 磁盘清理确认卡片:照抄 ConfirmCleanView 版式(标题、已选汇总、谨慎说明、默认键给取消)。
/// 受保护项在列表勾选阶段已被排除,故此处只需固定提示被移入废纸篓的项可恢复。
struct DiskConfirmView: View {
    let vm: DiskAnalysisViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("confirm.title")).font(.title3).bold()
            Text(loc("detail.selected", vm.selectedNodes.count, byteText(vm.selectedBytes)))
                .monospacedDigit()

            Divider()
            Text(loc("disk.confirm.hint"))
                .font(.callout).foregroundStyle(.secondary)

            // 破坏性确认的默认键给取消(HIG 惯例,⏎=安全侧);Esc 经 onExitCommand 关闭。
            HStack {
                Spacer()
                Button(loc("common.cancel")) { vm.confirmPresented = false }
                    .keyboardShortcut(.defaultAction)
                Button(loc("common.moveToTrash")) {
                    vm.cleanSelected()
                    vm.confirmPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onExitCommand { vm.confirmPresented = false }
        .padding(20)
        .frame(width: 480)
    }
}
