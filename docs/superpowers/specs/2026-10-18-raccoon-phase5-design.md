# 五期设计:状态监控 + 系统优化(Monitor)

状态:已实施(待人工 QA)(2026-10-18)

## 1. 背景与目标

侧边栏 `monitor` 模块(gauge 图标)自一期起一直是占位。五期把它做实:

- **状态监控**:磁盘、内存、CPU、电池、网络五类指标的只读仪表盘
- **系统优化**:建议卡(点击跳转对应模块)+ 用户级启动项管理(五期唯一的全新动作实现)

核心原则:**动作优先复用已审计管线**。清理、快照瘦身(`tmutil-thin`)、系统垃圾(`system.crash-reports` 等)在规则库与 CleanKit 中均已存在,五期不新增任何删除或进程调用代码,只新增监控数据采集、建议引擎与启动项管理。

## 2. 非目标(本期不做)

- **不做「释放内存」类动作**:现代 macOS 内存压缩机制下无效且有害,仪表盘只展示
- **不做系统级启动项修改**:`/Library/LaunchAgents`、`/Library/LaunchDaemons` 只读展示,标注「系统级,本应用不修改」
- **不做 App Store 式会话登录项管理**:现代 SDK 已移除 `LSSharedFileList` 头文件,免 root 列举无可行 API,列为已知限制
- **不做 SSID 展示**:macOS 14+ 获取 Wi-Fi SSID 需要定位权限,与清洁类应用的隐私姿态冲突
- **不改 `rules.json`**:`system.crash-reports`(诊断报告)与 `cautious.tm-snapshots`(快照瘦身)已存在,version 保持 1
- **不新增任何 `Process` 调用**:tmutil 复用既有 `SnapshotCleaner`

## 3. 关键决策

| 决策 | 结论 | 依据 |
| --- | --- | --- |
| 架构 | 新增 `MonitorKit` + `LaunchKit` 两个纯逻辑 SPM target | 与「每期一个 Kit」惯例一致,采样/解析与编排职责分离 |
| 登录项禁用方式 | plist 经 `TrashService.trashItem` 移废纸篓 | 全仓唯一删除实现,可从废纸篓放回恢复,trash-only 红线零例外 |
| TM 快照 / 系统垃圾 | 监控页只加入口与建议卡,跳清理模块 | `cautious.tm-snapshots`、`system.crash-reports` 规则已存在,零新增危险面 |
| sparkline 实现 | 自绘 `Canvas` | 沿四期 `TreemapView` 惯例,不引 Charts 框架,风格统一 |
| 轮询节奏 | CPU/内存 2s,磁盘/电池 30s,网络事件驱动;窗口非活跃暂停 | 采集成本与刷新价值平衡 |

## 4. 总体架构

```
Raccoon (UI)           MonitorHomeView / LaunchItemsView / 确认弹窗
AppCore                MonitorViewModel(轮询状态机) / LaunchItemsViewModel
MonitorKit (新)        纯逻辑:采样组装 + 建议引擎
  ├─ DiskMetrics       mountedVolumeURLs + volumeAvailableCapacityForImportantUsage
  ├─ MemoryMetrics     host_statistics64(HOST_VM_INFO64) + sysctl hw.memsize
  ├─ CPUMetrics        host_processor_info tick 差值 → user/sys/idle %
  ├─ PowerMetrics      IOKit IOPSCopyPowerSourcesInfo(电量/充电/电源类型)
  ├─ NetworkStatus     NWPathMonitor(在线/离线 + 接口类型,事件驱动)
  └─ SuggestionEngine  输入快照 → [Suggestion]{icon,title,detail,destination}
LaunchKit (新)         纯逻辑:LaunchAgents 解析 + 禁用编排
  ├─ LaunchItemParser  plist → LaunchItem{label,program,runAtLoad,keepAlive,disabled}
  ├─ LaunchItemScanner 用户级 ~/Library/LaunchAgents(可操作) + 系统级只读清单
  └─ LaunchItemStore   禁用编排:ProtectionStore 门禁 → TrashService.trashItem
既有复用               SnapshotCleanerServicing / CleanExecutor / rules.json / ExclusionsStore
```

**系统调用缝隙**:所有 mach/IOKit/NWPath/FileManager 调用藏进协议(`HostSampling`、`PowerSampling`、`VolumeProviding`、`PathMonitoring`),实现类薄壳不测,数学与组装纯函数全测。沿 DiskKit 先例。

**MonitorKit 不依赖 AppCore**;LaunchKit 依赖 CleanKit(`ProtectionStore`、`TrashService`)但不依赖 ScanKit/AppCore。

## 5. 详细设计

### 5.1 采集(MonitorKit)

- **磁盘**:所有可写用户卷;每卷 `{name, totalBytes, availableBytes, purgeableBytes}`;`~` 所在卷标记系统盘。`volumeAvailableCapacityForImportantUsage` 给出含可清除空间的估值,`purgeable = importantUsage - 纯 available`
- **内存**:`{totalBytes, usedBytes, compressedBytes, wiredBytes, purgeableFreeBytes}`;`used = total - free - inactive - purgeable`(外部页计入 used);不做「内存压力」红绿灯——压力等级需要内核私有信号,展示四项构成已足够
- **CPU**:相邻两次采样的 tick 差值 `/ elapsed ticks` → `{userPct, systemPct, idlePct}`;每核求和后再归一;60 点环形缓冲;**首个采样无差值,展示为空而非 0%**
- **电池**:`{percentage, charging, onBattery}`;桌面机无电池电源源 → `hasBattery = false`,UI 显示「外接电源」
- **网络**:`{online, interface: .wifi/.wired/.other}`,`NWPathMonitor` 回调驱动,不轮询

### 5.2 建议引擎(SuggestionEngine)

