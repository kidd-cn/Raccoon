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
            VStack(alignment: .leading, spacing: 2) {
                // 主数字 = 本类口径,与工具栏「全选/全不选」同范围
                Text(loc("detail.selected", vm.selectedCount(in: category),
                         byteText(vm.selectedBytes(in: category))))
                    .monospacedDigit()
                // 副行 = 全局口径:「清理」始终作用于全部已选,跨类是默认选中态的常态,
                // 不告知会让用户以为只清理本类;两者相等(仅本类有选中)时不重复同一个数字
                if vm.selectedPaths.count != vm.selectedCount(in: category) {
                    Text(loc("detail.selectedAll", vm.selectedPaths.count, byteText(vm.selectedBytes)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
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
                // 空 label 仅服务视觉布局;VoiceOver 语义走本修饰符:快照项与可见标题同源
                // (path 是 tmutil:// 伪标签,不能进旁白),普通项读展示名、缺 app 名时读路径
                .accessibilityLabel(hit.action == .tmutilThin
                    ? (hit.snapshotDate.map { loc("detail.snapshot", $0) } ?? hit.path)
                    : (hit.appName ?? hit.path))
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
