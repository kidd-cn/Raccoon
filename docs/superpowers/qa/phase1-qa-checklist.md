# Raccoon 一期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理,CLT 6.4 / macOS 27.0 SDK)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」「⏳ 待人工」或混合拆分,**绝无将待人工项标成已验**。
>
> - **✅ 自动核验**:证据为测试名(`Tests/` 文件:行)或代码落位;全部 75 用例经 `Scripts/test.sh` 于本 worktree 全绿(40+26+9)。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤。

## 一、计划原生 12 项

### 1. swift run 完整扫描真实机器,四类卡片合理数据或空态正常 — ⏳ 待人工

- 核验方式:GUI 操作。
- 步骤:`swift run` → 点击「开始扫描」→ 观察四类卡片(系统垃圾/开发工具缓存/应用缓存/谨慎清理)出现合理数据;在无开发工具的机器上 dev 类应显示空态(`detail.empty`)。
- 逻辑背书:扫描管线与四类聚合由 75 测试覆盖(`summaries_aggregatedByCategory`、`bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions`);规则根缺失空态见 `defaultMode_missingRootYieldsEmpty`。

### 2. cautious 类别默认全不勾选,橙色标识 — 混合(自动 + 待人工)

- ✅ 自动核验:默认选择集只含「safe 且未运行」——`Tests/AppCoreTests/ScanViewModelTests.swift:33-45`(cautious 与 running 构造项均不进 `selectedPaths`,断言 `== ["/a"]`);选择逻辑源头 `Sources/AppCore/ScanViewModel.swift:67`。
- ⏳ 待人工:橙色标识目测。步骤:扫描后查看 cautious 卡片描边与明细页「谨慎」标签为橙色(`Sources/Raccoon/DetailListView.swift:77` 已落 `.orange`,颜色是否如预期需人眼)。

### 3. 运行中应用缓存项黄色「应用运行中」且默认不勾选 — 混合(自动 + 待人工)

- ✅ 自动核验:检测逻辑 `defaultMode_runningAppFlagged`(`Tests/ScanKitTests/ScanEngineTests.swift`)、`testWorkspaceDetector_returnsSet`(`Tests/CleanKitTests/SystemIntegrationTests.swift:29`);默认不勾选同上项(`ScanViewModelTests.swift:35,45`)。
- ⏳ 待人工:黄色标签目测。步骤:保持某应用(如 Safari/微信)运行 → 扫描 → 明细页该应用缓存行应显示黄色「应用运行中」胶囊(`Sources/Raccoon/DetailListView.swift:76`)且默认未勾选。

### 4. 明细勾选联动底部「已选 N 项 · X GB」 — ✅ 自动核验

- 证据:`Tests/AppCoreTests/ScanViewModelTests.swift:49-50`(toggle `/b` 后 `selectedBytes == 30`);`toggle/selectAll/selectNone/uncheckCautiousAndRunning` 全路径在 `ScanViewModel.swift:81-95`,bottomBar 文案绑定 `vm.selectedPaths.count` 与 `selectedBytes`(`Sources/Raccoon/DetailListView.swift:42`,SwiftUI 声明式绑定保证显示一致)。
- 结果:联动数值逻辑全绿;显示格式(`detail.selected` 键,59 键 L10n 之一)双语齐备。

### 5. 清理后报告数字与废纸篓项目数一致;放回文件可恢复 — 混合(自动 + 待人工)

- ✅ 自动核验:报告聚合 `testClean_aggregatesReport_andSkipsProtected`、`testClean_progressReportsEachItem`(`Tests/CleanKitTests/CleanExecutorTests.swift`);VM 级 `testCleanSelected_reportsWritesHistory_andDismiss`(`ScanViewModelTests.swift:65-90`,断言 `report.trashedCount == 1` 且 MockTrash 收到的调用恰为勾选项);真实 `FileManager.trashItem` 生效 `testFileManagerTrashService_trashesTempFile`(`Tests/CleanKitTests/TrashServiceTests.swift:21-27`,真实将临时文件移入废纸篓并断言原路径消失)。
- ⏳ 待人工:从废纸篓「放回」验证可恢复。步骤:清理若干文件 → 打开废纸篓 → 记数与报告「N 项已移入废纸篓」一致 → 右键一个文件「放回原位置」→ 确认文件回到原路径且应用可用。

