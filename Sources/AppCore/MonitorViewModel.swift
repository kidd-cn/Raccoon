import Foundation
import Darwin
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
    /// 自开机以来各物理接口累计收发字节
    func traffic() -> NetworkTrafficCounters?
}

public extension SystemSampling {
    /// 默认无流量数据:五期既有测试假体零改动兼容,真实覆盖在 LiveSystemSampler。
    func traffic() -> NetworkTrafficCounters? { nil }
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
    /// 本拍流量:累计 + 可选速率;失败拍冻结旧值。
    public private(set) var traffic: NetworkTraffic?
    /// CPU 历史曲线:内部为 SampleRing(容量 60,溢出弃最旧),最旧在前;
    /// 只读投影(存储在 ring 里,外部不可直接改写)。
    public var cpuHistory: [CPULoad] { ring.values }
    /// CPU 持续采集失败(连续两次及以上取不到 tick):视图据此显示「暂不可用」,
    /// 而不是永远停在「正在采集首个样本…」。成功后立即清零。
    public private(set) var cpuUnavailable = false

    private let sampler: SystemSampling
    private let fastInterval: TimeInterval
    private let slowInterval: TimeInterval
    /// 注入时钟:流量成功拍恰读一次(elapsed 与基准存储共用同一时刻)。
    private let now: @Sendable () -> Date

    /// 曾 start 过(区别于「循环在跑」):setActive 暂停后据此决定能否重启。
    private var started = false
    private var fastTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    /// 上一次 CPU tick 快照:computeCPULoad 的差值基准,暂停/停止不清空,
    /// 恢复后首个采样即可继续出点。
    private var previousTicks: [Int32]?
    /// 流量差分基准及其采样时刻。与 CPU 基准「无条件前移」不同:流量基准只在
    /// 成功采样拍前移(理由见 refreshFast 流量段注释)。
    private var previousTraffic: NetworkTrafficCounters?
    private var previousTrafficAt: Date?
    private var ring = SampleRing<CPULoad>(capacity: 60)
    /// cpuTicks() 连续失败次数:单次失败可能只是瞬时抖动,连续两次才判「暂不可用」。
    private var cpuFailureCount = 0

