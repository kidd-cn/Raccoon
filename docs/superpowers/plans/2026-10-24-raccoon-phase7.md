# Raccoon 七期实施计划:网络流量显示

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 网络指标从「仅连通性」升级为「连通性 + 实时速率(↓/↑)+ 自开机以来累计收发」,落地菜单栏标签、菜单栏面板、五期监控页三处。

**Architecture:** 沿既有分层——MonitorKit 纯函数(接口白名单/去重/差分钳制)→ AppCore 采集壳(sysctl NET_RT_IFLIST2,零权限)与双 VM 差分状态 → MenuBarKit 快照与短格式 → Raccoon UI 渲染与 L10n。速率由 VM 快循环两次采样差分得出;累计直接取接口计数器(自开机以来,无持久化)。

**Tech Stack:** Swift 6 / SwiftUI(macOS 14+,CLT-only 工具链)/ Swift Testing / sysctl NET_RT_IFLIST2。

**Spec:** `docs/superpowers/specs/2026-10-24-raccoon-phase7-design.md`

## Global Constraints(每任务隐含全条)

- 零新增删除代码:全仓唯一删除实现仍是 `Sources/CleanKit/TrashService.swift:21` 的 `FileManager.trashItem`;不得新增 `removeItem`/`unlink`/`Process(`。
- 零第三方依赖;`Package.swift` 首行 `swift-tools-version: 6.3` 不得上调。
- L10n:en/zh 键集 1:1(CI 强制);本地化文案只出现在 Raccoon 层;zh 值全角标点;单位符号(`B`/`K`/`M`/`G`、`KB/s`、`↓`/`↑`)为通用符号不翻译。
- CLT-only 工具链缺 SwiftUI 宏插件:`@State`/`@Binding`/`@Environment` 一律手写展开(`_x: State<T>` + 计算属性,沿 `MenuBarLabelView`/`MonitorHomeView` 写法);`@Observable`/`@Bindable` 可用。
- 测试只经 `Scripts/test.sh`(禁裸 `swift test`;单套件 `Scripts/test.sh --filter <Suite>`);基线 **375** 只增不减。
- 真实系统采集薄壳不单测(与 `LiveSystemSampler` 既有口径一致,靠代码审);纯逻辑全部 TDD。
- 依赖方向:MenuBarKit 只依赖 MonitorKit;AppCore 依赖 MonitorKit/MenuBarKit;Raccoon 显式声明所用 target。

## Review Focus(测试覆盖不了、最易咬人的五类输入)

1. **休眠唤醒首拍**:跨休眠差分 ÷ 墙钟间隔,首拍速率失真——期望:下一拍自愈,不崩不错持续(人工 QA;VM 侧以「elapsed ≤ 0 → 速率 nil」兜住时钟回拨一类)。→ T4/T5 测时钟回拨,真休眠归人工。
2. **VPN/虚拟接口双计**:口径 = 仅 `en*`;期望:开 VPN 后数字 ≈ 物理链路实际字节,不翻倍(人工 QA 对照活动监视器时须先讲明口径差异)。→ T1 白名单测试 + T8 QA 清单注明。
3. **采集失败/空**:无 `en*` 接口或 sysctl 失败/解析异常 → `traffic()` 返回 nil;期望:快照冻结旧值、UI 不误报 0 流量。→ T1 空输入测试 + T2 代码审。
4. **计数器重置/接口插拔**:USB 网卡拔插、驱动重载致 delta < 0;期望:该维钳 0,不出现负速率/负累计。→ T1/T4/T5 钳制测试。
5. **菜单栏窄空间**:速率文本 `↓999B ↑12.3M` 随长度变化;期望:系统截断时图标仍在,不挤压崩溃(iconOnly 样式完全不受影响)。→ 人工 QA(T6 保持现有 iconOnly 分支零改动)。

---

### Task 1: MonitorKit 流量纯函数(模型/白名单去重/差分钳制)

