import Testing
import MonitorKit
import MenuBarKit

@Suite struct MenuBarLabelFormatterTests {

    private func volume(
        name: String = "Volume",
        total: Int64,
        available: Int64,
        isSystemDisk: Bool = false
    ) -> VolumeInfo {
        VolumeInfo(
            name: name,
            totalBytes: total,
            availableBytes: available,
            purgeableBytes: 0,
            isSystemDisk: isSystemDisk
        )
    }

    private func memory(total: Int64, used: Int64) -> MemoryStats {
        MemoryStats(
            totalBytes: total,
            usedBytes: used,
            compressedBytes: 0,
            wiredBytes: 0,
            purgeableFreeBytes: 0
        )
    }

    private func cpu(user: Double, system: Double) -> CPULoad {
        CPULoad(userPct: user, systemPct: system, idlePct: max(0, 100 - user - system))
    }

    // MARK: - 磁盘

    @Test func diskPercentRounds() {
        // 100/300 = 33.33…% → 33,钉住的是「可用/总量」的取值口径;
        // 四舍五入本身由 diskPercentRoundsHalfUp(62.5→63)覆盖。
        let snapshot = MenuBarSnapshot(volumes: [volume(total: 300, available: 100)])
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(33))
    }

    @Test func diskPercentRoundsHalfUp() {
        // 125/200 = 62.5% → 63(.5 进位)。
        let snapshot = MenuBarSnapshot(volumes: [volume(total: 200, available: 125)])
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(63))
    }

    @Test func diskSkipsZeroTotalVolumeWhenChoosing() {
        // 零容量卷排在最前也不得被选中,选卷应落到正常卷上。
        let zero = volume(name: "Zero", total: 0, available: 0)
        let normal = volume(name: "Normal", total: 100, available: 60)
        let snapshot = MenuBarSnapshot(volumes: [zero, normal])
        #expect(snapshot.diskVolume == normal)
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(60))
    }

    @Test func diskNegativeAvailableClampsToZero() {
        let snapshot = MenuBarSnapshot(volumes: [volume(total: 100, available: -20)])
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(0))
    }

    @Test func diskPrefersSystemDiskEvenWhenExternalHasLowerRatio() {
        let system = volume(name: "Macintosh HD", total: 100, available: 50, isSystemDisk: true)
        let external = volume(name: "External", total: 100, available: 10)
        let snapshot = MenuBarSnapshot(volumes: [external, system])
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(50))
    }

    @Test func diskPicksLowestAvailableRatioWhenNoSystemDisk() {
        let roomy = volume(name: "Roomy", total: 100, available: 40)
        let tight = volume(name: "Tight", total: 200, available: 20)
        let snapshot = MenuBarSnapshot(volumes: [roomy, tight])
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(10))
    }

    @Test func diskWithoutVolumesIsNone() {
        let label = MenuBarLabelFormatter.label(
            metric: .disk, style: .iconAndValue, snapshot: MenuBarSnapshot()
        )
        #expect(label == .none)
    }

    @Test func diskWithZeroTotalIsNone() {
        let snapshot = MenuBarSnapshot(volumes: [volume(total: 0, available: 0)])
        let label = MenuBarLabelFormatter.label(metric: .disk, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .none)
    }

    // MARK: - 内存

    @Test func memoryPercentRounds() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 200, used: 125))
        let label = MenuBarLabelFormatter.label(metric: .memory, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(63))
    }

    @Test func memoryWithoutDataIsNone() {
        let label = MenuBarLabelFormatter.label(
            metric: .memory, style: .iconAndValue, snapshot: MenuBarSnapshot()
        )
        #expect(label == .none)
    }

    @Test func memoryWithZeroTotalIsNone() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 0, used: 0))
        let label = MenuBarLabelFormatter.label(metric: .memory, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .none)
    }

    // MARK: - CPU

    @Test func cpuPercentRounds() {
        let snapshot = MenuBarSnapshot(cpu: cpu(user: 12.4, system: 5.4))
        let label = MenuBarLabelFormatter.label(metric: .cpu, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(18))
    }

    @Test func cpuPercentClampsToHundred() {
        let snapshot = MenuBarSnapshot(cpu: cpu(user: 90, system: 90))
        let label = MenuBarLabelFormatter.label(metric: .cpu, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .percent(100))
    }

    @Test func cpuWithoutDataIsNone() {
        let label = MenuBarLabelFormatter.label(
            metric: .cpu, style: .iconAndValue, snapshot: MenuBarSnapshot()
        )
        #expect(label == .none)
    }

    @Test func cpuNonFiniteIsNone() {
        let nan = MenuBarSnapshot(cpu: CPULoad(userPct: .nan, systemPct: 5, idlePct: 0))
        #expect(MenuBarLabelFormatter.label(metric: .cpu, style: .iconAndValue, snapshot: nan) == .none)

        let infinite = MenuBarSnapshot(cpu: CPULoad(userPct: .infinity, systemPct: 5, idlePct: 0))
        #expect(MenuBarLabelFormatter.label(metric: .cpu, style: .iconAndValue, snapshot: infinite) == .none)
    }

    // MARK: - 网络

    @Test func networkPassesStatusThrough() {
        let status = NetworkStatus(online: true, interface: .wifi)
        let snapshot = MenuBarSnapshot(network: status)
        let label = MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
        #expect(label == .network(status))
    }

    @Test func networkPassesNilThrough() {
        let label = MenuBarLabelFormatter.label(
            metric: .network, style: .iconAndValue, snapshot: MenuBarSnapshot()
        )
        #expect(label == .network(nil))
    }

    // MARK: - iconOnly

    @Test func iconOnlyIsAlwaysNone() {
        let snapshot = MenuBarSnapshot(
            volumes: [volume(total: 500, available: 200)],
            memory: memory(total: 200, used: 125),
            cpu: cpu(user: 12.4, system: 5.4),
            network: NetworkStatus(online: true, interface: .wired),
            // traffic 完整时 iconOnly 仍须 .none:样式 guard 先于 metric 分派,结构性质。
            traffic: NetworkTraffic(receivedBytes: 1, sentBytes: 2, receivedBPS: 1536, sentBPS: 512)
        )
        for metric in MenuBarMetric.allCases {
            let label = MenuBarLabelFormatter.label(
                metric: metric, style: .iconOnly, snapshot: snapshot
            )
            #expect(label == .none, "metric \(metric) should be .none for iconOnly")
        }
    }

    // MARK: - 快照模型

    @Test func snapshotDefaultsAreEmpty() {
        let snapshot = MenuBarSnapshot()
        #expect(snapshot.volumes.isEmpty)
        #expect(snapshot.memory == nil)
        #expect(snapshot.cpu == nil)
        #expect(snapshot.battery == nil)
        #expect(snapshot.network == nil)
        #expect(snapshot.diskVolume == nil)
    }

    @Test func diskVolumeIsSystemDiskWhenPresent() {
        let system = volume(name: "Macintosh HD", total: 100, available: 50, isSystemDisk: true)
        let external = volume(name: "External", total: 100, available: 10)
        let snapshot = MenuBarSnapshot(volumes: [external, system])
        #expect(snapshot.diskVolume == system)
    }

    // MARK: - 流量短格式(spec §3:1024 进制、一位小数、单位单字符)

    @Test func shortRateBytes() {
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(0) == "0B")
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(512) == "512B")
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(1023.9) == "1023B")
    }

    @Test func shortRateNegativeClampsToZero() {
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(-5) == "0B")
    }

    @Test func shortRateKiloMegaGiga() {
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(1024) == "1.0K")
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(1536) == "1.5K")
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(1_048_576) == "1.0M")
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(1_258_291.2) == "1.2M")
        #expect(MenuBarLabelFormatter.shortBytesPerSecond(1_288_490_188.8) == "1.2G")
    }

    @Test func networkLabelPrefersTrafficWhenRatesReady() {
        let traffic = NetworkTraffic(receivedBytes: 1, sentBytes: 2, receivedBPS: 1536, sentBPS: 512)
        let snapshot = MenuBarSnapshot(
            network: NetworkStatus(online: true, interface: .wifi), traffic: traffic)
        #expect(MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
            == .traffic(down: "1.5K", up: "512B"))
    }

    @Test func networkLabelFallsBackWithoutTraffic() {
        let snapshot = MenuBarSnapshot(network: NetworkStatus(online: true, interface: .wifi))
        #expect(MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
            == .network(NetworkStatus(online: true, interface: .wifi)))
    }

    @Test func networkLabelFallsBackWhenRatesPending() {
        // 首拍:traffic 在但速率为 nil(无差分基准)→ 回退接口文案
        let traffic = NetworkTraffic(receivedBytes: 1, sentBytes: 2, receivedBPS: nil, sentBPS: nil)
        let snapshot = MenuBarSnapshot(
            network: NetworkStatus(online: false, interface: .other), traffic: traffic)
        #expect(MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
            == .network(NetworkStatus(online: false, interface: .other)))
    }

    @Test func snapshotTrafficDefaultsToNil() {
        #expect(MenuBarSnapshot().traffic == nil)
    }
}
