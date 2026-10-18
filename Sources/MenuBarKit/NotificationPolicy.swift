import Foundation
import MonitorKit

/// 通知触发策略:纯函数真值表,不做任何 I/O 或状态写入。
/// 调用方负责把返回的 kind 落成通知,并把 `now` 写回时间戳存储。
public enum NotificationPolicy {
    /// 同类通知的最小间隔(6 小时):既避免刷屏,也保证长时间故障仍有提醒。
    public static let cooldown: TimeInterval = 21_600

    /// 低磁盘阈值取「比例或绝对字节」双条件:小容量卷按比例可能过早告警,
    /// 大容量卷按比例又可能等到字节殆尽才提示,二者取「或」覆盖两种极端。
    public static let lowDiskFraction = 0.10
    public static let lowDiskBytes: Int64 = 10_737_418_240

    /// 返回本次应发送的通知,顺序固定为低磁盘在前、高内存在后。
    public static func evaluate(
        snapshot: MenuBarSnapshot,
        preferences: MenuBarPreferences,
        lastNotified: [NotificationKind: Date],
        now: Date
    ) -> [NotificationKind] {
        guard preferences.notificationsEnabled else { return [] }

        var result: [NotificationKind] = []
        if isLowDisk(snapshot), isDue(.lowDisk, lastNotified: lastNotified, now: now) {
            result.append(.lowDisk)
        }
        if isHighMemory(snapshot, threshold: preferences.memoryThreshold),
           isDue(.highMemory, lastNotified: lastNotified, now: now) {
            result.append(.highMemory)
        }
        return result
    }

    private static func isLowDisk(_ snapshot: MenuBarSnapshot) -> Bool {
        guard let volume = snapshot.diskVolume else { return false }
        let fraction = volume.totalBytes > 0
            ? Double(volume.availableBytes) / Double(volume.totalBytes)
            : 0
        return fraction < lowDiskFraction || volume.availableBytes < lowDiskBytes
    }

    private static func isHighMemory(_ snapshot: MenuBarSnapshot, threshold: Double) -> Bool {
        guard let memory = snapshot.memory, memory.totalBytes > 0 else { return false }
        return Double(memory.usedBytes) / Double(memory.totalBytes) >= threshold
    }

    /// 时间戳缺失视为从未通知;用 >= 让恰好冷却结束时恢复提醒。
    private static func isDue(
        _ kind: NotificationKind,
        lastNotified: [NotificationKind: Date],
        now: Date
    ) -> Bool {
        guard let last = lastNotified[kind] else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }
}
