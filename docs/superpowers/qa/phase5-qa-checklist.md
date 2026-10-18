# Raccoon 五期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」或「⏳ 待人工」,**绝不将待人工项标成已验,也不把代码落位当成测试证据**。
>
> - **✅ 自动核验**:证据为真实运行的命令输出、测试名与文件位置,或明确标注的代码锚点;不包含任何 GUI 目测结论。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤与预期,一律未预标绿。
>
> **实测基线(2026-10-18,分支 `feat/phase5`,代码态 `d9d022d`)**:
>
> - `Scripts/test.sh` 全量 **298/298 绿**(四期基线 231 → 五期 298,只增不减,净增 67)。
> - 中英 L10n 各 **167** 键,键集 diff 为空(167:167 1:1)。
> - 终验安全 grep 符合期望:全仓零 unlink/removeItem 实现,唯一删除实现仍为 `TrashService.swift:21` 的 `FileManager.trashItem`;五期代码 diff(a881c4b..d9d022d)零新增 `removeItem`/`unlink`/`Process(` 调用。
> - 本文档所有「✅」均以该次实测为准;命令输出逐条留存原文,无编造。
>
> **数值可复现性说明**:本文档中的字节数、百分比、耗时均为当次运行值,会随机型、系统负载、卷状态与电池状态变化;可复现的是测试计数(298)、exit code、L10n 键数与构建成功与否,不是具体数值。

## 一、✅ 自动核验项(6 项)

### 1. 全量测试 298/298 绿 — ✅

```text
$ Scripts/test.sh > /tmp/phase5-full-test.log 2>&1; echo EXIT=$?
EXIT=0
```

`/tmp/phase5-full-test.log` 中 7 组结果行原文:

```text
✔ Test run with 66 tests in 6 suites passed after 0.059 seconds.
✔ Test run with 48 tests in 4 suites passed after 0.102 seconds.
✔ Test run with 32 tests in 6 suites passed after 0.001 seconds.
✔ Test run with 19 tests in 3 suites passed after 0.002 seconds.
✔ Test run with 14 tests in 2 suites passed after 0.202 seconds.
✔ Test run with 29 tests in 8 suites passed after 0.093 seconds.
✔ Test run with 90 tests in 9 suites passed after 0.769 seconds.
```

合计 66 + 48 + 32 + 19 + 14 + 29 + 90 = **298**,exit 0,无 skip、无 fail。

> 注:每行末尾的秒级计时为当次运行值,因机而异、不可精确复现;测试计数(298)与 exit(0)可复现。

### 2. 删除红线 grep:零 unlink/removeItem 实现,唯一 trashItem 实现,五期零新增危险调用 — ✅

```text
$ grep -rn "removeItem\|unlink" Sources/ --include='*.swift'
Sources/CleanKit/TrashService.swift:18:    /// 唯一删除动作:移入废纸篓。绝不 unlink。
# 命中 1 行,且为「绝不 unlink」注释,零实现调用 → 符合期望

$ grep -rn "trashItem" Sources/ --include='*.swift'
Sources/CleanKit/TrashService.swift:21:            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
Sources/CleanKit/TrashService.swift:25:            // /Applications 下 root/admin 归属的应用,直接 trashItem 会报权限不足;
Sources/AppCore/ScanViewModel.swift:34:    // (否则硬编码真实服务会对不存在的 /a 真调 trashItem → .vanished → trashedCount 断言必红)
# 命中 3 行:唯一实现为 TrashService.swift:21;另两行均为注释
```

```text
$ git diff a881c4b..HEAD -- Sources | grep -E '^\+.*(removeItem|unlink|Process\()'
(无输出)
# 五期新增代码零删除实现、零新增进程调用;快照瘦身仍复用既有 SnapshotCleaner
```

结论:五期零新增删除路径,`FileManager.trashItem` 仍是唯一删除实现,启动项禁用经 `TrashService.trashItem` 移入废纸篓,与 spec §6 四道门映射一致。

### 3. 工具链:Swift 6.3、零第三方依赖 — ✅

```text
$ grep -n "swift-tools-version" Package.swift
1:// swift-tools-version: 6.3

$ grep -rn "\.package(" Package.swift
(无输出,grep exit 1)
# → 零第三方依赖 → 符合期望
```

### 4. L10n 键集:167:167,diff 为空 — ✅

```text
$ diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
       <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
(无输出,exit 0)
zh_keys=167
en_keys=167
```

### 5. swift build — ✅

```text
$ swift build 2>&1 | grep -E "error:|Build complete" | tail -3
Build complete! (2.94秒)
```

> 注:构建耗时因机而异;`Build complete` 与零 error 可复现。本机 CLT 工具链会输出若干 `ld: warning: search path ... not found`,为本机工具链环境警告,非代码错误。

### 6. 本分支五期提交序列 — ✅

