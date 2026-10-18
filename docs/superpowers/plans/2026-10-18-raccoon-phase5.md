# 五期实现计划:状态监控 + 系统优化(Monitor)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把侧边栏 `monitor` 占位做实:五类指标只读仪表盘 + 建议卡 + 用户级启动项管理(禁用 = plist 移废纸篓)。

**Architecture:** 新增 `MonitorKit`(采样组装 + 建议引擎,纯逻辑)与 `LaunchKit`(plist 解析 + 禁用编排)两个 SPM target;`MonitorViewModel`/`LaunchItemsViewModel` 在 AppCore;视图在 Raccoon。所有 mach/IOKit/NWPath/FileManager 调用藏进协议缝隙,数学与组装纯函数全测(沿 DiskKit 先例)。

**Tech Stack:** Swift 6 + SwiftUI(macOS 14+),系统框架 Foundation/IOKit/Network,零第三方依赖,Canvas 自绘 sparkline。

**Spec:** `docs/superpowers/specs/2026-10-18-raccoon-phase5-design.md`

## Global Constraints

- tools-version 保持 6.3 不升;零 `.package(` 依赖
- **trash-only**:全仓唯一删除实现是 `Sources/CleanKit/TrashService.swift` 的 `FileManager.trashItem`;禁止新增 `removeItem`/`unlink`/`Process` 调用(tmutil 复用既有 `SnapshotCleaner`;测试清理自建临时目录可用 `try? FileManager.default.removeItem`,唯一例外)
- `rules.json` 不动(version 保持 1)
- 测试只经 `Scripts/test.sh`(禁 bare `swift test`;单套件 `Scripts/test.sh --filter <Suite>`;`swift build` 可用);用例总数只增不减,基线 231
- L10n:`Sources/Raccoon/Resources/en.lproj/Localizable.strings` 与 `zh-Hans.lproj/Localizable.strings` key 1:1(CI 强制);zh 值全角标点
- CLT-only:不写 SwiftUI 宏(`@State`/`@Binding` 手写展开,沿四期 `RootView`/`DiskAnalysisHomeView` 模式);`@Observable` 可用
- 测试不真删:启动项禁用测试注入 `TrashServicing` 假体
- 深浅色适配与无障碍标签沿既有模式;不引 Charts

## Review Focus

1. **硬保护/被排除的 plist 可被禁用**——期望:isDenied 命中即 no-op 并置灰。→ Task 6 门禁测试。
2. **损坏 plist 被静默丢弃**——期望:照常列出、标「无法解析」。→ Task 5 fixture 测试。
3. **CPU 首采样显示 0%**——期望:无差值时展示空态而非 0。→ Task 2 nil 语义测试。
4. **purgeable 出现负数**(importantUsage < available)——期望:clamp ≥ 0。→ Task 1 测试。
5. **桌面机无电池**(空电源源)——期望:hasBattery=false 显示「外接电源」,不崩溃不显示 NaN。→ Task 3 测试。

---

### Task 1: MonitorKit target + DiskMetrics(卷组装)

**Files:**
- Modify: `Package.swift`(新增 target `MonitorKit`、testTarget `MonitorKitTests`;`AppCore` 与 `Raccoon` 的 dependencies 追加 `"MonitorKit"`)
- Create: `Sources/MonitorKit/DiskMetrics.swift`
- Test: `Tests/MonitorKitTests/DiskMetricsTests.swift`

**Interfaces:**
- Consumes: 无(首个 MonitorKit 文件)
- Produces:
```swift
public struct VolumeInfo: Equatable, Sendable {
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let purgeableBytes: Int64
    public let isSystemDisk: Bool
}
/// 纯函数组装。purgeable = max(0, importantUsageBytes - availableBytes);
/// isSystemDisk = (name == homeVolumeName)。
public func assembleVolumeInfo(name: String, totalBytes: Int64, availableBytes: Int64,
                               importantUsageBytes: Int64, homeVolumeName: String) -> VolumeInfo
```

