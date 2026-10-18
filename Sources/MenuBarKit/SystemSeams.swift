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
    /// 返回 false 表示未获授权;「用户拒绝」与「请求失败」只有 Bool 通道,不可区分。
    /// 调用方文案应表述为「无法获得通知权限」,不要断言用户拒绝;
    /// 尚未请求(nil)须与 false 分开展示。
    func requestAuthorization() async -> Bool
    func post(_ kind: NotificationKind) async
}
