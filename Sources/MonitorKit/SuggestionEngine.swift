import Foundation

/// 建议跳转目的地:复用已审计的动作管线入口。
public enum SuggestionDestination: Equatable, Sendable {
    case diskAnalysis
    case cleanup
    case launchItems
}

/// 单条建议:id 即 L10n key 尾段("disk" / "snapshots" / "launchitems" / "crashreports"),
/// icon 与标题由 UI 按 id 映射 L10n——本层只决定「何时建议、跳去哪」。
public struct Suggestion: Equatable, Sendable {
    public let id: String
    public let destination: SuggestionDestination

    /// 显式 memberwise:合成的仅 internal,而 AppCore/Raccoon 是独立模块,
    /// 测试/预览需在 MonitorKit 之外直接构造期望值。
    public init(id: String, destination: SuggestionDestination) {
        self.id = id
        self.destination = destination
    }
}

/// 规则输入:由各采集器聚合的最坏值(全部卷中最小可用比例/字节)与三项事实计数。
public struct SuggestionsInput: Equatable, Sendable {
    /// 全部卷中最小可用比例
    public let minVolumeFreeFraction: Double
    /// 全部卷中最小可用字节
    public let minVolumeFreeBytes: Int64
    public let hasSnapshots: Bool
    public let userLaunchAgentCount: Int
    public let crashReportCount: Int

    public init(minVolumeFreeFraction: Double, minVolumeFreeBytes: Int64,
                hasSnapshots: Bool, userLaunchAgentCount: Int, crashReportCount: Int) {
        self.minVolumeFreeFraction = minVolumeFreeFraction
        self.minVolumeFreeBytes = minVolumeFreeBytes
        self.hasSnapshots = hasSnapshots
        self.userLaunchAgentCount = userLaunchAgentCount
        self.crashReportCount = crashReportCount
    }
}

/// 磁盘可用比例告警线:严格小于才建议,恰好 10% 视为健康。
private let diskFreeFractionThreshold: Double = 0.10

/// 磁盘可用字节告警线:10 GiB,与比例阈值构成「或」关系——小卷比例健康但
/// 绝对字节告急、大卷反之,双阈值互为兜底。
private let diskFreeBytesThreshold: Int64 = 10_737_418_240

/// 建议引擎真值表(纯函数)。稳定顺序:磁盘 → 快照 → 启动项 → 崩溃报告
/// (spec §5.2 表),UI 按数组顺序渲染,与命中组合无关。磁盘条件为「或」且
/// 两个阈值均严格小于;无命中返回空数组。
public func suggestions(for input: SuggestionsInput) -> [Suggestion] {
    var result: [Suggestion] = []
    if input.minVolumeFreeFraction < diskFreeFractionThreshold
        || input.minVolumeFreeBytes < diskFreeBytesThreshold {
        result.append(Suggestion(id: "disk", destination: .cleanup))
    }
    if input.hasSnapshots {
        result.append(Suggestion(id: "snapshots", destination: .cleanup))
    }
    if input.userLaunchAgentCount > 0 {
        result.append(Suggestion(id: "launchitems", destination: .launchItems))
    }
    if input.crashReportCount > 0 {
        result.append(Suggestion(id: "crashreports", destination: .cleanup))
    }
    return result
}