### 6. 设置页添加排除路径 → 重扫 → 该路径不出现 — 混合(自动 + 待人工)

- ✅ 自动核验:过滤机制 `defaultMode_userExclusionFiltersHit`(`Tests/ScanKitTests/ScanEngineTests.swift`)、排除清单存取 `testAddNormalizeDedupeAndPersist` / `testRemoveAndReload`(`Tests/AppCoreTests/ExclusionsStoreTests.swift`)、合并语义 `testUserExclusion_denyAndMerge`(`Tests/CleanKitTests/ProtectionStoreTests.swift`)。
- ⏳ 待人工:NSOpenPanel 添加交互(与项 13 合并执行)。步骤:设置 → 排除清单 → 「添加路径…」→ 选一个含缓存的目录 → 回主页重扫 → 确认该目录不在任何类别结果中。

### 7. 扫描中点取消 → 回到 idle,无残留状态 — 混合(自动 + 待人工)

- ✅ 自动核验:引擎取消语义 `cancellation_throws`(`Tests/ScanKitTests/ScanEngineTests.swift:157-167`,断言抛 `CancellationError`);VM 捕获路径 `Sources/AppCore/ScanViewModel.swift:69-70`(`CancellationError → phase = .idle`);残留清理 `dismissReport`/重扫复位见 `startScan_resetsCategoryInFocus`(`ScanViewModelTests.swift:127-137`)。**诚实说明**:「扫描进行中取消」的 VM 级专测暂无(现有 cancel 断言在 completed 态,`ScanViewModelTests.swift:54-55`),该缝隙由引擎级测试 + 代码路径覆盖。
- ⏳ 待人工:GUI 点取消。步骤:发起大目录扫描 → 进度条走动中点「取消」→ 应回主页 idle 态、无进度残留;再次扫描可正常发起。

### 8. 浅色/深色外观正常 — ⏳ 待人工

- 核验方式:人眼目测(代码面全部使用系统语义色与纯系统控件,无硬编码颜色,理论自动适配)。
- 步骤:系统设置切换浅色/深色(或在运行中用调试覆盖切换)→ 逐页(主页/明细/确认弹窗/报告/设置)检查文字对比度、橙色/黄色标签可读性。

### 9. 语言切英文界面变英文,删偏好恢复中文 — ⏳ 待人工

- 核验方式:GUI 目测(需重启应用)。
- 步骤:`defaults write com.raccooncleaner.Raccoon AppleLanguages -array en` → 重启应用 → 全部界面应为英文(59 键 en 全量);`defaults delete com.raccooncleaner.Raccoon AppleLanguages` → 重启 → 恢复中文。
- 逻辑背书:两份 Localizable.strings 各 59 键 1:1(本轮 `settings.remove` 新增后),`loc()` 消费覆盖全部用户可见文案。

### 10. history.json 有记录,主页显示「上次清理释放 X」 — 混合(自动 + 待人工)

- ✅ 自动核验:存储路径 `~/Library/Application Support/Raccoon/history.json`(`Sources/CleanKit/CleanReport.swift:28,42`);读写 roundtrip `append_and_loadAll_roundtrip`、损坏恢复 `append_preservesCorruptFileAside_andRecovers`(`Tests/CleanKitTests/HistoryStoreTests.swift`);VM 级闭环 `testCleanSelected_reportsWritesHistory_andDismiss`(`ScanViewModelTests.swift:80-84`,清理后 `loadLastCleanup()` 断言 `freedBytes == 100`)。
- ⏳ 待人工:真机文件与主页回显。**当前状态(2026-10-15)**:目录已存在但 `history.json` 尚未生成(本机尚未执行过真实清理)。步骤:完成一次真实清理 → 确认 `history.json` 生成且含本次记录 → 主页显示「上次清理释放 X」。

### 11. 微信等容器路径:结果只出现 …/Caches 子目录,绝无聊天记录目录 — 混合(自动 + 待人工)