- [ ] **Step 1: 写失败测试**——三条断言:常规组装(importantUsage > available 时 purgeable 为差值);**clamp**(`importantUsageBytes < availableBytes` 时 purgeable == 0);`isSystemDisk` 同名 true / 异名 false。
- [ ] **Step 2:** `Scripts/test.sh --filter DiskMetricsTests` 预期 FAIL(符号未定义)。
- [ ] **Step 3: 实现**(纯函数 + Package.swift target 接线,真实 FileManager 采集器留给 Task 4 的缝隙)。
- [ ] **Step 4:** `Scripts/test.sh --filter DiskMetricsTests` PASS;`swift build` 通过。
- [ ] **Step 5: Commit** `feat(monitor): MonitorKit target 与卷信息组装(purgeable clamp、系统盘标记)`

### Task 2: MemoryMetrics + CPUMetrics(tick 差值、首采样空态、环形缓冲)

**Files:**
- Create: `Sources/MonitorKit/MemoryMetrics.swift`、`Sources/MonitorKit/CPUMetrics.swift`
- Test: `Tests/MonitorKitTests/MemoryMetricsTests.swift`、`Tests/MonitorKitTests/CPUMetricsTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
```swift
public struct MemoryStats: Equatable, Sendable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let compressedBytes: Int64
    public let wiredBytes: Int64
    public let purgeableFreeBytes: Int64
}
/// used = total - free - inactive - purgeable(spec §5.1,clamp ≥ 0;外部页计入 used)。
/// 入参为页计数 × 页大小换算后的字节;纯函数只做组装。
public func assembleMemoryStats(totalBytes: Int64, freeBytes: Int64, inactiveBytes: Int64,
                                purgeableBytes: Int64, wiredBytes: Int64, compressedBytes: Int64) -> MemoryStats

public struct CPULoad: Equatable, Sendable {
    public let userPct: Double
    public let systemPct: Double
    public let idlePct: Double
}
/// 扁平化 per-core 四元组(user, system, idle, nice),每核求和差值后归一到 0...100。
/// previous 为 nil(首采样)或两组长度不符 → nil;总差值为 0 → nil(无流逝)。
public func computeCPULoad(previous: [Int32]?, current: [Int32]) -> CPULoad?

public struct SampleRing<T> {
    public init(capacity: Int)
    public mutating func append(_ value: T)
    public var values: [T] { get }   // 最旧在前,最多 capacity 个
}
```

- [ ] **Step 1: 写失败测试**——内存:常规组装、used clamp(占用超总量时 ≥ 0);CPU:两采样差值数学(手工算好期望百分数)、**首采样 nil**、长度不符 nil、总差值 0 nil、多核求和;环形缓冲:超容量丢弃最旧、顺序保持。
- [ ] **Step 2:** `Scripts/test.sh --filter MemoryMetricsTests`、`--filter CPUMetricsTests` 预期 FAIL。
- [ ] **Step 3: 实现**。
- [ ] **Step 4:** 两个 filter PASS;`Scripts/test.sh` 全量绿(只增不减)。
- [ ] **Step 5: Commit** `feat(monitor): 内存构成组装与 CPU tick 差值计算(首采样空态)`

### Task 3: PowerMetrics + NetworkStatus + SuggestionEngine

**Files:**
- Create: `Sources/MonitorKit/PowerMetrics.swift`、`Sources/MonitorKit/NetworkMetrics.swift`、`Sources/MonitorKit/SuggestionEngine.swift`
- Test: `Tests/MonitorKitTests/PowerAndNetworkTests.swift`、`Tests/MonitorKitTests/SuggestionEngineTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
```swift
public struct BatteryInfo: Equatable, Sendable {
    public let hasBattery: Bool        // 空电源源 → false
    public let percentage: Double      // 0...100
    public let charging: Bool
    public let onBattery: Bool
}
/// 纯组装:输入 IOPS 描述字典的提取值(调用方薄壳负责 IOKit)。
/// 无电池:hasBattery=false,percentage 保持 0,不产生 NaN。
public func assembleBatteryInfo(hasSource: Bool, percent: Double?, charging: Bool, onBattery: Bool) -> BatteryInfo

public enum NetworkInterface: Equatable, Sendable { case wifi, wired, other }
public struct NetworkStatus: Equatable, Sendable { public let online: Bool; public let interface: NetworkInterface }
public func assembleNetworkStatus(satisfied: Bool, isWiFi: Bool, isWired: Bool) -> NetworkStatus
// !satisfied → online=false, interface 一律 .other

public enum SuggestionDestination: Equatable, Sendable { case diskAnalysis, cleanup, launchItems }
public struct Suggestion: Equatable, Sendable { public let id: String; public let destination: SuggestionDestination }
// id 即 L10n key 尾段:"disk" / "snapshots" / "launchitems" / "crashreports";icon 与标题由 UI 按 id 映射 L10n
public struct SuggestionsInput: Equatable, Sendable {
    public let minVolumeFreeFraction: Double     // 全部卷中最小可用比例
    public let minVolumeFreeBytes: Int64         // 全部卷中最小可用字节
    public let hasSnapshots: Bool
    public let userLaunchAgentCount: Int
    public let crashReportCount: Int
    public init(minVolumeFreeFraction: Double, minVolumeFreeBytes: Int64,
                hasSnapshots: Bool, userLaunchAgentCount: Int, crashReportCount: Int)
}
/// 稳定顺序:磁盘 → 快照 → 启动项 → 崩溃报告(spec §5.2 表)。
/// 磁盘阈值:fraction < 0.10 **或** bytes < 10_737_418_240,严格小于。
public func suggestions(for input: SuggestionsInput) -> [Suggestion]
```

