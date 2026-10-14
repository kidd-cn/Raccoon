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

    init() {
        _exclusions = State(wrappedValue: ExclusionsStore())
    }

    var body: some Scene {
        WindowGroup {
            RootView(exclusions: exclusions)
                .frame(minWidth: 860, minHeight: 560)
                // 27.0 SDK 无 Scene.windowTitle;用内容级 navigationTitle 承担窗口标题。
                .navigationTitle(loc("app.name"))
        }
        Settings {
            SettingsView(exclusions: exclusions)
        }
    }
}
