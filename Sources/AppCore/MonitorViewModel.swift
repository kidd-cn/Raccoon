import Foundation
import Observation
import MonitorKit
import IOKit.ps

// MARK: - 采集缝隙

/// 系统采集缝隙:实现类薄壳不测,测试注入假体。
/// 协议刻意不 throws——失败以「nil / 空数组 / 默认值」表达,
/// 由 VM 按指标逐个隔离,单指标取不到不拖垮其余字段与状态机。
public protocol SystemSampling: Sendable {
    /// FileManager.mountedVolumeURLs + assembleVolumeInfo 组装
    func volumes() -> [VolumeInfo]
    /// host_statistics64;取不到 → nil
    func memory() -> MemoryStats?
    /// host_processor_info 扁平四元组;取不到 → nil
    func cpuTicks() -> [Int32]?
    func battery() -> BatteryInfo
}

// MARK: - 轮询状态机

/// 系统监控页 VM:双频轮询(fast = CPU/内存,slow = 卷/电池)+ 前台驱动。
/// phase 语义:idle(未 start)/ running(start 后、首轮 slow 未完成)/
/// ready(首轮 slow 完成,数据落位)。stop/暂停均保留已采数据。
@MainActor
@Observable
public final class MonitorViewModel {
    public enum Phase: Equatable, Sendable { case idle, running, ready }

    public private(set) var phase: Phase = .idle
    public private(set) var volumes: [VolumeInfo]?
    public private(set) var memory: MemoryStats?
    public private(set) var battery: BatteryInfo?
    public private(set) var network: NetworkStatus?
    /// CPU 历史曲线:内部为 SampleRing(容量 60,溢出弃最旧),最旧在前;
    /// 只读投影(存储在 ring 里,外部不可直接改写)。
    public var cpuHistory: [CPULoad] { ring.values }

    private let sampler: SystemSampling
    private let fastInterval: TimeInterval
    private let slowInterval: TimeInterval

    /// 曾 start 过(区别于「循环在跑」):setActive 暂停后据此决定能否重启。
    private var started = false
    private var fastTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    /// 上一次 CPU tick 快照:computeCPULoad 的差值基准,暂停/停止不清空,
    /// 恢复后首个采样即可继续出点。
    private var previousTicks: [Int32]?
    private var ring = SampleRing<CPULoad>(capacity: 60)

    public init(sampler: SystemSampling, fastInterval: TimeInterval = 2, slowInterval: TimeInterval = 30) {
        self.sampler = sampler
        self.fastInterval = fastInterval
        self.slowInterval = slowInterval
    }

    /// 幂等:已 running/ready 不重复建循环;phase → running。
    public func start() {
        guard phase == .idle else { return }
        started = true
        phase = .running
        startLoops()
    }

    /// 取消循环,phase → idle;数据保留(展示层可继续读最后一次快照)。
    public func stop() {
        started = false
        cancelLoops()
        phase = .idle
    }

    /// 前台开关:false 停循环(保留 started 标记,phase 不动);
    /// true 曾 start 过则重启循环,从未 start 过则忽略。
    public func setActive(_ active: Bool) {
        if active {
            guard started else { return }
            startLoops()
        } else {
            cancelLoops()
        }
    }

    /// 快频采样:cpu + memory。首采样无基准(computeCPULoad 返回 nil)不入历史;
    /// memory()/cpuTicks() 返回 nil 时该指标保持旧值,其余照常。
    public func refreshFast() {
        if let stats = sampler.memory() {
            memory = stats
        }
        guard let current = sampler.cpuTicks() else { return }
        if let load = computeCPULoad(previous: previousTicks, current: current) {
            ring.append(load)
        }
        // 基准无条件前移:长度变化等无效区间只丢当前这一个点,下轮即恢复
        previousTicks = current
    }

    /// 慢频采样:volumes + battery;首个 slow 完成后 phase → ready。
    /// 空卷列表视作采集失败,保留旧值;battery 是非可选口径,台式机的
    /// hasBattery=false 本身就是有效数据,照常落位。
    public func refreshSlow() {
        let fresh = sampler.volumes()
        if !fresh.isEmpty {
            volumes = fresh
        }
        battery = sampler.battery()
        if phase == .running {
            phase = .ready
        }
    }

    /// 网络状态由 NWPathMonitor(独立监听,Task 5+ 接线)推送式更新。
    public func setNetwork(_ s: NetworkStatus) {
        network = s
    }

    // MARK: - 循环管理

    private func startLoops() {
        cancelLoops()
        let fast = fastInterval
        let slow = slowInterval
        // [weak self]:VM 释放后循环随下一拍自然退出,不持有已销毁的观察对象
        fastTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshFast()
                try? await Task.sleep(for: .seconds(fast))
            }
        }
        slowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshSlow()
                try? await Task.sleep(for: .seconds(slow))
            }
        }
    }

    private func cancelLoops() {
        fastTask?.cancel()
        fastTask = nil
        slowTask?.cancel()
        slowTask = nil
    }
}

