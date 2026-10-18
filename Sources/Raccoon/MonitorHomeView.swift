import SwiftUI
import Network
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
    let onNavigate: (Module) -> Void

    private var _scenePhase: Environment<ScenePhase>
    private var _facts: State<ProbeFacts>
    private var _networkObserver: State<NetworkPathObserver>
    // 启动项子页是 monitor 的栈内子导航(建议卡与工具区共用同一入口)。
    private var _showLaunchItems: State<Bool>

    private var scenePhase: ScenePhase { _scenePhase.wrappedValue }
    private var facts: ProbeFacts {
        get { _facts.wrappedValue }
        nonmutating set { _facts.wrappedValue = newValue }
    }
    private var networkObserver: NetworkPathObserver { _networkObserver.wrappedValue }
    private var showLaunchItems: Bool {
        get { _showLaunchItems.wrappedValue }
        nonmutating set { _showLaunchItems.wrappedValue = newValue }
    }

    init(vm: MonitorViewModel, launchItemsVM: LaunchItemsViewModel,
         onNavigate: @escaping (Module) -> Void) {
        self.vm = vm
        self.launchItemsVM = launchItemsVM
        self.onNavigate = onNavigate
        _scenePhase = Environment(\.scenePhase)
        _facts = State(wrappedValue: ProbeFacts())
        _networkObserver = State(wrappedValue: NetworkPathObserver())
        _showLaunchItems = State(wrappedValue: false)
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
            .navigationDestination(isPresented: Binding(get: { showLaunchItems },
                                                        set: { showLaunchItems = $0 })) {
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
            let primaryIndex = volumes.firstIndex(where: \.isSystemDisk) ?? 0
            let primary = volumes[primaryIndex]
            let others = volumes.enumerated()
                .filter { $0.offset != primaryIndex }
                .map(\.element)
            VStack(alignment: .leading, spacing: 12) {
                SystemDiskCard(volume: primary)
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
                           detail: "\(Int(battery.percentage.rounded()))%")
            } else {
                // 台式机 / 无电池机型:hasBattery=false 本身就是有效数据,显示外接电源
                StatusCard(icon: "powerplug", title: loc("monitor.battery.external"), detail: nil)
            }
        } else {
            StatusCard(icon: "powerplug", title: loc("monitor.unavailable"), detail: nil)
        }
    }

    @ViewBuilder
    private var networkCard: some View {
        if let network = vm.network {
            if network.online {
                StatusCard(icon: networkIcon(network.interface),
                           title: networkTitle(network.interface),
                           detail: nil)
            } else {
                StatusCard(icon: "wifi.slash", title: loc("monitor.network.offline"), detail: nil)
            }
        } else {
            StatusCard(icon: "network", title: loc("monitor.unavailable"), detail: nil)
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
            showLaunchItems = true
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
                    showLaunchItems = true
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
            Text("\(Int(percent.rounded()))%").font(.callout).monospacedDigit()
        }
    }

    private func networkTitle(_ interface: NetworkInterface) -> String {
        switch interface {
        case .wifi: loc("monitor.network.wifi")
        case .wired: loc("monitor.network.wired")
        case .other: loc("monitor.network.other")
        }
    }

    private func networkIcon(_ interface: NetworkInterface) -> String {
        switch interface {
        case .wifi: "wifi"
        case .wired: "cable.connector"
        case .other: "network"
        }
    }
}

// MARK: - 探针快照

private struct ProbeFacts: Equatable {
    var hasSnapshots = false
    var userLaunchAgentCount = 0
    var crashReportCount = 0
}

// MARK: - NWPathMonitor 桥

/// 事件驱动监听:`NWPathMonitor` 回调在后台队列,组装成 `NetworkStatus` 后
/// 切回主 actor 交给 VM。`cancel()` 后实例不可复用(Apple 文档),故每次 start 新建。
/// 锁保护 monitor 的创建/取消与跨队列可见性;类本身无隔离,可在 View init 中构造。
private final class NetworkPathObserver: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.raccoon.monitor.network-path")
    private var monitor: NWPathMonitor?

    func start(onUpdate: @escaping @MainActor @Sendable (NetworkStatus) -> Void) {
        lock.lock()
        if monitor != nil {
            lock.unlock()
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        lock.unlock()

        monitor.pathUpdateHandler = { path in
            let status = assembleNetworkStatus(
                satisfied: path.status == .satisfied,
                isWiFi: path.usesInterfaceType(.wifi),
                isWired: path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                onUpdate(status)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
    }
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

    private var usedBytes: Int64 { max(0, volume.totalBytes - volume.availableBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc("monitor.disk.system"), systemImage: "internaldrive")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(volume.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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
