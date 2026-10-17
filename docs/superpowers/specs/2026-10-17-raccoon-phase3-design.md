# 三期设计:AI 工具清理(AI Cleanup)

日期:2026-10-17
状态:已与用户对齐范围与边界,待计划拆解
前置:一期(规则扫描清理)、二期(应用卸载 + 残留清理)已完成合并

## 1. 背景与目标

路线图三期:**AI 工具清理(Claude/Cursor/Ollama 等)**。AI 工具在本机普遍留下数 GB 级可再生内容(实测:Cursor agent 数据 3.0G、`~/.cache/codex-runtimes` 3.6G、`~/.claude/{skills,plugins}` 2.0G、Cursor 缓存/日志 0.5G),其中真正可安全清理的缓存/日志散落在 `~/Library`、`~/Library/Caches`、`~/.cache`、`~/.claude` 等处,用户难以逐一定位。

三期目标:在**独立「AI 清理」入口**中,扫描并清理 AI 工具的**可再生内容**(缓存、日志、可重新下载的运行时/模型/插件缓存),全程复用一期扫描与清理引擎,零新删除路径,零提权。

**用户已确认的三项决策**:
1. 范围 = AI 工具清理(不做系统级 `/Library` 与提权,该项继续顺延)。
2. 清理边界 = **只列可再生内容**;会话记录、用户技能、工作区历史等用户数据一律不列出。
3. UI = 侧边栏独立「AI 清理」模块入口,复用一期扫描/清理流,页面按工具分组。

## 2. 非目标(本期不做)

- 系统级 `/Library` 残留与任何提权(继续顺延,不动安全模型)。
- AI 工具的**用户数据**清理:会话/项目历史(`~/.claude/projects`、`Cursor/User/**`、`anysphere.cursor-agent-worker`)、用户技能(`~/.claude/skills`)、编辑历史(`~/.claude/file-history`)、设置与登录态——永不列出,即使体积更大。
- VS Code / Windsurf / Zed / LM Studio 等规则:后续按需加 JSON 条目即可(声明式,加规则 = 扩功能),不写新代码。
- 清理调度/自动化、AI 工具占用分析图表。

## 3. 关键决策

| # | 决策 | 结论 | 理由 |
| - | ---- | ---- | ---- |
| D1 | 清理边界 | **只列可再生内容**(缓存/日志/可重下的运行时、模型、插件缓存);用户数据永不列出 | 与一期「规则只指向可再生内容」原则完全一致,零新增安全面;大体积用户数据宁可不列,不可误删 |
| D2 | UI 归属 | **侧边栏独立「AI 清理」入口**(`.aiCleanup` 从占位转正),页面只显示 `category=ai` 的结果并按工具分组 | 六模块骨架预留的分流点;可发现性好;与主清理页互不混扰 |
| D3 | 引擎复用 | **原样复用 ScanEngine / CleanExecutor / 确认弹窗 / 报告页 / 历史**;`ScanViewModel` 增加「类别过滤」参数(主清理页传全集去 `ai`,AI 页传 `[.ai]`) | 「唯一删除实现」不变;两个模块各自持有 ViewModel(与卸载模块同模式),状态互不干扰 |
| D4 | 规则形态 | **继续声明式 `rules.json`**:`RuleCategory` 新增 `.ai` case;`CleanupRule` 新增可选 `tool` 字段(纯字符串,如 `claude-desktop`)供 UI 分组 | 位置/路径是全局 schema;后续扩工具 = 加 JSON 条目,不改代码 |
| D5 | 模型/运行时分级 | **可重下但代价高**的整块内容(Ollama 模型、HuggingFace hub、Codex 运行时)= `cautious`(默认不勾、橙色、单独确认);纯缓存/日志 = `safe` | 重下数 GB 对用户是实际代价,不能默认勾选;与一期 Xcode Archives/CoreSimulator 同口径 |
| D6 | 共享根下的精确路径 | 在 `~/Library/Caches`、`~/.cache` 等已有规则根之下,**一律用叶子精确路径**作新规则根,并把该路径首段加入祖先规则的 `exclude`(沿用 pip/Homebrew 先例) | 防双重计数;既有 `subRuleExcludedFromAncestorRule` 测试会强制此约束,漏加 exclude 直接红灯 |

## 4. 总体架构

```
RootView(detail 分流)
 ├─ .cleanup   → CleanupHomeView(vm: cleanupVM)      // 类别过滤: system/dev/apps/cautious
 ├─ .aiCleanup → AICleanupHomeView(vm: aiVM)         // 新增;类别过滤: [.ai]
 └─ .uninstall → UninstallHomeView(vm: uvm)           // 二期,不动
```