输入 = 采集快照 + 三个探针(注入协议,实现薄壳):快照存在性(`SnapshotCleanerServicing.listSnapshots`)、LaunchAgents 非空、DiagnosticReports 非空。规则(全部可单测真值表):

| 条件 | 建议 | 跳转 |
| --- | --- | --- |
| 任一卷可用 < 10% 或 < 10 GB | 磁盘空间紧张 | 磁盘分析 |
| 本地快照存在 | 快照占用可回收 | 清理模块 |
| 用户 LaunchAgents ≥ 1 | 审查开机自启项 | 启动项管理 |
| DiagnosticReports ≥ 1 | 崩溃报告可清理 | 清理模块 |

无命中 → 建议区整体隐藏(不显示「一切正常」占位)。建议是**只读引导**,自身不携带动作。

### 5.3 启动项管理(LaunchKit)

- **扫描**:`~/Library/LaunchAgents/*.plist`;解析 `Label`、`Program`/`ProgramArguments`(取首个为展示名)、`RunAtLoad`、`KeepAlive`、`Disabled`;非 plist 文件忽略;**解析失败的条目照常列出**并标「无法解析」,展示原始文件名,不静默丢弃
- **禁用**:逐项确认弹窗(沿四期 `DiskConfirmView` 模式,列出文件名与 Label)→ `TrashService.trashItem` 移废纸篓 → 列表即时移除;`CleanReport.source = "launch-items"` 记入历史
- **保护门**:每个可操作项先过 `ProtectionStore.isDenied`(硬保护 + 用户排除);被拒项**照常列出、禁用按钮置灰并标注原因**(信息可见、操作被拒)。用户排除沿用 `ExclusionsStore`,启动项页支持对单项添加排除
- **恢复**:引导语明示「移入废纸篓,可从废纸篓放回恢复」;不做应用内撤销
- **系统级**:`/Library/LaunchAgents`、`/Library/LaunchDaemons` 只读清单(文件名 + Label 若可解析),区块头部固定文案「系统级,需管理员权限,本应用不修改」

### 5.4 UI(Raccoon)

`Module.monitor` 移入 `availableCases`。`MonitorHomeView` 自上而下:

1. **指标网格**:系统盘大卡(可用/总量条形 + purgeable 提示)、内存卡(已用/压缩/联动/可清除)、CPU 卡(user/sys/idle + sparkline)、电池/网络状态行
2. **建议卡**(有才显示):icon + 标题 + 一句说明,点击切换导航
3. **优化工具**:启动项管理入口(子页)、快照瘦身(跳清理)、系统垃圾(跳清理)

`LaunchItemsView`:用户级列表(可禁用)→ 系统级只读列表 → 确认弹窗。全部 en/zh key 1:1,zh 值全角标点;深浅色 + 无障碍标签沿既有模式。

### 5.5 ViewModel(AppCore)

- `MonitorViewModel`:持采样器协议,`start()` 建 Timer(2s/30s)与 NWPathMonitor,`stop()` 释放;`scenePhase` 非活跃暂停;状态 `{idle, running, ready}`;单个采集器失败该指标卡显示「暂不可用」,不拖垮整页;时钟注入(`PollingClock` 协议)保证可测
- `LaunchItemsViewModel`:加载/禁用/排除三动作;禁用经 `CleanExecutor` 单目标(path, action `.trash`,`source: "launch-items"`)生成报告并记入历史

## 6. 安全与四道门映射

| 门 | 五期落点 |
| --- | --- |
| 硬保护 | 启动项禁用前 `ProtectionStore.isDenied`;硬保护根下的 plist(如 `~/Library` 若在硬保护内)永不可禁用 |
| 用户排除 | `ExclusionsStore` 同源;排除项照常列出、按钮置灰并标注,支持页内添加 |
| 安全分级 | LaunchAgents 禁用为新「cautious 级动作」,确认弹窗默认取消;监控仪表盘纯只读不进门禁 |
| trash-only | 唯一删除实现仍是 `TrashService.swift` 的 `FileManager.trashItem`;五期零新增 `removeItem`/`unlink`/`Process` |

## 7. 测试策略(TDD 锚点)

- **MonitorKit**:CPU tick 差值数学(含跨零、首采样空态)、内存构成组装、卷信息组装与 purgeable 计算、建议引擎真值表(每规则命中/不命中/边界 10%/10GB)、环形缓冲容量
- **LaunchKit**:plist 解析(fixtures:完整/缺 Label/ProgramArguments 形态/损坏 XML 不静默)、扫描器目录遍历与非 plist 忽略、禁用编排(注入 TrashService 假体,**测试不真删**)、保护门拒绝路径
- **AppCore**:MonitorViewModel 轮询节奏(注入时钟)、暂停恢复、LaunchItemsViewModel 禁用后列表更新与报告 source
- 全部经 `Scripts/test.sh`;测试总数只增不减(基线 231)

## 8. 验收标准(Done)

1. `monitor` 模块可用:五类指标展示,窗口切后台轮询暂停
2. 建议卡按规则出现/隐藏,点击正确跳转
3. 用户级 LaunchAgents 可列出、可禁用(进废纸篓)、可排除;系统级只读
4. `Scripts/test.sh` 全绿;红线检查零新增违规删除/进程调用
5. L10n en/zh 1:1,zh 全角标点;README 路线图与 QA 清单更新

## 9. 已知限制

- 会话登录项(App Store 式)无法免 root 列举,不展示
- 系统级 LaunchAgents/Daemons 只读,修改需用户自行处理
- 不展示 SSID;网络状态为连通性级别
- CPU sparkline 首个轮询周期为空;磁盘数据 30s 才刷新一次
- 内存「已用」为 Mach 统计口径,与活动监视器「内存压力」不一一对应
