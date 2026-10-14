import SwiftUI
import CleanKit
import AppCore

struct ReportView: View {
    let report: CleanReport
    let vm: ScanViewModel
    var body: some View { Text(loc("report.done")) }
}
