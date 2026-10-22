import SwiftUI
import AppCore
import MenuBarKit

/// 设置页「菜单栏」tab:指标/图标样式/开机自启/阈值通知。
/// 只写偏好与跳转系统设置,不执行任何清理动作——与下拉面板同一条安全边界。
/// vm 为 @Observable:class 的字段读取在 body 内自动注册依赖,故 let 转发即可,
/// 无需 @Bindable(与 MenuBarPanelView 口径一致)。
struct MenuBarSettingsPane: View {
    let vm: MenuBarMonitorViewModel

    var body: some View {
        // 说明行按状态条件出现,高度可变;500×340 外框不动,内部滚动兜底。
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker(loc("menubar.panel.metric"), selection: metricBinding) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                        Text(loc("menubar.metric.\(metric.rawValue)")).tag(metric)
                    }
                }
                .pickerStyle(.menu)

                Picker(loc("menubar.settings.iconStyle"), selection: iconStyleBinding) {
                    ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                        Text(iconStyleText(style)).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Divider()

                Toggle(isOn: launchAtLoginBinding) {
                    Text(loc("menubar.settings.launchAtLogin"))
                }
                // 系统已登记但未获批:引导用户去设置批准,不重复注册。
                if vm.loginStatus == .requiresApproval {
                    caption(loc("menubar.settings.requiresApproval"))
                    Button(loc("menubar.settings.openSystemSettings")) {
                        vm.openLoginItemSystemSettings()
                    }
                    .controlSize(.small)
                }
                if vm.loginStatus == .unavailable {
                    caption(loc("menubar.settings.loginUnavailable"))
                }

                Divider()

                Toggle(isOn: notificationsBinding) {
                    Text(loc("menubar.settings.notifications"))
                }
                caption(loc("menubar.settings.notifyHint"))
                // nil(尚未询问)与 false(未获授权)分开处理:仅 false 出引导行。
                // 授权通道只有 Bool,拒绝与失败不可区分,文案据实说「无法获得」。
                if vm.notificationAuthorized == false {
                    caption(loc("menubar.settings.notifyDenied"))
                        .foregroundStyle(.orange)
                }

                HStack {
                    Text(loc("menubar.settings.memoryThreshold"))
                    Spacer()
                    Text("\(memoryPercent)%")
                        .monospacedDigit()
                    // 本 SDK 的 Stepper 无「无标签」初始化器:空标题 + labelsHidden,
                    // 数值由左侧 Text 呈现,避免重复。
                    Stepper("", value: memoryPercentBinding, in: 70...95, step: 5)
                        .labelsHidden()
                }
                // 阈值只在通知开启时有意义;关闭时禁用,避免改不动也说不清。
                .disabled(!vm.preferences.notificationsEnabled)

                if let error = vm.lastError {
                    Text(loc("menubar.settings.error", error))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 绑定

    private var metricBinding: Binding<MenuBarMetric> {
        Binding(get: { vm.preferences.metric },
                set: { vm.setMetric($0) })
    }

    private var iconStyleBinding: Binding<MenuBarIconStyle> {
        Binding(get: { vm.preferences.iconStyle },
                set: { vm.setIconStyle($0) })
    }

    // setLaunchAtLogin 为同步方法:失败时 VM 不写偏好,Toggle 读回旧值自然回弹。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { vm.preferences.launchAtLogin },
                set: { vm.setLaunchAtLogin($0) })
    }

    // 授权是异步的:落回 Task;被拒时 VM 把 notificationsEnabled 存为 false,
    // Toggle 同样回弹,不假装成功。
    private var notificationsBinding: Binding<Bool> {
        Binding(get: { vm.preferences.notificationsEnabled },
                set: { enabled in
                    Task { await vm.setNotificationsEnabled(enabled) }
                })
    }

    // 阈值以 0.70...0.95 存储,UI 用整数百分比编辑;
    // 70...95 与 MenuBarPreferences.memoryThresholdRange 同口径(乘 100 取整受浮点误差影响,故写字面量)。
    private var memoryPercentBinding: Binding<Int> {
        Binding(get: { Int((vm.preferences.memoryThreshold * 100).rounded()) },
                set: { vm.setMemoryThreshold(Double($0) / 100) })
    }

    private var memoryPercent: Int {
        Int((vm.preferences.memoryThreshold * 100).rounded())
    }

    // MARK: - 小组件

    private func iconStyleText(_ style: MenuBarIconStyle) -> String {
        switch style {
        case .iconOnly: return loc("menubar.settings.iconOnly")
        case .iconAndValue: return loc("menubar.settings.iconAndValue")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
