# Raccoon 三期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」或「⏳ 待人工」,**绝不将待人工项标成已验,也不把代码落位当成测试证据**。
>
> - **✅ 自动核验**:证据为真实运行的命令输出、测试名与文件位置,或明确标注的代码锚点;不包含任何 GUI 目测结论。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤与预期,一律未预标绿。
>
> **实测基线(2026-10-18,分支 `feat/phase3`,HEAD `ec49f79`)**:
> - `Scripts/test.sh` 全量 **199/199 绿**:UninstallKit **66** / ScanKit **48** / CleanKit **27** / AppCore **58**(二期基线 183 → 三期 199,只增不减,净增 16)。
> - 中英 L10n 各 **105** 键,键集 diff 为空(105:105 1:1)。
> - 终验安全 grep 三条均符合期望,无任何越期望命中(原文见下)。
> - 本文档所有「✅」均以该次实测为准;测试名已逐条 grep 确认存在,无编造。

## 一、✅ 自动核验项(7 项)

### 1. 终验安全 grep:零 unlink 实现、唯一 trashItem 实现、零提权 — ✅

三条终验命令与原始输出(2026-10-18 实测,`feat/phase3` @ `ec49f79`,仅扫 `Sources/`,不含 `Tests/`):

```text
$ grep -rn "removeItem\|unlink" Sources/ --include="*.swift"
Sources/CleanKit/TrashService.swift:18:    /// 唯一删除动作:移入废纸篓。绝不 unlink。
# 命中 1 行,且为「绝不 unlink」注释,零实现调用 → 符合期望

$ grep -rn "trashItem" Sources/ --include="*.swift"
Sources/CleanKit/TrashService.swift:21:            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
Sources/AppCore/ScanViewModel.swift:34:    // (否则硬编码真实服务会对不存在的 /a 真调 trashItem → .vanished → trashedCount 断言必红)
# 命中 2 行:唯一实现为 TrashService.swift:21(FileManagerTrashService.trash 内的
# FileManager.trashItem);另一行(ScanViewModel.swift:34)为解释依赖注入的注释,非实现调用
# → 符合期望「唯一实现」

$ grep -rni "authorization\|osascript\|launchctl\|SMJobBless\|withPrivileged" Sources/ --include="*.swift"
(零命中,grep exit 1)
# → 无任何提权代码模式 → 符合期望
```

结论:三期零新增删除路径,`CleanExecutor → FileManager.trashItem` 仍是唯一删除实现;与 spec §7.4「trash-only、本期零新删除代码」及 §9.4「全程无提权、无 `rm`/unlink(终审 grep 复核)」一致。

### 2. 全量测试 199/199 绿(二期基线 183,只增不减)— ✅

`Scripts/test.sh` 实测(exit 0,swift-testing,本地 CLT 工具链):

| 模块 | 二期基线 | 三期实测 | 增量 |
| ---- | -------- | -------- | ---- |
| UninstallKit | 66 | 66 | 0 |
| ScanKit | 40 | 48 | +8 |
| CleanKit | 27 | 27 | 0 |
| AppCore | 50 | 58 | +8 |
| **合计** | **183** | **199** | **+16** |

四个 target 的 `Test run with … passed` 逐套核对,无 skip、无 fail。

### 3. L10n 键集:105:105,diff 为空 — ✅

```bash
diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
     <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
# 输出为空,exit 0;两侧各 105 键(二期 94 → 三期 105,ai.tool.* 等 keysym 新增对齐)
```

### 4. 两页隔离与 VM 级口径 — ✅

- `categoryFilter_aiPageShowsOnlyAI` / `categoryFilter_mainPageExcludesAI` / `categoryFilter_nilShowsAll`(`Tests/AppCoreTests/ScanViewModelTests.swift:307,320,335`):`[.ai]` 只含 AI、主页面(全集去 ai)绝不含 AI、nil 不过滤回归。
- `aiPage_endToEnd_scanSelectCleanReport`(同文件 `:350`):AI 页全流程 mock 走通——扫描、勾选、cautious 不默认勾、清理、报告收敛、history 落条。
- `startScan_resetsCategoryInFocus`、`selectedScope_perCategoryAndGlobal`(同文件):重扫复位类别焦点;选择集按类/全局口径钉住。

### 5. 按工具分组(纯函数)与 tool 透传 — ✅

