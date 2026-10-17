# Raccoon 二期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」「⏳ 待人工」或「混合(自动半段 + 人工半段)」,**绝不将待人工项标成已验,也不把代码落位当成测试证据**。
>
> - **✅ 自动核验**:证据为真实存在的测试名与文件位置,或明确标注的代码锚点;不包含任何 GUI 目测结论。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤与预期。
> - **混合**:自动半段与人工半段分列,自动半段不替人工半段背书。
>
> **实测基线(2026-10-17,分支 `feat/phase2`,HEAD `8cb571a`)**:
> - `Scripts/test.sh` 全量 **175/175 绿**:UninstallKit **63** / ScanKit **40** / CleanKit **27** / AppCore **45**。
> - 中英 L10n 各 **93** 键,键集 diff 为空(93:93 1:1)。
> - 本文档所有「✅」均以该次实测为准;测试名已逐条 grep 确认存在,无编造。

## 一、✅ 自动核验项(10 项)

### A1. 应用发现:Apple 应用排除、一层子目录、同 ID 去重、符号链接越界跳过 — ✅

- `findsTopLevelAndOneSubdirectoryLevel`(`Tests/UninstallKitTests/AppDiscoveryTests.swift:21`):应用根顶层与一层子目录被发现,更深层不进入结果。
- `skipsAppleAppsAndMissingPlist`(同文件:36):`com.apple.*` 被排除;缺 `Info.plist` 的包计入不可读而非应用。
- `dedupesSameBundleIDByRootOrder`(同文件:49):同一 Bundle ID 跨根只保留根顺序中的首个。
- `skipsSymlinkEscapingRoot`(同文件:60):解析后逃出应用根的符号链接被跳过。
- 补充:`followsSymlinkedRoot`(:100)、`skipsAppleBundleIDsCaseInsensitivelyAndCountsEmptyIDUnreadable`(:120)、`doesNotDescendIntoNestedAppBundles`(:140)、`ignoresPlainFileApp`(:111)。

### A2. 关联数据分级与默认勾选:可再生勾、userData 不勾、未确认归属不勾 — ✅

- `openDetailDefaultsToRegenerableExactOnly`(`Tests/AppCoreTests/UninstallViewModelTests.swift:53`):默认选择集仅含「精确归属(bundleID)+ 可再生」;userData 与名称匹配的低置信项均不勾。
- `findsExactLocationsWithGrading`(`Tests/UninstallKitTests/LeftoverLocatorTests.swift:20`):各位置的归属精确度与安全分级正确。
- `nameMatchIsLowConfidence`(同文件:55)、`groupContainerAcceptsTeamPrefixedName`(:49)、`dedupesSamePathByLocationIDOrder`(:63)。
- 硬保护与用户排除不进定位结果:`excludesUserExclusionsAndHardProtectedPaths`(同文件:72)。

### A3. 卸载提交 = 本体 + 已勾选;本体被跳过时应用留列表且报告可见 — ✅

- `uninstallSubmitsBundleAndSelectedLeftovers`(`Tests/AppCoreTests/UninstallViewModelTests.swift:71`):`MockTrash` 收到的调用恰为 `[应用本体, 已勾选可再生数据]`,默认未勾的 userData 不提交;报告字节数 = 本体 + 已勾选;应用移出列表;`detailAppID == nil`;`lastUninstallBundleRemoved == true`;history 落一条。
- `skippedBundleKeepsAppAndCleanedLeftoversConverge`(同文件:98):本体被 trash 跳过 → 应用仍在列表;报告 `skipped` 含本体路径;`detailAppID == nil`;`lastUninstallBundleRemoved == false`;已提交的关联数据仍正常收敛。
- `uninstallClosesDetailImmediately`(:131):清理 Task 尚未完成时详情页已退栈(防旧详情盖住进度/报告)。
- 剩余项收敛:`appRemovedKeepsUnselectedUserDataAsRemaining`(:189)、`appRemovedKeepsSkippedLeftover`(:209)。

### A4. 孤儿扫描默认勾选 = 高置信 + 可再生;跳过项收敛留在结果里;未勾选项保留 — ✅

