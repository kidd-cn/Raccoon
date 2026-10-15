import SwiftUI
import CleanKit
import AppCore

struct ReportView: View {
    let report: CleanReport
    let vm: ScanViewModel

    func reasonText(_ code: String) -> String {
        let key = "reason.\(code)"
        let value = loc(key)
        return value == key ? loc("reason.other") : value
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text(loc("report.done")).font(.title2).bold()
            // freed 口径:仅统计成功移入废纸篓的字节;vanished(应用抢先删)与快照不计入
            Text(loc("report.freed", byteText(report.freedBytes))).monospacedDigit()
            Text(loc("report.trashed", report.trashedCount)).monospacedDigit().foregroundStyle(.secondary)
            if report.vanishedCount > 0 {
                Text(loc("report.vanished", report.vanishedCount)).monospacedDigit().foregroundStyle(.secondary)
            }
            if report.snapshotCount > 0 {
                Text(loc("report.snapshots", report.snapshotCount)).monospacedDigit().foregroundStyle(.secondary)
            }
            if !report.skipped.isEmpty {
                DisclosureGroup(loc("report.skipped", report.skipped.count)) {
                    ForEach(report.skipped, id: \.path) { item in
                        HStack {
                            Text(item.path).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(reasonText(item.reason)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }
            HStack {
                Button(loc("report.again")) {
                    vm.dismissReport()
                    vm.startScan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
