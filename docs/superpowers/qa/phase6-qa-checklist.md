# Raccoon 六期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」或「⏳ 待人工」,**绝不将待人工项标成已验,也不把代码落位当成测试证据**。
>
> - **✅ 自动核验**:证据为真实运行的命令输出、测试名与文件位置,或明确标注的代码锚点;不包含任何 GUI 目测结论。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤与预期,一律未预标绿。
>
> **实测基线(2026-10-22,分支 `feat/phase6`,代码态 `2e98922`;本文档所有数字均来自本清单编写前在该代码态的实际运行,共执行全量测试 3 次,各组计数逐次一致)**:
>
> - `Scripts/test.sh` 全量 **372/372 绿**(五期基线 300 → 六期 372,只增不减,净增 72:新增 `MenuBarKitTests` 组 56,末组 `AppCoreTests` 91 → 107)。
> - 中英 L10n 各 **195** 键,键集 diff 为空(195:195 1:1;五期基线 167 → 六期 +28)。
> - 删除红线 grep 符合期望:全仓零 unlink/removeItem 实现,唯一删除实现仍为 `TrashService.swift:21` 的 `FileManager.trashItem`;六期代码 diff(`main..HEAD`,限 `Sources` 与 `Package.swift`)零新增 `removeItem`/`unlink`/`Process(` 调用。
> - `swift build` 通过(零 error);工具链 6.3、零第三方依赖。
> - 本文档所有「✅」均以该次实测为准;命令输出逐条留存原文,无编造。
>
> **数值可复现性说明**:本文档中的字节数、百分比、耗时均为当次运行值,会随机型、系统负载、卷状态与电池状态变化;可复现的是测试计数(372)、exit code、L10n 键数与构建成功与否,不是具体数值。

## 一、✅ 自动核验项(6 项)

### 1. 全量测试 372/372 绿 — ✅

```text
$ Scripts/test.sh 2>&1 | grep -E "Test run with|error:"
```

8 组结果行原文(执行于 `2e98922`):

```text
✔ Test run with 66 tests in 6 suites passed after 0.049 seconds.
✔ Test run with 48 tests in 4 suites passed after 0.122 seconds.
✔ Test run with 32 tests in 6 suites passed after 0.001 seconds.
✔ Test run with 56 tests in 3 suites passed after 0.008 seconds.
✔ Test run with 20 tests in 3 suites passed after 0.002 seconds.
✔ Test run with 14 tests in 2 suites passed after 0.204 seconds.
✔ Test run with 29 tests in 8 suites passed after 0.092 seconds.
✔ Test run with 107 tests in 10 suites passed after 0.894 seconds.
```

合计 66 + 48 + 32 + 56 + 20 + 14 + 29 + 107 = **372**,exit 0,无 skip、无 fail、无 `error:` 行。

组归属(另一次带套件名上下文的运行中,每组结果行之前逐列的 `✔ Suite …` 名与其 suites 数一一对应):

| 组 | tests/suites | 归属 test target |
| --- | --- | --- |
| 1 | 66/6 | UninstallKitTests |
| 2 | 48/4 | ScanKitTests |
| 3 | 32/6 | MonitorKitTests |
| 4 | **56/3** | **MenuBarKitTests**(MenuBarLabelFormatterTests、NotificationPolicyTests、MenuBarPreferencesTests,六期新增) |
| 5 | 20/3 | LaunchKitTests |
| 6 | 14/2 | DiskKitTests |
| 7 | 29/8 | CleanKitTests |
| 8 | **107/10** | AppCoreTests(含 MenuBarMonitorViewModelTests,五期记录为 91 → 六期 107) |

> 注:每行末尾的秒级计时为当次运行值,因机而异、不可精确复现;测试计数(372)与 exit(0)可复现。本文档编写前共完整运行 3 次,8 组计数逐次一致。

### 2. 删除红线 grep:零 unlink/removeItem 实现,唯一 trashItem 实现,六期零新增危险调用 — ✅

