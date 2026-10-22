# 六期设计:菜单栏工具集(Menu Bar)

状态:已实施(待人工 QA,2026-10-22)

## 1. 背景与目标

六期是路线图的最后一期:把 Raccoon 从「打开才运行的清理应用」变成常驻菜单栏的轻量系统监控仪。

- **菜单栏常驻指标**:图标 + 可选数值(磁盘/内存/CPU/网络 四选一),选择持久化
- **下拉快捷面板**:五类指标摘要 + CPU/内存/网络 sparkline + 快捷入口(主窗口各模块、设置、退出)
- **开机自启**:`SMAppService.mainApp` 注册为登录项,免 root
- **阈值通知**:磁盘不足/内存偏高时发本地通知,带冷却去重
- **图标样式**:仅图标 / 图标 + 数值

核心原则:**只读监控 + 导航**,不携带任何删除动作。所有系统能力经协议薄壳封装,纯逻辑全测。

## 2. 非目标(本期不做)

- **不做菜单栏内一键清理/自动清理/定时清理**:所有清理动作仍须进入主窗口,走既有四道门与确认流
- **不做仅菜单栏模式**:不启用 `LSUIElement`,Dock 图标与主窗口保持现状
- **不做风扇/温度/SSD 健康/GPU**:需要额外 IOKit/SMC 私有信号,超出只读监控范围
- **不做通知历史/通知中心管理**:只发即时本地通知
- **不改 `rules.json`,不新增删除实现,不新增 `Process` 调用**
- **不做菜单栏拖拽排序/多指标并列**:四选一常驻,避免菜单栏宽度失控

## 3. 关键决策

| 决策 | 结论 | 依据 |
| --- | --- | --- |
| 架构 | 新增 `MenuBarKit`(纯逻辑,依赖 `MonitorKit`)+ `AppCore/MenuBarMonitorViewModel` | 沿「每期一个 Kit」惯例;格式化/策略/偏好与 UI 分离 |
| 采样 | 独立节奏:CPU/内存 5s,磁盘/电池 30s,网络事件驱动 | 菜单栏需常驻轻量刷新;不与监控页共享生命周期,互不拖累 |
| 菜单栏控件 | `MenuBarExtra` + `.menuBarExtraStyle(.window)` | 系统原生,面板可承载卡片与 sparkline |
| 导航 | 模块选择上提为共享 `NavigationModel`;面板只发导航意图 | 快捷入口需从菜单栏唤起主窗口并定位模块 |
| 自启 | `SMAppService.mainApp` | 免 root、系统设置可见;不写 LaunchAgent |
| 通知 | `UNUserNotificationCenter` + 纯策略/节流 | 授权与投递是薄壳,判定与冷却可单测 |
| 存储 | `UserDefaults`(注入 store 协议) | 轻量偏好,无需文件存储 |

## 4. 总体架构

```
Raccoon (UI)          MenuBarExtra / MenuBarPanelView / MenuBarSettingsPane / NavigationModel
AppCore               MenuBarMonitorViewModel(采样节奏、通知触发、菜单栏文字)
MenuBarKit (新)       MenuBarMetric / MenuBarPreferences / MenuBarPreferenceStore
  ├─ MenuBarLabelFormatter   纯函数:指标 + 快照 → 菜单栏文字
  ├─ NotificationPolicy      低磁盘/高内存判定 + 6h/类冷却
  ├─ LoginItemManaging       协议 + SMAppService 薄壳
  └─ Notifying               协议 + UNUserNotificationCenter 薄壳
MonitorKit (五期)     VolumeInfo / MemoryStats / CPULoad / BatteryInfo / NetworkStatus / SystemSampling
既有                  SparklineView(五期)、Settings scene、L10n、RootView
```

**系统调用缝隙**:`SMAppService`、`UNUserNotificationCenter`、`UserDefaults` 全部藏在协议后;实现类薄壳不测,判定/格式化/冷却纯函数全测。沿五期 `SystemSampling` 先例。

**依赖方向**:`MenuBarKit → MonitorKit`;`AppCore → MenuBarKit + MonitorKit`;`Raccoon → AppCore + MenuBarKit`。`MenuBarKit` 不依赖 AppCore/CleanKit。

## 5. 详细设计

### 5.1 MenuBarKit(纯逻辑)