    public init(sampler: SystemSampling, fastInterval: TimeInterval = 2, slowInterval: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.sampler = sampler
        self.fastInterval = fastInterval
        self.slowInterval = slowInterval
        self.now = now
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

    /// 快频采样:memory + 流量 + cpu。首采样无基准(computeCPULoad 返回 nil)不入历史;
    /// memory()/traffic()/cpuTicks() 返回 nil 时该指标保持旧值,其余照常。
    public func refreshFast() {
        if let stats = sampler.memory() {
            memory = stats
        }
        // 流量段刻意位于 cpuTicks 失败提前返回之前:cpuTicks 连续失败会在下方 guard
        // 处提前 return,流量若排在其后,「CPU 暂不可用」期间会一并断流。单指标
        // 隔离(见 SystemSampling 顶部注释)要求 CPU 失败不拖垮流量。
        // 流量差分与 CPU 基准的「无条件前移」语义不同:流量基准只在成功采样拍前移,
        // 失败拍(nil)既不动 traffic 也不动基准。理由:跨失败拍差分会把失败/休眠
        // 时长摊进速率(失败期间虚低、恢复拍虚高),按「失败拍不可信」口径冻结
        // 展示,恢复拍以上一次成功基准续算。
        if let current = sampler.traffic() {
            // 只调一次 now():同一时刻既算 elapsed 又存基准,两次读取会注入序列错位。
            let sampledAt = now()
            if let previous = previousTraffic, let previousAt = previousTrafficAt {
                traffic = assembleTraffic(
                    current: current,
                    previous: previous,
                    elapsedSeconds: sampledAt.timeIntervalSince(previousAt)
                )
            }
            // 无论是否已有基准都前移:首拍建立基准不出值,之后每成功拍续算。
            previousTraffic = current
            previousTrafficAt = sampledAt
        }
        guard let current = sampler.cpuTicks() else {
            cpuFailureCount += 1
            // 非首次失败才置不可用:首轮失败仍可能是挂起中的瞬时状态。
            if cpuFailureCount >= 2 { cpuUnavailable = true }
            return
        }
        cpuFailureCount = 0
        cpuUnavailable = false
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

    /// 自开机以来各物理接口累计收发字节。薄壳不单测(同 volumes() 口径,靠代码审):
    /// 只做 sysctl(NET_RT_IFLIST2) 系统调用与 assembleTrafficCounters 纯函数组装。
    /// 数据源刻意不走 getifaddrs:其 AF_LINK 条目的 ifa_data 指向 32 位 struct
    /// if_data(u_int32 计数,单接口 ~4 GiB 即回绕),而 NET_RT_IFLIST2 的
    /// RTM_IFINFO2 消息携带 if_data64(u_int64 计数,活动监视器同款),
    /// 「开机以来累计」在正常使用中不回绕。消息按 ifm_msglen 步进,仅处理
    /// RTM_IFINFO2;接口名取 ifm_addrs 位图中 RTAX_IFP 位的 sockaddr_dl
    /// (sdl_data 前 sdl_nlen 字节,非零终止),sockaddr 按 4 字节 int 对齐步进;
    /// 同名消息只保留首条,交 assembleTrafficCounters 复用同一套 en 白名单去重
    /// 口径;两次 sysctl 失败或解析异常 → nil。
    public func traffic() -> NetworkTrafficCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: length,
                                                      alignment: MemoryLayout<Int64>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&mib, u_int(mib.count), buffer, &length, nil, 0) == 0, length > 0 else { return nil }
        var byName: [String: (rx: Int64, tx: Int64)] = [:]
        let headerSize = MemoryLayout<if_msghdr2>.size
        var offset = 0
        while offset < length {
            // 每条消息前 4 字节必在:msglen(u_short@0)与 type(u_char@3)
            guard length - offset >= 4 else { return nil }
            let msglen = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard msglen >= 4, offset + msglen <= length else { return nil }
            if buffer.loadUnaligned(fromByteOffset: offset + 3, as: UInt8.self) == UInt8(RTM_IFINFO2),
               msglen >= headerSize {
                // 整头仅在 msglen ≥ sizeof 后整读,短消息(RTM_NEWMADDR2 等)不触碰
                let ifm = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let msgEnd = offset + msglen
                var saOffset = offset + headerSize
                // sockaddr 紧跟消息头,按 ifm_addrs 位序(RTAX 顺序)排布
                for bit in 0..<RTAX_MAX where ifm.ifm_addrs & (1 << bit) != 0 {
                    guard saOffset + 8 <= msgEnd else { return nil }
                    if bit == RTAX_IFP {
                        // if_dl.h 布局:u_char sdl_nlen@5、char sdl_data[12]@8;
                        // 名字非零终止,只读 sdl_nlen 个字节(接口真名不可能超 12)
                        let nlen = Int(buffer.loadUnaligned(fromByteOffset: saOffset + 5, as: UInt8.self))
                        guard nlen > 0, nlen <= 12,
                              saOffset + 8 + nlen <= msgEnd else { return nil }
                        var nameBytes: [UInt8] = []
                        nameBytes.reserveCapacity(nlen)
                        for i in 0..<nlen {
                            nameBytes.append(buffer.loadUnaligned(fromByteOffset: saOffset + 8 + i, as: UInt8.self))
                        }
                        let name = String(decoding: nameBytes, as: UTF8.self)
                        // 同名消息(IPv4/IPv6 等地址族)只计首条:计数器是接口级同一份
                        if byName[name] == nil {
                            byName[name] = (Int64(bitPattern: ifm.ifm_data.ifi_ibytes),
                                            Int64(bitPattern: ifm.ifm_data.ifi_obytes))
                        }
                    }
                    // sa_len(u_char@0)为 0 的历史消息按 4 计,步进修圆到 int 对齐
                    let saLen = Int(buffer.loadUnaligned(fromByteOffset: saOffset, as: UInt8.self))
                    saOffset += (max(saLen, 4) + 3) & ~3
                }
            }
            offset += msglen
        }
        let entries = byName.map { (name: $0.key, rx: $0.value.rx, tx: $0.value.tx) }
        return assembleTrafficCounters(entries)
    }

    /// IOPS 容量键历史上有 NSNumber/String 两种形态,统一取 Double;
    /// 除数 max ≤ 0 时直接给非有限结果走 nil 分支,不做除法。
    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
