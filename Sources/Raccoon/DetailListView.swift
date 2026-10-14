import SwiftUI
import ScanKit
import AppCore

struct DetailListView: View {
    let vm: ScanViewModel
    let category: RuleCategory
    var body: some View { Text(loc("detail.title")) }
}
