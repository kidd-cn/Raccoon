import Foundation
import AppKit
import UninstallKit

/// 运行中判定:NSRunningApplication 标注 Sendable 且类方法可在任意线程调用
/// (属性读取原子;列表可能受 run-loop 策略影响而短暂陈旧)。
public struct NSRunningAppChecker: RunningAppChecking {
    public init() {}
    public func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

/// LaunchServices 侧:NSWorkspace 是 @MainActor 隔离的,故整体收在主线程;
/// 协议方法是 async,调用方 await 时自动切换。
@MainActor
public struct WorkspaceBundleResolver: InstalledBundleResolving {
    public init() {}
    public func isResolvable(_ bundleID: String) async -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

/// 生产装配:主目录可注入(测试传临时目录)。
public enum UninstallServices {
    @MainActor
    public static func make(home: URL = URL(fileURLWithPath: NSHomeDirectory()))
        -> (discovery: AppDiscovering, locator: LeftoverLocating, orphans: OrphanScanning) {
        let roots = [URL(fileURLWithPath: "/Applications"),
                     home.appendingPathComponent("Applications", isDirectory: true)]
        return (AppDiscovery(appRoots: roots, running: NSRunningAppChecker()),
                LeftoverLocator(home: home),
                OrphanScanner(home: home, resolver: WorkspaceBundleResolver()))
    }
}
