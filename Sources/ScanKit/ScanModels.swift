import Foundation
import CleanKit

public struct ScanHit: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let ruleID: String
    public let category: RuleCategory
    public let safety: SafetyLevel
    public let path: String
    public let sizeBytes: Int64
    public let isDirectory: Bool
    public let bundleID: String?
    public let appName: String?
    public let isAppRunning: Bool
    public let action: RuleAction
    public let snapshotDate: String?

    public init(ruleID: String, category: RuleCategory, safety: SafetyLevel, path: String,
                sizeBytes: Int64, isDirectory: Bool = false, bundleID: String? = nil,
                appName: String? = nil, isAppRunning: Bool = false,
                action: RuleAction = .trash, snapshotDate: String? = nil) {
        self.ruleID = ruleID
        self.category = category
        self.safety = safety
        self.path = path
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.bundleID = bundleID
        self.appName = appName
        self.isAppRunning = isAppRunning
        self.action = action
        self.snapshotDate = snapshotDate
    }

    public var cleanItem: CleanItem {
        CleanItem(path: path, sizeBytes: sizeBytes,
                  action: action == .tmutilThin ? .tmutilThin(date: snapshotDate) : .trash)
    }
}

public struct CategorySummary: Identifiable, Equatable, Sendable {
    public let category: RuleCategory
    public let totalBytes: Int64
    public let hitCount: Int
    public var id: RuleCategory { category }
    public init(category: RuleCategory, totalBytes: Int64, hitCount: Int) {
        self.category = category
        self.totalBytes = totalBytes
        self.hitCount = hitCount
    }
}

public struct ScanProgress: Equatable, Sendable {
    public let rulesDone: Int
    public let rulesTotal: Int
    public let hitsFound: Int
    public let bytesFound: Int64
    public init(rulesDone: Int, rulesTotal: Int, hitsFound: Int, bytesFound: Int64) {
        self.rulesDone = rulesDone
        self.rulesTotal = rulesTotal
        self.hitsFound = hitsFound
        self.bytesFound = bytesFound
    }
}

public struct ScanResult: Sendable {
    public let hits: [ScanHit]
    public let summaries: [CategorySummary]
    public let permissionSkippedCount: Int
    public let truncatedRuleIDs: Set<String>
    public let excludedCount: Int
    public init(hits: [ScanHit], summaries: [CategorySummary], permissionSkippedCount: Int,
                truncatedRuleIDs: Set<String>, excludedCount: Int) {
        self.hits = hits
        self.summaries = summaries
        self.permissionSkippedCount = permissionSkippedCount
        self.truncatedRuleIDs = truncatedRuleIDs
        self.excludedCount = excludedCount
    }
}

public protocol ScanServicing: Sendable {
    func scan(exclusions: [String],
              progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult
}
