import SwiftUI
import AppKit
import AppCore
import MenuBarKit
import MonitorKit

/// 菜单栏下拉面板:指标概览 + 只读快捷入口。
/// 安全边界:面板只做导航与系统设置跳转,不提供任何清理/删除动作。
struct MenuBarPanelView: View {
    let vm: MenuBarMonitorViewModel
    let navigation: NavigationModel

    // 本机 CLT 工具链缺 SwiftUI 宏插件,手写 @Environment/@State 展开。
    // macOS 14 起 openSettings 可由 Environment 提供,无需外部注入闭包。
    private var _openSettings: Environment<OpenSettingsAction>
    private var _openWindow: Environment<OpenWindowAction>

    private var openSettings: OpenSettingsAction { _openSettings.wrappedValue }
    private var openWindow: OpenWindowAction { _openWindow.wrappedValue }

    init(vm: MenuBarMonitorViewModel, navigation: NavigationModel) {
        self.vm = vm
        self.navigation = navigation
        _openSettings = Environment(\.openSettings)
        _openWindow = Environment(\.openWindow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(loc("menubar.panel.metric"), selection: metricBinding) {
                ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                    Text(loc("menubar.metric.\(metric.rawValue)")).tag(metric)
                }
            }
            .pickerStyle(.menu)

            Divider()

            diskSection
            memorySection
            cpuSection
            batterySection
            networkSection

            Divider()

            Text(loc("menubar.panel.quickActions"))
                .font(.caption)
                .foregroundStyle(.secondary)
            quickActions
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { vm.refreshNow() }
    }

    private var metricBinding: Binding<MenuBarMetric> {
        Binding(get: { vm.preferences.metric },
                set: { vm.setMetric($0) })
    }

    // MARK: - 指标

    @ViewBuilder
    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(loc("menubar.metric.disk"), icon: "internaldrive")
            if let volume = vm.snapshot.diskVolume {
                HStack {
                    Text("\(byteText(volume.availableBytes)) / \(byteText(volume.totalBytes))")
                        .font(.callout)
                    Spacer()
                    Text(volume.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ProgressView(value: Double(volume.totalBytes - volume.availableBytes),
                             total: Double(max(volume.totalBytes, 1)))
                    // 与填充同口径(已用比):VoiceOver 念出的数字必须和条长一致。
                    .accessibilityLabel(loc("menubar.panel.disk.accessibility",
                                            percentText(usedPercent(volume))))
                // 与五期磁盘卡口径一致:无可清除空间时不占一行。
                if volume.purgeableBytes > 0 {
                    Text(loc("monitor.disk.purgeable", byteText(volume.purgeableBytes)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                unavailable
            }
        }
    }

    /// 已用占比(0...100),与 ProgressView 填充同一公式;total ≤ 0 按 0 计,不产生除零。
    private func usedPercent(_ volume: VolumeInfo) -> Double {
        Double(max(0, volume.totalBytes - volume.availableBytes))
            / Double(max(volume.totalBytes, 1)) * 100
    }

    @ViewBuilder
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(loc("menubar.metric.memory"), icon: "memorychip")
            if let memory = vm.snapshot.memory {
                ProgressView(value: Double(memory.usedBytes),
                             total: Double(max(memory.totalBytes, 1)))
                    // 与五期内存卡同一标签键。
                    .accessibilityLabel(loc("monitor.memory.used"))
                Text("\(byteText(memory.usedBytes)) / \(byteText(memory.totalBytes))")
                    .font(.callout)
                HStack(alignment: .top, spacing: 14) {
                    stat(loc("monitor.memory.compressed"), byteText(memory.compressedBytes))
                    stat(loc("monitor.memory.wired"), byteText(memory.wiredBytes))
                    stat(loc("monitor.memory.purgeable"), byteText(memory.purgeableFreeBytes))
                }
            } else {
                unavailable
            }
        }
    }

    @ViewBuilder
    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(loc("menubar.metric.cpu"), icon: "cpu")
            if let cpu = vm.snapshot.cpu {
                // 60 点环形历史逐点推进(与五期 MonitorHomeView 同映射口径);
                // snapshot.cpu 出点 ⇔ 历史入点,故此处非 nil 时序列至少 1 个。
                SparklineView(values: vm.cpuHistory.map { $0.userPct + $0.systemPct },
                              tint: .accentColor)
                    .frame(height: 30)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(percentText(cpu.userPct + cpu.systemPct))
                        .font(.title3)
                        .monospacedDigit()
                    Spacer()
                    stat(loc("monitor.cpu.user"), percentText(cpu.userPct))
                    stat(loc("monitor.cpu.system"), percentText(cpu.systemPct))
                }
            } else {
                Text(loc("monitor.cpu.pending"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(loc("menubar.metric.battery"), icon: "battery.100")
            if let battery = vm.snapshot.battery {
                if battery.hasBattery {
                    HStack(spacing: 8) {
                        Image(systemName: battery.charging ? "battery.100.bolt" : "battery.100")
                        Text(batteryTitle(battery))
                        Spacer()
                        Text(percentText(battery.percentage))
                            .monospacedDigit()
                    }
                    .font(.callout)
                } else {
                    // 台式机/无电池机型:hasBattery=false 是有效数据,按外接电源展示。
                    Label(loc("monitor.battery.external"), systemImage: "powerplug")
                        .font(.callout)
                }
            } else {
                unavailable
            }
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle(loc("menubar.metric.network"), icon: "wifi")
            if let network = vm.snapshot.network {
                // 在线/离线标题与图标共用共享 helper,与标签、监控页同口径。
                Label(interfaceTitle(network), systemImage: interfaceIcon(network))
                    .font(.callout)
                // 与磁盘节 purgeable 同口径:流量未采集(首拍前)不占行。
                if let traffic = vm.snapshot.traffic {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("↓ \(rateText(traffic.receivedBPS)) ↑ \(rateText(traffic.sentBPS))")
                            .font(.callout)
                            .monospacedDigit()
                        Text(loc("menubar.panel.network.totals",
                                 byteText(traffic.receivedBytes), byteText(traffic.sentBytes)))
                            .font(.callout)
                    }
                    // 合并朗读:速率行与累计行合为一个元素(标题→速率→累计顺序不变);接口标题仍在独立元素。
                    .accessibilityElement(children: .combine)
                }
            } else {
                unavailable
            }
        }
    }

