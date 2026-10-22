import Testing
import Foundation
import MonitorKit
import MenuBarKit
@testable import AppCore

// MARK: - 假体

/// 可编程采样假体(命名避开同模块 MonitorViewModelTests 的 FakeSampler):
/// cpuTicks 按调用序数放大,保证跨采样差值恒非零。
final class MenuBarFakeSampler: SystemSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var tickCalls = 0

    var memoryFails = false
    var cpuFails = false
    var volumesResult: [VolumeInfo] = [
        VolumeInfo(name: "Macintosh HD", totalBytes: 500, availableBytes: 100,
                   purgeableBytes: 50, isSystemDisk: true)
    ]
    var batteryResult = BatteryInfo(hasBattery: true, percentage: 66,
                                    charging: false, onBattery: true)

    /// 累计调用次数:验证 start 幂等时循环条数没有翻倍。
    var tickCallCount: Int { lock.withLock { tickCalls } }

    func volumes() -> [VolumeInfo] { volumesResult }

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
            // 单核四元组 (user, system, idle, nice):随序数增长 → 差值恒 > 0
            return [100 * n, 50 * n, 1000 * n, 0]
        }
    }

    func battery() -> BatteryInfo { batteryResult }
}

/// 内存偏好存储:记录写入次数,并模拟真实 store 的「按 kind 合并」语义,
/// 以便验证冷却时间戳跨 VM 实例(重启)仍生效。
final class FakePreferenceStore: MenuBarPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPreferences: MenuBarPreferences
    private var storedLastNotified: [NotificationKind: Date]
    private var preferenceSaveCount = 0
    private var notifiedSaveCount = 0

    init(preferences: MenuBarPreferences = MenuBarPreferences(),
         lastNotified: [NotificationKind: Date] = [:]) {
        storedPreferences = preferences
        storedLastNotified = lastNotified
    }

    var preferences: MenuBarPreferences { lock.withLock { storedPreferences } }
    var lastNotified: [NotificationKind: Date] { lock.withLock { storedLastNotified } }
    var saveCount: Int { lock.withLock { preferenceSaveCount } }
    var lastNotifiedSaveCount: Int { lock.withLock { notifiedSaveCount } }

    func load() -> MenuBarPreferences { lock.withLock { storedPreferences } }

    func save(_ p: MenuBarPreferences) {
        lock.withLock {
            storedPreferences = p
            preferenceSaveCount += 1
        }
    }

    func loadLastNotified() -> [NotificationKind: Date] { lock.withLock { storedLastNotified } }

    func saveLastNotified(_ m: [NotificationKind: Date]) {
        lock.withLock {
            for (kind, date) in m { storedLastNotified[kind] = date }
            notifiedSaveCount += 1
        }
    }
}

/// 通知假体:授权结果可设,顺序记录已投递类别。
final class FakeNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var postedKinds: [NotificationKind] = []
    private var authorizationRequests = 0
    var authorizationResult = true

    var posts: [NotificationKind] { lock.withLock { postedKinds } }
    var requestCount: Int { lock.withLock { authorizationRequests } }

    func requestAuthorization() async -> Bool {
        lock.withLock { authorizationRequests += 1 }
        return authorizationResult
    }

    func post(_ kind: NotificationKind) async {
        lock.withLock { postedKinds.append(kind) }
    }
}

/// 登录项假体:可设当前状态、成功后的状态与抛错;
/// `statusWhenThrowing` 模拟系统在失败路径上已改写状态,验证 VM 重读而非用旧值。
final class FakeLoginItem: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var setEnabledCalls: [Bool] = []

    var status: LoginItemStatus = .disabled
    var statusAfterSet: LoginItemStatus?
    var statusWhenThrowing: LoginItemStatus?
    var errorToThrow: Error?

    var calls: [Bool] { lock.withLock { setEnabledCalls } }

    func setEnabled(_ enabled: Bool) throws {
        if let errorToThrow {
            if let statusWhenThrowing { status = statusWhenThrowing }
            throw errorToThrow
        }
        lock.withLock { setEnabledCalls.append(enabled) }
        if let statusAfterSet { status = statusAfterSet }
    }

    func openSystemSettings() {}
}

/// 会挂起 post 的通知假体:用于强制两个评估方交错,
/// 钉住「第二次评估在第一次 await post 期间进入」这一真实竞态窗口。
final class SuspendingNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var postedKinds: [NotificationKind] = []
    private var postEntered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var posts: [NotificationKind] { lock.withLock { postedKinds } }
    var hasEnteredPost: Bool { lock.withLock { postEntered } }

    func requestAuthorization() async -> Bool { true }

    func post(_ kind: NotificationKind) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                postEntered = true
                continuations.append(continuation)
            }
        }
        lock.withLock { postedKinds.append(kind) }
    }

    /// 放行所有已挂起的 post(修复前会有两个,修复后只有一个)。
    func releaseAll() {
        let waiting = lock.withLock {
            let c = continuations
            continuations = []
            return c
        }
        for continuation in waiting { continuation.resume() }
    }

    /// 轮询等待首个 post 进入挂起状态(MainActor 上 Task.yield 让出即可推进)。
    func waitUntilPostEntered() async {
        while !hasEnteredPost { await Task.yield() }
    }
}