- **`MenuBarMetric`**:`.disk`、`.memory`、`.cpu`、`.network`,`CaseIterable`、`Sendable`
- **`MenuBarIconStyle`**:`.iconOnly`、`.iconAndValue`
- **`MenuBarSnapshot`**:`{volumes: [VolumeInfo], memory: MemoryStats?, cpu: CPULoad?, battery: BatteryInfo?, network: NetworkStatus?}`;`volumes` 为空数组表示磁盘不可用
- **`MenuBarLabelFormatter.text(metric:style:snapshot:) -> String`**:
  - `.iconOnly` → 空串(视图只显示图标)
  - 磁盘 → 系统盘可用百分比取整(`83%`);无系统盘标记时取可用比例最低的可见卷(与通知策略同一选卷规则);无数据 → `—`
  - 内存 → 已用/总量取整百分比(`62%`)
  - CPU → user + system 取整百分比(`18%`)
  - 网络 → 在线时按接口显示,离线显示离线态
  - formatter 返回 `MenuBarLabel`(`Equatable` 枚举):`.percent(Int)`、`.network(NetworkStatus?)`、`.none`;具体符号(如 `Wi-Fi`/`LAN`/`Offline`)由视图层本地化,保证纯函数稳定可测
- **`MenuBarPreferences`**:`{metric, iconStyle, launchAtLogin, notificationsEnabled, memoryThreshold}`;默认 `.disk` / `.iconAndValue` / false / false / 0.85;`memoryThreshold` 限制 0.70...0.95
- **`MenuBarPreferenceStore`** 协议:`load() -> MenuBarPreferences`、`save(_:)`、`loadLastNotified() -> [NotificationKind: Date]`、`saveLastNotified(_:)`;`UserDefaultsPreferenceStore` 薄壳(键前缀 `menubar.`)。冷却时间戳持久化,应用重启后 6h 内不重复打扰
- **`NotificationKind`**:`.lowDisk`、`.highMemory`
- **`NotificationPolicy.evaluate(snapshot:preferences:lastNotified:now:) -> [NotificationKind]`**:
  - 低磁盘:取系统盘;无系统盘标记时取可用比例最低的卷。可用比例 `< 0.10` **或** 可用字节 `< 10_737_418_240`(严格小于,与五期建议引擎同阈值)
  - 高内存:已用比例 `>= preferences.memoryThreshold`
  - 冷却:同类距上次通知 `< 21_600s`(6h)不再触发;返回按 `.lowDisk → .highMemory` 固定顺序
  - 通知总开关关闭 → 恒返回 `[]`
- **`LoginItemStatus`**:`.disabled`、`.enabled`、`.requiresApproval`、`.unavailable`;`LoginItemManaging` 协议:`status`、`setEnabled(_:) throws`、`openSystemSettings()`
- **`Notifying`** 协议:`requestAuthorization() async -> Bool`、`post(_ kind: NotificationKind) async`;具体文案由 App 层壳本地化,协议保持语言无关

### 5.2 ViewModel(AppCore)

`@MainActor @Observable MenuBarMonitorViewModel`:

- 注入:`SystemSampling`、`MenuBarPreferenceStore`、`Notifying`、`LoginItemManaging`、`fastInterval = 5`、`slowInterval = 30`
- 状态:`preferences`、`snapshot: MenuBarSnapshot`、`label: MenuBarLabel`、`isStarted`、`notificationAuthorized: Bool?`、`loginStatus: LoginItemStatus`
- `start()`:幂等;建 fast/slow 循环(沿五期冻结间隔方案,避免计时抖动)
- `stop()`:取消两个循环;预留给未来「完全退出」路径
- `refreshNow()`:立即全量采样一次(面板打开时调用)
- `setMetric(_:)` / `setIconStyle(_:)`:`preferences` 持久化并即时刷新 `label`
- `setMemoryThreshold(_:)`:clamp 到 0.70...0.95 并持久化
- `setLaunchAtLogin(_:)`:经 `LoginItemManaging` 设置,成功后刷新 `loginStatus`;`requiresApproval` 不视为失败
- `openLoginItemSystemSettings()`:转调系统设置登录项页(需批准状态引导)
- `setNotificationsEnabled(_:)`:开启时请求授权;拒绝则保持 false 并记录状态
- 慢循环额外执行 `NotificationPolicy`:命中则 `post`,并更新内存中的 `lastNotified`(以 `Date` 注入可测)
- 单个采集器返回 nil → 该字段为 nil,不影响其他指标;`label` 回退 `—`

### 5.3 UI(Raccoon)

