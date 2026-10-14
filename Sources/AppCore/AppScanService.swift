import Foundation
import ScanKit
import CleanKit

/// 生产装配:每次扫描用最新排除清单构建保护层。
public struct AppScanService: ScanServicing {
    public init() {}

    public func scan(exclusions: [String],
                     progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        let protection = ProtectionStore(userExclusions: exclusions)
        let store = RuleStore(protection: protection)
        let engine = ScanEngine(deps: .init(
            protection: protection,
            runningBundleIDs: { await WorkspaceRunningAppDetector().runningBundleIDs() }
        ))
        let loaded = try store.loadBundled()
        return try await engine.scan(rules: loaded.rules, progress: progress)
    }
}
