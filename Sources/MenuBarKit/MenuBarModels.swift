import Foundation
import MonitorKit

/// 菜单栏展示的指标维度。原始值用于设置持久化,新增取值不得改动既有原始值。
public enum MenuBarMetric: String, CaseIterable, Sendable, Equatable {
    case disk, memory, cpu, network
}

/// 菜单栏展示样式:仅图标,或图标 + 数值文案。
public enum MenuBarIconStyle: String, CaseIterable, Sendable, Equatable {
    case iconOnly, iconAndValue
}

/// 菜单栏渲染所需的只读快照。各监控域独立可选:采集失败或尚未就绪的域
/// 保持 nil,格式化层据此退回「不显示数值」而非误报。
public struct MenuBarSnapshot: Equatable, Sendable {
    public let volumes: [VolumeInfo]
    public let memory: MemoryStats?
    public let cpu: CPULoad?
    public let battery: BatteryInfo?
    public let network: NetworkStatus?

    public init(
        volumes: [VolumeInfo] = [],
        memory: MemoryStats? = nil,
        cpu: CPULoad? = nil,
        battery: BatteryInfo? = nil,
        network: NetworkStatus? = nil
    ) {
        self.volumes = volumes
        self.memory = memory
        self.cpu = cpu
        self.battery = battery
        self.network = network
    }
}

public extension MenuBarSnapshot {
    /// 菜单栏磁盘指标对应的卷:系统盘优先——否则多卷机器上会随机显示外置盘;
    /// 无系统盘标记时退化为可用比例最低的卷(最需要被关注的那个)。空列表 → nil。
    var diskVolume: VolumeInfo? {
        if let systemDisk = volumes.first(where: { $0.isSystemDisk }) {
            return systemDisk
        }
        return volumes.min { lhs, rhs in
            Self.availableRatio(lhs) < Self.availableRatio(rhs)
        }
    }

    /// total ≤ 0 的卷不参与「最低比例」比较(比例无意义),排到最后。
    private static func availableRatio(_ volume: VolumeInfo) -> Double {
        guard volume.totalBytes > 0 else { return .greatestFiniteMagnitude }
        let ratio = Double(volume.availableBytes) / Double(volume.totalBytes)
        return ratio.isFinite ? ratio : .greatestFiniteMagnitude
    }
}

/// 菜单栏文案的中间表示:数值形态与网络形态分开,渲染层各自决定图标/文本组合。
public enum MenuBarLabel: Equatable, Sendable {
    /// 0...100 的整数百分比
    case percent(Int)
    /// 网络状态原样透传(nil 表示尚未采集到)
    case network(NetworkStatus?)
    /// 不显示数值(仅图标)
    case none
}