**Files:**
- Create: `Sources/MonitorKit/TrafficMetrics.swift`
- Test: `Tests/MonitorKitTests/TrafficMetricsTests.swift`(沿现有 `Tests/MonitorKitTests/` 组织)

**Interfaces:**
- Consumes: 无(独立纯函数;`import Foundation`)
- Produces(Task 2/3/4/5 依赖,签名逐字):
  - `public struct NetworkTrafficCounters: Equatable, Sendable { public let rxBytes: Int64; public let txBytes: Int64; public init(rxBytes: Int64, txBytes: Int64) }`(显式 memberwise:合成仅 internal,跨模块假体需构造,理由同 `NetworkStatus.init` 注释)
  - `public struct NetworkTraffic: Equatable, Sendable { public let receivedBytes: Int64; public let sentBytes: Int64; public let receivedBPS: Double?; public let sentBPS: Double?; public init(receivedBytes: Int64, sentBytes: Int64, receivedBPS: Double?, sentBPS: Double?) }`
  - `public func assembleTrafficCounters(_ entries: [(name: String, rx: Int64, tx: Int64)]) -> NetworkTrafficCounters?` — 仅 `name.hasPrefix("en")` 参与统计;同名条目只计首条(按名去重为防御性约束);求和;无匹配 → nil
  - `public func assembleTraffic(current: NetworkTrafficCounters, previous: NetworkTrafficCounters, elapsedSeconds: TimeInterval) -> NetworkTraffic` — 累计 = current;任一维 delta < 0 该维钳 0;`elapsedSeconds <= 0` → 双维速率 nil(累计照常);否则 BPS = Double(delta) / elapsedSeconds

- [ ] **Step 1: 写失败测试**(断言值逐字,1024 进制口径不在本任务,勿混入)

