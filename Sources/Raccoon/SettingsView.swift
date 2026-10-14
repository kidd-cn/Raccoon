import SwiftUI
import AppCore

struct SettingsView: View {
    let exclusions: ExclusionsStore
    var body: some View { Text(loc("settings.title")) }
}