- `orphanScanDefaultsToHighConfidenceRegenerable`(`Tests/AppCoreTests/UninstallViewModelTests.swift:308`):仅「精确归属 + 可再生」进入默认选择集;低置信即使可再生也不勾;结果按大小降序;`failedLocationIDs` 原样透出。
- `cleanOrphansConvergesOnlyCleanedSubset`(同文件:335):提交两条、其中一条被跳过 → 跳过的仍留在结果与选择集,报告可见,`remainingCount == 1`。
- `unselectedOrphanRemainsAfterClean`(:525):未勾选项清理后仍在结果中,`remainingBytes` 正确。
- 扫描透传已安装集合:`orphanScanPassesInstalledSetsFromDiscovery`(:388);孤儿判定本身见 `Tests/UninstallKitTests/OrphanScannerTests.swift` 的 `highConfidenceOrphanWhenBundleIDNotInstalled`(:24)、`installedAppsAreNotOrphans`(:37)、`appleBundleIDsAreNeverOrphans`(:49)、`lowConfidenceForNonReverseDNSNames`(:65)、大小写折叠 `installedBundleIDMatchingIsCaseInsensitive`(:138) 等。

### A5. 作用域白名单:越界路径不进提交(卸载流与孤儿流各一条)— ✅

- 卸载流 VM 级:`scopeWhitelistDropsRoguePaths`(`Tests/AppCoreTests/UninstallViewModelTests.swift:149`)——手动塞入 `~/Library/Preferences/...` 后被剔除,提交仅为本体 + 合法项。
- 卸载流安全锚点:`scopeWhitelistDropsRogueLocatorItems`(同文件:167)——上游定位器返回越界项且默认勾选会选中它们时,提交前仍被 scope 剔除(不依赖上游过滤的副作用)。
- 孤儿流:`orphanCleanDropsRogueLocatorItems`(同文件:369)。
- 基础不变量:`scopeOnlyAllowsDirectChildrenOfKnownFolders`(`Tests/UninstallKitTests/LeftoverLocatorTests.swift:137`);路径穿越 `rejectsBundleIDPathTraversalAcrossLocations`(:82)、`rejectsAppNamePathTraversalAcrossLocations`(:88);祖先符号链接越界 `skipsLocationWhoseResolvedDirEscapesLibrary`(:112,孤儿侧同文件 `Tests/UninstallKitTests/OrphanScannerTests.swift:105`);`~/Library` 自身为链接仍可定位 `libraryItselfBeingSymlinkStillLocates`(:123)。

### A6. `~/Library/Preferences`、`~/Library/Cookies` 硬保护事实 — ✅

- `preferencesAndCookiesAreHardProtected`(`Tests/UninstallKitTests/LeftoverLocationsTests.swift:64`):`ProtectionStore.isDenied` 对 Preferences/Cookies 下路径均为真,Caches 不受影响。
- `excludedFoldersNeverEnterTableAndAreDenied`(同文件:52):位置表的排除目录与硬保护一致,Preferences/Cookies 不进入二期位置表。
- `tableHasExpectedIDsAndGrading`(同文件:8):位置表 ID、归属与分级符合规格。

### A7. history 保留最近 200 条 — ✅

- `keepsOnlyLatest200Reports`(`Tests/CleanKitTests/HistoryStoreTests.swift:32`):追加 205 条后 `loadAll().count == 200`,最早 5 条被裁剪,首尾内容正确。
- 辅证:`append_and_loadAll_roundtrip`、`append_preservesCorruptFileAside_andRecovers`(同文件)。

### A8. 一期清理进度回投 — ✅(二期进度见「已知测试缺口」)

- `cleanSelected_reportsProgress`(`Tests/AppCoreTests/ScanViewModelTests.swift:289`):清理开始时 `total == 2`、完成后 `done == 2`,`CleanProgress` 经回调回投 VM。
- 二期卸载/孤儿清理进度已在代码落位(`UninstallViewModel.swift:190` 初始化、`:198` 逐项回投),但**无专测断言中间态**;不将代码落位冒充自动核验,详见文末缺口。

### A9. 状态机守卫、取消复位与 stale 结果过滤 — ✅