```text
$ grep -rn "removeItem\|unlink" Sources/ --include='*.swift'
Sources/CleanKit/TrashService.swift:18:    /// 唯一删除动作:移入废纸篓。绝不 unlink。
# 命中 1 行,且为「绝不 unlink」注释,零实现调用 → 符合期望(与五期口径一致)

$ grep -rn "trashItem" Sources/ --include='*.swift'
Sources/CleanKit/TrashService.swift:21:            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
Sources/CleanKit/TrashService.swift:25:            // /Applications 下 root/admin 归属的应用,直接 trashItem 会报权限不足;
Sources/AppCore/ScanViewModel.swift:34:    // (否则硬编码真实服务会对不存在的 /a 真调 trashItem → .vanished → trashedCount 断言必红)
# 命中 3 行:唯一实现为 TrashService.swift:21;另两行均为注释
```

```text
$ git diff main..HEAD -- Sources Package.swift | grep -E '^\+.*(removeItem|unlink|Process\()'
(无输出,grep exit 1)
# 六期新增代码零删除实现、零新增进程调用;菜单栏为只读监控 + 导航,无任何删除入口
```

结论:六期零新增删除路径,`FileManager.trashItem` 仍是唯一删除实现,菜单栏与通知不触碰删除,与 spec §6 红线表一致。

### 3. 工具链:Swift 6.3、零第三方依赖 — ✅

```text
$ grep -n "swift-tools-version" Package.swift
1:// swift-tools-version: 6.3

$ grep -rn "\.package(" Package.swift
(无输出,grep exit 1)
# → 零第三方依赖 → 符合期望
```

### 4. L10n 键集:195:195,diff 为空;zh 全角抽查通过 — ✅

```text
$ diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
       <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
(无输出,exit 0)
zh_keys=195
en_keys=195
```

zh 全角抽查(六期新增 `menubar.settings.*` 键,值内 ASCII `,;:!?` 检查无命中):

```text
$ grep -n 'menubar.settings' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings
166:"menubar.settings.tab" = "菜单栏";
167:"menubar.settings.iconStyle" = "图标样式";
168:"menubar.settings.iconOnly" = "仅图标";
169:"menubar.settings.iconAndValue" = "图标 + 数值";
170:"menubar.settings.launchAtLogin" = "开机自启";
171:"menubar.settings.requiresApproval" = "已登记为登录项，需在系统设置中批准。";
172:"menubar.settings.openSystemSettings" = "打开系统设置";
173:"menubar.settings.loginUnavailable" = "此系统上登录项不可用。";
174:"menubar.settings.notifications" = "阈值通知";
175:"menubar.settings.notifyHint" = "磁盘空间不足或内存占用偏高时提醒（每类 6 小时最多一次）。";
176:"menubar.settings.notifyDenied" = "无法获得通知权限，请在系统设置中允许浣熊清理发送通知。";
177:"menubar.settings.memoryThreshold" = "内存提醒阈值";
178:"menubar.settings.error" = "登录项更新失败。";
```

引号内值经 `sed` 剥离键与 `"; ` 定界后 grep ASCII `,;:!?`:无命中(grep exit 1),中文文案均用全角标点(`，。（）`);行首语法分隔符 `:` 与行尾 `";` 为 `.strings` 语法,不属文案。

### 5. swift build — ✅

```text
$ swift build 2>&1 | grep -E "error:|Build complete" | tail -3
Build complete! (1.86秒)
```

> 注:构建耗时因机而异;`Build complete` 与零 error 可复现。

### 6. 本分支六期提交序列 — ✅

