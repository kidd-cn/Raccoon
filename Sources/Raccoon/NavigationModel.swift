import Observation

/// 应用级导航状态。主窗口(侧边栏选择)与菜单栏面板共用一个实例,
/// 菜单栏据此把选择切换到指定模块;引用类型故由调用方持有并注入。
@MainActor
@Observable
final class NavigationModel {
    var selection: Module = .cleanup
    /// Monitor 模块内的启动项子页是否打开(栈内导航,不是侧边栏模块)。
    var openLaunchItems: Bool = false
}