- 取消发现可复位重试:`cancelledDiscoveryResetsTaskAndAllowsRetry`(`Tests/AppCoreTests/UninstallViewModelTests.swift:226`)。
- 重入/并发守卫:`uninstallIsGuardedWhileCleaning`(:279)、`cleanOrphansIsGuardedWhileCleaning`(:509)、`scanOrphansIsNoOpBeforeDiscoveryCompletes`(:408)、`scanOrphansIsNoOpWhileScanning`(:450)、`startDiscoveryIsIdempotentWithoutForce`(:254)、`cancelOrphanScanReturnsToIdle`(:358)。
- stale 过滤:`staleProgressAfterCancelIsIgnored`(:427)、`staleTaskCleanupDoesNotClearNewerScanHandle`(:473);一期对称守卫 `cleanSelected_reentrancyGuarded`(`Tests/AppCoreTests/ScanViewModelTests.swift:110`)。
- 生产装配不触真实 `/Applications`:`factoryWiresLocatorForTempHome`、`factoryWiresOrphanScanForTempHome`、`runningCheckerMatchesSystemQuery`(`Tests/AppCoreTests/UninstallServicesTests.swift:24,9,39`)。

### A10. 发现/扫描进度与失败位置透出 — ✅

- `recordsFailedLocationWhenEnumerationFails`(`Tests/UninstallKitTests/OrphanScannerTests.swift:188`):位置目录枚举失败被记录为 `failedLocationIDs`(值为位置 ID,UI 再映射为目录名),进度仍走完。
- `missingLocationsAreNotFailuresAndProgressCompletes`(同文件:93):位置缺失不算失败,进度完成数为位置总数。
- `reportsProgressWhileEnumerating`(`Tests/UninstallKitTests/AppDiscoveryTests.swift:81`)、`throwsOnCancellation`(:229)。

## 二、⏳ 待人工项(8 项)

### M1. 卸载一个真实测试应用:本体与勾选数据进废纸篓、可放回;userData 默认未勾 — ⏳ 待人工

- **造数步骤**:
  1. 准备一个自建测试 `.app`(Bundle ID 如 `com.example.raccoon-test`),放入 `~/Applications`;先运行一次,确保 LaunchServices 有记录。
  2. 手工创建两个关联数据目录/文件:
     - `mkdir -p ~/Library/Caches/com.example.raccoon-test && printf 'cache' > ~/Library/Caches/com.example.raccoon-test/test-cache.bin`
     - `mkdir -p "$HOME/Library/Application Support/com.example.raccoon-test" && printf 'userdata' > "$HOME/Library/Application Support/com.example.raccoon-test/test-userdata.bin"`
  3. 打开「卸载」→ 进入该应用详情,确认 **Caches 与 Application Support 两组条目都出现**。
- 操作:观察默认勾选 → 点「卸载…」→ 确认弹窗核对总项数与字节 → 点卸载。
- 预期:应用本体固定参与提交;**Caches 项默认勾选,Application Support 项默认不勾**;废纸篓中出现本体与 Caches 项;逐个「放回」后能恢复原路径;未勾的 userData 仍在磁盘,并在报告「剩余项」/列表口径中体现。
- 自动半段见 A2/A3,不能替代本项。

### M2. 卸载后列表即时移除;本体/残留被跳过时留在列表并显示原因 — ⏳ 待人工

- 步骤:
  1. 完成一次成功卸载(按 M1 造数)→ 观察返回列表后的应用集合。
  2. **可复现跳过法**:在 `~/Applications` 下的测试应用副本上操作,对某个已勾选的残留目录(或测试应用副本本身)执行 `chflags uchg <path>`(或 `chmod 000 <path>`)→ 执行卸载。
  3. 验证后恢复:`chflags nouchg <path>` / `chmod 755 <path>`。
- 预期:成功时该应用立即从列表消失;触发跳过时应用仍在列表;报告页「跳过」区显示路径与原因;残留被跳过时仍留在剩余项中。
- 更稳妥:优先在 `~/Applications` 的测试副本上制造跳过,避免影响真实应用。
- 自动半段见 A3/A4。

### M3. 残留扫描在真机发现真实无主残留,分组与失败位置展示正确 — ⏳ 待人工