- [ ] **Step 1: 写失败测试**——电池:有源各字段、**空源 hasBattery=false 且无 NaN**;网络:离线归 .other、Wi-Fi/有线映射;建议:**每规则命中/不命中**、两条边界(恰好 0.10 不建议、恰好 10_737_418_240 字节不建议)、多命中顺序固定、全不命中返回 []。
- [ ] **Step 2:** 两个 filter 预期 FAIL。
- [ ] **Step 3: 实现**。
- [ ] **Step 4:** filter PASS + 全量绿。
- [ ] **Step 5: Commit** `feat(monitor): 电池/网络组装与建议引擎真值表(边界严格小于)`

### Task 4: AppCore MonitorViewModel(轮询状态机、暂停、单指标失败隔离)

**Files:**
- Create: `Sources/AppCore/MonitorViewModel.swift`
- Test: `Tests/AppCoreTests/MonitorViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1–3 全部纯函数与类型
- Produces(AppCore 内 `import MonitorKit`):
```swift
/// 系统采集缝隙:实现类薄壳不测,测试注入假体。
public protocol SystemSampling: Sendable {
    func volumes() -> [VolumeInfo]        // FileManager.mountedVolumeURLs + Task 1 组装
    func memory() -> MemoryStats?
    func cpuTicks() -> [Int32]?           // host_processor_info;取不到 → nil
    func battery() -> BatteryInfo
}
@MainActor @Observable public final class MonitorViewModel {
    public enum Phase: Equatable, Sendable { case idle, running, ready }
    public init(sampler: SystemSampling)
    public private(set) var phase: Phase
    public private(set) var volumes: [VolumeInfo]?      // nil = 暂不可用
    public private(set) var memory: MemoryStats?
    public private(set) var cpuHistory: [CPULoad]        // ≤ 60 点,最旧在前
    public private(set) var battery: BatteryInfo?
    public private(set) var network: NetworkStatus?
    public func start()          // phase→running;建 fast(2s)/slow(30s)两个 Task 循环
    public func stop()
    public func setActive(_ active: Bool)   // scenePhase:false 时停循环,true 时若已 start 则重启
    public func refreshFast()    // cpu+memory;cpu 差值经 computeCPULoad,首采样 nil 不入历史
    public func refreshSlow()    // volumes+battery
    public func setNetwork(_ s: NetworkStatus)
}
```
Timer 循环体:`while !Task.isCancelled { refreshFast(); try? await Task.sleep(for: .seconds(2)) }`(slow 同理 30s);任一指标采集抛错/返回 nil → 该字段保持上一值或 nil,不影响 `phase`。
- [ ] **Step 1: 写失败测试**(假体 sampler):start→running、refreshFast 一次后 cpuHistory 仍空(**首采样**)、两次后 1 点、refreshSlow 填 volumes/battery、单指标假体抛错其余照常、stop→循环退出(cpuHistory 不再增长)、setActive(false/true) 恢复。
- [ ] **Step 2:** `Scripts/test.sh --filter MonitorViewModelTests` 预期 FAIL。
- [ ] **Step 3: 实现**(真壳 `LiveSystemSampler` 一并写在本文件,调 Task 1–3 组装函数;文件内注释说明 mach 调用点)。
- [ ] **Step 4:** filter PASS + 全量绿。
- [ ] **Step 5: Commit** `feat(monitor): MonitorViewModel 轮询状态机(暂停恢复、单指标失败隔离)`

### Task 5: LaunchKit target + LaunchItemParser + LaunchItemScanner

**Files:**
- Modify: `Package.swift`(target `LaunchKit`,dependencies `["CleanKit"]`;testTarget `LaunchKitTests`;`AppCore`/`Raccoon` deps 追加 `"LaunchKit"`)
- Create: `Sources/LaunchKit/LaunchItemModels.swift`、`Sources/LaunchKit/LaunchItemParser.swift`、`Sources/LaunchKit/LaunchItemScanner.swift`
- Test: `Tests/LaunchKitTests/LaunchItemParserTests.swift`、`Tests/LaunchKitTests/LaunchItemScannerTests.swift`(fixtures 用代码在临时目录生成,**不提交二进制 fixture**)

**Interfaces:**
- Consumes: 无
- Produces:
```swift
public struct LaunchItem: Equatable, Sendable, Identifiable {
    public let path: String
    public let fileName: String
    public let label: String?        // 解析失败 → nil
    public let programName: String?  // Program 或 ProgramArguments 首个
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let disabled: Bool
    public let parseFailed: Bool
    public var id: String { path }
}
public enum LaunchItemParser {
    /// 损坏/非字典 plist → LaunchItem(parseFailed: true, label: nil),**绝不静默丢弃**
    public static func parse(data: Data, path: String, fileName: String) -> LaunchItem
    public static func parse(fileURL: URL) -> LaunchItem
}
public struct LaunchDirectoryListing: Equatable, Sendable {
    public let userItems: [LaunchItem]      // ~/Library/LaunchAgents/*.plist,按 fileName 排序
    public let systemItems: [LaunchItem]    // /Library/LaunchAgents + /Library/LaunchDaemons,只读清单
}
public struct LaunchItemScanner: Sendable {
    public init(fm: FileManager = .default)
    public func scan() -> LaunchDirectoryListing   // 非 .plist 忽略;目录不存在 → 空数组,不报错
}
```

- [ ] **Step 1: 写失败测试**——解析:完整 plist(Label/ProgramArguments/RunAtLoad/KeepAlive/Disabled)、Program 回退、缺 Label(其余照常)、**损坏 XML parseFailed=true**、顶层非字典 parseFailed;扫描:临时目录含 2 plist + 1 `.txt` + 1 子目录 → 只列 2 且有序、目录不存在返回空。
- [ ] **Step 2:** 两个 filter 预期 FAIL。
- [ ] **Step 3: 实现**(PropertyListSerialization;扫描器枚举 contentsOfDirectory)。
- [ ] **Step 4:** filter PASS;测试清理自建临时目录(允许的 `try? removeItem` 例外)。
- [ ] **Step 5: Commit** `feat(launch): LaunchKit 解析与扫描(损坏 plist 不静默、非 plist 忽略)`

### Task 6: LaunchItemStore 禁用编排(保护门 + trash-only)

**Files:**
- Create: `Sources/LaunchKit/LaunchItemStore.swift`
- Test: `Tests/LaunchKitTests/LaunchItemStoreTests.swift`

**Interfaces:**
- Consumes: Task 5 类型;CleanKit `ProtectionStore.isDenied`、`TrashServicing`、`CleanExecutor.clean(_:onProgress:source:)`、`CleanItem.init(path:sizeBytes:action:)`
- Produces:
```swift
public enum DisableOutcome: Sendable {
    case denied(reason: String)             // isDenied 命中,未触达文件系统
    case trashed(report: CleanReport)       // 报告 skipped 为空
    case failed(reason: String)             // 其余失败(报告未产生 trashed)
}
public struct LaunchItemStore: Sendable {
    public init(trash: TrashServicing, protection: ProtectionStore)
    /// CleanItem(path: item.path, sizeBytes: 0),source 固定 "launch-items"。
    public func disable(_ item: LaunchItem) async -> DisableOutcome
}
```

- [ ] **Step 1: 写失败测试**(假体 TrashServicing 记录调用):**硬保护命中**(构造 hardRoots 含 item.path)→ `.denied` 且假体零调用;**用户排除命中**同;正常项 → `.trashed(report:)` 且假体收到该 path;报告 `source == "launch-items"`。
- [ ] **Step 2:** filter 预期 FAIL。
- [ ] **Step 3: 实现**(内部持 `CleanExecutor(trash:protection:)`;skipped 空且 trashed>0 → `.trashed(report:)`,未 trashed → `.failed`)。
- [ ] **Step 4:** filter PASS + 全量绿;红线自检:`grep -rn "removeItem\|unlink" Sources/LaunchKit/` 仅测试临时目录清理注释级出现。
- [ ] **Step 5: Commit** `feat(launch): 启动项禁用编排(保护门拦截、trash-only、source 记账)`

### Task 7: UI——monitor 模块启用 + MonitorHomeView + L10n

**Files:**
- Modify: `Sources/Raccoon/RootView.swift`(`availableCases` 加入 `.monitor`;detail switch 拆出 `.monitor` 分支;手写展开 `_monitorVM: State<MonitorViewModel>`,sampler 用 `LiveSystemSampler()`)
- Create: `Sources/Raccoon/MonitorHomeView.swift`、`Sources/Raccoon/SparklineView.swift`
- Modify: `Sources/Raccoon/Resources/en.lproj/Localizable.strings`、`zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Task 4 `MonitorViewModel`;既有 `loc(_:)`、`.onScenePhaseChange` 等既有模式(沿四期视图写法)
- Produces: `MonitorHomeView(vm:)`、`SparklineView(values: [Double], tint: Color)`(Canvas 折线,空数组画空态)

