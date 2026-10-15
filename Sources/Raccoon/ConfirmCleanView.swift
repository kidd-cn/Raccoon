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

            HStack {
                Spacer()
                Button(loc("common.cancel")) { vm.confirmPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(loc("common.moveToTrash")) { vm.cleanSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
