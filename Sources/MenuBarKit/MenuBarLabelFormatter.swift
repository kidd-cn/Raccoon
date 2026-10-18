import Foundation
import MonitorKit

/// 纯函数格式化:把监控快照折算成菜单栏文案模型,不触碰任何采集或 UI。
public enum MenuBarLabelFormatter {

    public static func label(
        metric: MenuBarMetric,
        style: MenuBarIconStyle,
        snapshot: MenuBarSnapshot
    ) -> MenuBarLabel {
        guard style == .iconAndValue else { return .none }

        switch metric {
        case .disk:
            guard let volume = snapshot.diskVolume else { return .none }
            return percentLabel(numerator: volume.availableBytes, denominator: volume.totalBytes)

        case .memory:
            guard let memory = snapshot.memory else { return .none }
            return percentLabel(numerator: memory.usedBytes, denominator: memory.totalBytes)

        case .cpu:
            guard let cpu = snapshot.cpu else { return .none }
            return percentLabel(value: cpu.userPct + cpu.systemPct)

        case .network:
            return .network(snapshot.network)
        }
    }

    /// 比例 → 0...100 整数百分比;分母非正、非有限值一律 .none。
    private static func percentLabel(numerator: Int64, denominator: Int64) -> MenuBarLabel {
        guard denominator > 0 else { return .none }
        return percentLabel(value: Double(numerator) / Double(denominator) * 100)
    }

    /// 数值 → 0...100 整数百分比(四舍五入后夹取);非有限值 .none。
    private static func percentLabel(value: Double) -> MenuBarLabel {
        guard value.isFinite else { return .none }
        // 先在 Double 域夹取再转 Int:超大值直接 Int(_:) 会溢出陷阱。
        return .percent(Int(min(100, max(0, value.rounded()))))
    }
}