```text
$ git log --oneline main..HEAD
2e98922 fix(menubar): 登录项错误码化、Stepper 无障碍与授权代际守卫
96d0d39 feat(menubar): 设置页菜单栏 tab(自启/通知/阈值)与双语文案
8f16d8a fix(menubar): 磁盘进度条无障碍标签口径统一
19f0f4a refactor(menubar): 网络/百分比文案下沉共享与面板口径对齐
fd7a8e4 feat(menubar): 菜单栏常驻指标与下拉快捷面板
e2585e8 fix(ui): 离开监控页时清理启动项子页标记
d155d13 refactor(ui): 模块选择上提为共享 NavigationModel
c760fcb fix(menubar): 自启幂等、通知失败可诊断与授权语义注释
3ded441 build: Raccoon 显式声明 MenuBarKit 依赖
f1912ac feat(menubar): SMAppService 与通知系统薄壳
aa29950 fix(menubar): 通知评估去重、循环取消与测试确定性
f8171a7 feat(menubar): MenuBarMonitorViewModel(采样节奏、通知冷却、自启状态)
294c8d6 fix(menubar): 低磁盘判定容量未知时仅看字节并补边界用例
acaa306 feat(menubar): 通知策略真值表与系统缝隙协议
9c6e13d fix(menubar): 偏好 NaN 防御、测试域唯一化与合并写语义
2748c19 feat(menubar): 菜单栏偏好与通知冷却时间戳持久化
ca6df06 docs(test): 修正磁盘百分比用例注释口径(四舍五入由 .5 进位用例覆盖)
4b7c38e test(menubar): 补格式化边界与选卷顺序用例
b58737b feat(menubar): MenuBarKit 与菜单栏文案格式化
```

共 19 个提交,覆盖 MenuBarKit 纯逻辑、AppCore ViewModel、系统薄壳、UI(MenuBarExtra/面板/设置 tab)与修复轮次。

## 二、⏳ 待人工项(15 项,一律未预标绿)

### A1. 菜单栏图标常驻与四指标切换 — ⏳ 待人工

- [ ] 步骤:启动 Raccoon.app,观察菜单栏右侧出现常驻图标;打开下拉面板,在顶部指标选择器中依次切换 disk/memory/cpu/network;完全退出应用后重新启动(或注销再登录)。
- 预期:图标常驻不闪退;选中磁盘时数值为系统盘可用百分比(与 Finder「简介」量级一致)、内存为已用百分比、CPU 为 user+system 百分比、网络按接口显示(Wi-Fi/LAN/离线态);切换即时生效;重启后仍保留上次所选指标(偏好持久化)。

### A2. 图标样式切换与无数据占位 — ⏳ 待人工

- [ ] 步骤:设置页「菜单栏」tab 切「仅图标」再切「图标 + 数值」;切到 CPU 指标后立刻观察最初几秒(首个采样周期无 tick 差值)。
- 预期:「仅图标」时菜单栏只剩图标、无数值文本;「图标 + 数值」时数值紧随图标;某指标暂无数据时该位置显示 `—`,而非 0%、空白或裸 key;样式选择重启后保留。

### A3. 下拉面板五类指标卡与 CPU sparkline — ⏳ 待人工

- [ ] 步骤:点击菜单栏图标展开面板,逐卡检查磁盘/内存/CPU/电池/网络。
- 预期:五类卡片自上而下齐备——磁盘卡(可用/总量 + 条形)、内存卡(已用/总量 + 压缩/联动/可清除)、CPU 卡(百分比 + sparkline 曲线,逐点推进、最多 60 点)、电池卡(按机型显示充电/电池/外接)、网络卡(接口类型或离线);采不到的指标卡显示「暂不可用」占位,整页无裸 key、无布局溢出。

### A4. 面板打开即刷新(onAppear refreshNow)— ⏳ 待人工

- [ ] 步骤:开着面板让数值推进一段时间,记录磁盘百分比附近状态;关闭面板,在后台跑一个大文件写入(或删一个 GB 级文件到废纸篓),稍等后重新打开面板。
- 预期:面板出现时立即全量采样(refreshNow),新数值当次即可见,不出现「上一次数分钟的陈旧值」;重开首帧不闪空白或全 `—` 后再跳数。

