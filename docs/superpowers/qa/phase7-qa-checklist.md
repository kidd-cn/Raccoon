# Raccoon 七期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」或「⏳ 待人工」,**绝不将待人工项标成已验,也不把代码落位当成测试证据**。
>
> - **✅ 自动核验**:证据为真实运行的命令输出、测试名与文件位置,或明确标注的代码锚点;不包含任何 GUI 目测结论。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤与预期,一律未预标绿。
>
> **实测基线(2026-10-24,分支 `feat/phase7`,代码态 `2441f31`;七期自 main `7f369c9` 分叉,至代码态共 15 个提交;本文档所有数字均来自本清单编写前在该代码态的实际运行)**:
>
> - `Scripts/test.sh` 全量 **396/396 绿**(六期基线 375 → 七期 396,只增不减,净增 21:`MonitorKitTests` 32 → 39(新增 `TrafficMetricsTests` 套件)、`MenuBarKitTests` 56 → 63、`AppCoreTests` 110 → 117,各 +7;其余五组计数与套件数与六期逐组一致)。
> - 中英 L10n 各 **200** 键,键集 diff 为空(200:200 1:1;六期基线 195 → 七期 +5)。
> - 删除红线 grep 符合期望:七期代码 diff(`7f369c9..HEAD`,限 `Sources` 与 `Package.swift`)**零**新增 `removeItem`/`unlink`/`Process(` 调用(原文见自动核验 3)。
> - `swift build --target Raccoon` 通过(`Build complete`,零 error)。
> - 本文档所有「✅」均以该次实测为准;命令输出逐条留存原文,无编造。
>
> **数值可复现性说明**:本文档中的秒级计时均为当次运行值,因机而异、不可精确复现;可复现的是测试计数(396)、exit code、L10n 键数与构建成功与否。速率/累计等运行期数字依赖系统网络活动,本文档不记录、也不以其为证据。

## 一、✅ 自动核验项(5 项)

### 1. 全量测试 396/396 绿 — ✅

```text
$ ./Scripts/test.sh 2>&1 | grep -E "Test run with|error:"
```

8 组结果行原文(执行于 `2441f31`):

```text
✔ Test run with 66 tests in 6 suites passed after 0.054 seconds.
✔ Test run with 48 tests in 4 suites passed after 0.100 seconds.
✔ Test run with 39 tests in 7 suites passed after 0.001 seconds.
✔ Test run with 63 tests in 3 suites passed after 0.007 seconds.
✔ Test run with 20 tests in 3 suites passed after 0.002 seconds.
✔ Test run with 14 tests in 2 suites passed after 0.201 seconds.
✔ Test run with 29 tests in 8 suites passed after 0.091 seconds.
✔ Test run with 117 tests in 10 suites passed after 0.742 seconds.
```

合计 66 + 48 + 39 + 63 + 20 + 14 + 29 + 117 = **396**,exit 0,无 skip、无 fail、无 `error:` 行。

组归属(同一运行中各组结果行之前逐列的 `✔ Suite …` 名与 suites 数一一对应):

| 组 | tests/suites | 归属 test target(套件名) |
| --- | --- | --- |
| 1 | 66/6 | UninstallKitTests(LeftoverLocations、FileSize、LeftoverLocator、Smoke、OrphanScanner、AppDiscovery) |
| 2 | 48/4 | ScanKitTests(Smoke、RuleStore、ScanEngine、BundledRules) |
| 3 | **39/7** | **MonitorKitTests**(DiskMetrics、SampleRing、**TrafficMetrics**、MemoryMetrics、CPUMetrics、PowerAndNetwork、SuggestionEngine;`TrafficMetricsTests` 为七期新增套件) |
| 4 | **63/3** | **MenuBarKitTests**(NotificationPolicy、MenuBarLabelFormatter、MenuBarPreferences;七期速率短格式用例并入 LabelFormatter) |
| 5 | 20/3 | LaunchKitTests(LaunchItemStore、LaunchItemParser、LaunchItemScanner) |
| 6 | 14/2 | DiskKitTests(SquarifiedTreemap、DiskScanner) |
| 7 | 29/8 | CleanKitTests(Smoke、CleanReportSource、CleanExecutor、ProtectionStore、SystemIntegration、TrashService、SnapshotCleaner、HistoryStore) |
| 8 | **117/10** | **AppCoreTests**(Smoke、AIToolGroups、ExclusionsStore、UninstallServices、LaunchItemsViewModel、ScanViewModel、DiskAnalysisViewModel、UninstallViewModel、MenuBarMonitorViewModel、MonitorViewModel;后两个 VM 套件七期各并入流量差分用例) |

