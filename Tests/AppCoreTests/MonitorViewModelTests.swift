import Testing
import Foundation
import MonitorKit
@testable import AppCore

// MARK: - 采样假体

/// 可编程假体:cpuTicks 每次调用按调用序数放大,保证跨采样差值恒非零;
/// memoryFails / cpuFails 模拟单指标失败(memory()/cpuTicks() → nil)。
/// VM 是 @MainActor,全部调用发生在主 actor,锁只作跨 actor 读取计数的保险。
final class FakeSampler: SystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var tickCalls = 0
    var memoryFails = false
    var cpuFails = false

    /// cpuTicks 累计调用次数(验证轮询循环条数,如 start 幂等)。
    var tickCallCount: Int { lock.withLock { tickCalls } }

    func volumes() -> [VolumeInfo] {
        [VolumeInfo(name: "Macintosh HD", totalBytes: 500, availableBytes: 100,
                    purgeableBytes: 50, isSystemDisk: true)]
    }

    func memory() -> MemoryStats? {
        guard !memoryFails else { return nil }
        return MemoryStats(totalBytes: 16, usedBytes: 8, compressedBytes: 2,
                           wiredBytes: 3, purgeableFreeBytes: 1)
    }

    func cpuTicks() -> [Int32]? {
        lock.withLock {
            guard !cpuFails else { return nil }
            tickCalls += 1
            let n = Int32(tickCalls)
            // 单核四元组 (user, system, idle, nice):数值随调用序数增长 → 差值恒 > 0
            return [100 * n, 50 * n, 1000 * n, 0]
        }
    }

    func battery() -> BatteryInfo {
        BatteryInfo(hasBattery: true, percentage: 66, charging: false, onBattery: true)
    }
}

// MARK: - 测试

/// 快间隔统一 0.05s(慢间隔取 60s,让慢循环首轮之外不再干扰断言);
/// 其余用例用超大间隔把循环「冻结」,只走手动 refresh 路径,不依赖真实计时。
@Suite @MainActor
final class MonitorViewModelTests {
    private func makeVM(memoryFails: Bool = false,
                        fast: TimeInterval = 60, slow: TimeInterval = 60) -> (vm: MonitorViewModel, sampler: FakeSampler) {
        let sampler = FakeSampler()
        sampler.memoryFails = memoryFails
        return (MonitorViewModel(sampler: sampler, fastInterval: fast, slowInterval: slow), sampler)
    }

    @Test func startSetsRunningAndIsIdempotent() async throws {
        // 间隔取 60s 冻结循环:单循环在测试时长内不可能二拍,
        // 双循环则会在首拍各采一轮 → tick 数翻倍且首拍即出历史点
        let (vm, sampler) = makeVM(fast: 60, slow: 60)
        #expect(vm.phase == .idle)
        vm.start()
        #expect(vm.phase == .running)
        vm.start()   // 幂等:已 running 不重复建循环
        try await Task.sleep(for: .milliseconds(100))   // 只够首拍,不够二拍
        #expect(sampler.tickCallCount == 1)
        #expect(vm.cpuHistory.isEmpty)
        vm.stop()
    }

    @Test func refreshFastFirstSampleEmptyThenOnePoint() {
        let (vm, _) = makeVM()
        vm.refreshFast()
        #expect(vm.cpuHistory.isEmpty)   // 首采样无基准,不入历史
        #expect(vm.memory != nil)        // memory 非 diff 口径,首轮即落位
        vm.refreshFast()
        #expect(vm.cpuHistory.count == 1)
    }

    @Test func cpuHistoryCapsAt60() {
        let (vm, _) = makeVM()
        for _ in 0..<65 { vm.refreshFast() }
        #expect(vm.cpuHistory.count == 60)   // 定长环形,溢出弃最旧
    }

    @Test func refreshSlowFillsSlowMetricsAndBecomesReady() {
        let (vm, _) = makeVM()
        vm.start()
        #expect(vm.phase == .running)
        #expect(vm.volumes == nil)
        #expect(vm.battery == nil)
        vm.refreshSlow()
        #expect(vm.phase == .ready)          // 首个 slow 完成即 ready
        #expect(vm.volumes?.count == 1)
        #expect(vm.battery?.hasBattery == true)
        vm.stop()
        #expect(vm.phase == .idle)
        #expect(vm.volumes != nil)           // stop 保留数据
    }