### A5. 快捷入口逐项与主窗口重开定位 — ⏳ 待人工

- [ ] 步骤:在面板底部分别点「主窗口」「清理」「卸载」「AI 清理」「磁盘分析」「启动项管理」「设置」「退出」;先关闭主窗口(点红叉,不退出应用),再点「磁盘分析」入口;重复验证其他模块入口。
- 预期:各入口正确抵达对应模块(设置打开设置页且能直达「菜单栏」tab);主窗口已关闭时点任一模块入口能重新打开主窗口**并定位到该模块**,不停留在默认首页;「退出」使进程终止、菜单栏图标消失;启动项管理经监控页进入的子页路径与五期一致。

### A6. 多卷场景选卷规则 — ⏳ 待人工

- [ ] 步骤:挂载一个外置卷/模拟第二 APFS 卷,使系统盘之外存在可用比例更低的卷;把菜单栏指标设为磁盘,对比面板磁盘卡与菜单栏数值。
- 预期:菜单栏磁盘百分比始终取**系统盘**;当快照中不存在带系统盘标记的卷时(仅见非系统卷),取可用比例最低的卷(与通知策略同一选卷规则);数值与面板磁盘大卡一致,不出现两个数打架。

### A7. 开机自启注册与需批准状态 — ⏳ 待人工

- [ ] 步骤:设置页「菜单栏」tab 打开「开机自启」;打开「系统设置 → 通用 → 登录项」查看;回到应用记录状态;关闭开关再看系统设置;若系统标为待批准(如刚注册未批准),观察设置页。
- 预期:开启后登录项列表出现 Raccoon;关闭后消失;`requiresApproval` 时设置页显示「已登记为登录项，需在系统设置中批准。」说明与「打开系统设置」按钮,点击直达该页,且该状态不被当作失败回滚开关;注销重登后应用自启且菜单栏指标在。

### A8. 通知授权流程 — ⏳ 待人工

- [ ] 步骤:首次打开「阈值通知」开关,观察系统授权弹窗;选「允许」重开一次、再选「不允许」重开一次(必要时先在系统设置中重置权限)。
- 预期:首次开启触发系统授权弹窗;允许后开关保持开启;拒绝后开关**回弹为关**,设置页显示「无法获得通知权限，请在系统设置中允许浣熊清理发送通知。」引导,应用不静默假装开启。

### A9. 阈值通知触发与内容隐私 — ⏳ 待人工

- [ ] 步骤:场景 A:找一台磁盘充裕的机器的副本或在测试卷上把可用空间压到 <10% 或 <10 GiB,开启通知等慢循环;场景 B:把内存提醒阈值调到 70%,运行吃内存程序把已用比例推过阈值。
- 预期:命中后 30 秒内(慢循环粒度)收到本地通知;低磁盘通知只报可用空间量/比例,高内存通知只报占用比例,**不含任何路径与文件名**;未命中不骚扰。

### A10. 通知 6h 冷却与持久化 — ⏳ 待人工

- [ ] 步骤:触发一次低磁盘(或高内存)通知后,保持条件成立等 6 小时内的多个慢循环;期间完全退出应用再重新启动,确认条件仍成立;再制造另一类(高内存)命中。
- 预期:同类通知 6 小时内不再重复投递;**重启应用后冷却仍然生效**(冷却时间戳持久化于偏好存储,不因重启立刻再发);不同类(低磁盘 vs 高内存)冷却互不占用;6 小时后条件仍成立才会再发一次。

### A11. 前台横幅展示 — ⏳ 待人工

- [ ] 步骤:把 Raccoon 主窗口置于前台激活状态,制造一次阈值命中(如同 A9 场景 B)等通知。
- 预期:应用在前台时通知横幅仍然展示(delegate willPresent 生效),而非被系统静默吞掉;横幅内容正常,点击不触发任何清理动作。

### A12. 设置页「菜单栏」tab 控件与无障碍 — ⏳ 待人工

