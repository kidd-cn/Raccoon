import SwiftUI
import AppCore
import MenuBarKit
import UserNotifications

@main
struct RaccoonApp: App {
    // 本机工具链(Command Line Tools 6.4 + macOS 27.0 SDK)缺少 SwiftUI 宏插件
    // libSwiftUIMacros.dylib,@State 无法由宏展开;State<Value> 本体仍是
    // @propertyWrapper(见 SwiftUICore 接口),故手写宏的等价展开形态。
    private var _exclusions: State<ExclusionsStore>
    var exclusions: ExclusionsStore {
        get { _exclusions.wrappedValue }
        nonmutating set { _exclusions.wrappedValue = newValue }
    }
    // 导航状态跨 scene(主窗口/菜单栏)共享,故由 App 持有唯一实例。
    private var _navigation: State<NavigationModel>
    var navigation: NavigationModel {
        get { _navigation.wrappedValue }
        nonmutating set { _navigation.wrappedValue = newValue }
    }
    // 菜单栏 VM 同样是跨 scene 的唯一实例:标签与下拉面板读同一份快照。
    private var _menuBarVM: State<MenuBarMonitorViewModel>
    var menuBarVM: MenuBarMonitorViewModel { _menuBarVM.wrappedValue }

    // UNUserNotificationCenter.delegate 是 weak,必须由 App 强持有,
    // 否则前台横幅的代理方法永远不会被调用。
    private let notificationDelegate = RaccoonNotificationDelegate()

    init() {
        _exclusions = State(wrappedValue: ExclusionsStore())
        _navigation = State(wrappedValue: NavigationModel())
        let menuBarVM = MenuBarMonitorViewModel(
            sampler: LiveSystemSampler(),
            preferences: UserDefaultsPreferenceStore(),
            notifier: UNNotifier(),
            loginItem: SMAppServiceLoginItem())
        _menuBarVM = State(wrappedValue: menuBarVM)
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        // 单窗口场景:openWindow(id:) 对 Window 是「已开则置前、已关则重开同一窗口」;
        // WindowGroup 语义允许多窗口,openWindow(id:) 会每次新开副本(人工 QA 实测),
        // 且每个副本会各自重建 RootView 内的全套 VM,故必须用 Window 而非 WindowGroup。
        // Window 的 init 无默认标题(与 WindowGroup 不同),传空串沿用下方
        // navigationTitle 承担窗口标题的既有口径。
        Window("", id: "main") {
            RootView(exclusions: exclusions, navigation: navigation)
                .frame(minWidth: 860, minHeight: 560)
                // 27.0 SDK 无 Scene.windowTitle;用内容级 navigationTitle 承担窗口标题。
                // 窗口标题兜底;RootView 侧栏 List 上的同调用服务列头,两处勿删其一
                .navigationTitle(loc("app.name"))
        }
        Settings {
            // 与菜单栏下拉面板共用同一 VM:设置页改偏好后,标签即时反映。
            SettingsView(exclusions: exclusions, menuBarVM: menuBarVM)
        }
        // .task 在 MenuBarLabelView 内启动采样,不在此处 start:App init 早于
        // 视图生命周期,启动即建循环会拖慢冷启动。
        MenuBarExtra {
            MenuBarPanelView(vm: menuBarVM, navigation: navigation)
        } label: {
            MenuBarLabelView(vm: menuBarVM)
        }
        .menuBarExtraStyle(.window)
    }
}
