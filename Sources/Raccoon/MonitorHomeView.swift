import SwiftUI
import AppCore
import MonitorKit
import CleanKit
import LaunchKit

/// 五期「状态监控」首页:只读仪表盘。
/// 指标网格(系统盘大卡 + 其他卷小卡 + 内存 + CPU + 电池/网络)→ 建议卡(空数组整体隐藏)
/// → 优化工具入口。单指标取不到只在该卡显示「暂不可用」,不拖垮整页。
///
/// 本机 CLT 工具链缺 SwiftUI 宏插件:所有 `@State`/`@Environment` 均手写展开,
/// 沿 RootView 的 `_name: State<T>` 写法。
struct MonitorHomeView: View {
    let vm: MonitorViewModel
    let launchItemsVM: LaunchItemsViewModel
    let navigation: NavigationModel
    let onNavigate: (Module) -> Void

    private var _scenePhase: Environment<ScenePhase>
    private var _facts: State<ProbeFacts>
    private var _networkObserver: State<NetworkPathWatcher>

    private var scenePhase: ScenePhase { _scenePhase.wrappedValue }
    private var facts: ProbeFacts {
        get { _facts.wrappedValue }
        nonmutating set { _facts.wrappedValue = newValue }
    }
    private var networkObserver: NetworkPathWatcher { _networkObserver.wrappedValue }