- [ ] **Step 1: 实现视图**——结构按 spec §5.4:系统盘大卡(可用/总量条形 + purgeable 提示)+ 其他卷小卡;内存卡四项;CPU 卡(user/sys/idle + sparkline,`cpuHistory.isEmpty` 显示 `monitor.cpu.pending`);电池/网络行(无电池显示外接电源文案);nil 指标显示「暂不可用」;建议卡区(空数组整体隐藏);「优化工具」区三个入口(启动项 `NavigationLink`-式跳 Task 8 子页,快照/系统垃圾先占位按钮,Task 8 接线前禁用)。`.onAppear { vm.start() }` + scenePhase 桥接 `setActive`。
- [ ] **Step 2: L10n**——两语言同步新增(本任务 key 尾段):`monitor.title`、`monitor.disk.system`、`monitor.disk.purgeable`、`monitor.memory.title`、`monitor.memory.used`、`monitor.memory.compressed`、`monitor.memory.wired`、`monitor.memory.purgeable`、`monitor.cpu.title`、`monitor.cpu.user`、`monitor.cpu.system`、`monitor.cpu.idle`、`monitor.cpu.pending`、`monitor.battery.external`、`monitor.battery.charging`、`monitor.battery.onbattery`、`monitor.network.wifi`、`monitor.network.wired`、`monitor.network.other`、`monitor.network.offline`、`monitor.suggest.disk`、`monitor.suggest.snapshots`、`monitor.suggest.launchitems`、`monitor.suggest.crashreports`、`monitor.tools.title`、`monitor.tools.launchitems`、`monitor.tools.snapshots`、`monitor.tools.crashreports`、`monitor.unavailable`。zh 值全角标点。
- [ ] **Step 3: 验证**——`swift build` 通过;`Scripts/test.sh` 全量绿(含既有 L10n 1:1 测试);**人工冒烟留给 QA 清单,不在此勾**。
- [ ] **Step 4: Commit** `feat(ui): 状态监控仪表盘(指标卡+sparkline+建议卡,L10n 双语)`