- **`RaccoonApp`**:新增 `MenuBarExtra { MenuBarPanelView(...) } label: { MenuBarLabelView(...) }`,style `.window`;ViewModel 在 App 级持有并 `start()`
- **`MenuBarLabelView`**:`gauge.with.needle` 图标 + `label` 文本(本地化:磁盘/内存/CPU 数值、`Wi-Fi`/`LAN`/`Offline`);`iconOnly` 时不显示文本
- **`MenuBarPanelView`**(自上而下):
  1. 指标选择器(`Picker`,四选一,即时生效)
  2. 磁盘卡(可用/总量 + 条形)、内存卡(已用/总量 + 压缩/联动/可清除)、CPU 卡(百分比 + `SparklineView`)、电池卡、网络卡(含接口类型)
  3. 底部快捷入口:主窗口(打开/激活)、清理、卸载、AI 清理、磁盘分析、启动项管理、设置、退出
  4. 面板出现时 `refreshNow()`;无数据时显示「暂不可用」占位而非裸 key
- **`NavigationModel`**:`@MainActor @Observable`,`selection: Module` + `openLaunchItems: Bool`;`RootView` 与 `MonitorHomeView` 共用;菜单栏入口设置目标后 `NSApp.activate` + 打开主窗口(`openWindow` 或 AppKit 激活)
- **`SettingsView`** 新增「菜单栏」tab:`MenuBarSettingsPane`(指标、图标样式、自启开关+状态说明、通知开关+内存阈值 `Stepper` 70–95%)。通知被系统拒绝时显示引导文案
- 全部 en/zh key 1:1(预计 +28~34 key),zh 值全角标点;深浅色 + 无障碍标签沿既有模式

### 5.4 通知薄壳

- `UNUserNotificationCenterNotifier`(位于 App 层):请求授权;`post(kind)` 用 L10n 构造标题/正文后投递即时 `UNNotificationRequest`
- 应用在前台时通过 `UNUserNotificationCenterDelegate` 仍展示横幅(否则前台默认不弹)
- 通知内容不包含路径等敏感信息:低磁盘只报可用空间,高内存只报占用比例

### 5.5 自启薄壳

- `SMAppServiceLoginItem`:`status` 映射 `.enabled`/`.requiresApproval`/`.disabled`;`setEnabled` 调 `register()`/`unregister()`;异常向上抛,ViewModel 保留原状态并暴露 `lastError`
- 系统设置中标为「需要批准」时,设置页显示说明与「打开系统设置」按钮

## 6. 安全与红线

| 红线 | 六期落点 |
| --- | --- |
| 删除实现 | 零新增;唯一 `trashItem` 不变;菜单栏无任何删除入口 |
| 进程调用 | 零新增 `Process(`;自启用 `SMAppService`,通知用系统框架 |
| 规则库 | `rules.json` 不改,version 不变 |
| 权限 | 仍非沙盒、免 root;仅申请通知授权与登录项注册 |
| 隐私 | 通知不含路径/文件名;采样数据不落盘、不外发 |

## 7. 测试策略(TDD 锚点)

- **MenuBarKit**
  - `MenuBarLabelFormatter`:四指标正常值、无数据 `—`、`iconOnly` 空、百分比取整边界
  - `NotificationPolicy`:低磁盘比例边界(0.10 恰好不触发)、字节边界(10 GiB 恰好不触发)、高内存阈值边界(>=)、冷却 6h 边界、总开关关闭、返回顺序
  - `MenuBarPreferences` 阈值 clamp、默认值、UserDefaults 往返(注入独立 suite)
- **AppCore**
  - `MenuBarMonitorViewModel`:注入假采样器 + 冻结时钟;start 幂等、fast/slow 节奏、refreshNow、单指标失败隔离、指标切换即时更新 label、通知命中与冷却不重复、授权被拒时开关回落、自启 requiresApproval 保留状态
- 全部经 `Scripts/test.sh`;基线 300,只增不减

## 8. 验收标准(Done)

1. 菜单栏图标常驻;四选一指标与图标样式切换即时生效且重启后保留
2. 下拉面板五类指标与 sparkline 正常;无数据降级为「暂不可用」;快捷入口可唤起主窗口并定位模块
3. 开机自启可注册/取消,系统设置中可见;需批准状态有说明
4. 通知开关与阈值可用;低磁盘/高内存命中即发,6h 内不重复;拒绝授权时不静默假装成功
5. `Scripts/test.sh` 全绿;红线零新增;L10n en/zh 1:1;README 路线图六期更新、QA 清单更新

## 9. 已知限制

- 菜单栏文字受系统可用宽度限制,长文本可能被系统截断(图标样式可切「仅图标」)
- 应用未运行时无法采样或发通知;需开启开机自启才能常驻
- 自启注册可能要求用户在「系统设置 → 通用 → 登录项」手动批准
- CPU 数值为 5s 采样粒度;磁盘/电池 30s 才刷新
- 内存口径为 Mach 统计,与活动监视器「内存压力」不一一对应
- 通知只在慢循环(30s)评估,阈值触发最长延迟 30s
- 不做仅菜单栏模式,退出主窗口后 Dock 图标仍在
