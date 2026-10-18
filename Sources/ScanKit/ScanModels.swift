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
    /// 归属工具标识(继承自 rule.tool),AI 清理页按它分组;非 AI 规则的命中为 nil。
    public let tool: String?

    public init(ruleID: String, category: RuleCategory, safety: SafetyLevel, path: String,
                sizeBytes: Int64, isDirectory: Bool = false, bundleID: String? = nil,
                appName: String? = nil, isAppRunning: Bool = false,
                action: RuleAction = .trash, snapshotDate: String? = nil, tool: String? = nil) {
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
        self.tool = tool
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

    /// 按类别聚合:字节为类别内合计,命中数为条数,空类别不出现在结果中。
    /// 扫描收尾(ScanEngine)与清理后重算(ScanViewModel)共用本实现——同一口径两处各写一份,
    /// 改一处必漏另一处;须假定入参已按 path 去重(去重属扫描管线职责)。
    public static func aggregate(_ hits: [ScanHit]) -> [CategorySummary] {
        let byCategory = Dictionary(grouping: hits, by: \.category)
        return RuleCategory.allCases.compactMap { category in
            guard let list = byCategory[category] else { return nil }
            return CategorySummary(category: category,
                                   totalBytes: list.reduce(Int64(0)) { $0 + $1.sizeBytes },
                                   hitCount: list.count)
        }
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
