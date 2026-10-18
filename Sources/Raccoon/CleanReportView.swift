import SwiftUI
import CleanKit

/// 共用清理报告页(一期清理 / 卸载 / 残留清理三个入口同一形态)。
/// 有剩余项时「返回列表」是主按钮;全部清完时「再扫一次」是主按钮(与一期一致)。
struct CleanReportView: View {
    let report: CleanReport
    let remainingCount: Int
    let remainingBytes: Int64
    let onBack: (() -> Void)?
    let onRescan: (() -> Void)?
    var onScanOrphans: (() -> Void)? = nil
    /// 来源标注(如「磁盘分析」):非 nil 时在标题下以小号次要文字展示。
    var sourceLabel: String? = nil

    private func reasonText(_ code: String) -> String {
        let key = "reason.\(code)"
        let value = loc(key)
        return value == key ? loc("reason.other") : value
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44)).foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(loc("report.done")).font(.title2).bold()
            if let sourceLabel {
                Text(sourceLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            // 部分清理后剩余项仍在结果里,必须说出来:否则用户只能靠「再扫一次」重新发现它们。
            // 无字节口径的来源(如启动项禁用)只报数量,避免出现「0 字节未清理」的怪话。
            if remainingCount > 0 {
                Text(remainingBytes > 0
                     ? loc("report.remaining", remainingCount, byteText(remainingBytes))
                     : loc("report.remaining.count", remainingCount))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                if remainingCount > 0 {
                    if let onScanOrphans {
                        // 本体已删但残留仍在:继续清残留是唯一正确的续作,回列表已无该应用。
                        Button(loc("orphans.scan")) { onScanOrphans() }
                            .buttonStyle(.borderedProminent)
                        if let onBack {
                            Button(loc("report.backToList")) { onBack() }
                        }
                        if let onRescan {
                            Button(loc("report.again")) { onRescan() }
                        }
                    } else {
                        // 还有剩余项时回列表是主路径(不必重扫即可接着清)。
                        if let onBack {
                            Button(loc("report.backToList")) { onBack() }
                                .buttonStyle(.borderedProminent)
                        }
                        if let onRescan {
                            Button(loc("report.again")) { onRescan() }
                        }
                    }
                } else {
                    // 全部清完:再扫一次为主按钮;返回列表仍始终可选。
                    if let onRescan {
                        Button(loc("report.again")) { onRescan() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let onBack {
                        Button(loc("report.backToList")) { onBack() }
                    }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
