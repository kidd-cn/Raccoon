import SwiftUI
import AppCore

/// 禁用启动项确认卡片:沿 DiskConfirmView 版式——逐项列出 Label 与文件名、说明后果、
/// 破坏性确认的默认键给「取消」(⏎=安全侧),Esc 经 onExitCommand 关闭。
struct LaunchConfirmView: View {
    let row: LaunchItemsViewModel.Row
    /// 禁用编排在飞(Finder 降级可能挂数秒):两个按钮都锁住并给出进度态,防连点重入。
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("launch.confirm.title")).font(.title3).bold()

            VStack(alignment: .leading, spacing: 4) {
                Text(row.item.label ?? row.item.fileName)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.item.fileName)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider()
            Text(loc("launch.confirm.hint"))
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(loc("common.cancel"), action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                Button(loc("launch.disable"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
            }
        }
        .onExitCommand { if !isBusy { onCancel() } }
        .padding(20)
        .frame(width: 440)
    }
}
