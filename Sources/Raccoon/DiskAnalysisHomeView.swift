import SwiftUI
import UniformTypeIdentifiers
import AppCore
import DiskKit
import CleanKit

/// 磁盘分析主页:由 vm.phase 驱动 idle/scanning/completed/cleaning/report/failed 六态。
/// treemap 分段先占位,后续任务替换;列表态含面包屑下钻、勾选门禁与 others 聚合行。
private enum DiskViewMode: Hashable {
    case treemap
    case list
}

struct DiskAnalysisHomeView: View {
    let vm: DiskAnalysisViewModel
    // 手写 @State 展开(本机 CLT 工具链缺 libSwiftUIMacros.dylib,见 RaccoonApp.swift 注释)。
    private var _viewMode: State<DiskViewMode>
    private var _importerPresented: State<Bool>

    private var viewMode: DiskViewMode {
        get { _viewMode.wrappedValue }
        nonmutating set { _viewMode.wrappedValue = newValue }
    }
    var importerPresented: Bool {
        get { _importerPresented.wrappedValue }
        nonmutating set { _importerPresented.wrappedValue = newValue }
    }

    init(vm: DiskAnalysisViewModel) {
        self.vm = vm
        _viewMode = State(wrappedValue: .list)
        _importerPresented = State(wrappedValue: false)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle: idleView
                case .scanning: scanningView
                case .completed: completedView
                case .cleaning: cleaningView
                case .report(let report): reportView(report)
                case .failed(let message): failedView(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.diskAnalysis"))
        }
        .sheet(isPresented: Binding(get: { vm.confirmPresented },
                                    set: { vm.confirmPresented = $0 })) {
            DiskConfirmView(vm: vm)
        }
    }

    // MARK: - 各 phase

    private var idleView: some View {
        VStack(spacing: 18) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(loc("disk.idle.hint"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button(loc("disk.start")) { vm.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button(loc("disk.chooseFolder")) { importerPresented = true }
            }
        }
        .fileImporter(isPresented: _importerPresented.projectedValue,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                vm.startScan(rootPath: url.path)
            }
        }
    }

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            if let progress = vm.progress {
                Text(loc("disk.progress.scanned", byteText(progress.bytesScanned)))
                    .foregroundStyle(.secondary)
                Text(progress.currentPath)
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Button(loc("common.cancel")) { vm.cancelScan() }
        }
    }

    private var completedView: some View {
        VStack(spacing: 0) {
            breadcrumbs
            HStack {
                Picker(String(), selection: _viewMode.projectedValue) {
                    Text(loc("disk.view.treemap")).tag(DiskViewMode.treemap)
                    Text(loc("disk.view.list")).tag(DiskViewMode.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                Button(loc("disk.rescan")) { vm.startScan() }
            }
            .padding(.vertical, 8)
            Divider()
            if viewMode == .list {
                listView
            } else {
                treemapPlaceholder
            }
            Divider()
            bottomBar
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(vm.drillPath.enumerated()), id: \.offset) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Button { vm.drillTo(depth: index) } label: {
                        Text(index == 0 ? loc("disk.root.home") : node.name)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var listView: some View {
        List {
            if vm.displayRows.isEmpty {
                Text(loc("disk.empty"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.displayRows) { row in
                    rowView(row)
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func rowView(_ row: DisplayRow) -> some View {
        switch row.kind {
        case .item(let node):
            DiskRowView(
                name: node.name,
                sizeBytes: node.sizeBytes,
                isDirectory: node.isDirectory,
                containsProtected: node.containsProtected,
                selected: vm.selectedPaths.contains(node.path),
                onToggle: { vm.toggle(node.path) },
                onDrill: { vm.drill(into: node) })
        case .others(let count, let bytes):
            HStack {
                Text(loc("disk.others", count, byteText(bytes)))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var treemapPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.system(size: 36)).foregroundStyle(.tertiary)
            Text(loc("disk.view.treemap")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            Text(loc("detail.selected", vm.selectedNodes.count, byteText(vm.selectedBytes)))
                .monospacedDigit()
            Spacer()
            Button(loc("common.moveToTrash")) { vm.confirmPresented = true }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedNodes.isEmpty)
        }
        .padding(12)
    }

    private var cleaningView: some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(vm.cleanProgress.done),
                         total: Double(max(vm.cleanProgress.total, 1)))
                .frame(maxWidth: 320)
            Text(loc("common.clean")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reportView(_ report: CleanReport) -> some View {
        CleanReportView(
            report: report,
            remainingCount: vm.remainingCount,
            remainingBytes: vm.remainingBytes,
            onBack: { vm.returnToResults() },
            onRescan: { vm.dismissReport(); vm.startScan() },
            sourceLabel: loc("report.source.diskAnalysis"))
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.yellow)
            Text(loc("home.failed", message)).multilineTextAlignment(.center)
            Button(loc("home.retry")) { vm.startScan() }
        }
    }
}

/// 列表单行:勾选状态唯一源自 vm.selectedPaths(经 selected 入参),set 弃用 newValue 走 toggle 翻转。
/// 受保护项禁用勾选并显示「受保护」标签;行点击经 drill(into:) 下钻(目录才生效,文件为 no-op)。
struct DiskRowView: View {
    let name: String
    let sizeBytes: Int64
    let isDirectory: Bool
    let containsProtected: Bool
    let selected: Bool
    let onToggle: () -> Void
    let onDrill: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(String(), isOn: Binding(get: { selected }, set: { _ in onToggle() }))
                .labelsHidden()
                .disabled(containsProtected)
                .accessibilityLabel(name)
            Image(systemName: isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if containsProtected {
                Text(loc("disk.list.protected"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(byteText(sizeBytes))
                .foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onDrill() }
    }
}