    init(vm: MonitorViewModel, launchItemsVM: LaunchItemsViewModel,
         navigation: NavigationModel,
         onNavigate: @escaping (Module) -> Void) {
        self.vm = vm
        self.launchItemsVM = launchItemsVM
        self.navigation = navigation
        self.onNavigate = onNavigate
        _scenePhase = Environment(\.scenePhase)
        _facts = State(wrappedValue: ProbeFacts())
        _networkObserver = State(wrappedValue: NetworkPathWatcher())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    metricsSection
                    suggestionsSection
                    toolsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(loc("monitor.title"))
            // 启动项子页是 monitor 的栈内子导航(建议卡与工具区共用同一入口);
            // 状态上提到 NavigationModel,菜单栏等外部入口也能直接打开。
            .navigationDestination(isPresented: Binding(
                get: { navigation.openLaunchItems },
                set: { navigation.openLaunchItems = $0 })) {
                LaunchItemsView(vm: launchItemsVM)
            }
        }
        .task {
            vm.start()
            // 首帧若不在前台(极少见),先按当前 scenePhase 校正,后续由 onChange 接管
            vm.setActive(scenePhase == .active)
            networkObserver.start { status in
                vm.setNetwork(status)
            }
            await probeSuggestionsFacts()
        }
        .onDisappear {
            // NWPathMonitor.cancel() 不可复用;下次 .task 会重建(见 observer 实现)。
            // 轮询循环不是 .task 的子任务,必须显式停:VM 由 RootView 长期持有,
            // 不停则离开本页后仍会 2s/30s 采样。数据保留,返回时 start() 自动重启。
            networkObserver.cancel()
            vm.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            vm.setActive(phase == .active)
        }
    }

    // MARK: - 指标网格

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            diskSection
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                memoryCard
                cpuCard
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                batteryCard
                networkCard
            }
        }
    }

    /// 系统盘大卡 + 其他卷小卡。卷列表为 nil/空(慢频首轮未完成或采集失败)时只显示降级卡。
    @ViewBuilder
    private var diskSection: some View {
        let volumes = vm.volumes ?? []
        if volumes.isEmpty {
            UnavailableCard(title: loc("monitor.disk.system"), icon: "internaldrive")
        } else {
            // 没有任何卷被判定为系统盘时不把首卷硬当系统盘:仍展示首卷,但不贴标识。
            let systemIndex = volumes.firstIndex(where: \.isSystemDisk)
            let primaryIndex = systemIndex ?? 0
            let primary = volumes[primaryIndex]
            let others = volumes.enumerated()
                .filter { $0.offset != primaryIndex }
                .map(\.element)
            VStack(alignment: .leading, spacing: 12) {
                SystemDiskCard(volume: primary,
                               title: systemIndex == nil ? nil : loc("monitor.disk.system"))
                if !others.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(Array(others.enumerated()), id: \.offset) { _, volume in
                            VolumeCard(volume: volume)
                        }
                    }
                }
            }
        }
    }

    private var memoryCard: some View {
        MetricCard(title: loc("monitor.memory.title"), icon: "memorychip") {
            if let memory = vm.memory {
                ProgressView(value: Double(memory.usedBytes),
                             total: Double(max(memory.totalBytes, 1)))
                    .accessibilityLabel(loc("monitor.memory.used"))
                metricRow(loc("monitor.memory.used"),
                          "\(byteText(memory.usedBytes)) / \(byteText(memory.totalBytes))")
                metricRow(loc("monitor.memory.compressed"), byteText(memory.compressedBytes))
                metricRow(loc("monitor.memory.wired"), byteText(memory.wiredBytes))
                metricRow(loc("monitor.memory.purgeable"), byteText(memory.purgeableFreeBytes))
            } else {
                Text(loc("monitor.unavailable")).foregroundStyle(.secondary)
            }
        }
    }

    private var cpuCard: some View {
        MetricCard(title: loc("monitor.cpu.title"), icon: "cpu") {
            let history = vm.cpuHistory
            if let latest = history.last {
                SparklineView(values: history.map { $0.userPct + $0.systemPct },
                              tint: .accentColor)
                    .frame(height: 44)
                HStack(spacing: 16) {
                    cpuValue(loc("monitor.cpu.user"), latest.userPct)
                    cpuValue(loc("monitor.cpu.system"), latest.systemPct)
                    cpuValue(loc("monitor.cpu.idle"), latest.idlePct)
                }
            } else if vm.cpuUnavailable {
                Text(loc("monitor.unavailable")).foregroundStyle(.secondary)
            } else {
                Text(loc("monitor.cpu.pending")).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var batteryCard: some View {
        if let battery = vm.battery {
            if battery.hasBattery {
                let title = battery.charging
                    ? loc("monitor.battery.charging")
                    : (battery.onBattery ? loc("monitor.battery.onbattery")
                                         : loc("monitor.battery.external"))
                let icon = battery.charging ? "battery.100.bolt" : "battery.100"
                StatusCard(icon: icon,
                           title: title,
                           // assembleBatteryInfo 已夹取到 0...100,percentText 显示无变化。
                           detail: percentText(battery.percentage))
            } else {
                // 台式机 / 无电池机型:hasBattery=false 本身就是有效数据,显示外接电源
                StatusCard(icon: "powerplug", title: loc("monitor.battery.external"), detail: nil)
            }
        } else {
            StatusCard(icon: "powerplug", title: loc("monitor.unavailable"), detail: nil)
        }
    }

    private var networkCard: some View {
        MetricCard(title: loc("monitor.network.title"), icon: interfaceIcon(vm.network)) {
            // 标题/图标映射共享 interfaceTitle/interfaceIcon:
            // nil → 「暂不可用」+ network,离线 → 「离线」+ wifi.slash,与原分支语义一致。
            Label(interfaceTitle(vm.network), systemImage: interfaceIcon(vm.network))
                .font(.callout)
            // 与面板速率行同款:流量未采集(首拍/失败拍)时速率与累计整体不占行,
            // 状态行照常在(单指标失败隔离,与内存卡口径一致)。
            if let traffic = vm.traffic {
                Text("↓ \(rateText(traffic.receivedBPS)) ↑ \(rateText(traffic.sentBPS))")
                    .font(.callout)
                    .monospacedDigit()
                metricRow(loc("monitor.network.received"), byteText(traffic.receivedBytes))
                metricRow(loc("monitor.network.sent"), byteText(traffic.sentBytes))
            }
        }
    }

    // MARK: - 建议卡

    /// 无命中时整体隐藏(spec §5.2:不显示「一切正常」占位)。
    @ViewBuilder
    private var suggestionsSection: some View {
        let items = suggestionItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items, id: \.id) { suggestion in
                    Button {
                        open(suggestion.destination)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: suggestionIcon(suggestion.id))
                                .foregroundStyle(.tint)
                                .frame(width: 20)
                            Text(loc("monitor.suggest.\(suggestion.id)"))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .cardChrome()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var suggestionItems: [Suggestion] {
        let volumes = vm.volumes ?? []
        let minFreeFraction = volumes.map { volume -> Double in
            guard volume.totalBytes > 0 else { return 1 }
            return Double(volume.availableBytes) / Double(volume.totalBytes)
        }.min() ?? 1
        // 无卷数据时取最大字节,避免「取不到数据」被误判为磁盘告急
        let minFreeBytes = volumes.map(\.availableBytes).min() ?? Int64.max
        return suggestions(for: SuggestionsInput(
            minVolumeFreeFraction: minFreeFraction,
            minVolumeFreeBytes: minFreeBytes,
            hasSnapshots: facts.hasSnapshots,
            userLaunchAgentCount: facts.userLaunchAgentCount,
            crashReportCount: facts.crashReportCount))
    }

    private func open(_ destination: SuggestionDestination) {
        switch destination {
        case .diskAnalysis:
            onNavigate(.diskAnalysis)
        case .cleanup:
            onNavigate(.cleanup)
        case .launchItems:
            navigation.openLaunchItems = true
        }
    }

    private func suggestionIcon(_ id: String) -> String {
        switch id {
        case "disk": "internaldrive"
        case "snapshots": "clock.arrow.circlepath"
        case "launchitems": "power"
        case "crashreports": "exclamationmark.triangle"
        default: "lightbulb"
        }
    }

    // MARK: - 优化工具

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(loc("monitor.tools.title"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 12) {
                toolButton(icon: "power", title: loc("monitor.tools.launchitems")) {
                    navigation.openLaunchItems = true
                }
                // 快照与系统垃圾都落在清理模块(同一页内的对应清理项)。
                toolButton(icon: "clock.arrow.circlepath",
                           title: loc("monitor.tools.snapshots")) {
                    onNavigate(.cleanup)
                }
                toolButton(icon: "trash", title: loc("monitor.tools.crashreports")) {
                    onNavigate(.cleanup)
                }
            }
        }
    }

    private func toolButton(icon: String, title: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - 探针

    /// 三个建议探针:快照存在性(async)、用户 LaunchAgents 数、崩溃报告数。
    /// 在 `.task` 里取一次;失败/目录缺失一律按「无」处理(探针不打断页面)。
    private func probeSuggestionsFacts() async {
        let snapshots = await TmutilSnapshotCleaner().listSnapshots()
        let launchAgentCount = LaunchItemScanner().scan().userItems.count
        facts = ProbeFacts(hasSnapshots: !snapshots.isEmpty,
                           userLaunchAgentCount: launchAgentCount,
                           crashReportCount: Self.crashReportCount())
    }

    private static func crashReportCount() -> Int {
        let path = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }
        return (try? fm.contentsOfDirectory(atPath: path).count) ?? 0
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.callout).monospacedDigit()
        }
    }

    private func cpuValue(_ label: String, _ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            // 共享 percentText(夹取口径);合法 CPU 占比本就在 0...100,显示无变化。
            Text(percentText(percent)).font(.callout).monospacedDigit()
        }
    }
}