- **造数步骤**:
  1. 创建无主残留:`mkdir -p ~/Library/Caches/com.example.nonexistent-raccoon-test && printf 'orphan' > ~/Library/Caches/com.example.nonexistent-raccoon-test/test-orphan.bin`。
  2. 打开「卸载」→「孤儿残留」→ 扫描;该目录应归入「已确认归属(高置信)」组。
  3. **失败位置**:临时执行 `chmod 000 ~/Library/Caches` 制造枚举失败 → 重新扫描 → 确认底部失败位置以目录名(如 `Caches`)展示 → 先记录原权限(`stat -f %A ~/Library/Caches`,实测默认 `700`)并用同值恢复(通常 `chmod 700 ~/Library/Caches`)。
  4. 空态:删除第 1 步造数目录后复扫:若无其他真实孤儿残留应显示空态;否则至少确认该造数目录已从结果消失。
- 预期:真实无主残留出现;「已确认归属(高置信)」与「未确认归属」分组正确;未确认项默认不勾选;失败位置以目录名展示;空库时显示空态。
- 自动半段见 A4/A10。

### M4. 应用运行中标识与确认弹窗警告 — ⏳ 待人工

- 步骤:保持某个测试应用(或任意可运行应用)运行 → 进入卸载列表与详情 → 点卸载。
- 预期:列表行与详情头部出现黄色「应用运行中」标识;确认弹窗出现黄色警告;不因运行中而绕过确认或默认勾选。
- 自动半段:运行检查查询有测试(`runningCheckerMatchesSystemQuery`),但黄色标识与警告为视觉项。

### M5. 中英切换、浅/深色下新页面无破版;空态/搜索/长路径截断 — ⏳ 待人工

- 步骤:分别在中文/英文、浅色/深色下走「卸载列表 → 应用详情 → 孤儿残留 → 确认弹窗 → 报告页」;测试空搜索、无匹配搜索、超长路径行。
- 语言切换命令(同一期):`defaults write com.raccooncleaner.Raccoon AppleLanguages -array en` → 重启应用应显示英文;`defaults delete com.raccooncleaner.Raccoon AppleLanguages` → 重启恢复中文。
- 预期:文案完整不截断、无重叠/溢出;长路径以中间截断显示;空态与搜索无结果提示可读;分组标题与标签对比度足够;**应用详情与孤儿页均不出现 `~/Library/Preferences`、`~/Library/Cookies` 条目**。
- 自动半段:L10n 键集 93:93(见混合项 H1),不代表视觉无破版。

### M6. `LeftoverRow` 点 Toggle 与点行空白处各只切换一次 — ⏳ 待人工

- 步骤:在应用详情与孤儿结果中,分别「精确点击 Toggle」与「点击该行空白/文字区域」多次。
- 预期:两种点击各只切换一次;不得出现点一次跳两次(双触发)。
- 代码锚点:`AppDetailView.swift:109,129-130` 的 `Toggle` + 行级 `onTapGesture`;正确性依赖 SwiftUI 控件优先权,必须真机验证。

### M7. 在应用详情页切到另一模块再切回,导航状态是否恢复 — ⏳ 待人工

- 步骤:进入某应用详情 → 点侧边栏「清理」→ 再点回「卸载」。
- 预期:导航状态有确定行为(回到列表或恢复详情均可接受,但需一致);若点击同一应用行无响应,按缺陷记录(可能残留 `detailAppID` 或导航栈异常)。

### M8. 模块切换后已扫描的孤儿结果不被清空 — ⏳ 待人工

- 步骤:扫描孤儿并得到结果 → 切到「清理」模块 → 再切回「卸载」并回到孤儿页。
- 预期:结果、选择集与失败位置仍在,不要求重扫。
- 代码锚点:孤儿状态由 `UninstallViewModel` 持有,模块切换不应重置;需真机确认视图重建不触发重扫。

## 三、混合项(5 项,自动半段与人工半段分列)

### H1. 中英双语与浅/深色适配 — 混合

- ✅ 自动半段:zh-Hans 与 en 各 93 键,键集 diff 为空;全部二期新增文案经 `loc()` 消费;规则描述双语由既有测试保证。
- ⏳ 人工半段:切换系统语言与外观,逐页检查新页面文案、换行与对比度;见 M5。

