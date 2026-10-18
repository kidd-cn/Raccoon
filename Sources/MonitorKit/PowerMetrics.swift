import Foundation

/// 电池状态快照:侧栏电源区段的展示单元,值语义、可跨并发域传递。
public struct BatteryInfo: Equatable, Sendable {
    /// 空电源源 → false:台式机/无电池机型据此整体隐藏电源区段
    public let hasBattery: Bool
    /// 0...100;无电池时保持 0,不产生 NaN
    public let percentage: Double
    /// 外接电源(或已充满)时为 true
    public let charging: Bool
    /// 正在放电(未接电源且非充满)
    public let onBattery: Bool

    /// 显式 memberwise:合成的仅 internal,而 AppCore/Raccoon 是独立模块,
    /// 采样假体/预览需在 MonitorKit 之外直接构造快照。
    public init(hasBattery: Bool, percentage: Double, charging: Bool, onBattery: Bool) {
        self.hasBattery = hasBattery
        self.percentage = percentage
        self.charging = charging
        self.onBattery = onBattery
    }
}

/// 纯组装:输入 IOPS 描述字典的提取值(调用方薄壳负责 IOKit)。
/// hasSource=false 或 percent 缺失一律按无电池处理——数据缺失宁可少显示不错报;
/// percent 传值则夹到 0...100,IOKit 在异常电源下会给出界外原始值。
public func assembleBatteryInfo(hasSource: Bool, percent: Double?, charging: Bool, onBattery: Bool) -> BatteryInfo {
    guard hasSource, let percent else {
        return BatteryInfo(hasBattery: false, percentage: 0, charging: charging, onBattery: onBattery)
    }
    return BatteryInfo(
        hasBattery: true,
        percentage: min(100, max(0, percent)),
        charging: charging,
        onBattery: onBattery
    )
}
