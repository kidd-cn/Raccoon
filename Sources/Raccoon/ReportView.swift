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
            // 部分清理后剩余项仍在结果里,必须说出来:否则用户只能靠「再扫一次」重新发现它们
            if !vm.hits.isEmpty {
                Text(loc("report.remaining", vm.hits.count, byteText(vm.remainingBytes)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                // 还有剩余项时回列表是主路径(不必重扫即可接着清);全部清完时只剩再扫一次
                if vm.hits.isEmpty {
                    Button(loc("report.again")) { vm.dismissReport(); vm.startScan() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(loc("report.backToList")) { vm.returnToResults() }
                        .buttonStyle(.borderedProminent)
                    Button(loc("report.again")) { vm.dismissReport(); vm.startScan() }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
