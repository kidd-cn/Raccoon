import SwiftUI
import ScanKit
import AppCore

/// 三期「AI 清理」首页:专属 ScanViewModel(categoryFilter=[.ai]),按工具分组展示。
/// 确认弹窗、报告页、历史与主清理页同源复用;两页 ViewModel 互不共享状态(spec D3)。
struct AICleanupHomeView: View {
    @Bindable var vm: ScanViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle: idleView
                case .scanning: scanningView
                case .completed: completedView
                case .cleaning:
                    VStack(spacing: 12) {
                        ProgressView(value: Double(vm.cleanProgress.done),
                                     total: Double(max(vm.cleanProgress.total, 1)))
                            .frame(maxWidth: 320)
                        Text(loc("common.clean")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .report(let report): ReportView(report: report, vm: vm)
                case .failed(let message): failedView(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.aiCleanup"))
        }
        .sheet(isPresented: $vm.confirmPresented) {
            ConfirmCleanView(vm: vm)
        }
    }

    var idleView: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(loc("ai.startHint"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(loc("common.scan")) { vm.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if let last = vm.lastCleanup {
                Text(loc("home.lastCleanup", byteText(last.freedBytes)))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(loc("home.neverCleaned"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // 扫描中与失败视图与 CleanupHomeView 同构:复用 home.scanning/common.cancel/
    // home.cancelHint/home.failed/home.retry 键,图标区分入口。
    // 不展示 home.found:vm.progress.bytesFound 是引擎全局计数,含本页永不列出的类别,展示会误导。
    var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(loc("home.scanning", vm.progress.rulesDone, vm.progress.rulesTotal))
                .foregroundStyle(.secondary)
            Button(loc("common.cancel")) { vm.cancelScan() }
            Text(loc("home.cancelHint")).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    var completedView: some View {
        Group {
            if vm.hits.isEmpty {
                VStack(spacing: 14) {
                    Text(loc("ai.empty")).foregroundStyle(.secondary)
                    Button(loc("report.again")) { vm.startScan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(AIToolGrouper.groups(in: vm.hits)) { group in
                                toolSection(group)
                            }
                        }
                    }
                    bottomBar
                }
            }
        }
    }

    func toolSection(_ group: AIToolGroup) -> some View {
        let items = vm.selectedItems.filter { $0.tool == group.tool }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc("ai.tool.\(group.id)")).font(.headline)
                Spacer()
                // 组头数字 = 本组已选口径(与 DetailListView 底栏「本类口径」同义)
                if !items.isEmpty {
                    Text(loc("detail.selected", items.count,
                             byteText(items.reduce(Int64(0)) { $0 + $1.sizeBytes })))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(group.hits) { hit in
                DetailRow(hit: hit,
                          selected: vm.selectedPaths.contains(hit.path)) { vm.toggle(hit.path) }
            }
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
        .padding(.top, 8)
    }

    func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.yellow)
            Text(loc("home.failed", message)).multilineTextAlignment(.center)
            Button(loc("home.retry")) { vm.startScan() }
        }
    }
}