```swift
import Testing
import Foundation
import MonitorKit

@Suite struct TrafficMetricsTests {
    // 白名单:en 前缀参与,其余(lo/utun/ipsec/awdl/llw/ap/bridge)全排除
    @Test func whitelistOnlyEnInterfaces() {
        let counters = assembleTrafficCounters([
            (name: "en0", rx: 100, tx: 10),
            (name: "lo0", rx: 5, tx: 5),
            (name: "utun3", rx: 50, tx: 50),
            (name: "ipsec0", rx: 7, tx: 7),
            (name: "awdl0", rx: 9, tx: 9),
            (name: "llw0", rx: 3, tx: 3),
            (name: "ap1", rx: 2, tx: 2),
            (name: "bridge0", rx: 4, tx: 4),
        ])
        #expect(counters == NetworkTrafficCounters(rxBytes: 100, txBytes: 10))
    }

    // 同名去重:sysctl 每接口恰一条,同名重复现采集中并不出现;去重保留为防御性约束(同名只计首条,防双计)
    @Test func deduplicatesSameNameEntries() {
        let counters = assembleTrafficCounters([
            (name: "en0", rx: 100, tx: 10),
            (name: "en0", rx: 100, tx: 10),
            (name: "en1", rx: 1, tx: 1),
            (name: "en1", rx: 999, tx: 999),
        ])
        #expect(counters == NetworkTrafficCounters(rxBytes: 101, txBytes: 11))
    }

    @Test func emptyInputIsNil() {
        #expect(assembleTrafficCounters([]) == nil)
    }

    @Test func allExcludedIsNil() {
        #expect(assembleTrafficCounters([(name: "utun0", rx: 1, tx: 1)]) == nil)
    }

    // 差分:正常推进
    @Test func trafficDeltaComputesRates() {
        let t = assembleTraffic(
            current: NetworkTrafficCounters(rxBytes: 2048, txBytes: 2048),
            previous: NetworkTrafficCounters(rxBytes: 1024, txBytes: 512),
            elapsedSeconds: 2)
        #expect(t.receivedBytes == 2048 && t.sentBytes == 2048)
        #expect(t.receivedBPS == 512.0 && t.sentBPS == 768.0)
    }

    // 负 delta(接口重置/计数器清零)该维钳 0,另一维照常
    @Test func negativeDeltaClampsToZeroPerDimension() {
        let t = assembleTraffic(
            current: NetworkTrafficCounters(rxBytes: 10, txBytes: 3000),
            previous: NetworkTrafficCounters(rxBytes: 1000, txBytes: 1000),
            elapsedSeconds: 1)
        #expect(t.receivedBytes == 10 && t.sentBytes == 3000)
        #expect(t.receivedBPS == 0.0 && t.sentBPS == 2000.0)
    }

    // elapsed ≤ 0(同拍/时钟回拨):速率 nil,累计照出
    @Test func nonPositiveElapsedYieldsNilRatesOnly() {
        let counters = NetworkTrafficCounters(rxBytes: 500, txBytes: 600)
        for elapsed in [0.0, -3.0] {
            let t = assembleTraffic(current: counters, previous: NetworkTrafficCounters(rxBytes: 100, txBytes: 100), elapsedSeconds: elapsed)
            #expect(t.receivedBytes == 500 && t.sentBytes == 600)
            #expect(t.receivedBPS == nil && t.sentBPS == nil)
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败** — `Scripts/test.sh --filter TrafficMetricsTests`,预期编译错误「cannot find 'assembleTrafficCounters'」
- [ ] **Step 3: 实现** `Sources/MonitorKit/TrafficMetrics.swift`,按 Produces 签名逐字;`assembleTrafficCounters` 用 `var seen = Set<String>()` 去重 + 求和;文档注释注明「真实 sysctl NET_RT_IFLIST2 采集不在本层」(与 `NetworkMetrics.swift:25` 注释口径一致)
- [ ] **Step 4: 跑测试确认全绿** — 同 Step 2 命令
- [ ] **Step 5: Commit** — `feat(traffic): MonitorKit 流量计数白名单去重与差分钳制`

### Task 2: AppCore 采集壳与协议扩展(sysctl NET_RT_IFLIST2)

**Files:**
- Modify: `Sources/AppCore/MonitorViewModel.swift`(SystemSampling 协议 ~:11 加要求 + 默认实现;`LiveSystemSampler` ~:166 加覆盖实现)

**Interfaces:**
- Consumes: Task 1 的 `NetworkTrafficCounters`/`assembleTrafficCounters`
- Produces(Task 4/5 依赖):
  - `SystemSampling` 协议新增 `func traffic() -> NetworkTrafficCounters?`,并配 `public extension SystemSampling { func traffic() -> NetworkTrafficCounters? { nil } }` 默认实现——注释写明:默认 nil 使五期既有测试假体零改动兼容,真覆盖在 LiveSystemSampler
  - `LiveSystemSampler.traffic()`:`sysctl(NET_RT_IFLIST2)` 一次性快照(64 位 `if_data64`,活动监视器同款)→ 解析 `RTM_IFINFO2`/`if_msghdr2`,接口名取自 RTAX_IFP 的 `sockaddr_dl` → `[(name, rx, tx)]` 摊平 → `assembleTrafficCounters`;系统调用失败/解析异常/无 en 接口 → nil。薄壳不单测(注释同 `volumes()` 口径)。**执行注记:首版曾用 getifaddrs(提交 `878941a`),因 AF_LINK 的 `if_data` 计数器为 32 位(单接口 ~4 GiB 回绕,撑不住累计口径)改为 sysctl NET_RT_IFLIST2**

- [ ] **Step 1: 协议加要求 + extension 默认实现**(要求本体与默认实现放一起,注释说明兼容动机)
- [ ] **Step 2: LiveSystemSampler 覆盖** — mib `[CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]` 两次调用(先估 size 再取);按字节遍历 buffer,仅 `ifm_type == RTM_IFINFO2`;名字:ifm_addrs 含 RTAX_IFP 位时按 RTAX 顺序遍历 sockaddr(步进按 4 字节对齐)取 `sockaddr_dl`,sdl_data+sdl_nlen 取名;计数:`ifm_data.ifi_ibytes/ifi_obytes`(struct if_data64,u_int64;SDK 实名为 ifi_*)
- [ ] **Step 3: 全量回归** — `./Scripts/test.sh`,预期 375/375 绿(默认实现保证旧假体不破;零新测试——纯逻辑已由 Task 1 覆盖,薄壳靠审)
- [ ] **Step 4: Commit** — `feat(traffic): SystemSampling 流量接缝与 getifaddrs 采集壳`

### Task 3: MenuBarKit 快照字段、标签 case 与短格式

**Files:**
- Modify: `Sources/MenuBarKit/MenuBarModels.swift`(`MenuBarSnapshot` 加字段、`MenuBarLabel` 加 case)
- Modify: `Sources/MenuBarKit/MenuBarLabelFormatter.swift`(.network 分支 + 短格式函数)
- Test: `Tests/MenuBarKitTests/MenuBarLabelFormatterTests.swift`(追加;该文件已有 volume/memory/cpu helper 复用)

**Interfaces:**
- Consumes: Task 1 `NetworkTraffic`
- Produces(Task 4/6 依赖):
  - `MenuBarSnapshot` 新增 `public let traffic: NetworkTraffic?`,init 追加带默认值参数 `traffic: NetworkTraffic? = nil`(放 `network` 之后;现有调用零改动)
  - `MenuBarLabel` 新增 `case traffic(down: String, up: String)`
  - `MenuBarLabelFormatter.label` 的 `.network` 分支:`guard let t = snapshot.traffic, let down = t.receivedBPS, let up = t.sentBPS else { return .network(snapshot.network) }` → `.traffic(down: shortBytesPerSecond(down), up: shortBytesPerSecond(up))`(速率未就绪/traffic nil 一律回退现有接口文案口径)
  - `public static func shortBytesPerSecond(_ bps: Double) -> String` — `max(0, bps)`;`< 1024` → `"\(Int(bps))B"`;否则 1024 进制逐级 K/M/G,`String(format: "%.1f%@", value, unit)` 统一一位小数(`String(format:)` 不做本地化,恒为点号)

- [ ] **Step 1: 写失败测试**(追加到 `MenuBarLabelFormatterTests.swift`;断言值逐字)

```swift
// MARK: - 流量短格式(spec §3:1024 进制、一位小数、单位单字符)

