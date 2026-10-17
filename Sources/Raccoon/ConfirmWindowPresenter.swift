import AppKit
import SwiftUI
import AppCore

/// 确认卡片宿主窗口。
///
/// 本机实测:确认卡片无论用 sheet 还是 overlay 都无法可见地呈现在
/// NavigationStack 推入的详情页上(状态与重渲染均正常,纯显示层问题)。
/// 改用独立 NSWindow 宿主 SwiftUI 卡片,不依赖 SwiftUI 层级合成,必然可见。
/// 窗口不可手动关闭(无 close 按钮),只能经「取消/卸载」按钮把 confirmFlow 置 nil 后关闭。
@MainActor
enum ConfirmWindowPresenter {
    private static var window: NSWindow?

    static func sync(confirmFlow: UninstallViewModel.CleanFlow?,
                     vm: UninstallViewModel) {
        switch (confirmFlow, window) {
        case (.some(let flow), nil):
            let controller = NSHostingController(
                rootView: UninstallConfirmView(vm: vm, flow: flow))
            let win = NSWindow(contentViewController: controller)
            win.styleMask = [.titled]
            win.title = loc(flow == .apps ? "uninstall.confirm.title" : "orphans.confirm.title")
            win.isReleasedWhenClosed = false
            win.center()
            win.makeKeyAndOrderFront(nil)
            window = win
        case (nil, .some(let win)):
            win.orderOut(nil)
            window = nil
        case (.some(let flow), .some(let win)):
            win.title = loc(flow == .apps ? "uninstall.confirm.title" : "orphans.confirm.title")
        case (nil, nil):
            break
        }
    }
}