> 注:本文档编写前共完整运行 2 次,均 exit 0;8 组计数取自第二次全量留档,两次末组(117)一致。

### 2. L10n 键集 200:200、diff 为空;七期新增 5 键双语齐备 — ✅

```text
$ grep -c '^"' Sources/Raccoon/Resources/en.lproj/Localizable.strings
200
$ grep -c '^"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings
200
```

```text
$ diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
       <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
(无输出,exit 0)
```

七期新增键(六期基线 195 → 200,两表同增;`git diff 7f369c9..HEAD -- Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings` 原文):

```text
+"monitor.network.pending" = "正在采集速率…";
+"monitor.network.received" = "收";
+"monitor.network.sent" = "发";
+"monitor.network.title" = "网络";
+"menubar.panel.network.totals" = "收 %@ / 发 %@";
```

英文侧对应:`Sampling rate…` / `Received` / `Sent` / `Network` / `Recv %@ / Sent %@`。单位符号(`B`/`K`/`M`/`G`、`/s`)与 `↓`/`↑` 箭头为通用符号不翻译,不占键;新增键值内无半角标点(`…` 为全角省略号,`/` 为累计行的格式分隔符)。

### 3. 删除红线 grep:七期零新增 removeItem/unlink/Process( — ✅

```text
$ git diff 7f369c9..HEAD -- Sources Package.swift | grep -E '^\+.*(removeItem|unlink|Process\()'
(无输出,grep exit 1)
# 七期新增代码零删除实现、零新增进程调用;网络流量为只读监控增强,无任何删除入口
```

结论:七期零新增删除路径,`FileManager.trashItem` 仍是唯一删除实现(`Sources/CleanKit/TrashService.swift`,六期已验、本期未触及),与 spec §8 全局约束一致。

### 4. swift build --target Raccoon — ✅

```text
$ swift build --target Raccoon 2>&1 | tail -5
[68 / 72] Raccoon-product
[71 / 73] Raccoon-product
/Users/adder.chia/programs/github/macCleaner/.worktrees/phase7/Package.swift: Raccoon-product: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found
/Users/adder.chia/programs/github/macCleaner/.worktrees/phase7/Package.swift: Raccoon-product: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found
Build complete! (2.01秒)
```

> 注:两条 ld warning 为 CLT 工具链链接器搜索路径的本机环境提示,非 error(与六期构建同环境同现);`Build complete` 与零 error 可复现,耗时因机而异。

### 5. 七期提交序列 — ✅

```text
$ git log --oneline 7f369c9..HEAD
2441f31 fix(traffic): 网络卡头部改固定图标消除双 wifi
9e8e33a feat(traffic): 监控页网络卡升级为速率+累计指标卡
2c2c9a0 fix(traffic): 面板速率行打磨与 a11y 注释对齐
4180063 feat(traffic): 菜单栏标签速率与面板网络卡收发展示
ea822c8 fix(traffic): 流量段注释措辞与断言风格对齐
2ff34fc feat(traffic): 监控页 VM 差分接入与注入时钟
8a61c9c test(traffic): 序列时钟注释收敛与读尽空安全
eeb913d feat(traffic): 菜单栏 VM 快循环差分接入
879766c fix(traffic): 短格式非有限值防御与 iconOnly 结构钉固
3731de7 feat(traffic): MenuBarKit 快照流量字段与标签短格式
4d1f1f8 docs(traffic): 注释与计划对齐 sysctl 口径——字段实名 ifi_*、采集层指向 LiveSystemSampler
b7efd5c fix(traffic): 采集壳改 sysctl NET_RT_IFLIST2 64 位计数
bf5b9e0 docs(traffic): 采集口径改 sysctl NET_RT_IFLIST2——getifaddrs AF_LINK 计数器 32 位撑不住累计
878941a feat(traffic): SystemSampling 流量接缝与 getifaddrs 采集壳
c70789d feat(traffic): MonitorKit 流量计数白名单去重与差分钳制
```

