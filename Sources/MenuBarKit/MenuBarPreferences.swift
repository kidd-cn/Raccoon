import Foundation

/// 通知类别。原始值参与 UserDefaults 键,新增取值不得改动既有原始值。
public enum NotificationKind: String, CaseIterable, Sendable, Equatable {
    case lowDisk, highMemory
}

/// 菜单栏偏好。阈值在 init 内夹取,保证任何来源(默认值、持久化、外部写入)
/// 得到的实例都落在合法区间。
public struct MenuBarPreferences: Equatable, Sendable {
    public static let memoryThresholdRange: ClosedRange<Double> = 0.70...0.95

    public let metric: MenuBarMetric
    public let iconStyle: MenuBarIconStyle
    public let launchAtLogin: Bool
    public let notificationsEnabled: Bool
    public let memoryThreshold: Double

    public init(
        metric: MenuBarMetric = .disk,
        iconStyle: MenuBarIconStyle = .iconAndValue,
        launchAtLogin: Bool = false,
        notificationsEnabled: Bool = false,
        memoryThreshold: Double = 0.85
    ) {
        self.metric = metric
        self.iconStyle = iconStyle
        self.launchAtLogin = launchAtLogin
        self.notificationsEnabled = notificationsEnabled
        // NaN 参与 min/max 仍是 NaN;若不拦,Task 3 的 >= 判定会永久不触发且无从察觉。
        guard memoryThreshold.isFinite else {
            self.memoryThreshold = 0.85
            return
        }
        self.memoryThreshold = min(
            max(memoryThreshold, Self.memoryThresholdRange.lowerBound),
            Self.memoryThresholdRange.upperBound
        )
    }
}

/// 偏好读写抽象,便于测试替换与 Task 4 的 ViewModel 隔离 UserDefaults。
public protocol MenuBarPreferenceStore: Sendable {
    func load() -> MenuBarPreferences
    func save(_ p: MenuBarPreferences)
    func loadLastNotified() -> [NotificationKind: Date]
    /// 按 kind 合并写入:未出现在 map 中的 kind 保留既有时间戳,不是整体替换。
    func saveLastNotified(_ m: [NotificationKind: Date])
}

public struct UserDefaultsPreferenceStore: MenuBarPreferenceStore {
    private enum Keys {
        static let metric = "menubar.metric"
        static let iconStyle = "menubar.iconStyle"
        static let launchAtLogin = "menubar.launchAtLogin"
        static let notificationsEnabled = "menubar.notificationsEnabled"
        static let memoryThreshold = "menubar.memoryThreshold"

        static func lastNotified(_ kind: NotificationKind) -> String {
            "menubar.lastNotified.\(kind.rawValue)"
        }
    }

    // UserDefaults 文档保证线程安全,但其类型未标注 Sendable,故显式声明。
    // 同时它本身是引用语义,不可改成 let 值拷贝。
    private nonisolated(unsafe) let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> MenuBarPreferences {
        let fallback = MenuBarPreferences()

        // 未知原始值(string(forKey:) 对非字符串也返回 nil)一律回退默认,
        // 避免外部写入非法值后得到不可渲染的枚举。
        let metric = defaults.string(forKey: Keys.metric)
            .flatMap(MenuBarMetric.init(rawValue:)) ?? fallback.metric
        let iconStyle = defaults.string(forKey: Keys.iconStyle)
            .flatMap(MenuBarIconStyle.init(rawValue:)) ?? fallback.iconStyle

        // 用 object(forKey:) 判定键是否存在:double(forKey:) 对缺失键返回 0,
        // 会被误当成「用户设了 0」再夹到下限。
        let threshold = (defaults.object(forKey: Keys.memoryThreshold) as? Double)
            ?? fallback.memoryThreshold

        return MenuBarPreferences(
            metric: metric,
            iconStyle: iconStyle,
            launchAtLogin: defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? fallback.launchAtLogin,
            notificationsEnabled: defaults.object(forKey: Keys.notificationsEnabled) as? Bool
                ?? fallback.notificationsEnabled,
            // init 会再次夹取,外部写入的越界阈值在此被修正。
            memoryThreshold: threshold
        )
    }

    public func save(_ p: MenuBarPreferences) {
        defaults.set(p.metric.rawValue, forKey: Keys.metric)
        defaults.set(p.iconStyle.rawValue, forKey: Keys.iconStyle)
        defaults.set(p.launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(p.notificationsEnabled, forKey: Keys.notificationsEnabled)
        defaults.set(p.memoryThreshold, forKey: Keys.memoryThreshold)
    }

    public func loadLastNotified() -> [NotificationKind: Date] {
        var result: [NotificationKind: Date] = [:]
        for kind in NotificationKind.allCases {
            guard let seconds = defaults.object(forKey: Keys.lastNotified(kind)) as? Double else {
                continue
            }
            result[kind] = Date(timeIntervalSince1970: seconds)
        }
        return result
    }

    public func saveLastNotified(_ m: [NotificationKind: Date]) {
        for (kind, date) in m {
            defaults.set(date.timeIntervalSince1970, forKey: Keys.lastNotified(kind))
        }
    }
}
