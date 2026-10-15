import SwiftUI
import AppKit
import AppCore

struct SettingsView: View {
    @Bindable var exclusions: ExclusionsStore

    var body: some View {
        TabView {
            ExclusionsPane(exclusions: exclusions)
                .tabItem { Label(loc("settings.exclusions"), systemImage: "hand.raised") }
            AboutPane()
                .tabItem { Label(loc("settings.about"), systemImage: "info.circle") }
        }
        .frame(width: 500, height: 340)
    }
}

struct ExclusionsPane: View {
    @Bindable var exclusions: ExclusionsStore

    var body: some View {
        VStack(spacing: 0) {
            Text(loc("settings.exclusionsHint"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.top, 10)
            List {
                ForEach(exclusions.exclusions, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            exclusions.remove(path)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack {
                Spacer()
                Button(loc("settings.add")) { addPath() }
            }
            .padding(10)
        }
    }

    func addPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            exclusions.add(url.path)
        }
    }
}

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 36)).foregroundStyle(.tint)
            Text(loc("settings.aboutBody"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
