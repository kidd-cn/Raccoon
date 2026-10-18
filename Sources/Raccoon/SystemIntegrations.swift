import Foundation
import MenuBarKit
import ServiceManagement
import UserNotifications

/// `SMAppService` 的登录项实现。只做系统调用与状态映射,
/// 是否允许注册等策略由调用方决定。
final class SMAppServiceLoginItem: LoginItemManaging, @unchecked Sendable {
    // 无可变状态;系统 API 自身线程安全,故跳过多线程检查。
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            return .disabled
        // 未来新增状态无法安全解释,降级为不可用而不是猜测。
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// 本地通知实现。文案取自 L10n,不携带路径/文件名等敏感信息。
final class UNNotifier: Notifying, @unchecked Sendable {
    // 系统框架线程安全,且本类无自有可变状态。
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> Bool {
        // 拒绝与抛错都等价于「未授权」,返回 false 交由调用方停止发送。
        let granted = try? await center.requestAuthorization(options: [.alert, .sound])
        return granted ?? false
    }

    func post(_ kind: NotificationKind) async {
        let keys: (title: String, body: String)
        switch kind {
        case .lowDisk:
            keys = ("menubar.notify.lowDisk.title", "menubar.notify.lowDisk.body")
        case .highMemory:
            keys = ("menubar.notify.highMemory.title", "menubar.notify.highMemory.body")
        }

        let content = UNMutableNotificationContent()
        content.title = loc(keys.title)
        content.body = loc(keys.body)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        // Notifying 协议无错误通道,失败只能忽略;由系统决定是否可达。
        try? await center.add(request)
    }
}

/// 前台通知代理:应用在前台时默认不展示通知,这里显式保留横幅与声音。
final class RaccoonNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
