import Foundation
import Observation
import MenuBarKit
import MonitorKit

/// 菜单栏常驻监控 VM:双频采样(fast = CPU/内存,slow = 卷/电池 + 通知评估),
/// 并把偏好、自启与通知授权状态聚合成视图可直接消费的只读面向。
/// 与五期 MonitorViewModel 共用 SystemSampling / computeCPULoad,但本类只服务
/// 菜单栏窄口径快照,不维护历史曲线与前台/后台状态机。
@MainActor
@Observable
public final class MenuBarMonitorViewModel {
    public private(set) var preferences: MenuBarPreferences
    public private(set) var snapshot: MenuBarSnapshot
    public private(set) var label: MenuBarLabel
    public private(set) var isStarted = false
    /// nil = 尚未询问过系统授权;false 表示明确被拒。
    public private(set) var notificationAuthorized: Bool?
    public private(set) var loginStatus: LoginItemStatus
    public private(set) var lastError: String?

    private let sampler: SystemSampling
    private let store: MenuBarPreferenceStore
    private let notifier: Notifying
    private let loginItem: LoginItemManaging
    private let fastInterval: TimeInterval
    private let slowInterval: TimeInterval
    private let now: @Sendable () -> Date

    /// 通知冷却时间戳:启动时从 store 恢复,跨重启仍生效。
    private var lastNotified: [NotificationKind: Date]
    /// 上一次 CPU tick:首采样无基准时 computeCPULoad 返回 nil。
    private var previousTicks: [Int32]?
    private var fastTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?

    public init(
        sampler: SystemSampling,
        preferences: MenuBarPreferenceStore,
        notifier: Notifying,
        loginItem: LoginItemManaging,
        fastInterval: TimeInterval = 5,
        slowInterval: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sampler = sampler
        self.store = preferences
        self.notifier = notifier
        self.loginItem = loginItem
        self.fastInterval = fastInterval
        self.slowInterval = slowInterval
        self.now = now

        let loaded = preferences.load()
        self.preferences = loaded
        self.lastNotified = preferences.loadLastNotified()
        self.loginStatus = loginItem.status
        // 初始快照为空:此时 label 只能是 .none / .network(nil),
        // 但必须按已加载偏好计算,保证首帧样式与指标一致。
        let empty = MenuBarSnapshot()
        self.snapshot = empty
        self.label = MenuBarLabelFormatter.label(
            metric: loaded.metric,
            style: loaded.iconStyle,
            snapshot: empty
        )
    }

    // MARK: - 循环生命周期

