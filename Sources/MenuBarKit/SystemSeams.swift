/// 登录项状态。`requiresApproval` 表示系统已登记但用户尚未在设置中批准,
/// 调用方据此引导而非重复注册。
public enum LoginItemStatus: Equatable, Sendable {
    case disabled, enabled, requiresApproval, unavailable
}

/// 登录项管理抽象。真实实现依赖 ServiceManagement,放在 App 层;
/// MenuBarKit 只保留协议,便于测试替换且不引入系统副作用。
public protocol LoginItemManaging: Sendable {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

/// 通知发送抽象。授权与发送均为异步,实现方不得吞掉授权失败。
public protocol Notifying: Sendable {
    func requestAuthorization() async -> Bool
    func post(_ kind: NotificationKind) async
}