### H2. 二期新页面布局与信息层级 — 混合

- ✅ 自动半段:归属/分级数据与默认勾选由 A2/A4 测试钉住(UI 分组按这些字段过滤);报告页图标 `accessibilityHidden`、`reasonText` 对未知原因回退 `reason.other` 为代码锚点(`CleanReportView.swift:14-24`)。
- ⏳ 人工半段:目测列表分组、标签颜色(橙/黄)、底部「已选 N 项 · X」是否含本体、报告页按钮主次关系;不得仅凭自动半段判为满足。

### H3. 生产装配与真机发现范围 — 混合

- ✅ 自动半段:`factoryWires*` 与 `runningCheckerMatchesSystemQuery` 证明装配与查询接线,且测试使用临时 home、不扫真实 `/Applications`。
- ⏳ 人工半段:确认真实机器上发现的应用集合合理、Apple 应用不出现、不可读计数符合实际;属 M1 的前置观察。

### H4. 确认弹窗快捷键:⏎ 触发取消、Esc 触发取消、破坏性按钮只能点按 — 混合

- ✅ 自动半段(仅代码锚点):`UninstallConfirmView.swift:45` 取消按钮 `.defaultAction`、`:52` `.onExitCommand`;一期 `ConfirmCleanView.swift:37,42` 同步修复。
- ⏳ 人工半段:在卸载与孤儿确认弹窗中分别按 Return、Esc,并尝试键盘聚焦「卸载/清理」按钮回车。预期两键均只关闭弹窗、不执行删除;破坏性动作只能鼠标点按。**Return 的事件探针仅是实施期一次性证据,不在仓库、不可复现,不作为验收依据;Return 与 Esc 都必须真机复核。**

### H5. 报告页「返回列表」与「扫描残留…」路径 — 混合

- ✅ 自动半段:路由与守卫有测试 `returnFromReportGoesBackToList`、`returnFromReportIsGuardedOutsideReport`(`Tests/AppCoreTests/UninstallViewModelTests.swift:118,247`);「扫描残留…」出现条件为代码锚点(`UninstallHomeView.swift` 的 `scanOrphansFromReportAction`:应用流 + 本体已删 + 仍有剩余)。
- ⏳ 人工半段:部分卸载(保留未勾 userData)使 `remainingCount > 0` 且本体已删 → 报告页点「扫描残留…」;另一次清理点「返回列表」。预期:「扫描残留…」仅在该条件下出现,点击后回列表并切到孤儿页自动扫描;「返回列表」回应用列表,已清理项消失、未清理项保留。

## 已知测试缺口(诚实记录)

1. **二期清理进度中间态无专测**:`UninstallViewModel.swift:190,198` 已回投 `cleanProgress`,但无测试像一期 `cleanSelected_reportsProgress` 那样断言卸载/孤儿清理的逐项中间态。计划文档已列为可选强化(3 项 + 门控 trash,断言中途 `done == 1`)。
2. **确认弹窗快捷键无仓库内自动化测试**:Return 的事件探针是实施期一次性证据,不在仓库、不可复现,不作为验收依据;Return 与 Esc 都必须由 H4 真机复核,破坏性按钮应只能点按。
3. **`LeftoverRow` 双触发**:依赖 SwiftUI 控件优先权,无单测可覆盖,必须 M6 真机验证。
4. **历史文件临时目录清理**:`HistoryStoreTests` 未显式清理临时目录,属测试卫生问题,不影响功能结论。

## 已知限制

引用 spec §8.4 与 §14 主要边界(§14.1/§14.3/§14.4):

1. **`~/Library/Preferences`、`~/Library/Cookies`**:一期门 1 整棵保护,二期不列出这两处的关联数据;放开需改门 1(窄口豁免 + 回归测试),列为三期候选,二期不动安全模型。
2. **系统级 `/Library` 残留与任何提权**:二期不做,不引入管理员授权;列为三期候选。
3. **非标准位置不扫描**:仅扫描声明式位置表(§6)内的位置,表外一律不扫,不做全盘启发式。
4. **非应用卸载路径**:Homebrew / CLI 工具等包管理不在二期范围。