    /// 幂等:已启动时忽略重复调用,避免叠加第二组循环。
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        startLoops()
    }

    /// 停止循环但保留已采数据与偏好,菜单栏在重开前仍可展示最后快照。
    public func stop() {
        cancelLoops()
        isStarted = false
    }

    /// 手动全量刷新:同步完成采样,通知评估因需 await 交给短命 Task,
    /// 不让同步接口阻塞调用方(菜单栏点击/首帧)。循环路径仍走 refreshSlow。
    public func refreshNow() {
        refreshFast()
        sampleSlowMetrics()
        Task { [weak self] in
            await self?.evaluateNotifications()
        }
    }

    /// 快频:memory + CPU。单项取不到时保留旧值,其余字段与 label 照常更新。
    public func refreshFast() {
        let memory = sampler.memory()
        var cpu = snapshot.cpu
        if let current = sampler.cpuTicks() {
            if let load = computeCPULoad(previous: previousTicks, current: current) {
                cpu = load
            }
            // 基准无条件前移:无效区间(长度不符等)只丢当前点,下轮即恢复。
            previousTicks = current
        }
        updateSnapshot(memory: memory, cpu: cpu)
    }

    /// 慢频:卷 + 电池,再按冷却表评估通知。
    public func refreshSlow() async {
        sampleSlowMetrics()
        await evaluateNotifications()
        recomputeLabel()
    }

    private func startLoops() {
        let fast = fastInterval
        let slow = slowInterval
        // [weak self]:VM 释放后循环随下一拍自然退出,不持有已销毁的观察对象。
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
                await self.refreshSlow()
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

    // MARK: - 采样

    private func sampleSlowMetrics() {
        let fresh = sampler.volumes()
        // 空列表按采集失败处理,保留旧值——与五期 MonitorViewModel 口径一致。
        let volumes = fresh.isEmpty ? snapshot.volumes : fresh
        updateSnapshot(volumes: volumes, battery: sampler.battery())
    }

    /// 通知评估与冷却落盘。命中项才写时间戳,saveLastNotified 按 kind 合并。
    private func evaluateNotifications() async {
        let hits = NotificationPolicy.evaluate(
            snapshot: snapshot,
            preferences: preferences,
            lastNotified: lastNotified,
            now: now()
        )
        guard !hits.isEmpty else { return }
        for kind in hits {
            await notifier.post(kind)
            lastNotified[kind] = now()
        }
        store.saveLastNotified(lastNotified)
    }

    // MARK: - 偏好与系统状态

    public func setNetwork(_ status: NetworkStatus) {
        updateSnapshot(network: status)
    }

    public func setMetric(_ metric: MenuBarMetric) {
        savePreferences(metric: metric)
    }

    public func setIconStyle(_ style: MenuBarIconStyle) {
        savePreferences(iconStyle: style)
    }

    public func setMemoryThreshold(_ value: Double) {
        // 交给 MenuBarPreferences.init 统一 clamp / NaN 回退。
        savePreferences(memoryThreshold: value)
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginStatus = loginItem.status
            lastError = nil
            // requiresApproval 也走成功路径:系统已登记,记录用户开启意图,
            // UI 再据 loginStatus 引导用户去设置中批准。
            savePreferences(launchAtLogin: enabled)
        } catch {
            let message = error.localizedDescription
            lastError = message.isEmpty ? "无法更新登录项" : message
            // 失败时状态可能已被系统改写,以 fake/系统当前值为准,不回填成功偏好。
            loginStatus = loginItem.status
        }
    }

    public func openLoginItemSystemSettings() {
        loginItem.openSystemSettings()
    }

    public func setNotificationsEnabled(_ enabled: Bool) async {
        guard enabled else {
            savePreferences(notificationsEnabled: false)
            return
        }
        let authorized = await notifier.requestAuthorization()
        notificationAuthorized = authorized
        // 授权被拒时如实保存 false,不假装开启。
        savePreferences(notificationsEnabled: authorized)
    }

    // MARK: - 状态合成

    /// 以「未传即保留」的语义重建不可变快照,并同步重算 label。
    /// 各指标只在自己成功采样时传入新值,天然实现单指标失败隔离。
    private func updateSnapshot(
        volumes: [VolumeInfo]? = nil,
        memory: MemoryStats? = nil,
        cpu: CPULoad? = nil,
        battery: BatteryInfo? = nil,
        network: NetworkStatus? = nil
    ) {
        snapshot = MenuBarSnapshot(
            volumes: volumes ?? snapshot.volumes,
            memory: memory ?? snapshot.memory,
            cpu: cpu ?? snapshot.cpu,
            battery: battery ?? snapshot.battery,
            network: network ?? snapshot.network
        )
        recomputeLabel()
    }

    private func savePreferences(
        metric: MenuBarMetric? = nil,
        iconStyle: MenuBarIconStyle? = nil,
        launchAtLogin: Bool? = nil,
        notificationsEnabled: Bool? = nil,
        memoryThreshold: Double? = nil
    ) {
        let updated = MenuBarPreferences(
            metric: metric ?? preferences.metric,
            iconStyle: iconStyle ?? preferences.iconStyle,
            launchAtLogin: launchAtLogin ?? preferences.launchAtLogin,
            notificationsEnabled: notificationsEnabled ?? preferences.notificationsEnabled,
            memoryThreshold: memoryThreshold ?? preferences.memoryThreshold
        )
        preferences = updated
        store.save(updated)
        recomputeLabel()
    }

    private func recomputeLabel() {
        label = MenuBarLabelFormatter.label(
            metric: preferences.metric,
            style: preferences.iconStyle,
            snapshot: snapshot
        )
    }
}