共 15 个提交,覆盖 MonitorKit 纯函数(en 白名单/同名去重/差分钳制)、AppCore 采集壳(sysctl `NET_RT_IFLIST2`;首版 getifaddrs 因 AF_LINK 计数器 32 位回绕弃用,见 `bf5b9e0`/`b7efd5c`)与两 VM 差分接入、MenuBarKit 快照字段与短格式、UI(菜单栏标签/面板网络卡/监控页指标卡)、修复轮次与口径文档对齐;本清单自身所在的 docs 提交在其后,不含于上表。

## 二、人工核验项(8 项,已人工核验)

> 2026-10-24 用户完成 A1–A8 人工核验并确认通过,无缺陷上报;以下勾验为该口径的如实记录。

### A1. 菜单栏标签网络速率(iconAndValue 样式)— ✅ 人工核验完成(2026-10-24)

- [x] 步骤:启动应用,设置页「菜单栏」tab 把指标选为「网络」、样式选「图标 + 数值」;盯住菜单栏标签最初两拍;随后发起一次大流量下载(或播放高码率视频)持续观察,再停止下载观察回落。
- 预期:首拍(尚无差分基准)回退现有接口文案(如「Wi-Fi」),不出半成品速率;次拍起变为短格式速率 `wifi ↓x.xK ↑xxxB`(1024 进制、单位单字符无空格、≥1K 统一一位小数);速率随下载明显上涨、停止后数拍内回落;`↓`/`↑` 分别对应收/发方向。

### A2. 面板网络卡:速率行与累计行、traffic 未采集/失败拍语义 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:点击菜单栏图标展开面板看网络卡——先冷启动应用立即展开(首拍前);再开着面板持续采样;然后断开 Wi-Fi/拔网线制造无 `en*` 接口或采集失败瞬间观察两行,恢复网络后再看。
- 预期:正常态接口状态行下有速率行(`↓ x KB/s ↑ y KB/s`,既有 ByteCountFormatter 口径 + `/s`)与累计行(`收 x / 发 y`);**traffic 为 nil(未采集,如首拍前)时速率与累计两行整体不渲染,接口状态行保留**;运行中失败拍为冻结语义——两行不消失、不归零,保留最后一次成功采样的数字(锚点:`MenuBarMonitorViewModel.swift:292` 的 `traffic ?? snapshot.traffic`;`MonitorViewModel.swift:118` 起注释「失败拍不动 traffic 也不动基准」),恢复采样后继续推进;速率位尚未就绪(两维 bps 为 nil,如时钟回拨拍)时显示「正在采集速率…」占位、累计照常(锚点 `Sources/Raccoon/L10n.swift:26` `rateText`)。

### A3. 监控页网络卡:指标卡三段与跨视图一致 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:打开主窗口「状态监控」页检查网络卡(七期由五期单行 StatusCard 升级为与其他卡一致的指标卡);与菜单栏面板(或标签)同屏对比数字。
- 预期:卡内三段齐备——接口状态行(`Wi-Fi`/`有线`/`其他`/`离线`/`暂不可用`标题与配套图标)、速率行(`↓ x/s ↑ y/s`)、累计行(`收 x`、`发 y` 两行);卡头为固定 `network` 类别图标,动态接口图标只在状态行,同卡不出现两个 wifi 图标(`2441f31` 修复口径);与菜单栏两处数字反映同一系统事实:量级一致、同拍不互相矛盾(两处独立采样,监控页 2s、菜单栏 5s,允许采样相位差内的差异)。

