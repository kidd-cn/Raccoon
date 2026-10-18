import Foundation

/// 菜单栏快捷入口的导航意图。纯数据枚举,不含行为——
/// 具体如何跳转由应用层(六期 Task 7 的面板)决定,避免 MenuBarKit 依赖 UI。
public enum QuickDestination: String, CaseIterable, Sendable {
    case mainWindow
    case cleanup
    case uninstall
    case aiCleanup
    case diskAnalysis
    case launchItems
    case settings
}