// MARK: - 真系统采集壳(薄壳,不单测,靠代码审)

/// 真机采样:只做 mach/IOKit/FileManager 系统调用与 MonitorKit 纯函数组装,
/// 不含任何策略。所有方法幂等、无线程限制(VM 在主 actor 调用,mach/IOKit
/// 查询为微秒级,不构成主线程负担)。
public final class LiveSystemSampler: SystemSampling, Sendable {
    public init() {}

    /// 物理内存总量(hw.memsize 只随机器而定,进程内取一次缓存)。
    private static let totalMemoryBytes: Int64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return Int64(value)
    }()

    /// host_statistics64 计数的页大小。经 host_page_size 函数调用获取而非
    /// vm_kernel_page_size 全局变量(后者在 Swift 6 下属共享可变状态),
    /// 值同为内核页尺寸(Apple Silicon 16K);随机器而定,进程内缓存一次。
    private static let pageSizeBytes: Int64 = {
        var size = vm_size_t(0)
        _ = host_page_size(mach_host_self(), &size)
        return Int64(size)
    }()

    public func volumes() -> [VolumeInfo] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let urls = fm.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                              options: [.skipHiddenVolumes]) else {
            return []
        }
        // 主卷名按「home 所在卷」判定,与 assembleVolumeInfo 的 isSystemDisk 口径一致
        let homeName = (try? fm.homeDirectoryForCurrentUser
            .resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? ""
        var result: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            guard let name = v.volumeName,
                  let total = v.volumeTotalCapacity,
                  let available = v.volumeAvailableCapacity else { continue }
            // important-usage 口径缺失时退化为普通可用容量 → purgeable 归 0
            let important = v.volumeAvailableCapacityForImportantUsage ?? Int64(available)
            result.append(assembleVolumeInfo(name: name,
                                             totalBytes: Int64(total),
                                             availableBytes: Int64(available),
                                             importantUsageBytes: important,
                                             homeVolumeName: homeName))
        }
        return result
    }

    public func memory() -> MemoryStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
                                           / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let total = Self.totalMemoryBytes
        let page = Self.pageSizeBytes
        guard total > 0, page > 0 else { return nil }
        return assembleMemoryStats(
            totalBytes: total,
            freeBytes: Int64(stats.free_count) * page,
            inactiveBytes: Int64(stats.inactive_count) * page,
            purgeableBytes: Int64(stats.purgeable_count) * page,
            wiredBytes: Int64(stats.wire_count) * page,
            compressedBytes: Int64(stats.compressor_page_count) * page
        )
    }

    public func cpuTicks() -> [Int32]? {
        var coreCount: natural_t = 0
        var buffer: processor_info_array_t?
        var count = mach_msg_type_number_t(0)
        let kr = host_processor_info(mach_host_self(), processor_flavor_t(PROCESSOR_CPU_LOAD_INFO),
                                     &coreCount, &buffer, &count)
        guard kr == KERN_SUCCESS, let ticks = buffer, count > 0 else { return nil }
        // host_processor_info 的返回缓冲归调用方所有,读完必须 vm_deallocate
        // 交还内核——每轮快询泄漏 (核数 × 4 × 4B),不释放会随运行时间持续累积
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: ticks)),
                              vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        // 缓冲布局即扁平四元组 (user, system, idle, nice) × 核数,与 computeCPULoad 对齐
        return Array(UnsafeBufferPointer(start: ticks, count: Int(count)))
    }

    public func battery() -> BatteryInfo {
        let empty = assembleBatteryInfo(hasSource: false, percent: nil, charging: false, onBattery: false)
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return empty   // 取不到电源信息(台式机/权限异常)→ 无电池口径
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            // percent 消毒(质量审移交):kIOPSMaxCapacity=0 时 0/0 会得 NaN,
            // 非有限值一律按缺失(nil)处理再传 assembleBatteryInfo,而非透传 NaN
            var percent: Double?
            if let max = Self.number(description[kIOPSMaxCapacityKey]),
               let current = Self.number(description[kIOPSCurrentCapacityKey]) {
                let ratio = current / max * 100
                percent = ratio.isFinite ? ratio : nil
            }
            let state = description[kIOPSPowerSourceStateKey] as? String
            return assembleBatteryInfo(hasSource: true,
                                       percent: percent,
                                       charging: description[kIOPSIsChargingKey] as? Bool ?? false,
                                       onBattery: state == kIOPSBatteryPowerValue)
        }
        return empty
    }

    /// IOPS 容量键历史上有 NSNumber/String 两种形态,统一取 Double;
    /// 除数 max ≤ 0 时直接给非有限结果走 nil 分支,不做除法。
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