    // MARK: - 快捷入口

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            quickButton(loc("menubar.action.openMain"), icon: "macwindow") { go(.mainWindow) }
            quickButton(loc("module.cleanup"), icon: "sparkles") { go(.cleanup) }
            quickButton(loc("module.uninstall"), icon: "shippingbox") { go(.uninstall) }
            quickButton(loc("module.aiCleanup"), icon: "brain") { go(.aiCleanup) }
            quickButton(loc("module.diskAnalysis"), icon: "chart.pie.fill") { go(.diskAnalysis) }
            quickButton(loc("monitor.tools.launchitems"), icon: "power") { go(.launchItems) }
            quickButton(loc("settings.title"), icon: "gearshape") { go(.settings) }
            quickButton(loc("menubar.action.quit"), icon: "xmark.circle") {
                // 退出是唯一不走窗口导航的入口。
                NSApp.terminate(nil)
            }
        }
    }

    /// 只读导航:先切换主窗口的模块选择,再确保窗口可见并置前。
    /// 不触发任何扫描或清理,用户仍需在主窗口中自行确认操作。
    private func go(_ destination: QuickDestination) {
        switch destination {
        case .mainWindow:
            break
        case .cleanup:
            navigation.selection = .cleanup
        case .uninstall:
            navigation.selection = .uninstall
        case .aiCleanup:
            navigation.selection = .aiCleanup
        case .diskAnalysis:
            navigation.selection = .diskAnalysis
        case .launchItems:
            navigation.selection = .monitor
            navigation.openLaunchItems = true
        case .settings:
            openSettings()
            return
        }
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 小组件

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .monospacedDigit()
        }
    }

    private var unavailable: some View {
        Text(loc("monitor.unavailable"))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func quickButton(_ title: String, icon: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func batteryTitle(_ battery: BatteryInfo) -> String {
        if battery.charging { return loc("monitor.battery.charging") }
        if battery.onBattery { return loc("monitor.battery.onbattery") }
        return loc("monitor.battery.external")
    }
}