// MARK: - 探针快照

private struct ProbeFacts: Equatable {
    var hasSnapshots = false
    var userLaunchAgentCount = 0
    var crashReportCount = 0
}

// MARK: - 卡片

/// 指标卡:标题 + 内容,统一深浅色卡片底色与描边。
private struct MetricCard<Content: View>: View {
    let title: String
    let icon: String
    let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .cardChrome()
    }
}

/// 状态卡(电池/网络):图标 + 主文案 + 可选副文案,不设标题行。
private struct StatusCard: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .cardChrome()
        .accessibilityElement(children: .combine)
    }
}

private struct SystemDiskCard: View {
    let volume: VolumeInfo
    /// nil = 无卷可判定为系统盘:标题退化为卷名,不误标「系统盘」。
    let title: String?

    private var usedBytes: Int64 { max(0, volume.totalBytes - volume.availableBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title ?? volume.name, systemImage: "internaldrive")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if title != nil {
                Text(volume.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(byteText(volume.availableBytes))
                    .font(.title2).bold().monospacedDigit()
                Text("/ \(byteText(volume.totalBytes))")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: Double(usedBytes),
                         total: Double(max(volume.totalBytes, 1)))
            if volume.purgeableBytes > 0 {
                Text(loc("monitor.disk.purgeable", byteText(volume.purgeableBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .cardChrome()
        .accessibilityElement(children: .combine)
    }
}

private struct VolumeCard: View {
    let volume: VolumeInfo

    private var usedBytes: Int64 { max(0, volume.totalBytes - volume.availableBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(volume.name, systemImage: "externaldrive")
                .font(.subheadline)
                .lineLimit(1)
            Text(byteText(volume.availableBytes))
                .font(.headline).monospacedDigit()
            ProgressView(value: Double(usedBytes),
                         total: Double(max(volume.totalBytes, 1)))
            if volume.purgeableBytes > 0 {
                Text(loc("monitor.disk.purgeable", byteText(volume.purgeableBytes)))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .cardChrome()
        .accessibilityElement(children: .combine)
    }
}

private struct UnavailableCard: View {
    let title: String
    let icon: String

    var body: some View {
        MetricCard(title: title, icon: icon) {
            Text(loc("monitor.unavailable")).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 卡片外观

private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5))
            )
    }
}

private extension View {
    func cardChrome() -> some View {
        modifier(CardChrome())
    }
}