```text
$ git log --oneline d86d5e8^..d9d022d
d9d022d fix(ui): 确认按钮双击守卫与首载空态
ea5c0d8 fix(ui): 启动项页排除入口与禁用并发/报告时序修复
de7c20c feat(ui): 启动项管理页(确认流、保护门置灰、排除、双语)
5135483 fix(ui): 离开监控页停止轮询(补 vm.stop)
f680400 feat(ui): 状态监控仪表盘(指标卡+sparkline+建议卡,L10n 双语)
a10c0ee feat(launch): 启动项禁用编排(保护门拦截、trash-only、source 记账)
be18efa fix(launch): LaunchItemScanner 根目录可注入(Task 8 测试确定性)
f64735e feat(launch): LaunchKit 解析与扫描(损坏 plist 不静默、非 plist 忽略)
a25ee74 test(monitor): 补 cpuTicks 失败隔离分支覆盖
0e7ff86 feat(monitor): MonitorViewModel 轮询状态机(暂停恢复、单指标失败隔离)
ed24e13 fix(monitor): 磁盘建议跳转改为磁盘分析(对齐 spec §5.2)
a6bd820 feat(monitor): 电池/网络组装与建议引擎真值表(边界严格小于)
bbb6963 fix(monitor): MemoryStats/CPULoad 补 memberwise public init(跨模块构造)
160c0fa feat(monitor): 内存构成组装与 CPU tick 差值计算(首采样空态)
b38b137 feat(monitor): MonitorKit target 与卷信息组装(purgeable clamp、系统盘标记)
1781426 docs: 五期实现计划——9 任务(MonitorKit/LaunchKit/AppCore/UI/文档,TDD 锚点+红线)
d86d5e8 docs: 五期设计稿——状态监控+系统优化(MonitorKit/LaunchKit,动作复用已审计管线)
```

## 二、⏳ 待人工项(15 项,一律未预标绿)

### A1. 仪表盘五类卡片真机渲染 — ⏳ 待人工

- [ ] 步骤:启动应用,进「状态监控」,观察指标区。
- 预期:系统盘大卡显示可用/总量与可用条形,若存在可清除空间则显示 purgeable 提示;内存卡显示已用/总量、压缩、联动(wired)、可清除四项;CPU 卡显示 user/system/idle 百分比与 sparkline;电池卡按机型显示充电中/使用电池/外接电源;网络卡显示 Wi-Fi/有线/其他或离线。数值量级合理,无裸 key、无布局溢出。

### A2. 窗口切后台轮询暂停与回前台恢复 — ⏳ 待人工

- [ ] 步骤:停留在监控页,记录 CPU sparkline 的推进;切换到其他应用/隐藏 Raccoon 一段时间,再切回。
- 预期:非活跃期间轮询暂停(CPU/内存 2s、磁盘/电池 30s 采样不再推进;可用 Instruments 的 Energy/Time Profiler 或采样日志核对);回前台后自动恢复,曲线从暂停前的历史继续,不清空、不重复建循环。

### A3. CPU sparkline 首周期空态 — ⏳ 待人工

- [ ] 步骤:首次进入监控页(或 VM 首次 start),观察 CPU 卡最初 2 秒。
- 预期:首个采样周期无差值,显示「等待首个采样」类空态文案而非 0% 或空白图;约 2 秒后出现第一个数据点,随后曲线逐点增长;历史最多 60 点,超出后丢弃最旧点。

### A4. 建议卡四种规则触发与跳转 — ⏳ 待人工

- [ ] 步骤:分别构造/等待以下条件,观察建议区:①任一卷可用空间 < 10% 或 < 10 GB;②存在本地 Time Machine 快照;③`~/Library/LaunchAgents` 至少 1 个 plist;④`~/Library/Logs/DiagnosticReports` 至少 1 项。
- 预期:四条规则各自出现对应建议卡;点击「磁盘空间紧张」跳到磁盘分析,「快照占用可回收」与「崩溃报告可清理」跳到清理模块,「审查开机自启项」进入启动项管理子页;无任何命中时整个建议区隐藏,不显示「一切正常」占位。

### A5. 启动项列表与系统级只读区 — ⏳ 待人工

- [ ] 步骤:从监控页进入「启动项管理」,对照 `~/Library/LaunchAgents` 与 `/Library/LaunchAgents`、`/Library/LaunchDaemons`。
- 预期:用户级列表逐项显示 Label(缺失时退回文件名)与文件名,RunAtLoad/KeepAlive/Disabled/无法解析/受保护标签按实际显示;无法解析的 plist 照常列出并标「无法解析」,不静默丢弃;非 plist 文件忽略;系统级区块只读、无禁用/排除按钮,页脚固定说明「系统级,需管理员权限,本应用不修改」。

### A6. 禁用确认弹窗默认键为取消 — ⏳ 待人工

- [ ] 步骤:对任一可操作启动项点「禁用」,观察确认卡片;直接按回车,再重开按 Esc。
- 预期:确认卡片列出 Label 与文件名并说明「移入废纸篓,可从废纸篓放回恢复」;默认聚焦「取消」,回车不触发禁用;Esc 关闭卡片;只有显式点击「禁用」才执行。

### A7. 确认卡进度态与确认→报告原地切换 — ⏳ 待人工