    @Test func memoryFailureIsolatedFromOtherMetrics() {
        let (vm, _) = makeVM(memoryFails: true)
        vm.start()
        vm.refreshFast()
        vm.refreshFast()
        vm.refreshSlow()
        #expect(vm.memory == nil)            // 失败指标保持不动
        #expect(vm.cpuHistory.count == 1)    // 其余指标照常
        #expect(vm.volumes?.count == 1)
        #expect(vm.battery?.hasBattery == true)
        #expect(vm.phase == .ready)          // phase 不受单指标失败拖累
        vm.stop()
    }

    @Test func stopHaltsLoops() async throws {
        let (vm, _) = makeVM(fast: 0.05, slow: 60)
        vm.start()
        try await Task.sleep(for: .milliseconds(500))   // 跑若干轮(留足并行负载余量)
        vm.stop()
        #expect(vm.phase == .idle)
        let frozen = vm.cpuHistory.count
        #expect(frozen >= 1)                            // 循环确实跑过
        try await Task.sleep(for: .milliseconds(200))
        #expect(vm.cpuHistory.count == frozen)          // 停摆后不再增长
    }

    @Test func setActivePausesAndResumes() async throws {
        let (vm, _) = makeVM(fast: 0.05, slow: 60)
        vm.start()
        try await Task.sleep(for: .milliseconds(150))
        vm.setActive(false)                             // 暂停:停循环、保留 started
        #expect(vm.phase != .idle)
        let paused = vm.cpuHistory.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(vm.cpuHistory.count == paused)          // 暂停期间不增长
        vm.setActive(true)                              // 恢复:曾 start 过则重启
        try await Task.sleep(for: .milliseconds(300))
        #expect(vm.cpuHistory.count > paused)           // 恢复后继续增长
        vm.stop()
    }

    @Test func setActiveTrueWithoutStartIsNoOp() async throws {
        let (vm, sampler) = makeVM(fast: 0.05, slow: 60)
        vm.setActive(true)                              // 从未 start 过 → 不建循环
        try await Task.sleep(for: .milliseconds(100))
        #expect(sampler.tickCallCount == 0)
        #expect(vm.phase == .idle)
    }

    @Test func cpuTicksFailureKeepsBaselineUnpolluted() {
        let (vm, sampler) = makeVM()
        sampler.cpuFails = true
        vm.start()
        #expect(vm.phase == .running)
        vm.refreshFast()
        vm.refreshFast()                       // 连续失败:不入历史、phase 不变
        #expect(vm.cpuHistory.isEmpty)
        #expect(vm.memory != nil)              // memory 照常落位
        #expect(vm.phase == .running)
        sampler.cpuFails = false
        vm.refreshFast()                       // 恢复:失败期间未存过脏基准 → 按首采样处理
        #expect(vm.cpuHistory.isEmpty)         // 仍不入(previousTicks 未被 nil 采样污染)
        vm.refreshFast()                       // 基准建立后恢复正常出点
        #expect(vm.cpuHistory.count == 1)
        vm.stop()
    }

    @Test func persistentCPUFailureSurfacesUnavailableThenRecovers() {
        let (vm, sampler) = makeVM()
        sampler.cpuFails = true
        vm.refreshFast()
        #expect(!vm.cpuUnavailable)            // 首次失败可能只是瞬时抖动
        vm.refreshFast()                       // 连续失败 → 暂不可用
        #expect(vm.cpuUnavailable)
        sampler.cpuFails = false
        vm.refreshFast()
        #expect(!vm.cpuUnavailable)            // 成功即清零
    }

    @Test func setNetworkStoresStatus() {
        let (vm, _) = makeVM()
        #expect(vm.network == nil)
        let status = NetworkStatus(online: true, interface: .wifi)
        vm.setNetwork(status)
        #expect(vm.network == status)
    }
}