- ✅ 自动核验:规则面设计即保证——`apps.wechat-cache` 路径精确到 `~/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches`(`Sources/ScanKit/Resources/rules.json:74-76`),聊天记录所在目录不在任何规则根内;规则存在性 `bundledRulesKeyRulesPresent`(`Tests/ScanKitTests/BundledRulesTests.swift:23-31`);与祖先规则无双重计数 `subRuleExcludedFromAncestorRule`(同文件:47-60)。
- ⏳ 待人工:真机安装微信时目测。步骤:安装并登录微信 → 扫描 → apps 类明细仅应出现 `…/Data/Library/Caches` 结尾条目,任何 `msg`/聊天记录目录不得出现;cautious 标识(该规则 `safety: cautious`)应默认未勾选。

### 12. 全程无崩溃无卡死,扫描期间 UI 可响应 — ⏳ 待人工

- 逻辑背书:扫描在后台 Task 执行、进度经 `@MainActor` 回投(`Sources/AppCore/ScanViewModel.swift:57-74`),不阻塞主线程;Task 16 已做无头活性验证(组装后 .app 二进制 8 秒探活存活,见计划文档执行记录)。
- ⏳ 待人工:步骤:完整跑一遍扫描(建议含大目录如 `~`)→ 期间拖动窗口、点菜单、滚证明细页 → 全程无卡死、无崩溃;结束后 Console.app 无 crash 报告(`~/Library/Logs/DiagnosticReports/Raccoon-*` 不新增)。

## 二、前序任务顺延追加项

### 13. NSOpenPanel 添加/删除排除路径交互流目测(Task 15 顺延)— ⏳ 待人工

- 步骤:设置 → 排除清单 → 「添加路径…」→ NSOpenPanel 弹出、可选文件或文件夹(设计取舍见 `Sources/Raccoon/SettingsView.swift:51-52` 注释)→ 选定后列表出现该路径 → 点该行 trash 按钮(本轮已加 `settings.remove` 无障碍标签)→ 路径消失且重扫后结果恢复出现。

### 14. 全程演练:扫描→卡片→明细→勾选→「清理…」→确认弹窗→「移入废纸篓」→报告→「再扫一次」回 idle;废纸篓确有项目且可放回(Task 14 顺延)— ⏳ 待人工

- 步骤:`swift run` → 开始扫描 → 四类卡片 → 点开一类别明细 → 全选/部分勾选(注意 cautious 单独分区与运行中黄色警告出现在确认弹窗)→ 底部「清理…」→ 确认弹窗核对总大小/项数、cautious 分区、运行中提示 → 点「移入废纸篓」(默认键应为取消/非破坏键,Task 14 I-1 修复)→ 报告页核对释放量/N 项/M 跳过 → 「再扫一次」回 idle → 打开废纸篓确认项目存在并放回一个文件。
- 关联 Task 14 已知缓议(非阻塞):M-2 全跳过时报告图标条件化、M-5 报告页关闭按钮,见计划文档执行记录。

### 15. 排除 `/`(或主目录)后扫描结果为空属安全方向行为,且可经设置页自行删除恢复(Task 15 质量审查增补)— 混合(自动 + 待人工)

- ✅ 自动核验:排除过滤机制 `defaultMode_userExclusionFiltersHit`(命中排除即不进结果——排除 `/` 覆盖一切规则根,空结果即其自然推论,方向安全);删除恢复的存储层 `testRemoveAndReload`(`Tests/AppCoreTests/ExclusionsStoreTests.swift`)。
- ⏳ 待人工:GUI 恢复路径。步骤:设置 → 手动添加 `/` → 回主页扫描 → 结果应为空且主页显示「已按保护与排除清单跳过 N 项」→ 设置页删掉 `/` → 重扫恢复正常结果。

### 16. VoiceOver 抽查:明细行 Toggle 与设置 trash 按钮读出有意义 label(本轮部分 A 修复后)— 混合(修复已落 + 待人工)

- ✅ 自动核验(修复落位):`Sources/Raccoon/DetailListView.swift:66-69`(明细 Toggle 加 `.accessibilityLabel(hit.appName ?? hit.path)`)与 `Sources/Raccoon/SettingsView.swift:40`(trash 按钮加 `.accessibilityLabel(loc("settings.remove"))`);`settings.remove` 键 en/zh 双语落位(L10n 58→59);`swift build` 零错误、75/75 绿(提交 883a4e2)。
- ⏳ 待人工:VoiceOver 实读。步骤:开启 VoiceOver(Cmd+F5)→ Tab/VO 方向键聚焦明细行勾选框 → 应读出条目应用名(或路径)而非空白;聚焦设置排除清单 trash 按钮 → 应读出「移除」/「Remove」。