/// 授权可挂起的假 notifier:requestAuthorization 挂起直到 releaseAuthorization。
/// 用于钉住「授权在飞、用户再次切换」的代际竞态窗口——没有这个假体,
/// 「弹窗未落定用户就再点一次」的真实时序无法在测试里确定性地复现。
final class GatedAuthNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    var authorizationResult = true

    var hasEnteredRequest: Bool { lock.withLock { entered } }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                entered = true
                continuations.append(continuation)
            }
        }
        return authorizationResult
    }

    /// 放行所有挂起中的授权请求(结果取当前 authorizationResult)。
    func releaseAuthorization() {
        let waiting = lock.withLock {
            let c = continuations
            continuations = []
            return c
        }
        for continuation in waiting { continuation.resume() }
    }

    /// 轮询等待授权进入挂起(与 SuspendingNotifier.waitUntilPostEntered 同法)。
    func waitUntilRequestSuspended() async {
        while !hasEnteredRequest { await Task.yield() }
    }

    func post(_ kind: NotificationKind) async {}
}

/// 可变时钟:通知冷却需要推进时间,@Sendable 闭包通过引用盒子读取。
final class MutableClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) { self.now = now }
}

// MARK: - 测试

/// 冻结类用例用 60s 大间隔,只走手动 refresh 路径,不依赖真实计时;
/// 循环用例显式传小间隔。每个用例结束 vm.stop()。
@Suite @MainActor
final class MenuBarMonitorViewModelTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeVM(
        preferences: MenuBarPreferences = MenuBarPreferences(),
        store: FakePreferenceStore? = nil,
        notifier: any Notifying = FakeNotifier(),
        loginItem: FakeLoginItem = FakeLoginItem(),
        sampler: MenuBarFakeSampler = MenuBarFakeSampler(),
        fast: TimeInterval = 60,
        slow: TimeInterval = 60,
        clock: MutableClock? = nil
    ) -> MenuBarMonitorViewModel {
        let store = store ?? FakePreferenceStore(preferences: preferences)
        let date = fixedDate
        let box = clock
        return MenuBarMonitorViewModel(
            sampler: sampler,
            preferences: store,
            notifier: notifier,
            loginItem: loginItem,
            fastInterval: fast,
            slowInterval: slow,
            now: { box?.now ?? date }
        )
    }

    // 1. 初始化:label 按偏好即时算出,loginStatus 取自 fake
    @Test func initializationDerivesLabelFromPreferencesAndLoginStatus() {
        let login = FakeLoginItem()
        login.status = .requiresApproval
        let vm = makeVM(
            preferences: MenuBarPreferences(metric: .network, iconStyle: .iconAndValue),
            loginItem: login
        )
        #expect(vm.snapshot == MenuBarSnapshot())
        #expect(vm.label == MenuBarLabel.network(nil))
        #expect(vm.loginStatus == .requiresApproval)
        #expect(vm.isStarted == false)
        #expect(vm.notificationAuthorized == nil)
        #expect(vm.lastError == nil)
        vm.stop()
    }

    // 2. setMetric / setIconStyle 即时更新 label 并持久化
    @Test func setMetricAndIconStyleUpdateLabelAndPersist() {
        let store = FakePreferenceStore()
        let vm = makeVM(store: store)
        vm.refreshFast()                       // memory 8/16 → 50%
        vm.setMetric(.memory)
        #expect(vm.label == .percent(50))
        #expect(store.preferences.metric == .memory)

        vm.setIconStyle(.iconOnly)
        #expect(vm.label == .none)
        #expect(store.preferences.iconStyle == .iconOnly)
        #expect(store.saveCount == 2)          // 两次设置各保存一次
        vm.stop()
    }

    // 3. start 幂等:两次 start 不产生第二组循环(完全确定性)
    @Test func startIsIdempotent() async throws {
        let sampler = MenuBarFakeSampler()
        // 双循环各有一拍首采样;间隔 60s 保证窗口内不可能二拍,
        // 故 tick 次数恰为 1(= 一组循环),双循环会是 2。
        let vm = makeVM(sampler: sampler, fast: 60, slow: 60)
        vm.start()
        vm.start()
        #expect(vm.isStarted)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sampler.tickCallCount == 1)
        vm.stop()
        #expect(!vm.isStarted)
    }

    // 4. refreshNow 同步全量采样并更新 snapshot/label
    @Test func refreshNowSamplesAllMetricsAndUpdatesLabel() {
        let vm = makeVM()
        vm.refreshNow()
        #expect(vm.snapshot.volumes.count == 1)
        #expect(vm.snapshot.memory != nil)
        #expect(vm.snapshot.battery?.hasBattery == true)
        // 首拍无 CPU 基准,第二拍才有差值
        vm.refreshNow()
        #expect(vm.snapshot.cpu != nil)
        #expect(vm.label == .percent(20))      // 系统盘 100/500 可用 → 20%
        vm.stop()
    }

    // 5. 单指标失败隔离:memory/tick 为 nil 不拖累卷与电池,label 回退 .none
    @Test func singleMetricFailureIsIsolated() async {
        let sampler = MenuBarFakeSampler()
        sampler.memoryFails = true
        sampler.cpuFails = true
        let vm = makeVM(
            preferences: MenuBarPreferences(metric: .memory),
            sampler: sampler
        )
        vm.refreshFast()
        await vm.refreshSlow()
        #expect(vm.snapshot.memory == nil)
        #expect(vm.snapshot.cpu == nil)
        #expect(vm.snapshot.volumes.count == 1)
        #expect(vm.snapshot.battery?.hasBattery == true)
        #expect(vm.label == .none)
        vm.stop()
    }

    // 6. 通知:命中 → 冷却内不重复 → 冷却结束再发 → 跨 VM 实例仍生效
    @Test func notificationCooldownAcrossRefreshesAndRestarts() async {
        let clock = MutableClock(fixedDate)
        let store = FakePreferenceStore(
            preferences: MenuBarPreferences(notificationsEnabled: true)
        )
        let notifier = FakeNotifier()
        let vm = makeVM(store: store, notifier: notifier, clock: clock)

        await vm.refreshSlow()                 // 卷 100/500,字节 < 10GiB → 低磁盘
        #expect(notifier.posts == [.lowDisk])
        #expect(store.lastNotified[.lowDisk] == fixedDate)

        await vm.refreshSlow()                 // 同一 now:冷却中,不重复
        #expect(notifier.posts.count == 1)

        clock.now = fixedDate.addingTimeInterval(NotificationPolicy.cooldown)
        await vm.refreshSlow()                 // 恰好冷却结束:恢复提醒
        #expect(notifier.posts == [.lowDisk, .lowDisk])
        vm.stop()

        // 新 VM 复用同一 store:从持久化的时间戳恢复冷却
        let restoredNotifier = FakeNotifier()
        let restored = makeVM(store: store, notifier: restoredNotifier, clock: clock)
        await restored.refreshSlow()           // 距上次通知 0s
        #expect(restoredNotifier.posts.isEmpty)
        restored.stop()
    }

    // 7. 通知总开关关闭:条件满足也不投递
    @Test func disabledNotificationsDoNotPost() async {
        let notifier = FakeNotifier()
        let vm = makeVM(
            preferences: MenuBarPreferences(notificationsEnabled: false),
            notifier: notifier
        )
        await vm.refreshSlow()
        #expect(notifier.posts.isEmpty)
        #expect(notifier.requestCount == 0)
        vm.stop()
    }

    // 8. 授权被拒:不假装开启,偏好如实保存 false
    @Test func deniedAuthorizationKeepsNotificationsDisabled() async {
        let store = FakePreferenceStore()
        let notifier = FakeNotifier()
        notifier.authorizationResult = false
        let vm = makeVM(store: store, notifier: notifier)

        await vm.setNotificationsEnabled(true)
        #expect(vm.notificationAuthorized == false)
        #expect(vm.preferences.notificationsEnabled == false)
        #expect(store.preferences.notificationsEnabled == false)
        #expect(store.saveCount == 1)
        vm.stop()
    }

    // 8b. 授权通过:开启偏好并持久化,只请求一次
    @Test func grantedAuthorizationEnablesNotifications() async {
        let store = FakePreferenceStore()
        let notifier = FakeNotifier()
        notifier.authorizationResult = true
        let vm = makeVM(store: store, notifier: notifier)

        await vm.setNotificationsEnabled(true)
        #expect(vm.notificationAuthorized == true)
        #expect(vm.preferences.notificationsEnabled == true)
        #expect(store.preferences.notificationsEnabled == true)
        #expect(store.saveCount == 1)
        #expect(notifier.requestCount == 1)
        vm.stop()
    }

    // 8c. 关闭通知:直接保存 false,不触发授权请求
    @Test func disablingNotificationsSkipsAuthorizationRequest() async {
        let store = FakePreferenceStore(
            preferences: MenuBarPreferences(notificationsEnabled: true)
        )
        let notifier = FakeNotifier()
        let vm = makeVM(store: store, notifier: notifier)

        await vm.setNotificationsEnabled(false)
        #expect(vm.preferences.notificationsEnabled == false)
        #expect(store.preferences.notificationsEnabled == false)
        #expect(store.saveCount == 1)
        #expect(notifier.requestCount == 0)
        #expect(vm.notificationAuthorized == nil)
        vm.stop()
    }

    // 8d. 并发评估只投递一次:第一个评估挂在 post 上时第二个进入,应被挡下
    @Test func concurrentEvaluationsPostOnlyOnce() async throws {
        let notifier = SuspendingNotifier()
        let vm = makeVM(
            preferences: MenuBarPreferences(notificationsEnabled: true),
            notifier: notifier
        )
        let first = Task { await vm.refreshSlow() }
        await notifier.waitUntilPostEntered()
        let second = Task { await vm.refreshSlow() }
        try await Task.sleep(for: .milliseconds(50))   // 让第二个评估跑到 await 处
        notifier.releaseAll()
        await first.value
        await second.value
        #expect(notifier.posts == [.lowDisk])
        vm.stop()
    }

    // 8e. 授权挂起期间再关通知:迟到的 true 不得覆盖最后意图(代际守卫)
    @Test func staleAuthorizationIsDiscardedAfterNewerIntent() async throws {
        let store = FakePreferenceStore()
        let notifier = GatedAuthNotifier()
        notifier.authorizationResult = true
        let vm = makeVM(store: store, notifier: notifier)

        let onCall = Task { await vm.setNotificationsEnabled(true) }
        await notifier.waitUntilRequestSuspended()
        // 弹窗仍挂起时用户关闭通知:直接落 false,并作废在飞的授权结果
        await vm.setNotificationsEnabled(false)
        notifier.releaseAuthorization()   // 授权结果 true 迟到返回
        await onCall.value

        #expect(vm.preferences.notificationsEnabled == false)
        #expect(store.preferences.notificationsEnabled == false)
        // 仅 OFF 的一次 save:迟到结果既不写偏好也不写授权缓存(保持未询问态)
        #expect(store.saveCount == 1)
        #expect(vm.notificationAuthorized == nil)
        vm.stop()
    }

    // 9. requiresApproval 不是失败:记录开启意图,不设错误
    @Test func requiresApprovalRecordsIntentWithoutError() {
        let store = FakePreferenceStore()
        let login = FakeLoginItem()
        login.statusAfterSet = .requiresApproval
        let vm = makeVM(store: store, loginItem: login)

        vm.setLaunchAtLogin(true)
        #expect(vm.lastError == nil)
        #expect(vm.loginStatus == .requiresApproval)
        #expect(vm.preferences.launchAtLogin == true)
        #expect(store.preferences.launchAtLogin == true)
        #expect(login.calls == [true])
        vm.stop()
    }

    // 10. 自启抛错:错误为稳定码(视图层据此出文案),状态重读系统当前值
    @Test func loginItemErrorSurfacesAndKeepsStatus() {
        let store = FakePreferenceStore()
        let login = FakeLoginItem()
        login.status = .enabled
        login.statusWhenThrowing = .unavailable
        login.errorToThrow = NSError(domain: "test", code: 1)
        let vm = makeVM(store: store, loginItem: login)

        vm.setLaunchAtLogin(false)
        #expect(vm.lastError == "login-item")
        #expect(vm.loginStatus == .unavailable)   // 系统在失败路径上已改写状态
        #expect(vm.preferences.launchAtLogin == false)
        #expect(store.saveCount == 0)
        vm.stop()
    }

    // 11. 阈值 setter 走 init 的 clamp
    @Test func memoryThresholdIsClampedOnSet() {
        let store = FakePreferenceStore()
        let vm = makeVM(store: store)
        vm.setMemoryThreshold(1.0)
        #expect(vm.preferences.memoryThreshold == 0.95)
        #expect(store.preferences.memoryThreshold == 0.95)
        vm.stop()
    }

    // 12. stop 后重 start:循环确实重新工作,isStarted 状态正确
    @Test func stopThenStartRestartsLoops() async throws {
        let sampler = MenuBarFakeSampler()
        let vm = makeVM(sampler: sampler, fast: 60, slow: 60)
        vm.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sampler.tickCallCount == 1)

        vm.stop()
        #expect(!vm.isStarted)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sampler.tickCallCount == 1)    // 停摆后不再采样

        vm.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.isStarted)
        #expect(sampler.tickCallCount == 2)    // 重启后首拍继续
        vm.stop()
    }
}