### Task 8: UI——LaunchItemsView + 确认流 + 排除 + 建议卡接线

**Files:**
- Create: `Sources/AppCore/LaunchItemsViewModel.swift`、`Sources/Raccoon/LaunchItemsView.swift`、`Sources/Raccoon/LaunchConfirmView.swift`
- Modify: `Sources/Raccoon/MonitorHomeView.swift`(工具区三入口实接:启动项子页、快照→清理模块、系统垃圾→清理模块)、两份 `.strings`

**Interfaces:**
- Consumes: Task 5 `LaunchItemScanner`、Task 6 `LaunchItemStore`、既有 `ExclusionsStore`、`HistoryStoring`(沿 `DiskAnalysisViewModel.swift:212` 的 `try? history.append(report)` 记账模式)、`report.source.*` 展示模式、四期 `DiskConfirmView` 确认弹窗模式(默认取消键)
- Produces:
```swift
@MainActor @Observable public final class LaunchItemsViewModel {
    public struct Row: Equatable, Identifiable { public let item: LaunchItem; public let denied: Bool; public var id: String { item.id } }
    public init(scanner: LaunchItemScanner, store: LaunchItemStore, exclusions: ExclusionsStore, history: HistoryStoring)
    public private(set) var userRows: [Row]
    public private(set) var systemItems: [LaunchItem]
    public func load() async
    public func disable(_ row: Row) async      // denied → no-op;.trashed(report) → try? history.append(report) + 重扫
    public func exclude(_ row: Row)            // exclusions.add(item.path) + reload
    public private(set) var lastReport: CleanReport?
}
```

