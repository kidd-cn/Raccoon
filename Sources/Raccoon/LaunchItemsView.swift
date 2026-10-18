import SwiftUI
import AppCore
import LaunchKit

/// 启动项管理子页:用户级可禁用/排除,系统级只读。
/// 删除只进废纸篓;禁用前一律经确认弹窗(默认键为取消),成功后展示报告并重扫列表。
///
/// 本机 CLT 工具链缺 SwiftUI 宏插件:`@State` 手写展开(见 RootView 注释)。
struct LaunchItemsView: View {
    let vm: LaunchItemsViewModel

    private var _pendingRow: State<LaunchItemsViewModel.Row?>

    private var pendingRow: LaunchItemsViewModel.Row? {
        get { _pendingRow.wrappedValue }
        nonmutating set { _pendingRow.wrappedValue = newValue }
    }

    init(vm: LaunchItemsViewModel) {
        self.vm = vm
        _pendingRow = State(wrappedValue: nil)
    }

    var body: some View {
        listContent
            .navigationTitle(loc("launch.title"))
            .task { await vm.load() }
            .sheet(isPresented: Binding(get: { vm.lastReport != nil },
                                        set: { if !$0 { vm.dismissReport() } })) {
                if let report = vm.lastReport {
                    CleanReportView(
                        report: report,
                        remainingCount: vm.userRows.count,
                        remainingBytes: 0,
                        onBack: { vm.dismissReport() },
                        onRescan: {
                            vm.dismissReport()
                            Task { await vm.load() }
                        },
                        sourceLabel: loc("report.source.launchItems"))
                }
            }
    }

    private var listContent: some View {
        List {
            Section(loc("launch.user")) {
                if vm.userRows.isEmpty {
                    Text(loc("launch.empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(vm.userRows) { row in
                        userRow(row)
                    }
                }
            }
            Section {
                if vm.systemItems.isEmpty {
                    Text(loc("launch.empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(vm.systemItems) { item in
                        systemRow(item)
                    }
                }
            } header: {
                Text(loc("launch.system"))
            } footer: {
                Text(loc("launch.system.hint"))
            }
            if let error = vm.lastError {
                Section {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
        .sheet(item: _pendingRow.projectedValue) { row in
            LaunchConfirmView(
                row: row,
                onCancel: { pendingRow = nil },
                onConfirm: {
                    pendingRow = nil
                    Task { await vm.disable(row) }
                })
        }
    }

    private func userRow(_ row: LaunchItemsViewModel.Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "power")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                // Label 缺失时退回文件名,列表永远有可读主标题。
                Text(row.item.label ?? row.item.fileName)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.item.fileName)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if row.item.parseFailed { tag(loc("launch.parsefailed")) }
                    if row.item.runAtLoad { tag(loc("launch.tag.runatload")) }
                    if row.item.keepAlive { tag(loc("launch.tag.keepalive")) }
                    if row.item.disabled { tag(loc("launch.tag.disabled")) }
                    if row.denied { tag(loc("launch.protected")) }
                }
            }
            Spacer(minLength: 8)
            if row.denied {
                Button(loc("launch.exclude")) { vm.exclude(row) }
                    .controlSize(.small)
            }
            Button(loc("launch.disable")) { pendingRow = row }
                .controlSize(.small)
                .disabled(row.denied)
        }
        .padding(.vertical, 2)
    }

    private func systemRow(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label ?? item.fileName)
                    .lineLimit(1).truncationMode(.middle)
                Text(item.fileName)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
