import SwiftUI
import AppKit
import AppCore

struct SettingsView: View {
    // 本体只读转发给子 pane(绑定需求在 pane 内各自 @Bindable),故用 let;RootView 同口径
    let exclusions: ExclusionsStore
    // 菜单栏 VM 是 @Observable:pane 内 body 读字段自动登记依赖,同样 let 转发
    let menuBarVM: MenuBarMonitorViewModel

    var body: some View {
        TabView {
            ExclusionsPane(exclusions: exclusions)
                .tabItem { Label(loc("settings.exclusions"), systemImage: "hand.raised") }
            MenuBarSettingsPane(vm: menuBarVM)
                .tabItem { Label(loc("menubar.settings.tab"), systemImage: "menubar.rectangle") }
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
                        .accessibilityLabel(loc("settings.remove"))
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

    // 用 NSOpenPanel 而非 SwiftUI fileImporter:后者无法同时表达「文件+文件夹混选」
    // (canChooseFiles + canChooseDirectories),排除清单两者都需要,勿「顺手现代化」。
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