@Test func shortRateBytes() {
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(0) == "0B")
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(512) == "512B")
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(1023.9) == "1023B")
}

@Test func shortRateNegativeClampsToZero() {
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(-5) == "0B")
}

@Test func shortRateKiloMegaGiga() {
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(1024) == "1.0K")
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(1536) == "1.5K")
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(1_048_576) == "1.0M")
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(1_258_291.2) == "1.2M")
    #expect(MenuBarLabelFormatter.shortBytesPerSecond(1_288_490_188.8) == "1.2G")
}

@Test func networkLabelPrefersTrafficWhenRatesReady() {
    let traffic = NetworkTraffic(receivedBytes: 1, sentBytes: 2, receivedBPS: 1536, sentBPS: 512)
    let snapshot = MenuBarSnapshot(
        network: NetworkStatus(online: true, interface: .wifi), traffic: traffic)
    #expect(MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
        == .traffic(down: "1.5K", up: "512B"))
}

@Test func networkLabelFallsBackWithoutTraffic() {
    let snapshot = MenuBarSnapshot(network: NetworkStatus(online: true, interface: .wifi))
    #expect(MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
        == .network(NetworkStatus(online: true, interface: .wifi)))
}

@Test func networkLabelFallsBackWhenRatesPending() {
    // 首拍:traffic 在但速率为 nil(无差分基准)→ 回退接口文案
    let traffic = NetworkTraffic(receivedBytes: 1, sentBytes: 2, receivedBPS: nil, sentBPS: nil)
    let snapshot = MenuBarSnapshot(
        network: NetworkStatus(online: false, interface: .other), traffic: traffic)
    #expect(MenuBarLabelFormatter.label(metric: .network, style: .iconAndValue, snapshot: snapshot)
        == .network(NetworkStatus(online: false, interface: .other)))
}