## §15 验收映射(spec §15.1–§15.8)

> 状态口径同本文档:「✅」仅表示自动化可核验面有证据,不等于真机验收通过;「⏳」为纯人工;「混合」为自动半段 + 人工半段。

| Done 条目 | 状态 | 对应清单项 | 证据/说明 |
| --------- | ---- | ---------- | --------- |
| 15.1 `swift run` 列出 `/Applications` 与 `~/Applications` 应用(排除 Apple/非应用),详情展示分级数据,`Preferences`/`Cookies` 不出现 | 混合 | A1 / A6 + M5 / M7 | 自动:发现过滤与去重(A1)、Preferences/Cookies 硬保护事实(A6);人工:M5 目视详情分组与两处不出现,M7 验证列表/详情导航。 |
| 15.2 真实卸载:本体与勾选数据进废纸篓且可放回,报告数字一致,userData 分区默认不勾 | ⏳ 待人工 | M1 | 见 M1 造数与步骤。A2/A3 只证明默认勾选与提交口径,不替代废纸篓放回与数字目视。 |
| 15.3 真机孤儿扫描发现真实无主残留,高置信/未确认分组正确,默认仅勾「高置信 + 可再生」 | 混合 | A4 / A5 + M3 | 自动:默认勾选、排序、跳过收敛与作用域(A4/A5);人工:M3 造数、分组与失败位置展示。 |
| 15.4 全程无提权、无 `rm`/unlink;`CleanExecutor` 仍是唯一删除路径 | ✅ | A3 / A5 / A9 | `grep -rn "removeItem\|unlink" Sources` 仅命中 `Sources/CleanKit/TrashService.swift:18` 的注释「绝不 unlink」,无任何实现调用;`removeItem` 零命中。文件删除唯一实现为 `Sources/CleanKit/TrashService.swift:21` 的 `FileManager.trashItem`;本地快照清理沿用一期 `tmutil deletelocalsnapshots` 例外(README 门 4 已载明),不属于文件删除实现。无提权代码模式(AuthorizationExecute/SMJobBless/sudo/NSAppleScript 等均无命中)。测试:`testClean_securityRegression_neverTrashesProtectedEvenIfInjected`(`Tests/CleanKitTests/CleanExecutorTests.swift:63`)、`testClean_aggregatesReport_andSkipsProtected`(:44)、`testFileManagerTrashService_trashesTempFile`(`Tests/CleanKitTests/TrashServiceTests.swift:21`)。 |
| 15.5 四道门在二期路径有自动化锚点(硬保护、排除清单、分级、trash-only),恶意/越界用例回归 | ✅ | A1–A7 / A9 | 门 1:A6 + A5;门 2:A1/A2;门 3:A2/A4;门 4:见 15.4;恶意/越界:A5/A9。 |
| 15.6 中英双语、浅色/深色适配 | 混合 | H1 / H2 + M5 | 自动:zh/en 各 93 键、键集 diff 为空;人工:H1/H2/M5 目视切换语言与外观。 |
| 15.7 `Scripts/test.sh` 全绿、CI 绿、L10n 键集 1:1 | 混合 | H1 + 统计 | 本地 **175/175 全绿**、L10n **93:93** 已实测(H1 自动半段);**CI 未在 `feat/phase2` 运行(该分支无 upstream、尚未推送),待推送后验证,不得标绿**。 |
| 15.8 README 与 QA 清单如实标注人工项与已知限制(§8.4、§14) | ✅ | 本文档 + README | README 新增「已知限制」段;本清单分列 ✅/⏳/混合,并在「已知测试缺口」记录未覆盖面。 |

## 统计

按条目整体归属计(共 **23** 项):

- **✅ 整体自动核验:10 项**(A1–A10)。其中 A8 仅覆盖一期进度;二期进度明确列为缺口,未标 ✅。
- **⏳ 整体待人工:8 项**(M1–M8),每项均给出操作步骤与预期。
- **混合:5 项**(H1–H5),自动半段与人工半段分列,自动半段不替人工背书。

**结论**:工程侧自动可核验面全部为绿(175/175、L10n 93:93);二期功能与交互的人工验收尚未执行,本文档不宣称任何未真机验证项为「满足」。
