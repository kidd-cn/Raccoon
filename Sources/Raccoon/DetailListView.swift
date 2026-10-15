import SwiftUI
import AppKit
import ScanKit
import AppCore

struct DetailListView: View {
    @Bindable var vm: ScanViewModel
    let category: RuleCategory

    var hits: [ScanHit] { vm.hits.filter { $0.category == category } }

    var body: some View {
        VStack(spacing: 0) {
            if hits.isEmpty {
                Text(loc("detail.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(hits) { hit in
                        DetailRow(hit: hit,
                                  selected: vm.selectedPaths.contains(hit.path)) { vm.toggle(hit.path) }
                    }
                }
            }
            Divider()
            bottomBar
        }
        .navigationTitle(loc("category.\(category.rawValue)"))
        .toolbar {
            Button(loc("detail.selectAll")) { vm.selectAll(in: category) }
            Button(loc("detail.selectNone")) { vm.selectNone(in: category) }
            Button(loc("detail.uncheckCautious")) { vm.uncheckCautiousAndRunning() }
        }
        .sheet(isPresented: $vm.confirmPresented) {
            ConfirmCleanView(vm: vm)
        }
    }

    var bottomBar: some View {
        HStack {
            Text(loc("detail.selected", vm.selectedPaths.count, byteText(vm.selectedBytes)))
                .monospacedDigit()
            Spacer()
            Button(loc("common.clean")) { vm.confirmPresented = true }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedPaths.isEmpty || vm.phase == .cleaning)
        }
        .padding(12)
    }
}

struct DetailRow: View {
    let hit: ScanHit
    let selected: Bool
    let onToggle: () -> Void

    var title: String {
        if hit.action == .tmutilThin, let date = hit.snapshotDate { return loc("detail.snapshot", date) }
        return hit.appName ?? hit.path.split(separator: "/").last.map(String.init) ?? hit.path
    }

    var body: some View {
        HStack(spacing: 10) {
            // 勾选状态唯一源自 vm.selectedPaths;set 弃用 newValue、统一走 toggle 翻转,勿在此写回
            Toggle(String(), isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .labelsHidden()
            AppIconView(bundleID: hit.bundleID)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(hit.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if hit.isAppRunning { TagView(text: loc("detail.appRunning"), color: .yellow) }
            if hit.safety == .cautious { TagView(text: loc("detail.cautious"), color: .orange) }
            Text(byteText(hit.sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        // 行级 tap 依赖 SwiftUI 控件优先权:点 Toggle 不触发本手势,双通道各触发一次
        .onTapGesture { onToggle() }
    }
}

struct TagView: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct AppIconView: View {
    let bundleID: String?
    var body: some View {
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 26, height: 26)
        } else {
            Image(systemName: "folder")
                .frame(width: 26, height: 26)
                .foregroundStyle(.secondary)
        }
    }
}