- [ ] 步骤:确认禁用一项,观察禁用期间与完成后的卡片;期间快速连点「禁用」。
- 预期:禁用期间确认卡显示进度指示、两个按钮均锁住,连点不重复执行;成功后同一 sheet 原地切换到报告态(不闪退、不被系统吞掉),报告来源标注「启动项管理」并显示剩余项数;失败时卡片关闭、页面显示可读失败原因(映射为本地化文案,未知代码落到「其他原因」),不伪造成功报告。

### A8. 禁用后 launchd 实际行为(重启后不再自启)— ⏳ 待人工

- [ ] 步骤:选一个可弃的自建用户级 LaunchAgent(或临时创建一个测试 plist)禁用,然后注销/重启。
- 预期:对应 plist 已移入废纸篓;重启/重新登录后 launchd 不再加载该 Label,进程不再自启。注意:禁用只移除 plist,不主动 `bootout` 已在运行的进程,本次登录内进程可能继续存活到退出/注销。

### A9. 废纸篓恢复 — ⏳ 待人工

- [ ] 步骤:从废纸篓把被禁用的 plist「放回原处」,重新登录。
- 预期:文件回到 `~/Library/LaunchAgents`,launchd 重新加载并在下次登录/重启后恢复自启;应用内不做撤销,恢复路径只有废纸篓。

### A10. 页内排除后置灰反馈与持久化 — ⏳ 待人工

- [ ] 步骤:对某个未受保护的用户级启动项点「排除」;再打开设置页排除清单核对;返回启动项页。
- 预期:该行立即显示「受保护」标签、禁用按钮置灰、排除按钮消失(操作被拒但信息可见);排除项仍列在列表中;排除写入设置页同一清单并持久化;重新进入页面/重启应用后仍为置灰状态。

### A11. 启动项首载空态与无闪烁 — ⏳ 待人工

- [ ] 步骤:清空或临时改名 `~/Library/LaunchAgents` 后进入启动项页;再恢复目录重进。
- 预期:首轮扫描完成前显示小进度指示,不闪一帧「空列表」;扫描完成且无条目时显示空态文案;系统级区块同样按加载完成后再渲染。

### A12. 单指标失败隔离与无电池机型 — ⏳ 待人工

- [ ] 步骤:在台式机/无电池机器上观察电池卡;模拟或等待某一采集器失败(如拔掉外置卷后观察磁盘卡)。
- 预期:无电池机型显示「外接电源」而非报错;单个采集器取不到数据时仅该卡显示「暂不可用」,其余卡片与页面交互不受影响;磁盘列表为空时显示降级卡而不是空白区。

### A13. 深浅色模式与窄窗口布局 — ⏳ 待人工

- [ ] 步骤:浅色/深色各过一遍监控页(五类卡片、建议卡、工具区)、启动项页(用户/系统列表、确认卡、报告);拉窄窗口。
- 预期:双模式均无裸 key、无对比度不足、无截断/重叠/溢出;窄窗口下指标网格自适应换列,建议卡与按钮仍可操作,长文件名中间截断。

### A14. VoiceOver 无障碍 — ⏳ 待人工

- [ ] 步骤:开启 VoiceOver,遍历监控页卡片、建议卡、工具按钮、启动项行与确认弹窗。
- 预期:卡片标题作为 heading 播报,磁盘/电池/网络卡内容合并为完整语句;按钮有明确标签与禁用状态;确认弹窗能读到 Label、文件名、后果说明与默认「取消」;sparkline 等纯视觉元素不产生无意义噪音,也不吞掉关键数值。

### A15. en/zh 双语与文案完整性 — ⏳ 待人工

- [ ] 步骤:系统语言切 English 与简体中文,各过一遍监控页与启动项页全部状态(含空态、错误态、确认/报告)。
- 预期:无裸 key、无英文串混入中文界面;中文使用全角标点;布局可容纳两种语言;L10n 键集 167:167 已在自动项核验,人工重点核对语义与排版。

## 已知限制

引用 spec §9 全部五条(README「已知限制」节已同步):

1. 会话登录项(App Store 式)无法免 root 列举,不展示。
2. 系统级 LaunchAgents/Daemons 只读,修改需用户自行处理。
3. 不展示 SSID;网络状态为连通性级别。
4. CPU sparkline 首个轮询周期为空;磁盘数据 30s 才刷新一次。
5. 内存「已用」为 Mach 统计口径,与活动监视器「内存压力」不一一对应。

沿承一至四期的限制不变:`~/Library/Preferences` 与 `~/Library/Cookies` 因硬保护不列出;系统级 `/Library` 残留与任何提权继续顺延;磁盘分析无 FDA 时 `~/Library` 部分子树不可读、体量口径为块占用。

## 统计

- **✅ 自动核验:6 项**(全量测试、删除红线 grep、工具链、L10n、swift build、提交序列)。
- **⏳ 待人工:15 项**(A1–A15),每项均为 `- [ ]` 未勾选,给出操作步骤与预期,无一预标绿。

**结论**:工程侧自动可核验面全部为绿(298/298、L10n 167:167、安全 grep 符合期望、swift build 通过);五期功能与交互的人工验收尚未执行,本文档不宣称任何未真机验证项为「满足」。
