import Foundation
import Testing
import MenuBarKit

// 串行执行:所有用例共享同一 UserDefaults 域,并行时彼此的清域会互相踩踏。
@Suite(.serialized) struct MenuBarPreferencesTests {

    private static let suiteName = "com.raccooncleaner.Raccoon.tests.menubarprefs"

    /// 每个用例独占干净 suite:UserDefaults 按域缓存,不清域会跨用例串扰。
    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        return defaults
    }

    private func cleanup(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: Self.suiteName)
    }

    // MARK: - 默认值

    @Test func defaults() {
        let prefs = MenuBarPreferences()
        #expect(prefs.metric == .disk)
        #expect(prefs.iconStyle == .iconAndValue)
        #expect(prefs.launchAtLogin == false)
        #expect(prefs.notificationsEnabled == false)
        #expect(prefs.memoryThreshold == 0.85)
    }

    // MARK: - 阈值 clamp

    @Test func thresholdBelowRangeClampsToLowerBound() {
        #expect(MenuBarPreferences(memoryThreshold: 0.5).memoryThreshold == 0.70)
    }

    @Test func thresholdAboveRangeClampsToUpperBound() {
        #expect(MenuBarPreferences(memoryThreshold: 1.0).memoryThreshold == 0.95)
    }

    @Test func thresholdInRangeIsKept() {
        #expect(MenuBarPreferences(memoryThreshold: 0.80).memoryThreshold == 0.80)
    }

    // MARK: - 持久化往返

    @Test func storeRoundTripPreservesAllFields() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)
        let prefs = MenuBarPreferences(
            metric: .memory,
            iconStyle: .iconOnly,
            launchAtLogin: true,
            notificationsEnabled: true,
            memoryThreshold: 0.90
        )

        store.save(prefs)
        #expect(store.load() == prefs)
    }

    @Test func storeLoadsDefaultsWhenSuiteIsEmpty() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)
        #expect(store.load() == MenuBarPreferences())
    }

    // MARK: - 非法/越界外部写入

    @Test func unknownRawValuesFallBackToDefaults() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        defaults.set("bogus", forKey: "menubar.metric")
        defaults.set("bogus", forKey: "menubar.iconStyle")

        let prefs = UserDefaultsPreferenceStore(defaults: defaults).load()
        #expect(prefs.metric == .disk)
        #expect(prefs.iconStyle == .iconAndValue)
    }

    @Test func outOfRangeStoredThresholdIsClampedOnLoad() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)

        defaults.set(1.5, forKey: "menubar.memoryThreshold")
        #expect(store.load().memoryThreshold == 0.95)

        defaults.set(0.1, forKey: "menubar.memoryThreshold")
        #expect(store.load().memoryThreshold == 0.70)
    }

    // MARK: - 通知时间戳

    @Test func lastNotifiedRoundTripKeepsSeconds() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)
        let diskDate = Date(timeIntervalSince1970: 1_700_000_123)
        let memoryDate = Date(timeIntervalSince1970: 1_700_000_456)

        store.saveLastNotified([.lowDisk: diskDate, .highMemory: memoryDate])
        let loaded = store.loadLastNotified()
        #expect(loaded.count == 2)
        #expect(loaded[.lowDisk] == diskDate)
        #expect(loaded[.highMemory] == memoryDate)
    }

    @Test func lastNotifiedKindsAreIndependent() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)
        let date = Date(timeIntervalSince1970: 1_700_000_789)

        store.saveLastNotified([.highMemory: date])
        let loaded = store.loadLastNotified()
        #expect(loaded[.highMemory] == date)
        #expect(loaded[.lowDisk] == nil)
    }

    @Test func lastNotifiedMissingKeysYieldEmptyDictionary() {
        let defaults = makeDefaults()
        defer { cleanup(defaults) }
        let store = UserDefaultsPreferenceStore(defaults: defaults)
        #expect(store.loadLastNotified().isEmpty)
    }

    @Test func notificationKindRawValuesAreStable() {
        // 原始值即 UserDefaults 键后缀,改动会丢用户已存的通知时间。
        #expect(NotificationKind.lowDisk.rawValue == "lowDisk")
        #expect(NotificationKind.highMemory.rawValue == "highMemory")
    }
}
