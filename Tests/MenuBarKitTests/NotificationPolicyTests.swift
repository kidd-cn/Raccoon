import Foundation
import Testing
import MonitorKit
import MenuBarKit

@Suite struct NotificationPolicyTests {

    private let gib: Int64 = 1_073_741_824
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

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

    /// 测试默认打开通知开关——生产默认是关闭的,真值表必须显式表达意图。
    private func prefs(threshold: Double = 0.85, enabled: Bool = true) -> MenuBarPreferences {
        MenuBarPreferences(notificationsEnabled: enabled, memoryThreshold: threshold)
    }

    private func disk(_ v: VolumeInfo) -> MenuBarSnapshot {
        MenuBarSnapshot(volumes: [v])
    }

    private func evaluate(
        _ snapshot: MenuBarSnapshot,
        _ preferences: MenuBarPreferences? = nil,
        lastNotified: [NotificationKind: Date] = [:],
        now: Date? = nil
    ) -> [NotificationKind] {
        NotificationPolicy.evaluate(
            snapshot: snapshot,
            preferences: preferences ?? prefs(),
            lastNotified: lastNotified,
            now: now ?? self.now
        )
    }

    // MARK: - 总开关

    @Test func disabledNotificationsReturnEmptyEvenWhenBothConditionsHit() {
        let snapshot = MenuBarSnapshot(
            volumes: [volume(total: 100 * gib, available: 1 * gib)],
            memory: memory(total: 100 * gib, used: 95 * gib)
        )
        #expect(evaluate(snapshot, prefs(enabled: false)).isEmpty)
    }

    // MARK: - 低磁盘比例边界

    @Test func diskFractionExactlyTenthWithEnoughBytesDoesNotTrigger() {
        // 20 GiB / 200 GiB = 0.10 恰在边界,严格小于才触发。
        let snapshot = disk(volume(total: 200 * gib, available: 20 * gib))
        #expect(evaluate(snapshot).isEmpty)
    }

    @Test func diskFractionJustBelowTenthTriggers() {
        let snapshot = disk(volume(total: 200 * gib, available: 20 * gib - 1))
        #expect(evaluate(snapshot) == [.lowDisk])
    }

    // MARK: - 低磁盘字节边界

    @Test func diskBytesExactlyThresholdWithSufficientFractionDoesNotTrigger() {
        // 10 GiB / 100 GiB 同时踩在比例与字节两条边界上,均须「严格小于」。
        let snapshot = disk(volume(total: 100 * gib, available: 10 * gib))
        #expect(evaluate(snapshot).isEmpty)
    }

    @Test func diskBytesOneBelowThresholdTriggers() {
        // 比例约 0.20 远高于 0.10,单独钉住字节阈值。
        let snapshot = disk(volume(total: 50 * gib, available: 10 * gib - 1))
        #expect(evaluate(snapshot) == [.lowDisk])
    }

    @Test func diskNegativeAvailableTriggers() {
        // 负可用值多来自采集异常,语义上仍代表空间极度不足,应告警。
        let snapshot = disk(volume(total: 100 * gib, available: -1))
        #expect(evaluate(snapshot) == [.lowDisk])
    }

    @Test func diskZeroTotalUsesBytesOnly() {
        // 容量未知(0)不得按 0% 比例判空盘;可用字节充足时不触发。
        let snapshot = disk(volume(total: 0, available: 500 * gib))
        #expect(evaluate(snapshot).isEmpty)
    }

    // MARK: - 内存阈值边界

    @Test func memoryAtThresholdTriggers() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 85 * gib))
        #expect(evaluate(snapshot) == [.highMemory])
    }

    @Test func memoryBelowThresholdDoesNotTrigger() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 84 * gib))
        #expect(evaluate(snapshot).isEmpty)
    }

    @Test func memoryWithZeroTotalIsDefensivelyIgnored() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 0, used: 0))
        #expect(evaluate(snapshot).isEmpty)
    }

    // MARK: - 冷却

    @Test func cooldownJustUnderSkips() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 90 * gib))
        let last = [NotificationKind.highMemory: now.addingTimeInterval(-21_599)]
        #expect(evaluate(snapshot, lastNotified: last).isEmpty)
    }

    @Test func cooldownExactlyElapsedTriggers() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 90 * gib))
        let last = [NotificationKind.highMemory: now.addingTimeInterval(-NotificationPolicy.cooldown)]
        #expect(evaluate(snapshot, lastNotified: last) == [.highMemory])
    }

    @Test func cooldownIsPerKind() {
        let snapshot = MenuBarSnapshot(
            volumes: [volume(total: 100 * gib, available: 5 * gib)],
            memory: memory(total: 100 * gib, used: 95 * gib)
        )
        let last = [NotificationKind.highMemory: now.addingTimeInterval(-1)]
        #expect(evaluate(snapshot, lastNotified: last) == [.lowDisk])
    }

    @Test func missingLastNotifiedEntryIsTreatedAsNeverNotified() {
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 90 * gib))
        #expect(evaluate(snapshot, lastNotified: [:]) == [.highMemory])
    }

    @Test func clockRollbackKeepsCooldownActive() {
        // 系统时钟回拨使间隔为负,仍小于冷却时长,应视为冷却中。
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 90 * gib))
        let last = [NotificationKind.highMemory: now.addingTimeInterval(60)]
        #expect(evaluate(snapshot, lastNotified: last).isEmpty)
    }

    // MARK: - 组合与顺序

    @Test func bothConditionsReturnLowDiskFirst() {
        let snapshot = MenuBarSnapshot(
            volumes: [volume(total: 100 * gib, available: 5 * gib)],
            memory: memory(total: 100 * gib, used: 95 * gib)
        )
        #expect(evaluate(snapshot) == [.lowDisk, .highMemory])
    }

    @Test func emptySnapshotReturnsEmpty() {
        #expect(evaluate(MenuBarSnapshot()).isEmpty)
    }

    // MARK: - 选卷规则

    @Test func healthySystemDiskWinsOverLowExternalVolume() {
        // 外置卷比例更低,但系统盘优先后不应因外置卷触发。
        let system = volume(name: "Macintosh HD", total: 100 * gib, available: 50 * gib, isSystemDisk: true)
        let external = volume(name: "External", total: 100 * gib, available: 1 * gib)
        let snapshot = MenuBarSnapshot(volumes: [external, system])
        #expect(evaluate(snapshot).isEmpty)
    }

    @Test func withoutSystemDiskLowestRatioVolumeIsChosen() {
        let roomy = volume(name: "Roomy", total: 100 * gib, available: 50 * gib)
        let tight = volume(name: "Tight", total: 200 * gib, available: 10 * gib)
        let snapshot = MenuBarSnapshot(volumes: [roomy, tight])
        #expect(evaluate(snapshot) == [.lowDisk])
    }

    // MARK: - 自定义阈值

    @Test func customThresholdOverridesDefault() {
        // 88% 已超默认 0.85 但未到自定义 0.90。
        let snapshot = MenuBarSnapshot(memory: memory(total: 100 * gib, used: 88 * gib))
        #expect(evaluate(snapshot) == [.highMemory])
        #expect(evaluate(snapshot, prefs(threshold: 0.90)).isEmpty)
    }

    // MARK: - 常量

    @Test func policyConstantsMatchSpec() {
        #expect(NotificationPolicy.cooldown == 21_600)
        #expect(NotificationPolicy.lowDiskFraction == 0.10)
        #expect(NotificationPolicy.lowDiskBytes == 10_737_418_240)
    }
}
