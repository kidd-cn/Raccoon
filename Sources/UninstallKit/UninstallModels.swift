import Foundation
import CleanKit

/// 已安装应用(来自 /Applications 与 ~/Applications 的 .app 包)。
public struct InstalledApp: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let version: String?
    public let appPath: String      // 绝对路径,已 resolve 符号链接
    public let sizeBytes: Int64     // .app 本体递归大小(不跟随符号链接)
    public let isRunning: Bool
    public init(bundleID: String, name: String, version: String? = nil,
                appPath: String, sizeBytes: Int64, isRunning: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.appPath = appPath
        self.sizeBytes = sizeBytes
        self.isRunning = isRunning
    }
}

/// 关联数据/残留的安全分级:regenerable 默认勾选;userData 默认不勾、橙色、单独确认。
public enum LeftoverSafety: String, Equatable, Sendable {
    case regenerable
    case userData
}

/// 归属置信度:精确 Bundle ID;名称匹配的低置信(未确认归属,永不默认勾选)。
public enum LeftoverOwnership: Equatable, Sendable {
    case bundleID
    case appName
}

public struct AppLeftover: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64
    public let safety: LeftoverSafety
    public let ownership: LeftoverOwnership
    public let locationID: String
    public init(path: String, sizeBytes: Int64, safety: LeftoverSafety,
                ownership: LeftoverOwnership, locationID: String) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.safety = safety
        self.ownership = ownership
        self.locationID = locationID
    }
}

public struct AppDiscoveryResult: Sendable {
    public let apps: [InstalledApp]
    public let unreadableCount: Int
    public init(apps: [InstalledApp], unreadableCount: Int) {
        self.apps = apps
        self.unreadableCount = unreadableCount
    }
}

public struct AppDiscoveryProgress: Equatable, Sendable {
    public let enumeratedCount: Int
    public init(enumeratedCount: Int) { self.enumeratedCount = enumeratedCount }
}

public struct OrphanScanResult: Sendable {
    public let orphans: [AppLeftover]
    public let failedLocationIDs: Set<String>
    public init(orphans: [AppLeftover], failedLocationIDs: Set<String>) {
        self.orphans = orphans
        self.failedLocationIDs = failedLocationIDs
    }
}

public struct OrphanScanProgress: Equatable, Sendable {
    public let completedLocations: Int
    public let totalLocations: Int
    public init(completedLocations: Int, totalLocations: Int) {
        self.completedLocations = completedLocations
        self.totalLocations = totalLocations
    }
}

public protocol AppDiscovering: Sendable {
    func discover(exclusions: [String],
                  progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult
}

public protocol LeftoverLocating: Sendable {
    func leftovers(for app: InstalledApp, exclusions: [String]) async -> [AppLeftover]
}

public protocol OrphanScanning: Sendable {
    func scan(installedBundleIDs: Set<String>,
              installedAppNames: Set<String>,
              exclusions: [String],
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult
}

/// 已安装集合的 LaunchServices 侧(生产实现经主线程查询 NSWorkspace;测试注入固定集合)。
public protocol InstalledBundleResolving: Sendable {
    func isResolvable(_ bundleID: String) async -> Bool
}

/// 运行中判定(生产读 NSRunningApplication;测试注入固定集合)。
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleID: String) -> Bool
}