@Test func snapshotTrafficDefaultsToNil() {
    #expect(MenuBarSnapshot().traffic == nil)
}
```

- [ ] **Step 2: 跑测试确认失败** — `Scripts/test.sh --filter MenuBarLabelFormatterTests`,预期编译错误(无 `traffic`/`traffic` case/`shortBytesPerSecond`)
- [ ] **Step 3: 实现** — 三个文件的改动按 Produces 逐字;`MenuBarLabel` 的 case 注释注明「网络指标速率就绪时的菜单栏短格式,视图渲染为 ↓down ↑up」
- [ ] **Step 4: 跑测试确认全绿** — 同 Step 2;再全量 `./Scripts/test.sh` 确认 375+新增 全绿
- [ ] **Step 5: Commit** — `feat(traffic): MenuBarKit 快照流量字段与标签短格式`

### Task 4: 六期 MenuBarMonitorViewModel 接入差分

**Files:**
- Modify: `Sources/AppCore/MenuBarMonitorViewModel.swift`(`refreshFast` ~:116、`updateSnapshot` ~:255)
- Test: `Tests/AppCoreTests/MenuBarMonitorViewModelTests.swift`(追加;复用文件内既有 fake 组织)

**Interfaces:**
- Consumes: Task 1 `assembleTraffic`/类型、Task 2 `SystemSampling.traffic()`
- Produces(Task 6 依赖):
  - `MenuBarMonitorViewModel.snapshot.traffic: NetworkTraffic?`(快照字段,经 `updateSnapshot` 的「未传即保留」语义维护)
  - 私有差分状态 `previousTraffic: NetworkTrafficCounters?` / `previousTrafficAt: Date?`;`refreshFast` 内:采样成功才前移基准(nil 失败拍冻结),`now()` 注入时钟供测试

- [ ] **Step 1: 写失败测试**(追加;需给文件内采样假体加可编程流量——若既有 fake 未实现 `traffic()`,加 `var trafficValue: NetworkTrafficCounters?` 存储属性即可,协议默认实现已兜底签名)

```swift
// 以下断言逐字;now 为注入时钟,fastInterval 无关(直接调 refreshFast)
@Test func trafficFirstTickAccumulatesWithoutRate() async throws {
    // 假体:traffic 返回固定 counters;now 返回递增序列 [t0, t0+5]
    // 第一次 refreshFast:snapshot.traffic == nil(无基准,不产 NetworkTraffic)
    // 第二次 refreshFast:snapshot.traffic != nil,累计 == counters 值,receivedBPS == delta/5
}
@Test func trafficFailureFreezesPreviousSnapshot() async throws {
    // 假体序列:counters → nil → counters(同值)
    // 三次 refreshFast 后:snapshot.traffic 保持第一次成功差分的结果(冻结),基准未前移
}
@Test func trafficClockRollbackYieldsNilRateButAdvancesBaseline() async throws {
    // now 序列 [t0, t0-10](回拨):第二次 refreshFast 后
    // snapshot.traffic!.receivedBPS == nil 且累计 == 新 counters;第三次(t0+5)恢复出速率
}
```

(写成完整可编译用例,断言以 `#expect` 落在上述行为点上;测试名即行为名)
- [ ] **Step 2: 跑测试确认失败** — `Scripts/test.sh --filter MenuBarMonitorViewModelTests`(预期 traffic 相关断言失败/编译错)
- [ ] **Step 3: 实现** — `refreshFast` 在 CPU 段后加流量段(采样 → 与 Task 4 Interfaces 一致的差分 → `updateSnapshot(traffic:)`);`updateSnapshot` 加 `traffic: NetworkTraffic? = nil` 参数透传给 `MenuBarSnapshot.init`
- [ ] **Step 4: 跑测试确认全绿** — 单套件 + 全量(基线 375 + Task 1/3/4 新增,只增不减)
- [ ] **Step 5: Commit** — `feat(traffic): 菜单栏 VM 快循环差分接入`

### Task 5: 五期 MonitorViewModel 接入(注入时钟)

