import SwiftUI
import AppCore
import MonitorKit

/// 菜单栏常驻标签:只渲染图标与数值,不承载任何操作入口。
/// 纯 View 按 `vm.label`(=偏好 + 快照的格式化结果)绘制,避免在此重复计算口径。
struct MenuBarLabelView: View {
    let vm: MenuBarMonitorViewModel

    // 本机 CLT 工具链缺 SwiftUI 宏插件,手写 @State 展开(见 RaccoonApp.swift)。
    private var _networkWatcher: State<NetworkPathWatcher>

    private var networkWatcher: NetworkPathWatcher { _networkWatcher.wrappedValue }

    init(vm: MenuBarMonitorViewModel) {
        self.vm = vm
        _networkWatcher = State(wrappedValue: NetworkPathWatcher())
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if let text = displayText {
                Text(text)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityText)
        .task {
            vm.start()
            // 菜单栏是常驻视图:网络状态在此订阅一次,指标与下拉面板共用同一快照。
            networkWatcher.start { status in
                vm.setNetwork(status)
            }
        }
        .onDisappear {
            // 与监控页同一语义:离开即停,重新出现时 start 会重建 monitor。
            networkWatcher.cancel()
        }
    }

    private var iconName: String {
        switch vm.preferences.metric {
        case .disk: "internaldrive"
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .network: "wifi"
        }
    }

    /// 无数据时的占位只在「图标 + 数值」样式下显示;纯图标样式保持空白。
    private var placeholder: String? {
        vm.preferences.iconStyle == .iconAndValue ? "—" : nil
    }

    private var displayText: String? {
        switch vm.label {
        case .percent(let value):
            return "\(value)%"
        case .network(let status):
            // 在线/离线的标题映射与监控页、下拉面板共用同一 helper。
            guard let status else { return placeholder }
            return interfaceTitle(status)
        case .none:
            return placeholder
        }
    }

    private var accessibilityText: String {
        let metric = loc("menubar.metric.\(vm.preferences.metric.rawValue)")
        // 「—」不是可读数值,无障碍只播报指标名。
        if let value = displayText, value != "—" {
            return loc("menubar.label.accessibility", "\(metric) \(value)")
        }
        return loc("menubar.label.accessibility", metric)
    }
}
