import AppKit

@MainActor
public protocol RunningAppDetecting: Sendable {
    func runningBundleIDs() -> Set<String>
}

/// NSWorkspace 是 @MainActor 隔离的(Swift 6 严格并发),检测器整体收在主线程;
/// ScanEngine 在扫描开始时通过 async 闭包取一次快照。
@MainActor
public struct WorkspaceRunningAppDetector: RunningAppDetecting {
    public init() {}
    public func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}

public struct AppIdentityResolver: Sendable {
    public init() {}

    /// 纯函数:路径中最后一个形如 com.xxx.yyy 的完整路径段。
    public static func bundleIDComponent(in path: String) -> String? {
        for comp in path.split(separator: "/").reversed() {
            let s = String(comp)
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 2, parts.allSatisfy({
                !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            }) {
                return s
            }
        }
        return nil
    }

    /// bundle id → 应用名:先运行中应用(localizedName),再已安装应用(bundle 文件名);查不到返回 nil。
    @MainActor
    public func appName(for bundleID: String) -> String? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }
}