**Files:**
- Modify: `Sources/AppCore/MonitorViewModel.swift`(`MonitorViewModel` 属性 ~:31、init ~:58、`refreshFast` ~:92)
- Test: `Tests/AppCoreTests/MonitorViewModelTests.swift`(追加)

**Interfaces:**
- Consumes: 同 Task 4
- Produces(Task 7 依赖):
  - `MonitorViewModel.public private(set) var traffic: NetworkTraffic?`
  - init 追加带默认值参数 `now: @escaping @Sendable () -> Date = Date.init`(现有调用零改动;与六期 VM 对齐,测试可注入时钟)
  - `refreshFast` 的差分语义与 Task 4 逐字一致(成功前移基准、失败冻结、回拨速率 nil)

- [ ] **Step 1: 写失败测试**(与 Task 4 三用例同构,直接调 `refreshFast`,断言 `vm.traffic`)
- [ ] **Step 2: 跑测试确认失败** — `Scripts/test.sh --filter MonitorViewModelTests`
- [ ] **Step 3: 实现** — 属性 + init 参数 + refreshFast 流量段(CPU 段之后;注意五期 refreshFast 的 cpuTicks 失败分支是提前 `return`,流量段必须放在该 `guard` **之前**,保证 CPU 失败拍流量照常推进)
- [ ] **Step 4: 跑测试确认全绿** — 单套件 + 全量
- [ ] **Step 5: Commit** — `feat(traffic): 监控页 VM 差分接入与注入时钟`

### Task 6: Raccoon 菜单栏标签与面板(L10n)

**Files:**
- Modify: `Sources/Raccoon/MenuBarLabelView.swift`(`displayText` ~:56)
- Modify: `Sources/Raccoon/MenuBarPanelView.swift`(`networkSection` ~:174)
- Modify: `Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings`(键集 1:1 同步加)

**Interfaces:**
- Consumes: Task 3 `.traffic(down:up:)`、Task 4 `snapshot.traffic`
- Produces(Task 8 复用):新 L10n 键(逐字,en/zh 同步):

```text
"menubar.panel.network.totals" = "Recv %@ / Sent %@";   / "收 %@ / 发 %@";
"monitor.network.pending"      = "Sampling rate…";       / "正在采集速率…";
"monitor.network.received"     = "Received";             / "收";
"monitor.network.sent"         = "Sent";                 / "发";
```

- 标签渲染:`displayText` 新分支 `case .traffic(let down, let up): return "↓\(down) ↑\(up)"`(纯符号拼接,无本地化键)
- 面板网络卡:在现有 `Label(interfaceTitle…)` 行下加两行——速率行 `↓ \(rateText(traffic.receivedBPS))` / `↑ \(rateText(traffic.sentBPS))`(新私有 helper:`guard let bps else { return loc("monitor.network.pending") }` → `byteText(Int64(max(0, bps))) + "/s"`);累计行 `Text(loc("menubar.panel.network.totals", byteText(traffic.receivedBytes), byteText(traffic.sentBytes)))`;`traffic` 为 nil 时两行整体不出现(与磁盘 purgeable 行「为 0 不占行」同口径);速率行加 `.accessibilityElement(children: .combine)` 并以累计行文本收尾合并朗读
- 手写 `@State` 展开约束:本任务两文件只读 VM,不新增状态属性,无涉

- [ ] **Step 1: 加键**(en/zh 同一 commit,`grep -c '^"'` 两侧相等)
- [ ] **Step 2: 实现标签与面板改动** — `swift build` 过
- [ ] **Step 3: 全量回归** — `./Scripts/test.sh` 全绿(UI 无新测试,零回归即可)
- [ ] **Step 4: Commit** — `feat(traffic): 菜单栏标签速率与面板网络卡收发展示`

### Task 7: 五期监控页网络卡升级