- [ ] **Step 1: 写失败测试**(`Tests/AppCoreTests/LaunchItemsViewModelTests.swift`,假体 trash + 注入内存 HistoryStoring 假体或临时目录 `JSONHistoryStore`):load 填充两侧列表、denied 行 disable 为 no-op、正常 disable 后列表移除且 `lastReport.source == "launch-items"`、history 里能读到该报告、exclude 后该行变 denied。
- [ ] **Step 2:** `Scripts/test.sh --filter LaunchItemsViewModelTests` 预期 FAIL。
- [ ] **Step 3: 实现 VM + 视图**——用户级列表(每行:Label/文件名、runAtLoad/keepAlive/disabled 标签、parseFailed 标「无法解析」、denied 置灰标「受保护」+「排除」按钮);系统级只读区含固定文案;确认弹窗逐项列出(默认取消);报告 toast 沿 `CleanReportView`;`RootView` 接线。
- [ ] **Step 4: L10n**——`launch.title`、`launch.user`、`launch.system`、`launch.system.hint`、`launch.parsefailed`、`launch.tag.runatload`、`launch.tag.keepalive`、`launch.tag.disabled`、`launch.disable`、`launch.confirm.title`、`launch.confirm.hint`、`launch.protected`、`launch.exclude`、`launch.empty`、`report.source.launchItems`。
- [ ] **Step 5:** 全量绿 + `swift build`。
- [ ] **Step 6: Commit** `feat(ui): 启动项管理页(确认流、保护门置灰、排除、双语)`

### Task 9: 文档——README + QA 清单

**Files:**
- Modify: `README.md`(路线图五期 → `✅ 已实现(待人工 QA)`;功能节加监控/启动项两段;测试用例数更新为实际值;已知限制并入 spec §9 要点)
- Create: `docs/superpowers/qa/phase5-qa-checklist.md`

**Interfaces:** 无代码接口。

- [ ] **Step 1: QA 清单**——诚实原则(沿四期):自动核验项只写有真实命令输出的;人工项 A1–An 全 `- [ ]`(仪表盘各卡真机渲染、后台暂停、建议卡触发、禁用后 LaunchAgents 行为、废纸篓恢复、深浅色、VoiceOver、双语);注明计时/数值可变;基线 HEAD 记本任务前一提交。
- [ ] **Step 2: README** 更新并跑 `Scripts/test.sh` 确认用例数数字与实际一致。
- [ ] **Step 3: Commit** `docs: 五期收尾——README、QA 清单、规格状态`

---

## 完成后

1. 整支分支终审(独立 fresh reviewer)
2. `Scripts/test.sh` 全量 + 红线检查(唯一 trashItem 实现、零新增 Process、L10n 1:1、tools-version 6.3)
3. spec 状态行改「已实施(待人工 QA)」
4. 合入/推送**须用户明确指示**,不得自行执行