## §11 验收核对(规格六条 Done 定义)

> 规格出处:`docs/superpowers/specs/2026-10-13-raccoon-phase1-design.md` §11。

| # | Done 定义 | 结论 | 证据与缺口 |
| - | --------- | ---- | ---------- |
| 1 | 四类规则扫描全流程可用,非开发目录亦能安全运行 | **部分** | 自动面:内置 27 条规则四类全覆盖、零拒绝零告警(`bundledRulesLoadClean`、`bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions`、`bundledRulesKeyRulesPresent`);非开发目录规则根缺失→空态(`defaultMode_missingRootYieldsEmpty`),75/75 绿。缺口:真机 GUI 全流程目测待人工(清单项 1/14)。 |
| 2 | 全部安全机制生效,恶意规则回归测试通过 | **满足** | 恶意规则回归:`testLoad_securityRegression_ruleAtProtectedPathRejected`、`testLoad_symlinkAliasToProtectedRejected`、`testLoad_symlinkEscapingHomeRejected`、`testI2_applicationsWildcardIncludeRejected`、`testSecurityRegression_rulePointingAtProtectedRootIsConflict`(RuleStoreTests)、`testClean_securityRegression_neverTrashesProtectedEvenIfInjected`(CleanExecutorTests,注入勾选后删除前仍拦截)、`testCleanSelected_skipsProtectedAtExecutorLevel`(ScanViewModelTests:92-107)、`testM1_rootPathConflictsWithEverything`、`testComponentPrefixMatch_notStringPrefix`、`testDefaultHardRoots_coverUserContentAndLibraryKeys`、`testC1_caseInsensitiveProtection`(ProtectionStoreTests)。四道门各有测试锚点;RuleStore 校验逻辑见 `Sources/ScanKit/RuleStore.swift:55-75`。 |
| 3 | 清理仅产生废纸篓入项,可恢复 | **部分** | 自动面:删除动作唯一实现 `FileManager.trashItem`(`Sources/CleanKit/TrashService.swift`,无 unlink 路径);`testFileManagerTrashService_trashesTempFile` 真实移入废纸篓;报告计数与勾选一致(`testCleanSelected_reportsWritesHistory_andDismiss`)。缺口:「放回恢复」为系统废纸篓固有行为,本项目侧的实证属 GUI 人工(清单项 5/14)。 |
| 4 | 中英文、浅色深色完整适配 | **部分** | 自动面:en/zh 两份 Localizable.strings 各 59 键 1:1(本轮新增 `settings.remove`);全部用户可见文案经 `loc()` 消费;`bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions` 保证规则描述双语;UI 纯系统控件+语义色,无硬编码颜色。缺口:语言切换与深浅色实际观感属人眼(清单项 8/9)。 |
| 5 | ScanKit/CleanKit 单测覆盖核心路径,CI(macOS runner)绿 | **部分** | 单测:75 用例全绿(本机 `Scripts/test.sh`:CleanKit 40 + ScanKit 26 + AppCore 9,Swift Testing @Test 共 75)。**CI 如实说明:本仓库尚无 CI 配置(无 `.github/` 目录),「CI 绿」待补**。补入口径:GitHub Actions `macos-latest` runner,步骤 `swift build && Scripts/test.sh`,以 75 全绿为门槛。 |
| 6 | 在本机完成一次真实扫描+清理演练,人工核对结果无误 | **待人工** | 天然人工项,对应清单项 14 的完整演练;本环境无 GUI 人工执行能力。前期已完成的无头替代:Task 16 .app 组装 + 8 秒活性探活、Task 15 直接启动探活(见计划文档执行记录),但不构成人工核对。 |

## 统计

按条目整体归属计(16 项):

- **✅ 整体自动核验:1 项**(项 4 勾选联动)。
- **混合(自动部分 + 待人工部分):9 项**(项 2、3、5、6、7、10、11、15、16)——每项均给出自动化证据与待人工步骤,自动部分未替人工背书。
- **⏳ 整体待人工:6 项**(项 1、8、9、12、13、14)。

§11 六条:满足 1(第 2 条)、部分 4(第 1/3/4/5 条)、待人工 1(第 6 条);工程侧唯一缺口是 CI 配置(待补,补入口径见上表第 5 条)。