- `RuleCategory` 新增 `.ai`(`codable` 值 `"ai"`)。`bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions` 断言规则覆盖全部类别 → **不加 ai 规则测试即红**,接线由测试强制。
- `ScanViewModel` 增加 `categoryFilter: Set<RuleCategory>?`(nil = 不过滤),在扫描结果归类处生效:hits/summaries/勾选/清理只含过滤后类别。两个模块各自实例化 `ScanViewModel`,互不共享状态。
- `CleanupRule` 新增 `public let tool: String?`(JSON 键 `tool`,缺省 nil)。AI 页按 `tool` 分组展示;`tool` 为 nil 的 ai 规则归入「其他」组(防御,新规则必须带 tool,由测试强制)。
- 主清理页对 `.ai` 类别过滤后,**不会**出现 AI 条目与 AI 类别卡片;AI 页反之只出现 `.ai`。确认弹窗(cautious 单独分区)、报告页、`JSONHistoryStore` 历史全部原样复用,「上次清理释放 X」自动覆盖 AI 清理来源。

## 5. 规则表(声明式,新增 `category:"ai"`)

删除单元粒度沿用一期语义:无 `include` 的规则以根的**一级子项**为删除单元;`include` 模式在根下**全树 glob 匹配**,命中目录整体为删除单元。

| id | 根路径 | 模式 | 分级 | tool | 说明 |
| -- | ------ | ---- | ---- | ---- | ---- |
| `ai.claude-desktop` | `~/Library/Application Support/Claude` | include: `Cache` `Code Cache` `GPUCache` `DawnGraphiteCache` `DawnWebGPUCache` | safe | claude-desktop | Electron 网页缓存(Claude 桌面版),重建自动 |
| `ai.claude-desktop-app-cache` | `~/Library/Caches/com.anthropic.claudefordesktop` | 叶子 | safe | claude-desktop | 桌面版系统缓存 |
| `ai.claude-desktop-updater` | `~/Library/Caches/com.anthropic.claudefordesktop.ShipIt` | 叶子 | safe | claude-desktop | 更新器暂存(Squirrel),可重建 |
| `ai.claude-code-cache` | `~/.claude/cache` | 叶子 | safe | claude-code | CLI 杂项缓存 |
| `ai.claude-code-snapshots` | `~/.claude/shell-snapshots` | 叶子 | safe | claude-code | shell 快照,自动再生 |
| `ai.claude-code-telemetry` | `~/.claude/telemetry` | 叶子 | safe | claude-code | 遥测临时数据 |
| `ai.claude-code-plugin-cache` | `~/.claude/plugins/cache` | 叶子 | safe | claude-code | 插件市场缓存,可重下(实测 673M) |
| `ai.cursor` | `~/Library/Application Support/Cursor` | include: `CachedData` `Cache` `GPUCache` `Code Cache` `DawnGraphiteCache` `DawnWebGPUCache` `CachedProfilesData` `logs` | safe | cursor | 编辑器缓存与日志(实测 ~530M) |
| `ai.cursor-app-cache` | `~/Library/Caches/com.todesktop.230313mzl4w4u92` | 叶子 | safe | cursor | 系统缓存(ToDesktop 封装) |
| `ai.cursor-compile-cache` | `~/Library/Caches/cursor-compile-cache` | 叶子 | safe | cursor | 编译缓存 |
| `ai.codex-cli-cache` | `~/Library/Caches/com.openai.codex` | 叶子 | safe | codex | Codex CLI 系统缓存 |
| `ai.codex-runtimes` | `~/.cache/codex-runtimes` | 叶子 | **cautious** | codex | CLI 运行时,可重下但实测 3.6G,代价高 |
| `ai.ollama-logs` | `~/.ollama/logs` | 叶子 | safe | ollama | 日志(标准路径,缺失即零命中) |
| `ai.ollama-models` | `~/.ollama/models` | 叶子 | **cautious** | ollama | 已拉取模型,可重下但动辄数 GB |
| `ai.huggingface-hub` | `~/.cache/huggingface/hub` | 叶子 | **cautious** | huggingface | 模型 blob,可重下代价高(标准路径) |
| `ai.chatgpt-cache` | `~/Library/Caches/com.openai.chat` | 叶子 | safe | chatgpt | ChatGPT 桌面版标准缓存路径(本机未验证,缺失即零命中) |

**祖先规则 exclude 同步修改**(防双重计数,`subRuleExcludedFromAncestorRule` 强制):
- `system.user-caches.exclude` += `com.anthropic.claudefordesktop`、`com.anthropic.claudefordesktop.ShipIt`、`com.todesktop.230313mzl4w4u92`、`cursor-compile-cache`、`com.openai.codex`、`com.openai.chat`
- `dev.dot-cache.exclude` += `codex-runtimes`、`huggingface`

