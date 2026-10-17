import SwiftUI
import CleanKit
import AppCore

struct ReportView: View {
    let report: CleanReport
    let vm: ScanViewModel

    var body: some View {
        CleanReportView(
            report: report,
            remainingCount: vm.hits.count,
            remainingBytes: vm.remainingBytes,
            onBack: { vm.returnToResults() },
            onRescan: { vm.dismissReport(); vm.startScan() })
    }
}