**Files:**
- Modify: `Sources/Raccoon/MonitorHomeView.swift`(`networkCard` ~:186;`MetricCard` 为同文件私有 struct 可直接用)
- Modify: `Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Task 5 `vm.traffic`、Task 6 的键(`monitor.network.pending`/`received`/`sent`)、现有 `interfaceTitle`/`interfaceIcon`/`byteText`
- Produces: 新键(若不存在才加;加则 en/zh 1:1):

```text
"monitor.network.title" = "Network";   / "网络";
```

- 网络卡由单行 `StatusCard` 升级为 `MetricCard(title: loc("monitor.network.title"), icon: interfaceIcon(vm.network))`,内容三行:①状态行 `Label(interfaceTitle(vm.network), systemImage: interfaceIcon(vm.network)).font(.callout)`;②速率行(有 `vm.traffic` 时):`↓ rateText(receivedBPS)` `↑ rateText(sentBPS)` 沿 Task 6 helper 口径(把 helper 提为文件内共享或复用 L10n.swift 共享函数,勿复制两份);③累计行 `metricRow(loc("monitor.network.received"), byteText(receivedBytes))` + `metricRow(loc("monitor.network.sent"), byteText(sentBytes))`;`vm.traffic` 为 nil 时②③不出现(单指标失败隔离,与内存卡「暂不可用」口径一致——状态行永远在)
- `batteryCard` 继续用 `StatusCard`,不动

- [ ] **Step 1: 加/确认键** — en/zh 同步
- [ ] **Step 2: 实现网络卡升级** — `swift build` 过
- [ ] **Step 3: 全量回归** — `./Scripts/test.sh` 全绿
- [ ] **Step 4: Commit** — `feat(traffic): 监控页网络卡升级为速率+累计指标卡`

### Task 8: 文档收尾(README/QA 清单/spec 状态)

**Files:**
- Modify: `README.md`(roadmap 加七期行、功能 bullet、已知限制、测试数)
- Create: `docs/superpowers/qa/phase7-qa-checklist.md`
- Modify: `docs/superpowers/specs/2026-10-24-raccoon-phase7-design.md`(状态行 → 「已实施(待人工 QA,<实际日期>)」)

**Interfaces:**
- Consumes: 前 7 任务的真实命令输出(测试计数、L10n 键数、红线 grep、提交序列)——所有 ✅ 数字必须来自本任务内实际执行,不许抄计划预估值
- Produces: 六期 QA 清单同构的七期清单(诚实声明/自动核验项/人工项 A1–An 全 `- [ ]` 未预勾)

- [ ] **Step 1: 实测并记录** — `./Scripts/test.sh`(记 8 组计数与合计)、`grep -c '^"'` 双语键数、红线 grep(`git diff <七期基线>..HEAD -- Sources Package.swift | grep -E '^\+.*(removeItem|unlink|Process\()'` 零输出)、`swift build`、`git log --oneline <基线>..HEAD`
- [ ] **Step 2: QA 清单** — 诚实声明 + 6 类自动核验(数字全部来自 Step 1 实测)+ 人工项(至少:菜单栏标签速率推进、面板/监控页速率与累计对照活动监视器(注明 en* 口径差异)、VPN 场景双计核验、休眠唤醒首拍、深浅色/双语/窄菜单栏、iconOnly 不受影响;每项附步骤与预期,一律 `- [ ]`)
- [ ] **Step 3: README 与 spec 状态行** — roadmap 表加「七期 | 网络流量显示 | ✅ 已实现(待人工 QA)」;已知限制同步 spec §7 五条(其中「不做 sparkline」与六期第 8 条口径合并去重,README 不重复列);功能 bullet 补「网络速率与累计(自开机以来)」
- [ ] **Step 4: Commit** — `docs: 七期收尾——README、QA 清单、规格状态`

---

## 执行交接

- 工作区:`git worktree add .worktrees/phase7 -b feat/phase7`(基线 = `main` @ 设计稿提交);基线验证 `./Scripts/test.sh` = 375/375 绿。
- 执行方式沿用六期:**subagent-driven**(每任务新实现者 → spec 审 → 质量审 → 修复回路;终审全分支)。任务间串行,不并行派发实现者。
- 合并与推送等用户明确指令(沿用六期约定)。