**永不列出的路径(测试钉住,防未来误加)**:`~/.claude/{projects, skills, file-history, history.jsonl, todos, statsig, downloads}`、`~/Library/Application Support/Cursor/User/**`(含 `globalStorage/anysphere.cursor-agent-worker`)、`Cursor/AgentStores`、任何沙盒容器整体(`~/Library/Containers/<id>` 不得作为规则根)。

## 6. UI 设计

- 侧边栏:`availableCases` 加入 `.aiCleanup`(图标沿用 `brain`,标签 `module.aiCleanup` = 「AI 清理 / AI Cleanup」);「即将推出」组剩 diskAnalysis/monitor。
- `AICleanupHomeView`:复用清理页的信息架构——按工具分组的分区(Claude / Claude Code / Cursor / Codex / Ollama / HuggingFace / ChatGPT / 其他),每组内条目按大小降序;组头显示该组已选合计;底部常驻「已选 N 项 · X」+「清理…」;cautious 项橙色标识、默认不勾;确认弹窗与报告页复用一期视图。
- 空态:扫描完成且零命中时显示「未发现 AI 工具的可再生内容」+「再扫一次」。
- L10n:新增键 en/zh 1:1(工具组名、空态、说明文案),zh 全角标点;主清理页若出现 `.ai` 卡片键(防御)也需备好双语。

## 7. 安全与四道门(全部原样继承)

1. **硬保护**:规则校验与扫描期 `isDenied` 复核不变;新规则不得与保护根冲突(`rulePathConflictsWithProtection` 既有校验强制)。
2. **用户排除**:排除路径在新模块同样生效(共用 `ExclusionsStore`)。
3. **安全分级**:`safe` 默认勾选、`cautious` 默认不勾 + 橙色 + 单独确认——一期既有逻辑,零改动。
4. **trash-only**:删除仍只经 `CleanExecutor` → `FileManager.trashItem`;本期**零新删除代码**。
- 规则根白名单:所有新根均在用户主目录内(`~/.claude`、`~/.ollama`、`~/.cache` 为合法根),`isAllowedRuleRoot` 既有校验强制。
- 运行中应用:其缓存项 trash 遇锁可能跳过,按既有 skipped 机制如实报告,不做特殊处理。

## 8. 测试策略(TDD 锚点)

- **规则 schema 新不变量**(BundledRulesTests):
  - 每条 `category=ai` 规则必须带非空 `tool`;
  - ai 规则根不得为 `~/.claude`、`~/.ollama`、任何 `~/Library/Containers/<id>` 本身;
  - 「永不列出」清单中的路径不得作为任何规则根或 include 命中(负向断言);
  - 既有测试自动接管:类别全覆盖、双语描述、根重叠、祖先 exclude 一致性(漏加 exclude 即红)。
- **ScanViewModel 过滤**:过滤 `[.ai]` 时 hits/summaries/勾选/清理不含其他类别;主页面过滤(去 ai)时不含 ai;nil 不过滤(回归)。
- **分组视图模型**:tool 分组、tool=nil 落入「其他」组。
- **端到端**:mock 引擎夹具走 AI 页全流程(扫描 → 勾选 → cautious 不默认勾 → 清理 → 报告收敛),复用一期既有夹具模式。
- 全量经 `Scripts/test.sh`;新测试数只增不减。

## 9. 验收标准(Done)

1. 侧边栏「AI 清理」可用;主清理页不出现 AI 条目;两页互不串状态。
2. AI 页按工具分组展示,cautious(模型/运行时)默认不勾、单独确认;safe 缓存默认勾选。
3. 清理只进废纸篓,报告与历史如实;未勾选与 skipped 项保留。
4. 全程无提权、无 `rm`/unlink;`CleanExecutor` 仍是唯一删除路径(终审 grep 复核)。
5. `Scripts/test.sh` 全绿;L10n 键集 en/zh 1:1;CI 推送后实测绿。
6. README(当前功能 + 路线图三期状态 + 已知限制)与三期 QA 清单如实更新,人工项不标绿。

## 10. 已知限制(须写入 README 与 QA 清单)

1. 仅覆盖 §5 表列工具;其他 AI 工具(VS Code Copilot、Windsurf、Zed、LM Studio 等)后续加规则即扩,本期不含。
2. 大体积用户数据(会话、技能、agent 工作数据)**有意不列出**;想回收 `~/.claude/skills`、`Cursor/User` 等空间需用户自行处理。
3. `ai.chatgpt-cache` 为标准路径,未在本机验证,缺失即零命中(无害)。
4. 运行中工具的缓存项可能因文件锁被跳过,按 skipped 如实报告。
5. `anysphere.cursor-agent-worker`(3.0G)无法确证可再生,本期不列;后续若确证可再评估。
