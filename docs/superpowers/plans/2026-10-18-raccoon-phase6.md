# 六期:菜单栏工具集 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Raccoon 做成常驻菜单栏的只读监控仪:四选一常驻指标、五类指标下拉面板、快捷入口、开机自启、阈值通知与图标样式。

**Architecture:** 新增纯逻辑 `MenuBarKit`(依赖 `MonitorKit`)承载格式化/偏好/通知策略与系统缝隙协议;`AppCore` 新增 `MenuBarMonitorViewModel` 独立采样;`Raccoon` 层放 `MenuBarExtra` UI、`SMAppService`/`UNUserNotificationCenter` 薄壳与设置页。所有删除与清理动作不进入本期。

**Tech Stack:** Swift 6 + SwiftUI(`MenuBarExtra`)、`ServiceManagement`(`SMAppService`)、`UserNotifications`、Observation;零第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-18-raccoon-phase6-design.md`

## Global Constraints

- `Package.swift` tools-version 保持 `6.3`;macOS 14+;零第三方依赖。
- 仅 Command Line Tools 工具链:SwiftUI 宏不可用,`@State` 手写展开(见 `RaccoonApp.swift` 注释);`@Bindable`、`@Observable` 可用。
- 测试唯一入口 `Scripts/test.sh`(禁止裸 `swift test`);全量基线 **300**,只增不减。
- 红线:`Sources/` 下零新增 `removeItem`/`unlink` 实现调用;唯一删除实现仍为 `Sources/CleanKit/TrashService.swift:21` 的 `trashItem`;零新增 `Process(`;`rules.json` 不改;非沙盒、免 root。
- 系统能力(`SMAppService`、`UNUserNotificationCenter`、`UserDefaults`)必须在协议后;壳不单测,纯逻辑全测。
- L10n en/zh 键集严格 1:1;zh 值使用全角标点;本地化文案只出现在 `Sources/Raccoon` 层。
- 不 push、不 merge、不 force-push,除非用户明确指令。
- 每任务结束提交一次,提交信息用下文给出的原文。

## Review Focus

1. **多卷场景**:磁盘 label 与低磁盘通知必须选系统盘(无系统盘标记时取可用比例最低的卷),不得把外置卷误报为系统盘或反之——Task 1/3 的测试钉死。
2. **通知边界与冷却**:比例恰 10%、字节恰 10 GiB 不触发;6h 冷却跨应用重启仍生效(时间戳持久化)——Task 3/4 测试钉死。
3. **授权与拒绝**:通知授权被拒、自启处于「需要批准」时,UI 与持久化偏好不得假装成功——Task 4 测试 + Task 8 UI。
4. **生命周期**:主窗口关闭后菜单栏 label 仍持续刷新;面板每次打开先 `refreshNow()` 取最新值,不展示陈旧快照——Task 7 + 人工项。
5. **本地化与宽度**:en/zh 下菜单栏文字、`iconOnly` 回退、无数据 `—` 均正确,窄菜单栏不溢出——Task 1/7/8 + 人工项。

---

### Task 1: MenuBarKit target、快照模型与 label 格式化

**Files:**
- Modify: `Package.swift`(新增 `MenuBarKit` target,deps `["MonitorKit"]`;新增 `MenuBarKitTests`;`AppCore` deps 追加 `"MenuBarKit"`)
- Create: `Sources/MenuBarKit/MenuBarModels.swift`
- Create: `Sources/MenuBarKit/MenuBarLabelFormatter.swift`
- Test: `Tests/MenuBarKitTests/MenuBarLabelFormatterTests.swift`

**Interfaces:**
- Consumes: `MonitorKit` 的 `VolumeInfo`、`MemoryStats`、`CPULoad`、`BatteryInfo`、`NetworkStatus`
- Produces:
  - `public enum MenuBarMetric: String, CaseIterable, Sendable, Equatable { case disk, memory, cpu, network }`
  - `public enum MenuBarIconStyle: String, CaseIterable, Sendable, Equatable { case iconOnly, iconAndValue }`
  - `public struct MenuBarSnapshot: Equatable, Sendable` 字段 `volumes: [VolumeInfo]`、`memory: MemoryStats?`、`cpu: CPULoad?`、`battery: BatteryInfo?`、`network: NetworkStatus?`;`public init(volumes:memory:cpu:battery:network:)` 全部带默认值
  - `public extension MenuBarSnapshot { var diskVolume: VolumeInfo? }`
  - `public enum MenuBarLabel: Equatable, Sendable { case percent(Int), network(NetworkStatus?), none }`
  - `public enum MenuBarLabelFormatter { public static func label(metric:style:snapshot:) -> MenuBarLabel }`

- [ ] **Step 1: 写失败测试**

覆盖:系统盘优先(外置卷可用比例更低也不选它);无系统盘标记时取最低可用比例卷;空卷 → `.none`;`totalBytes <= 0` → `.none`;百分比四舍五入(内存 125/200 → `.percent(63)`);CPU `12.4 + 5.4 → .percent(18)`、超 100 clamp 到 100;`iconOnly` 恒 `.none`;network 原样透传。

- [ ] **Step 2: 跑测试确认失败**

`Scripts/test.sh --filter MenuBarLabelFormatterTests` → 编译失败(类型不存在)。

- [ ] **Step 3: 实现**

`MenuBarSnapshot.diskVolume`:`volumes.first(where: \.isSystemDisk) ?? volumes.min(by: freeFraction)`;`freeFraction = total > 0 ? Double(available)/Double(total) : 0`。格式化规则严格照 spec §5.1:百分比 = `Int((ratio * 100).rounded())` 后 clamp `0...100`;无数据 → `.none`。

- [ ] **Step 4: 跑测试确认通过**

`Scripts/test.sh --filter MenuBarLabelFormatterTests`;再跑全量 ≥ 300。

- [ ] **Step 5: 提交**

`feat(menubar): MenuBarKit 与菜单栏文案格式化`

---

### Task 2: 偏好模型、持久化与冷却时间戳

**Files:**
- Create: `Sources/MenuBarKit/MenuBarPreferences.swift`
- Test: `Tests/MenuBarKitTests/MenuBarPreferencesTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `MenuBarMetric` / `MenuBarIconStyle`
- Produces:
  - `public enum NotificationKind: String, CaseIterable, Sendable, Equatable { case lowDisk, highMemory }`(由 Task 2 先定义,Task 3 的策略消费)
  - `public struct MenuBarPreferences: Equatable, Sendable` 字段 `metric`、`iconStyle`、`launchAtLogin`、`notificationsEnabled`、`memoryThreshold: Double`;`public static let memoryThresholdRange: ClosedRange<Double> = 0.70...0.95`;`public init(metric: .disk, iconStyle: .iconAndValue, launchAtLogin: false, notificationsEnabled: false, memoryThreshold: 0.85)`(init 内 clamp)
  - `public protocol MenuBarPreferenceStore: Sendable { func load() -> MenuBarPreferences; func save(_ p: MenuBarPreferences); func loadLastNotified() -> [NotificationKind: Date]; func saveLastNotified(_ m: [NotificationKind: Date]) }`
  - `public struct UserDefaultsPreferenceStore: MenuBarPreferenceStore { public init(defaults: UserDefaults = .standard) }`

- [ ] **Step 1: 写失败测试**

默认值;阈值 clamp(0.5 → 0.70,1.0 → 0.95,0.80 原样);`UserDefaults` 往返(用独立 `suiteName` + 测试后 `removePersistentDomain`);未知 raw 值回退默认;`lastNotified` 往返保留两种 kind 的秒级精度。

- [ ] **Step 2: 跑测试确认失败**

`Scripts/test.sh --filter MenuBarPreferencesTests`。

- [ ] **Step 3: 实现**

`UserDefaultsPreferenceStore` 键:`menubar.metric`、`menubar.iconStyle`、`menubar.launchAtLogin`、`menubar.notificationsEnabled`、`menubar.memoryThreshold`、`menubar.lastNotified.<kind.rawValue>`(`timeIntervalSince1970`)。`UserDefaults` 非 Sendable → `nonisolated(unsafe) let defaults`(官方线程安全)。`NotificationKind` 在本任务定义,供 Task 3 消费。

- [ ] **Step 4: 跑测试确认通过**

`Scripts/test.sh --filter MenuBarPreferencesTests`;全量 ≥ 300。

- [ ] **Step 5: 提交**

`feat(menubar): 菜单栏偏好与通知冷却时间戳持久化`

---

### Task 3: 通知策略与系统缝隙协议

**Files:**
- Create: `Sources/MenuBarKit/NotificationPolicy.swift`
- Create: `Sources/MenuBarKit/SystemSeams.swift`
- Test: `Tests/MenuBarKitTests/NotificationPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1/2 的 `MenuBarSnapshot`、`MenuBarPreferences`
- Produces:
  - `public enum NotificationPolicy`:`static let cooldown: TimeInterval = 21_600`、`static let lowDiskFraction = 0.10`、`static let lowDiskBytes: Int64 = 10_737_418_240`、`public static func evaluate(snapshot:preferences:lastNotified:now:) -> [NotificationKind]`
  - `public enum LoginItemStatus: Equatable, Sendable { case disabled, enabled, requiresApproval, unavailable }`
  - `public protocol LoginItemManaging: Sendable { var status: LoginItemStatus { get }; func setEnabled(_ enabled: Bool) throws; func openSystemSettings() }`
  - `public protocol Notifying: Sendable { func requestAuthorization() async -> Bool; func post(_ kind: NotificationKind) async }`

- [ ] **Step 1: 写失败测试**(真值表)

总开关关 → `[]`;低磁盘比例恰 0.10 且字节 ≥ 10 GiB → 不触发;比例 0.10 − ε → 触发;字节恰 10_737_418_240 且比例 ≥ 0.10 → 不触发;字节 − 1 → 触发;内存已用比例恰 0.85 → 触发、0.84 → 不触发;冷却 21_599s → 跳过、21_600s → 触发;两类同时命中 → `[.lowDisk, .highMemory]`;空卷/无内存数据不崩。

- [ ] **Step 2: 跑测试确认失败**

`Scripts/test.sh --filter NotificationPolicyTests`。

- [ ] **Step 3: 实现**

选卷复用 `snapshot.diskVolume`;`fraction = Double(available)/Double(total)`;冷却 `now.timeIntervalSince(last) >= Self.cooldown` 才可触发;顺序固定。`SystemSeams.swift` 只放协议与枚举,无实现。

- [ ] **Step 4: 跑测试确认通过**

`Scripts/test.sh --filter NotificationPolicyTests`;全量 ≥ 300。

- [ ] **Step 5: 提交**

`feat(menubar): 通知策略真值表与系统缝隙协议`

---

### Task 4: MenuBarMonitorViewModel

**Files:**
- Create: `Sources/AppCore/MenuBarMonitorViewModel.swift`
- Test: `Tests/AppCoreTests/MenuBarMonitorViewModelTests.swift`

**Interfaces:**
- Consumes: `SystemSampling`(五期)、Task 1–3 全部类型
- Produces:
  ```swift
  @MainActor @Observable public final class MenuBarMonitorViewModel {
      public init(sampler: SystemSampling,
                  preferences: MenuBarPreferenceStore,
                  notifier: Notifying,
                  loginItem: LoginItemManaging,
                  fastInterval: TimeInterval = 5,
                  slowInterval: TimeInterval = 30,
                  now: @escaping @Sendable () -> Date = Date.init)
      public private(set) var preferences: MenuBarPreferences
      public private(set) var snapshot: MenuBarSnapshot
      public private(set) var label: MenuBarLabel
      public private(set) var isStarted: Bool
      public private(set) var notificationAuthorized: Bool?
      public private(set) var loginStatus: LoginItemStatus
      public private(set) var lastError: String?
      public func start(); public func stop()
      public func refreshNow()
      public func refreshFast()
      public func refreshSlow() async
      public func setNetwork(_ status: NetworkStatus)
      public func setMetric(_ metric: MenuBarMetric)
      public func setIconStyle(_ style: MenuBarIconStyle)
      public func setMemoryThreshold(_ value: Double)
      public func setLaunchAtLogin(_ enabled: Bool)
      public func openLoginItemSystemSettings()
      public func setNotificationsEnabled(_ enabled: Bool) async
  }
  ```

- [ ] **Step 1: 写失败测试**

假体:`FakeSampler`(可编程 volumes/memory/tick/battery)、`FakePreferenceStore`(记录 lastNotified 与保存次数)、`FakeNotifier`(返回授权结果、记录 posts)、`FakeLoginItem`(可设 status/抛错)。用例:
1. 初始化即按偏好算出 label,`loginStatus` 取自 fake;
2. `setMetric(.memory)` 立即更新 label 并持久化;`setIconStyle(.iconOnly)` → `.none`;
3. `start()` 幂等(两次 start 后循环只运行一组;用 `fastInterval: 0.01` + 短等待核实 tick 次数有界);
4. `refreshNow()` 全量采样并更新 snapshot/label;
5. 单指标失败隔离:memory/tick 为 nil 时卷与电池照常,label 回退 `.none`;
6. 通知:低磁盘命中 → `post(.lowDisk)`;同 now 再刷 → 不重复;`now + 21_600` → 再发;新建 VM 复用同一 store → 冷却仍生效(跨重启);
7. 通知关闭 → 不调用 `post`;
8. 授权被拒 → `preferences.notificationsEnabled == false`、`notificationAuthorized == false` 且已保存;
9. `setLaunchAtLogin(true)` 后 fake 状态为 `.requiresApproval` → 不置 `lastError`,偏好记录开启意图;
10. 自启抛错 → `lastError` 非空、`loginStatus` 保持 fake 当前值;
11. `setMemoryThreshold(1.0)` → clamp 到 0.95。

- [ ] **Step 2: 跑测试确认失败**

`Scripts/test.sh --filter MenuBarMonitorViewModelTests`。

- [ ] **Step 3: 实现**

循环沿五期 `MonitorViewModel.startLoops` 模式(`Task { while !Task.isCancelled { refresh…; try? await Task.sleep(for: .seconds(interval)) } }` + `[weak self]`);`refreshSlow()` 为 `async`(需要 await notifier),内部命中后 `saveLastNotified`。`label` 在每次 snapshot 变化与偏好变化后重算。启动时 `lastNotified = preferences.loadLastNotified()`。

- [ ] **Step 4: 跑测试确认通过**

`Scripts/test.sh --filter MenuBarMonitorViewModelTests`;全量 ≥ 300。

- [ ] **Step 5: 提交**

`feat(menubar): MenuBarMonitorViewModel(采样节奏、通知冷却、自启状态)`

---

### Task 5: 系统薄壳(App 层)

**Files:**
- Create: `Sources/Raccoon/SystemIntegrations.swift`

**Interfaces:**
- Consumes: Task 3 的 `LoginItemManaging` / `Notifying` / `LoginItemStatus`
- Produces:
  - `final class SMAppServiceLoginItem: LoginItemManaging`(`SMAppService.mainApp.status` 映射:`.enabled→.enabled`、`.requiresApproval→.requiresApproval`、`.notRegistered/.notFound→.disabled`、`@unknown default→.unavailable`;`register()/unregister()`;`openSystemSettings()` 调 `SMAppService.openSystemSettingsLoginItems()`)
  - `final class UNNotifier: Notifying`(授权 `.alert, .sound`;`post(kind)` 用 `loc("menubar.notify.lowDisk.title")` 等键构造内容并即时投递)
  - `final class RaccoonNotificationDelegate: NSObject, UNUserNotificationCenterDelegate`(`willPresent` 返回 `[.banner, .sound]`)

- [ ] **Step 1: 实现薄壳**

只做系统调用与文案,不含策略。`UNNotifier` 需满足 `Sendable`:内部只持 `UNUserNotificationCenter.current()`,标 `@unchecked Sendable` 并注释理由(系统框架线程安全)。

- [ ] **Step 2: 验证**

`swift build` 通过;`grep -rn "Process(" Sources/` 无新增。

- [ ] **Step 3: 提交**

`feat(menubar): SMAppService 与通知系统薄壳`

---

### Task 6: 导航模型与主窗口接线

**Files:**
- Create: `Sources/MenuBarKit/QuickDestination.swift`
- Create: `Sources/Raccoon/NavigationModel.swift`
- Modify: `Sources/Raccoon/RootView.swift`(selection 改为转发 `NavigationModel`)
- Modify: `Sources/Raccoon/RaccoonApp.swift`(持有 `NavigationModel`;`WindowGroup(id: "main")`)

**Interfaces:**
- Produces:
  - `public enum QuickDestination: String, CaseIterable, Sendable { case mainWindow, cleanup, uninstall, aiCleanup, diskAnalysis, launchItems, settings }`
  - `@MainActor @Observable final class NavigationModel { var selection: Module; var openLaunchItems: Bool }`(Raccoon 内部)
  - `RootView.init(exclusions:navigation:)`;移除 `_selection: State<Module>`
  - `MonitorHomeView.init(vm:launchItemsVM:navigation:onNavigate:)`;内部 `_showLaunchItems: State<Bool>` 改为转发 `navigation.openLaunchItems`

- [ ] **Step 1: 实现**

`RootView` 的 `selection` 保持同名 get/set,内部转发 `navigation.selection`;侧栏绑定改为 `Binding(get:set:)`。`MonitorHomeView` 的启动项 `navigationDestination(isPresented:)` 改绑 `navigation.openLaunchItems`,原有 `.launchItems` 跳转回调也写该字段。`RaccoonApp` 手写展开 `State<NavigationModel>`,同时传给 `RootView` 与后续的菜单栏面板。

- [ ] **Step 2: 验证**

`swift build` + 全量测试 ≥ 300(现有 UI 行为不回归)。

- [ ] **Step 3: 提交**

`refactor(ui): 模块选择上提为共享 NavigationModel`

---

### Task 7: 菜单栏常驻 label 与下拉面板

**Files:**
- Create: `Sources/Raccoon/MenuBarLabelView.swift`
- Create: `Sources/Raccoon/MenuBarPanelView.swift`
- Create: `Sources/Raccoon/MenuBarNetworkWatcher.swift`
- Modify: `Sources/Raccoon/RaccoonApp.swift`(实例化 VM/壳、`MenuBarExtra`、`.menuBarExtraStyle(.window)`、通知 delegate 设置)
- Modify: `Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings`(面板与通知文案)

**Interfaces:**
- Consumes: Task 4 的 VM、Task 5 薄壳、Task 6 的 `NavigationModel` / `QuickDestination`;五期 `SparklineView`
- Produces: `MenuBarLabelView(vm:)`、`MenuBarPanelView(vm:navigation:openSettings:)`

- [ ] **Step 1: 实现 label**

图标按 `vm.preferences.metric` 切换(`internaldrive` / `memorychip` / `cpu` / `wifi`);`.percent(n)` → `"\(n)%"`;`.network(status)` 本地化 `Wi‑Fi`/`有线`/`离线`;`.none` 只显示图标。`.task { vm.start() }`。

- [ ] **Step 2: 实现面板**

顶部 `Picker` 绑 `vm.preferences.metric`;五类指标行(磁盘可用/总量 + 条形、内存四项、CPU % + `SparklineView`、电池、网络);`.onAppear { vm.refreshNow() }`;底部快捷入口调用:
```swift
func go(_ d: QuickDestination) {
    switch d { case .mainWindow: break; case .cleanup: navigation.selection = .cleanup; …; case .launchItems: navigation.selection = .monitor; navigation.openLaunchItems = true; case .settings: openSettings() }
    openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
}
```
启动项入口:本期通过主窗口「状态监控 → 启动项管理」进入(不新增独立模块);`openSettings` 用 `SettingsLink` 或 `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`(macOS 14 若失效则用 `@Environment(\.openSettings)`)。
`MenuBarNetworkWatcher`:`NWPathMonitor` 回调 → `Task { @MainActor in vm.setNetwork(...) }`。

- [ ] **Step 3: 验证**

`swift build` + 全量 ≥ 300;与 zh/en 键 1:1(同提交补齐两语言)。

- [ ] **Step 4: 提交**

`feat(menubar): 菜单栏常驻指标与下拉快捷面板`

---

### Task 8: 设置页「菜单栏」tab 与 L10n 收口

**Files:**
- Modify: `Sources/Raccoon/SettingsView.swift`(接收 VM,新增 tab)
- Create: `Sources/Raccoon/MenuBarSettingsPane.swift`
- Modify: `Sources/Raccoon/RaccoonApp.swift`(Settings scene 传入 VM)
- Modify: `Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Task 4 的 VM 全部 setter/状态
- Produces: `MenuBarSettingsPane(vm:)`

- [ ] **Step 1: 实现**

控件:指标 `Picker`、样式 `Picker`、自启 `Toggle`(调 `setLaunchAtLogin`)、通知 `Toggle`(Task 中 `await setNotificationsEnabled`)、内存阈值 `Stepper` 70...95 step 5;状态提示:`loginStatus == .requiresApproval` 显示说明 + 「打开系统设置」按钮;`notificationAuthorized == false` 显示被拒说明。`lastError` 非空时显示错误行。

- [ ] **Step 2: 验证**

`swift build`;全量 ≥ 300;用脚本核对键集:
`comm -3 <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort) <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort)` 输出为空;zh 值无 ASCII `,;:!?`。

- [ ] **Step 3: 提交**

`feat(menubar): 设置页菜单栏 tab(自启/通知/阈值)与双语文案`

---

### Task 9: 文档——README + 六期 QA 清单

**Files:**
- Modify: `README.md`(路线图六期 → `✅ 已实现(待人工 QA)`;功能节加菜单栏工具;测试数更新为实际值;已知限制并入 spec §9)
- Create: `docs/superpowers/qa/phase6-qa-checklist.md`
- Modify: `docs/superpowers/specs/2026-10-18-raccoon-phase6-design.md`(状态行 → 已实施(待人工 QA))

- [ ] **Step 1: QA 清单**

沿五期诚实原则:自动项只写真实命令输出(全量测试、红线 grep、L10n、build);人工项 A1–An 全 `- [ ]`,至少覆盖:菜单栏四指标切换与重启保留、图标样式、面板五卡与 sparkline、面板打开刷新、快捷入口(含主窗口已关闭时)、多卷显示、自启注册/取消/需批准、通知授权/拒绝/低磁盘与高内存触发/6h 冷却/重启后冷却仍生效、前台横幅、深浅色/窄菜单栏、en/zh、VoiceOver、通知不含路径。注明数值与计时可变、基线 HEAD 记本任务前一提交。

- [ ] **Step 2: README**

路线图、功能两段(常驻监控/快捷面板)、测试数、已知限制;跑 `Scripts/test.sh` 确认数字一致。

- [ ] **Step 3: 提交**

`docs: 六期收尾——README、QA 清单、规格状态`

---

## 完成后

- 全分支终审:重跑 `Scripts/test.sh`、`swift build`;红线检查(`removeItem`/`unlink`/`Process(` 零新增、`trashItem` 唯一、`rules.json` 未改、tools-version 6.3、L10n 1:1)。
- 终审通过后更新 spec 状态为「已实施(待人工 QA)」。
- **合并与推送必须等用户明确指令**;真机人工 QA 由用户按 `phase6-qa-checklist.md` 执行。