- `Tests/AppCoreTests/AIToolGroupsTests.swift` 四条:`groups_inCanonicalOrder_sizeDescWithin`(canonical 顺序、组内大小降序)、`groups_nilToolFallsIntoOtherGroupLast`(「其他」组殿后)、`groups_unknownToolSortedBeforeOther`(未知工具字典序)、`groups_emptyInputNoGroups`。
- `engineCarriesRuleToolIntoHits`(`Tests/ScanKitTests/ScanEngineTests.swift:227`):引擎把 `rule.tool` 带入 `ScanHit.tool`,分组数据源成立。

### 6. AI 规则门禁(正负向不变量)— ✅

- `bundledRulesAIRulesPresent`(`Tests/ScanKitTests/BundledRulesTests.swift:64`):16 条 ai 规则逐一点名存在。
- `aiRulesHaveNonEmptyTool`(`:77`):`category=ai` 必带非空 `tool`。
- `noRuleToolUsesReservedOtherId`(`:85`):`other` 为「其他」组保留 id,规则不得占用。
- `aiRuleToolsAreKnownValues`(`:93`):`tool` 须在白名单(claude-desktop/claude-code/cursor/codex/ollama/huggingface/chatgpt)。
- `aiRuleRootsAreNotUserDataDirectories`(`:104`)、`noRuleRootsAtSandboxContainerItself`(`:115`):`~/.claude`、`~/.ollama`、任何容器目录本体永不作规则根——「永不列出」清单的负向断言。
- 既有门禁(双语 description、类别全覆盖、根重叠告警)自动接管,三期未破坏。

### 7. 四道门在三期路径的既有锚点 — ✅

- 门 3(分级):safe 默认勾/cautious 默认不勾由一期夹具与 `aiPage_endToEnd_scanSelectCleanReport` 钉住;运行中项默认不勾含 AI 类夹具(`ScanViewModelTests.swift:355`,`hit("/ai/blocked", 50, running: true, category: .ai)`)。
- 门 4(trash-only):见自动核验项 1;`testCleanSelected_skipsProtectedAtExecutorLevel`、`testClean_securityRegression_neverTrashesProtectedEvenIfInjected` 继续绿。
- 门 2(用户排除):引擎层过滤有专测 `defaultMode_userExclusionFiltersHit`(`Tests/ScanKitTests/ScanEngineTests.swift:43`),与入口无关;存储层 `ExclusionsStoreTests` 继续绿。
- 门 1(硬保护):`ProtectionStoreTests` 与规则根白名单校验不变,三期新根全部经既有校验加载。

## 二、⏳ 待人工项(12 项,一律未预标绿)

### A1. 侧边栏「AI 清理」入口可用 — ⏳ 待人工

- 步骤:启动应用,观察侧边栏模块列表(应出现第三个可用入口,brain 图标),点击进入。
- 预期:进入「AI 清理」页;标题、空态提示与「开始扫描」按钮正常渲染、可点。
- 代码锚点:`RootView.swift:7`(`case cleanup, uninstall, aiCleanup`)、`:13`(图标)、`:18`(`availableCases`);`AICleanupHomeView.swift:31`(`navigationTitle`)。
- 自动半段:无(视图装配未自动化),存在性为代码锚点,可点性与渲染必须真机验证。

### A2. 主清理页无 AI 条目/AI 类别卡片 — ⏳ 待人工

- 步骤:在装有 AI 工具(如 `~/.claude`、Cursor)的真机上,主「清理」页扫描;检查类别卡片与明细列表。
- 预期:类别卡片只有系统垃圾 / 开发工具缓存 / 应用缓存 / 谨慎清理四类;明细中不出现任何 AI 类条目。
- 自动半段:`categoryFilter_mainPageExcludesAI`(VM 级过滤);页面装配与视觉需真机确认。

### A3. 两页状态隔离(交替扫描互不串)— ⏳ 待人工

- 步骤:先在 AI 页扫描出结果并勾选若干 → 切主清理页 → 交替扫描、勾选、清理各一次。
- 预期:两页各自的结果、选择集、清理进度、报告互不影响;一侧清理不丢失另一侧已勾未清项。
- 自动半段:两页各持专属 `ScanViewModel`(categoryFilter 分别为 `[.ai]` 与去 ai 全集),`startScan_resetsCategoryInFocus`、`selectedScope_perCategoryAndGlobal` 钉住 VM 口径;视图重建是否触发意外重置需真机确认。

### A4. 按工具分组、组内大小降序、组头已选合计 — ⏳ 待人工

