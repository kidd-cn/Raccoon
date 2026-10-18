import SwiftUI
import AppCore
import LaunchKit
import CleanKit

/// 启动项管理子页:用户级可禁用/排除,系统级只读。
/// 删除只进废纸篓;禁用前一律经确认弹窗(默认键为取消),成功后展示报告并重扫列表。
///
/// 确认与报告共用一个 `.sheet(item:)` 状态机:禁用完成后从确认态原地切到报告态,
/// 不会出现「一个 sheet 正在关闭、另一个 sheet 试图呈现」而被系统吞掉的竞态。
///
/// 本机 CLT 工具链缺 SwiftUI 宏插件:`@State` 手写展开(见 RootView 注释)。
struct LaunchItemsView: View {
    let vm: LaunchItemsViewModel

    private enum Presentation: Identifiable {
        case confirm(LaunchItemsViewModel.Row)
        case report(CleanReport)

        var id: String {
            switch self {
            case .confirm(let row):
                "confirm-\(row.id)"
            case .report(let report):
                "report-\(report.date.timeIntervalSince1970)-\(report.trashedCount)"
            }
        }
    }

    private var _presentation: State<Presentation?>

    private var presentation: Presentation? {
        get { _presentation.wrappedValue }
        nonmutating set { _presentation.wrappedValue = newValue }
    }

    init(vm: LaunchItemsViewModel) {
        self.vm = vm
        _presentation = State(wrappedValue: nil)
    }

    var body: some View {
        listContent
            .navigationTitle(loc("launch.title"))
            .task { await vm.load() }
            .sheet(item: _presentation.projectedValue) { item in
                switch item {
                case .confirm(let row):
                    LaunchConfirmView(
                        row: row,
                        isBusy: vm.isDisabling,
                        onCancel: { presentation = nil },
                        onConfirm: { confirm(row) })
                case .report(let report):
                    CleanReportView(
                        report: report,
                        remainingCount: vm.userRows.count,
                        remainingBytes: 0,
                        onBack: { closeReport() },
                        onRescan: {
                            closeReport()
                            Task { await vm.load() }
                        },
                        sourceLabel: loc("report.source.launchItems"))
                }
            }
    }

    /// 确认后不先关 sheet:禁用期间确认卡片保持可见并显示进度/禁用按钮;
    /// 完成后同一 sheet 切换到报告态(失败则关闭,页面显示可读原因)。
    private func confirm(_ row: LaunchItemsViewModel.Row) {
        // 双击排队时第二次必须原地返回,不得在第一次在飞期间把 sheet 关掉再重开。
        guard !vm.isDisabling else { return }
        Task {
            // disable 返回 false(被守卫挡下/前一刻变成受保护):保持当前 sheet 状态不动。
            guard await vm.disable(row) else { return }
            if let report = vm.lastReport {
                presentation = .report(report)
            } else {
                presentation = nil
            }
        }
    }

    private func closeReport() {
        presentation = nil
        vm.dismissReport()
    }

    private var listContent: some View {
        List {
            Section {
                if !vm.hasLoaded {
                    // 首轮扫描是同步枚举,通常一帧内完成;未完成前不渲染空态,避免闪烁。
                    ProgressView().controlSize(.small)
                } else if vm.userRows.isEmpty {
                    Text(loc("launch.empty")).foregroundStyle(.secondary)
                } else {
                    ForEach(vm.userRows) { row in
                        userRow(row)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(loc("launch.user"))
                    if vm.isDisabling {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            if vm.hasLoaded {
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
            }
            if let error = vm.lastError {
                Section {
                    Text(loc("launch.failed", reasonText(error)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    private func userRow(_ row: LaunchItemsViewModel.Row) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "power")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
            // 排除入口只对「尚未受保护」的行开放:排除后该行变灰、按钮消失即是反馈;
            // 已 denied 的行再排除不会有任何可见变化,故不显示。
            if !row.denied {
                Button(loc("launch.exclude")) { vm.exclude(row) }
                    .controlSize(.small)
                    .disabled(vm.isDisabling)
            }
            Button(loc("launch.disable")) { presentation = .confirm(row) }
                .controlSize(.small)
                .disabled(row.denied || vm.isDisabling)
        }
        .padding(.vertical, 2)
    }

    private func systemRow(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
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

    /// 内部稳定代码 → 可读文案(与 CleanReportView 同口径,未知代码落到「其他原因」)。
    private func reasonText(_ code: String) -> String {
        let key = "reason.\(code)"
        let value = loc(key)
        return value == key ? loc("reason.other") : value
    }
}
