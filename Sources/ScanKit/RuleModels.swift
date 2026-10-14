import Foundation

public enum RuleCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case system, dev, apps, cautious
    public var id: String { rawValue }
}

public enum SafetyLevel: String, Codable, Sendable {
    case safe, cautious
}

public enum RuleAction: String, Codable, Sendable {
    case trash
    case tmutilThin = "tmutil-thin"
}

public struct LocalizedText: Codable, Equatable, Sendable {
    public let zhHans: String?
    public let en: String?
    enum CodingKeys: String, CodingKey { case zhHans = "zh-Hans", en }
    public init(zhHans: String?, en: String?) { self.zhHans = zhHans; self.en = en }
    public func text(prefersChinese: Bool) -> String {
        prefersChinese ? (zhHans ?? en ?? "") : (en ?? zhHans ?? "")
    }
}

public struct CleanupRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let category: RuleCategory
    public let safety: SafetyLevel
    public let path: String
    public let include: [String]?
    public let exclude: [String]?
    public let action: RuleAction?
    public let description: LocalizedText?

    public var effectiveAction: RuleAction { action ?? .trash }
}

public struct RulePack: Codable, Sendable {
    public let version: Int
    public let rules: [CleanupRule]
}