- 步骤:AI 页扫描出多工具结果;检查分组顺序与组内排序;在各组勾选若干并看组头数字。
- 预期:组顺序为 claude-desktop → claude-code → cursor → codex → ollama → huggingface → chatgpt(未知工具字典序排后、「其他」殿后,真机通常不可见);组内条目大小降序;组头「已选 N 项 · X」只合计本组已选。
- 自动半段:`groups_inCanonicalOrder_sizeDescWithin` 等(AIToolGroupsTests);组头合计为代码锚点(`AICleanupHomeView.swift:96-106`,本组已选口径)。

### A5. safe 默认勾、cautious 默认不勾 + 橙色 — ⏳ 待人工

- 步骤:扫描后逐组检查默认勾选与颜色:重点看 `~/.cache/codex-runtimes`、`~/.ollama/models`、`~/.cache/huggingface/hub` 三条 cautious 项与各缓存 safe 项。
- 预期:16 条规则中 13 条 safe(缓存、日志类)命中的条目默认勾选;3 条 cautious(可重下的模型缓存/运行时)默认不勾并带橙色标识。
- 自动半段:默认勾选口径由 `aiPage_endToEnd_scanSelectCleanReport` 钉住;橙色为视觉项,必须目测。

### A6. cautious 确认弹窗单独分区 — ⏳ 待人工

- 步骤:勾选(或补勾)cautious 项后点「清理」,观察确认弹窗结构。
- 预期:cautious 项在弹窗中单独分区展示、不与 safe 混排;确认后才开始清理(复用一期 `ConfirmCleanView` 行为)。
- 自动半段:弹窗复用为代码锚点(`AICleanupHomeView.swift:33-35` 的 `sheet`);一期分区逻辑有既有测试,三期未新增视图专测。

### A7. 实清小目录,废纸篓可见且可「放回原处」 — ⏳ 待人工

- 造数步骤:挑一个本机未安装对应工具的 safe 规则根造数,例如 `mkdir -p ~/Library/Caches/com.openai.chat && printf 'qa' > ~/Library/Caches/com.openai.chat/qa-test.bin`(ChatGPT 桌面版未装时该目录仅含造数文件)。
- 步骤:AI 页扫描 → 定位该条目 → 清理 → 打开访达废纸篓。
- 预期:`qa-test.bin` 出现在废纸篓;右键「放回原处」可恢复原路径;报告页释放量与实际一致;history 落一条且主页回显「上次清理释放 X」。
- 自动半段:`testFileManagerTrashService_trashesTempFile`、`testCleanSelected_reportsWritesHistory_andDismiss`(机制层);真机废纸篓与放回必须人工。

### A8. 报告与历史如实(含 skipped)— ⏳ 待人工

- 步骤:做一次含跳过的清理(造法见 A11),然后检查报告页与主页历史回显。
- 预期:释放量、成功/跳过计数与实际一致;skipped 区列路径与原因;未清理项保留在结果列表中,无需重扫即可重试。
- 自动半段:`cleanSelected_keepsSkippedItemsInListAndSelection`、`cleanSelected_partialSelectionKeepsRemainingAndReturnsToList`(VM 级收敛);真实文件锁场景需人工。

### A9. 未装工具 → 空态 + 再扫一次 — ⏳ 待人工

- 步骤:在未安装任何 AI 工具的环境扫描 AI 页(或用 A10 排除全部已知工具后重扫)。
- 预期:完成态显示空态文案与「再扫一次」按钮;首扫(此前从未出结果)同样呈现空态而非空白页。
- 代码锚点:`AICleanupHomeView.swift:74-79`(`vm.hits.isEmpty` → `ai.empty` + `report.again` 按钮);空态为视图行为,无自动化,必须真机。

### A10. 排除路径生效(设置里排除 `~/.claude` 后 AI 页对应项消失)— ⏳ 待人工

- 步骤:设置页添加排除 `~/.claude` → 回 AI 页重新扫描。
- 预期:claude-code 组整体消失(其 4 条规则根均在 `~/.claude` 下);其余工具条目不受影响;主清理页同样不出现;移除排除后重扫恢复。
- 自动半段:`defaultMode_userExclusionFiltersHit`(引擎层过滤与入口无关)、`ExclusionsStoreTests`(存储);设置页到 AI 页的端到端链路需人工。

### A11. 运行中 Cursor 清其日志 → skipped 如实 — ⏳ 待人工

- 步骤:启动 Cursor 并正常使用片刻(制造日志与热缓存)→ AI 页扫描 → 勾选 Cursor 组条目(其日志由 `ai.cursor` 的 `logs` include 覆盖,`User`/`AgentStores` 已 exclude)→ 清理。
- 预期:被文件锁占用的条目进 skipped,报告如实列出;未锁定条目正常进废纸篓;运行中标识与默认不勾行为正常;跳过项留在结果中可重试。
- 自动半段:运行中项默认不勾有 AI 类夹具(`ScanViewModelTests.swift:355`)、skipped 收敛有 VM 级测试;真实文件锁与运行中标记为视觉/系统行为,必须人工。

