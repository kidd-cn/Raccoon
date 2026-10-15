import SwiftUI
import ScanKit
import AppCore

struct CleanupHomeView: View {
    @Bindable var vm: ScanViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle: idleView
                case .scanning: scanningView
                case .completed: completedView
                case .cleaning:
                    ProgressView(loc("common.clean"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .report(let report): ReportView(report: report, vm: vm)
                case .failed(let message): failedView(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.cleanup"))
        }
    }

    var idleView: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(loc("home.startHint"))
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

    var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(loc("home.scanning", vm.progress.rulesDone, vm.progress.rulesTotal))
                .foregroundStyle(.secondary)
            Text(loc("home.found", byteText(vm.progress.bytesFound)))
                .font(.title3).bold().monospacedDigit()
            Button(loc("common.cancel")) { vm.cancelScan() }
            Text(loc("home.cancelHint")).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    var completedView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                ForEach(vm.summaries) { summary in
                    CategoryCardView(summary: summary)
                        .contentShape(Rectangle())
                        .onTapGesture { vm.categoryInFocus = summary.category }
                }
            }
            .padding(.bottom, 12)
            footerNotes
        }
        // 明细导航用 item: 而非 NavigationLink:用户 pop 时自动写回 nil;
        // 但若目标页在栈上时本视图因 phase 切换离开层级,写回无契约保证——
        // 故 startScan/dismissReport 一并复位 categoryInFocus(双保险)。
        .navigationDestination(item: $vm.categoryInFocus) { category in
            DetailListView(vm: vm, category: category)
        }
    }

    var footerNotes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.permissionSkippedCount > 0 {
                Text(loc("home.permissionSkipped", vm.permissionSkippedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !vm.truncatedRuleIDs.isEmpty {
                Text(loc("home.partialScan", vm.truncatedRuleIDs.sorted().joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if vm.excludedCount > 0 {
                Text(loc("home.excludedNote", vm.excludedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct CategoryCardView: View {
    let summary: CategorySummary

    var isCautious: Bool { summary.category == .cautious }
    var icon: String {
        switch summary.category {
        case .system: "trash"
        case .dev: "hammer"
        case .apps: "app.badge"
        case .cautious: "exclamationmark.shield"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(loc("category.\(summary.category.rawValue)"), systemImage: icon)
                .font(.headline)
                .foregroundStyle(isCautious ? Color.orange : Color.primary)
            Text(byteText(summary.totalBytes))
                .font(.title2).bold().monospacedDigit()
            Text(loc("category.items", summary.hitCount))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(isCautious ? Color.orange.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isCautious ? Color.orange.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.5))
        )
    }
}
