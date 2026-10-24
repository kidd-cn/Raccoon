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
            // 速率未就绪(首拍无差分基准时 receivedBPS/sentBPS 为 nil)或无 traffic
            // 一律回退现有接口文案口径——回退文案优于显示半成品。
            guard let t = snapshot.traffic, let down = t.receivedBPS, let up = t.sentBPS else {
                return .network(snapshot.network)
            }
            return .traffic(down: shortBytesPerSecond(down), up: shortBytesPerSecond(up))
        }
    }

    /// 速率短格式(菜单栏窄空间):1024 进制、单位单字符无空格、
    /// ≥1K 统一一位小数(String(format:) 恒为点号,不做本地化);负值/非有限值按 0 计。
    public static func shortBytesPerSecond(_ bps: Double) -> String {
        let value = bps.isFinite ? max(0, bps) : 0
        guard value >= 1024 else { return "\(Int(value))B" }
        let kb = value / 1024
        guard kb >= 1024 else { return String(format: "%.1fK", kb) }
        let mb = kb / 1024
        guard mb >= 1024 else { return String(format: "%.1fM", mb) }
        return String(format: "%.1fG", mb / 1024)
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