- [ ] 步骤:打开设置页 →「菜单栏」tab,逐项操作:指标四选一、图标样式、开机自启、阈值通知、内存阈值 Stepper(拖到 70 以下与 95 以上各一次);开 VoiceOver 遍历该 tab。
- 预期:五组控件齐全、即时生效并持久化;Stepper 被钳制在 70%–95% 区间到界即停;VoiceOver 对每个控件播报可读标签与当前值(阈值与磁盘进度条无障碍标签按 `2e98922`/`8f16d8a` 修复后口径),不出现只读不到值或读裸 key 的情况。

### A13. 深浅色与窄菜单栏布局 — ⏳ 待人工

- [ ] 步骤:浅/深色模式各过一遍菜单栏图标+数值、下拉面板、设置 tab;把菜单栏挤满(打开多个常驻图标应用或缩窄可用宽度)观察 Raccoon 项。
- 预期:双模式均无对比度问题、无裸 key、面板无截断/重叠;菜单栏空间不足时系统可能截断数值文本,图标仍可见、可点击,选「仅图标」可完整保住图标;窄面板下卡片自适应,不溢出窗口。

### A14. en/zh 双语完整性 — ⏳ 待人工

- [ ] 步骤:系统语言在 English 与简体中文间各切换一次,过一遍菜单栏数值标签、下拉面板五卡+快捷入口、设置「菜单栏」tab、通知标题与正文(含 A9 两类通知)。
- 预期:四处文案完整、跟随系统语言、无裸 key、中文界面不混英文文案、中文标点全角(自动项已核 `menubar.settings.*` 抽查与 195:195 键集,人工重点核对语义准确与布局容纳);通知文案在锁定语言下与系统通知中心显示一致。

### A15. 主窗口监控页与菜单栏并存 — ⏳ 待人工

- [ ] 步骤:开启菜单栏指标与通知,同时打开主窗口「状态监控」页,两处长驻对比网络状态与磁盘量级;再抽查五期监控页原功能(卡片刷新、建议卡跳转)。
- 预期:两处网络状态显示一致(各自持有 watcher,同一系统事实不互相矛盾);菜单栏采样(CPU/内存 5s)与监控页轮询(2s)并存互不干扰、CPU 占用肉眼无恶化;监控页五期功能无回归(建议卡跳转、启动项子页进入/离开正常——含 `e2585e8` 修过的离开清理)。

## 已知限制

引用 spec §9 全部七条(README「已知限制」节已同步,内存 Mach 口径一条与五期既有限制相同、README 中不重复列出):

1. 菜单栏文字受系统可用宽度限制,长文本可能被系统截断(图标样式可切「仅图标」)
2. 应用未运行时无法采样或发通知;需开启开机自启才能常驻
3. 自启注册可能要求用户在「系统设置 → 通用 → 登录项」手动批准
4. CPU 数值为 5s 采样粒度;磁盘/电池 30s 才刷新
5. 内存口径为 Mach 统计,与活动监视器「内存压力」不一一对应
6. 通知只在慢循环(30s)评估,阈值触发最长延迟 30s
7. 不做仅菜单栏模式,退出主窗口后 Dock 图标仍在

沿承一至五期的限制不变:`~/Library/Preferences` 与 `~/Library/Cookies` 因硬保护不列出;系统级 `/Library` 残留与任何提权继续顺延;磁盘分析无 FDA 时 `~/Library` 部分子树不可读、体量口径为块占用;会话登录项无法免 root 列举。

## 统计

- **✅ 自动核验:6 项**(全量测试、删除红线 grep、工具链、L10n、swift build、提交序列)。
- **⏳ 待人工:15 项**(A1–A15),每项均为 `- [ ]` 未勾选,给出操作步骤与预期,无一预标绿。

**结论**:工程侧自动可核验面全部为绿(372/372、L10n 195:195、安全 grep 符合期望、swift build 通过);六期功能与交互的人工验收尚未执行,本文档不宣称任何未真机验证项为「满足」。
