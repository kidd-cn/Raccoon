import SwiftUI
import AppCore
import UninstallKit

struct AppDetailView: View {
    let vm: UninstallViewModel
    let app: InstalledApp

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    HStack(spacing: 10) {
                        AppIconView(bundleID: app.bundleID)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.version.map { loc("uninstall.version", $0) } ?? app.bundleID)
                                .font(.caption).foregroundStyle(.secondary)
                            // 头部展示本体路径:用户可确认将被移入废纸篓的到底是哪个包。
                            Text(app.appPath)
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if app.isRunning { TagView(text: loc("detail.appRunning"), color: .yellow) }
                        Text(byteText(app.sizeBytes))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Label(loc("uninstall.bundleFixed"), systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text(loc("uninstall.group.bundle"))
                }

                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            LeftoverRow(item: item,
                                        selected: vm.selectedLeftoverPaths.contains(item.path)) {
                                vm.toggleLeftover(item.path)
                            }
                        }
                    } header: {
                        Text(loc(group.titleKey))
                    }
                }

                if vm.isLoadingLeftovers {
                    // 定位完成前不能显示「没有发现关联数据」:那是尚未知,不是没有。
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(loc("uninstall.loadingLeftovers")).foregroundStyle(.secondary)
                        }
                    }
                } else if vm.leftovers.isEmpty {
                    Section {
                        Text(loc("uninstall.noLeftovers")).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            bottomBar
        }
        .navigationTitle(app.name)
        .toolbar {
            Button(loc("detail.selectAll")) { vm.selectAllLeftovers() }
                .disabled(vm.isLoadingLeftovers)
            Button(loc("detail.selectNone")) { vm.selectNoneLeftovers() }
                .disabled(vm.isLoadingLeftovers)
        }
    }

    var groups: [LeftoverGroup] {
        let exact = vm.leftovers.filter { $0.ownership == .bundleID }
        let unconfirmed = vm.leftovers.filter { $0.ownership == .appName }
        var out: [LeftoverGroup] = []
        let regenerable = exact.filter { $0.safety == .regenerable }
        let userData = exact.filter { $0.safety == .userData }
        if !regenerable.isEmpty {
            out.append(.init(id: "regen", titleKey: "uninstall.group.regenerable", items: regenerable))
        }
        if !userData.isEmpty {
            out.append(.init(id: "user", titleKey: "uninstall.group.userData", items: userData))
        }
        if !unconfirmed.isEmpty {
            out.append(.init(id: "unconfirmed", titleKey: "uninstall.group.unconfirmed", items: unconfirmed))
        }
        return out
    }

    var bottomBar: some View {
        HStack {
            // N/X 均含应用本体:本体固定随卸载一起提交,数字必须与提交范围一致
            Text(loc("detail.selected",
                     vm.selectedLeftoverItems.count + 1,
                     byteText(app.sizeBytes + vm.selectedLeftoverItems.reduce(Int64(0)) { $0 + $1.sizeBytes })))
                .monospacedDigit()
            Spacer()
            Button(loc("uninstall.button")) { vm.requestUninstall() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.cleanState != nil || vm.isLoadingLeftovers)
        }
        .padding(12)
    }
}

struct LeftoverGroup: Identifiable {
    let id: String
    let titleKey: String
    let items: [AppLeftover]
}

struct LeftoverRow: View {
    let item: AppLeftover
    let selected: Bool
    let onToggle: () -> Void

    var title: String { item.path.split(separator: "/").last.map(String.init) ?? item.path }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(String(), isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .labelsHidden()
                .accessibilityLabel(item.path)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(item.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if item.ownership == .appName {
                TagView(text: loc("uninstall.tag.unconfirmed"), color: .orange)
            } else if item.safety == .userData {
                TagView(text: loc("detail.cautious"), color: .orange)
            }
            Text(byteText(item.sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // 行级 tap 依赖 SwiftUI 控件优先权:点 Toggle 不触发本手势,双通道各触发一次
        .onTapGesture { onToggle() }
    }
}