### A4. 与活动监视器对照:速率量级一致、累计口径有差 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:打开活动监视器「网络」tab,记下收发速率与「已收到/已发送数据」;本应用面板与监控页记同项;跑一段大流量下载后再次对照。
- 预期:速率量级一致(数据同源:sysctl 接口字节计数,活动监视器同款数据源);**累计数字与活动监视器允许有明显差**——本应用口径为仅 `en*` 物理链路(不含 lo/utun/awdl 等),活动监视器为全接口求和,差异即口径差而非缺陷(对照以 spec §2 口径为准);VPN 下的表现另见 A5。

### A5. VPN 场景不双计 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:连接 VPN(产生 utun 隧道)前后各记录本应用与活动监视器的速率/累计;经隧道跑一段流量后再记录对比。
- 预期:本应用数字始终为 `en*` 物理链路实际传输量,不含 utun 隧道重复计数,量级不因隧道封装翻倍;活动监视器(全接口求和)可能同时含物理链路与隧道两份字节数,与本应用的差即隧道部分。

### A6. 休眠唤醒:首拍失真与下一拍自愈 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:开着应用(菜单栏指标=网络,或监控页在前台),合盖休眠数分钟后唤醒,立刻观察唤醒后前两三拍速率。
- 预期:唤醒后第一个速率样本跨了休眠时长(差分跨睡眠期,分母为整段墙钟间隔),可能失真(常见为被摊薄偏低);下一拍(监控页 2s/菜单栏 5s 后)恢复正常量级;过程不崩、不出负速率,累计行不受影响(接口计数器单调)。

### A7. 深浅色 / 双语 / 窄菜单栏 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:浅色与深色模式各过一遍菜单栏网络标签、面板网络卡、监控页网络卡;系统语言在 English 与简体中文间各切一次再看三处;把菜单栏挤满(多开常驻图标应用)观察网络标签。
- 预期:双模式无对比度问题、无裸 key;三处文案完整跟随系统语言——速率占位 zh「正在采集速率…」/ en「Sampling rate…」,累计行 zh「收 x / 发 y」/ en「Recv x / Sent y」,监控页卡题 zh「网络」/ en「Network」,中文值内不混半角标点;窄菜单栏下系统可能截断速率文本,图标仍可见可点、不挤压崩溃、不溢出。

### A8. iconOnly 样式完全不受影响 — ✅ 人工核验完成(2026-10-24)

- [x] 步骤:设置页「菜单栏」tab 样式切「仅图标」、指标保持「网络」,观察菜单栏;再切回「图标 + 数值」;样式与指标选择各重启一次应用确认保留。
- 预期:「仅图标」下菜单栏仍是纯图标、无任何速率文本,与六期行为完全一致(七期速率仅作用于 iconAndValue 分支,锚点 `MenuBarLabelFormatter.swift:12` `guard style == .iconAndValue else { return .none }`);切回后速率恢复显示;偏好重启保留。

## 已知限制

引用 spec §7 全部五条(README「已知限制」节已同步;其中第 5 条与六期既有「内存/网络为数值摘要,无曲线」为同一口径,README 在原条目合并确认、不重复列):

1. 口径为 `en*` 物理链路:与活动监视器(全接口)数字不同;VPN 下本口径不含隧道重复计数
2. 休眠唤醒后第一个速率样本跨了休眠时长,可能失真;下一拍恢复
3. 速率粒度 = 快循环间隔(监控页 2s、菜单栏 5s),非实时抖动级
4. 累计为「自开机以来」,重启归零;不做今日口径与持久化
5. 网络不做 sparkline(延续六期限制口径:面板曲线仅 CPU;速率与累计即数值摘要)

沿承一至六期的限制不变(六期清单「已知限制」节全表继续有效)。

## 统计

- **✅ 自动核验:5 项**(全量测试、L10n 键集、删除红线 grep、`swift build --target Raccoon`、七期提交序列)。
- **✅ 人工核验:8 项**(A1–A8),用户于 2026-10-24 完成核验确认通过,无缺陷上报。

**结论**:工程侧自动可核验面全部为绿(396/396、L10n 200:200、红线 grep 零输出、target 构建通过);七期人工验收已于 2026-10-24 由用户按 A1–A8 完成闭环。
