import Foundation

/// CPU 占用构成:user/system/idle 三段合计 100%,供占用环/构成条展示。
public struct CPULoad: Equatable, Sendable {
    /// 用户态占比(含 nice 低优先级进程,与顶层按 nice 归并展示的惯例一致)
    public let userPct: Double
    public let systemPct: Double
    public let idlePct: Double

    /// 显式 memberwise:合成的仅 internal,而 AppCore/Raccoon 是独立模块,
    /// 采样假体/预览需在 MonitorKit 之外直接构造快照。
    public init(userPct: Double, systemPct: Double, idlePct: Double) {
        self.userPct = userPct
        self.systemPct = systemPct
        self.idlePct = idlePct
    }
}

/// 纯函数:对扁平化 per-core tick 四元组 (user, system, idle, nice) 做跨采样差值。
/// 每核逐状态求差后跨核求和,user 与 nice 合并计入 userPct,再归一到 0...100。
/// 返回 nil 的三类无效区间:首采样(previous 为 nil,无基准可减)、
/// 长度不符或非 4 的倍数(采样不完整)、总差值 ≤ 0(无 tick 流逝或计数器回绕)。
/// 真实 host_processor_info 采集不在本层——保持可无副作用测试。
public func computeCPULoad(previous: [Int32]?, current: [Int32]) -> CPULoad? {
    guard let previous else { return nil }
    guard previous.count == current.count, current.count % 4 == 0 else { return nil }

    var user = 0
    var system = 0
    var idle = 0
    var nice = 0
    for core in stride(from: 0, to: current.count, by: 4) {
        user += Int(current[core]) - Int(previous[core])
        system += Int(current[core + 1]) - Int(previous[core + 1])
        idle += Int(current[core + 2]) - Int(previous[core + 2])
        nice += Int(current[core + 3]) - Int(previous[core + 3])
    }

    let total = user + system + idle + nice
    guard total > 0 else { return nil }

    return CPULoad(
        userPct: Double(user + nice) / Double(total) * 100,
        systemPct: Double(system) / Double(total) * 100,
        idlePct: Double(idle) / Double(total) * 100
    )
}