### A12. 双语文案与全角标点 — ⏳ 待人工

- 步骤:`defaults write com.raccooncleaner.Raccoon AppleLanguages -array en` → 重启应用检查英文;`defaults delete com.raccooncleaner.Raccoon AppleLanguages` → 重启恢复中文;浅色/深色各过一遍 AI 页(空态、扫描中、结果分组、确认弹窗、报告)。
- 预期:双语完整、无裸键(组头不出现 `ai.tool.<id>` 原文);中文用全角标点、英文半角;无截断、重叠或溢出。
- 自动半段:键集 105:105、diff 空;`aiRuleToolsAreKnownValues` 保证新工具必须先补 `ai.tool.*` 双语键;排版与标点目测必须人工。

## 已知限制

引用 spec §10 全部五条(README「安全设计」节已同步):

1. 仅覆盖 §5 表列工具;其他 AI 工具(VS Code Copilot、Windsurf、Zed、LM Studio 等)后续加规则即扩,本期不含。
2. 大体积用户数据(会话、技能、agent 工作数据)**有意不列出**;想回收 `~/.claude/skills`、`Cursor/User` 等空间需用户自行处理。
3. `ai.chatgpt-cache` 为标准路径,未在本机验证,缺失即零命中(无害)。
4. 运行中工具的缓存项可能因文件锁被跳过,按 skipped 如实报告。
5. `anysphere.cursor-agent-worker`(3.0G)无法确证可再生,本期不列;后续若确证可再评估。

沿承一、二期的限制不变:`~/Library/Preferences` 与 `~/Library/Cookies` 硬保护不列出;系统级 `/Library` 残留与任何提权继续顺延。

## §9 验收映射(spec §9.1–§9.6)

> 状态口径同本文档:「✅」仅表示自动化可核验面有证据,不等于真机验收通过;「⏳」为纯人工;「混合」为自动半段 + 人工半段。

| Done 条目 | 状态 | 对应清单项 | 证据/说明 |
| --------- | ---- | ---------- | --------- |
| 9.1 侧边栏「AI 清理」可用;主清理页无 AI 条目;两页互不串状态 | 混合 | 自动 4 + A1/A2/A3 | 自动:`categoryFilter_*` 三条 + `aiPage_endToEnd`;人工:入口可用性、主页面目测、交替操作。 |
| 9.2 AI 页按工具分组;cautious 默认不勾、单独确认;safe 默认勾 | 混合 | 自动 5 + A4/A5/A6 | 自动:`AIToolGroupsTests` 四条 + 端到端默认勾口径;人工:组序目测、橙色、弹窗分区。 |
| 9.3 清理只进废纸篓,报告与历史如实;未勾选与 skipped 保留 | 混合 | 自动 1/7 + A7/A8 | 自动:trash 唯一实现 grep + CleanKit 收敛测试;人工:废纸篓放回、报告数字目测。 |
| 9.4 全程无提权、无 `rm`/unlink;`CleanExecutor` 仍是唯一删除路径(终审 grep 复核) | ✅ | 自动核验项 1 | 三条 grep 原文见上:unlink 零实现、`trashItem` 唯一实现(TrashService.swift:21)、提权模式零命中。 |
| 9.5 `Scripts/test.sh` 全绿;L10n 键集 en/zh 1:1;CI 推送后实测绿 | 混合 | 自动 2/3 | 本地 199/199、105:105 已实测;**CI 属合并推送后的动作,本任务不推送、未跑**,合并后须在 `main` 复核(二期先例:CI run 实测绿后回填)。 |
| 9.6 README 与 QA 清单如实更新,人工项不标绿 | ✅ | 本文档 + README | README 补三期功能、已知限制、Schema `tool` 字段、路线图状态;本清单 12 个人工项全部未预标绿。 |

## 统计

按条目整体归属计(共 **19** 项):

- **✅ 自动核验:7 项**(终验 grep、全量测试、L10n、两页隔离、工具分组、规则门禁、四道门锚点)。
- **⏳ 待人工:12 项**(A1–A12),每项均给出操作步骤与预期,无一预标绿。

**结论**:工程侧自动可核验面全部为绿(199/199、L10n 105:105、安全 grep 三条符合期望);三期功能与交互的人工验收尚未执行,本文档不宣称任何未真机验证项为「满足」。
