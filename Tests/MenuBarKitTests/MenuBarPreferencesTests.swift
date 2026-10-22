import Foundation
import Testing
import MenuBarKit

// 每实例唯一域:多 worktree/多会话会并发跑测试,固定域名 + removePersistentDomain
// 会跨进程互踩(同 AppCoreTests 的既有做法)。
@Suite final class MenuBarPreferencesTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "menubarprefs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store() -> UserDefaultsPreferenceStore {
        UserDefaultsPreferenceStore(defaults: defaults)
    }

    // MARK: - 默认值

    @Test func defaultValues() {
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

    // 设置页 Stepper 用字面量 70...95、步长 5 呈现本区间:界值必须能换算成整数
    // 百分比且步长恰好可达两界,防止未来改区间时与 UI 字面量漂移。
    // 乘 100 有浮点误差(0.70×100 ≠ 70.0),换算口径与 UI 的 rounded 一致。
    @Test func thresholdRangeMapsToWholePercentSteps() {
        let range = MenuBarPreferences.memoryThresholdRange
        #expect(Int((range.lowerBound * 100).rounded()) == 70)
        #expect(Int((range.upperBound * 100).rounded()) == 95)
        #expect((95 - 70) % 5 == 0)
    }

    // MARK: - 持久化往返

    @Test func storeRoundTripPreservesAllFields() {
        let store = store()
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
        #expect(store().load() == MenuBarPreferences())
    }

    // MARK: - 非法/越界外部写入

    @Test func unknownRawValuesFallBackToDefaults() {
        defaults.set("bogus", forKey: "menubar.metric")
        defaults.set("bogus", forKey: "menubar.iconStyle")

        let prefs = store().load()
        #expect(prefs.metric == .disk)
        #expect(prefs.iconStyle == .iconAndValue)
    }

    @Test func outOfRangeStoredThresholdIsClampedOnLoad() {
        let store = store()

        defaults.set(1.5, forKey: "menubar.memoryThreshold")
        #expect(store.load().memoryThreshold == 0.95)

        defaults.set(0.1, forKey: "menubar.memoryThreshold")
        #expect(store.load().memoryThreshold == 0.70)
    }

    @Test func nonFiniteThresholdFallsBackToDefault() {
        // NaN 不参与 min/max 夹取,必须显式回退,否则下游比较永久静默。
        #expect(MenuBarPreferences(memoryThreshold: .nan).memoryThreshold == 0.85)

        defaults.set(Double.nan, forKey: "menubar.memoryThreshold")
        #expect(store().load().memoryThreshold == 0.85)
    }

    @Test func nonNumericStoredValuesFallBackToDefaults() {
        // 外部写入类型不符时 as? 转换失败,不得崩溃或把阈值误读为 0。
        defaults.set("high", forKey: "menubar.memoryThreshold")
        defaults.set("true", forKey: "menubar.launchAtLogin")
        defaults.set("true", forKey: "menubar.notificationsEnabled")

        let prefs = store().load()
        #expect(prefs.memoryThreshold == 0.85)
        #expect(prefs.launchAtLogin == false)
        #expect(prefs.notificationsEnabled == false)
    }

    // MARK: - 通知时间戳

    @Test func lastNotifiedRoundTripKeepsSeconds() {
        let store = store()
        let diskDate = Date(timeIntervalSince1970: 1_700_000_123)
        let memoryDate = Date(timeIntervalSince1970: 1_700_000_456)

        store.saveLastNotified([.lowDisk: diskDate, .highMemory: memoryDate])
        let loaded = store.loadLastNotified()
        #expect(loaded.count == 2)
        #expect(loaded[.lowDisk] == diskDate)
        #expect(loaded[.highMemory] == memoryDate)
    }

    @Test func lastNotifiedKindsAreIndependent() {
        let store = store()
        let date = Date(timeIntervalSince1970: 1_700_000_789)

        store.saveLastNotified([.highMemory: date])
        let loaded = store.loadLastNotified()
        #expect(loaded[.highMemory] == date)
        #expect(loaded[.lowDisk] == nil)
    }

    @Test func lastNotifiedMissingKeysYieldEmptyDictionary() {
        #expect(store().loadLastNotified().isEmpty)
    }

    @Test func notificationKindRawValuesAreStable() {
        // 原始值即 UserDefaults 键后缀,改动会丢用户已存的通知时间。
        #expect(NotificationKind.lowDisk.rawValue == "lowDisk")
        #expect(NotificationKind.highMemory.rawValue == "highMemory")
    }
}
