import SwiftUI
import AppCore

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

    init() {
        _exclusions = State(wrappedValue: ExclusionsStore())
        _navigation = State(wrappedValue: NavigationModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView(exclusions: exclusions, navigation: navigation)
                .frame(minWidth: 860, minHeight: 560)
                // 27.0 SDK 无 Scene.windowTitle;用内容级 navigationTitle 承担窗口标题。
                // 窗口标题兜底;RootView 侧栏 List 上的同调用服务列头,两处勿删其一
                .navigationTitle(loc("app.name"))
        }
        Settings {
            SettingsView(exclusions: exclusions)
        }
    }
}
