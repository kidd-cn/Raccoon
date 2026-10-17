# Raccoon 三期(AI 工具清理)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在独立「AI 清理」入口中扫描并清理 AI 工具的可再生内容(缓存/日志/可重下的运行时与模型缓存),全程复用一期引擎,零新删除路径、零提权。

**Architecture:** `RuleCategory` 新增 `.ai`,`CleanupRule`/`ScanHit` 新增可选 `tool` 字段(纯数据通道,引擎原样透传);16 条新规则全部走声明式 `rules.json`;`ScanViewModel` 增加 `categoryFilter`(主清理页 = 全集去 `.ai`,AI 页 = `[.ai]`,两页各自实例化互不干扰);新增 `AIToolGrouper` 按 `tool` 分组 + `AICleanupHomeView` 独立入口,确认弹窗/报告页/历史原样复用。

**Tech Stack:** Swift 6、SwiftUI、Swift Testing(`Scripts/test.sh` 唯一测试入口)、macOS 14+。

**Spec:** `docs/superpowers/specs/2026-10-17-raccoon-phase3-design.md`

## Global Constraints

- **零新删除代码**:任何任务不得新增 `removeItem`/`unlink` 实现调用;唯一删除动作仍是 `CleanExecutor` → `FileManager.trashItem`(`Sources/CleanKit/TrashService.swift`)。测试夹具清理临时目录的 `try? FileManager.default.removeItem` 不属删除路径,允许(沿用既有测试写法)。
- 测试唯一入口 `Scripts/test.sh`(勿裸跑 `swift test`,CLT 缺宏插件路径);单测过滤:`Scripts/test.sh --filter <SuiteName>`。
- `swift-tools-version` 保持 6.3 下限不动;本机 CLT 工具链无 SwiftUIMacros:`@State`/`@Binding` 必须手写展开(仿 `RootView` 现有 `_vm/_uvm/_selection` 模式),视图内可用 `@Bindable`。
- L10n:`Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings` 键集必须 1:1(CI diff 强制);`.strings` 的 zh 值用全角标点;`rules.json` 的 description 沿用该文件既有**半角**标点风格。
- `rules.json` `"version"` 保持 `1`:`tool` 为可选字段,`Codable` 可选解码向后兼容,不 bump(`RuleStore` 只认 version 1)。
- 安全分级由 `safety` 驱动,一期既有逻辑零改动:`safe` 默认勾选,`cautious` 默认不勾 + 橙色 + 单独确认(模型/运行时类规则一律 `safety=cautious`)。
- 每任务收尾时**全量** `Scripts/test.sh` 必须绿才能提交;用例数只增不减(当前 main 基线 183)。
- 不推送、不合并、不直接改 main;全部工作发生在执行期创建的 worktree(`feat/phase3`)。
- 主检出工作区可能有用户未提交的格式化改动:只在 worktree 内施工;Task 6 动 README 前先 `git status` 核对。

## Review Focus

spec 暗示但常规用例最易漏的五类输入,每行已钉到 owning task 的测试或 QA 清单:

1. **AI 工具正在运行时清理其缓存/日志**(文件被锁)→ 期望:该项进报告 `skipped`、保留在列表可重试,绝不丢条目也不虚报释放量。→ Task 3 e2e 用 `MockTrash.skippedFor` 钉住。
2. **未安装某 AI 工具**(规则根不存在)→ 期望:零命中、不报错,AI 页显示空态 + 再扫一次。→ 引擎缺根守卫由 ScanEngineTests 既有模式回归;空态人工核验见 phase3 QA 清单 A9。
3. **用户把 AI 路径加进排除清单** → 期望:对应项从 AI 页消失、`excludedCount` 如实上屏。→ 排除机制由 ScanEngineTests 既有用例回归;QA 清单 A10 人工核验。
4. **未来新增 ai 规则漏带 `tool`** → 期望:条目落「其他」组而非消失,且规则测试当场红灯强制补齐。→ Task 2 `aiRulesHaveNonEmptyTool` + Task 4 `groups_nilToolFallsIntoOtherGroupLast` 钉住。
5. **include 模式把用户数据目录名写进 include**(如 `"User"`,全树 glob 会伸入 `Cursor/User/**`)→ 期望:规则测试红灯;`ai.cursor` 用 `exclude: ["User", "AgentStores"]` 剪枝遍历,把 spec 的「永不列出」机制化。→ Task 2 `neverListedPathsAreNotRootsOrIncludes` 钉住。

---

## 执行前准备

- [ ] 从最新 `main` 建 worktree(遵循 superpowers:using-git-worktrees;`.worktrees/` 为项目既有目录):

```bash
cd /Users/adder.chia/programs/github/macCleaner
git check-ignore -q .worktrees || echo "需要先确认 .worktrees 已被忽略"
git worktree add .worktrees/phase3 -b feat/phase3 main
cd .worktrees/phase3
```

- [ ] 确认基线全绿:`Scripts/test.sh`(预期 183 用例全过)。
- [ ] **纪律提醒**:重读上方 Global Constraints 全部条目;特别是「删除只进废纸篓」与「不推送不合并」。

---

### Task 1: `tool` 数据通道——CleanupRule / ScanHit / 引擎透传

**Files:**
- Modify: `Sources/ScanKit/RuleModels.swift`(`CleanupRule` 末尾加字段)
- Modify: `Sources/ScanKit/ScanModels.swift`(`ScanHit` 加存储属性与 init 参数)
- Modify: `Sources/ScanKit/ScanEngine.swift`(6 处 ScanHit 构造点透传)
- Modify: `Tests/ScanKitTests/ScanFixtures.swift:29-34`(`rule` 助手加参)
- Modify: `Tests/ScanKitTests/ScanEngineTests.swift:172`(补 `tool: nil`)
- Test: `Tests/ScanKitTests/ScanEngineTests.swift`(新增用例)

**Interfaces:**
- Produces: `CleanupRule.tool: String?`(声明序在 `description` 之后);`ScanHit.tool: String?`(public init 末位参数,默认 `nil`);`ScanFixtures.rule(id:path:category:safety:include:exclude:tool:)`。后续所有任务经 `hit.tool` 读工具标识。

- [ ] **Step 1: 写会失败的测试**

`Tests/ScanKitTests/ScanEngineTests.swift` 套件内追加:

```swift
// 三期:rule.tool 必须随命中透传到 ScanHit,AI 页按它分组;缺省为 nil
@Test func engineCarriesRuleToolIntoHits() async throws {
    let root = (NSTemporaryDirectory() + "raccoon-tool-\(UUID().uuidString)").resolvingSymlinksInPath
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/with/sub", withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 64).write(to: URL(fileURLWithPath: root + "/with/sub/f"))
    try fm.createDirectory(atPath: root + "/without/sub", withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 32).write(to: URL(fileURLWithPath: root + "/without/sub/f"))
    defer { try? fm.removeItem(atPath: root) }
    let rules = [
        ScanFixtures.rule(id: "with-tool", path: root + "/with", tool: "cursor"),
        ScanFixtures.rule(id: "no-tool", path: root + "/without"),
    ]
    let result = try await ScanEngine(deps: .init(protection: ProtectionStore())).scan(rules: rules)
    let byRule = Dictionary(grouping: result.hits, by: \.ruleID)
    #expect(byRule["with-tool"]?.allSatisfy { $0.tool == "cursor" } == true)
    #expect(byRule["no-tool"]?.allSatisfy { $0.tool == nil } == true)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter ScanEngineTests/engineCarriesRuleToolIntoHits`
Expected: 编译失败(`ScanFixtures.rule` 无 `tool` 参数 / `CleanupRule` 无 `tool` 成员)。

- [ ] **Step 3: 实现字段与透传**

1. `Sources/ScanKit/RuleModels.swift` 的 `CleanupRule` 在 `description` 之后加:

```swift
    /// 归属工具标识(如 "claude-desktop"),AI 清理页按它分组;非 AI 规则留 nil。
    public let tool: String?
```

注意:memberwise init 因此多一个必填参数,两个既有调用点要同步补 `tool: nil`——`Tests/ScanKitTests/ScanFixtures.swift` 的 `rule` 助手(签名加 `tool: String? = nil` 并透传)与 `Tests/ScanKitTests/ScanEngineTests.swift:172`。

2. `Sources/ScanKit/ScanModels.swift` 的 `ScanHit`:存储属性加在 `snapshotDate` 之后 `public let tool: String?`;public init 末位加 `tool: String? = nil` 并赋值(默认值保证既有调用点不破)。

3. `Sources/ScanKit/ScanEngine.swift` 六处构造点透传:`snapshotHits`、`walkDefaultMode` 两处、`walkIncludeMode` 两处补 `tool: rule.tool`;`resolveAppNames` 的重建处补 `tool: hit.tool`。

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh --filter ScanEngineTests` → 新用例 PASS;再跑全量 `Scripts/test.sh` → 183+1 全绿。

- [ ] **Step 5: Commit**

```bash
git add Sources/ScanKit Tests/ScanKitTests
git commit -m "feat: 规则与命中透传 tool 字段(AI 页分组数据通道)"
```

---

### Task 2: `RuleCategory.ai` + 16 条 AI 规则 + 祖先 exclude + 负向不变量

**Files:**
- Modify: `Sources/ScanKit/RuleModels.swift:3-6`(`RuleCategory` 加 case)
- Modify: `Sources/Raccoon/CleanupHomeView.swift:118-125`(`CategoryCardView.icon` switch 补 `.ai`,编译器强制)
- Modify: `Sources/ScanKit/Resources/rules.json`(16 条新规则 + 两处祖先 exclude)
- Test: `Tests/ScanKitTests/BundledRulesTests.swift`(5 个新用例)

**Interfaces:**
- Consumes: Task 1 的 `CleanupRule.tool`。
- Produces: `RuleCategory.ai`;16 个规则 id(`ai.claude-desktop` … `ai.chatgpt-cache`);`rules.json` 的 `tool` 字段用法。

- [ ] **Step 1: 加 `case ai`**

`Sources/ScanKit/RuleModels.swift`:`case system, dev, apps, ai, cautious`(ai 在 cautious 之前;`allCases` 顺序即类别卡片顺序,ai 被过滤不出现在主页)。同步给 `Sources/Raccoon/CleanupHomeView.swift` 的 `CategoryCardView.icon` 补 `case .ai: "brain"`——switch 穷尽,不加则 app target 编译红。

- [ ] **Step 2: 写会失败的测试**

`Tests/ScanKitTests/BundledRulesTests.swift` 套件内追加(spec §5/§8):

```swift
// —— 三期:AI 规则不变量 ——

@Test func bundledRulesAIRulesPresent() throws {
    let lr = try RuleStore().loadBundled()
    let ids = Set(lr.rules.map(\.id))
    for expected in ["ai.claude-desktop", "ai.claude-desktop-app-cache", "ai.claude-desktop-updater",
                     "ai.claude-code-cache", "ai.claude-code-snapshots", "ai.claude-code-telemetry",
                     "ai.claude-code-plugin-cache", "ai.cursor", "ai.cursor-app-cache",
                     "ai.cursor-compile-cache", "ai.codex-cli-cache", "ai.codex-runtimes",
                     "ai.ollama-logs", "ai.ollama-models", "ai.huggingface-hub", "ai.chatgpt-cache"] {
        #expect(ids.contains(expected), "缺少 AI 规则 \(expected)")
    }
}

// AI 页按 tool 分组:ai 规则必须带非空 tool(既有「其他」组仅为防御兜底,不是豁免)
@Test func aiRulesHaveNonEmptyTool() throws {
    let lr = try RuleStore().loadBundled()
    for rule in lr.rules where rule.category == .ai {
        #expect(rule.tool?.isEmpty == false, "\(rule.id) 缺非空 tool,AI 页分组依赖它")
    }
}

// 用户数据整棵目录只允许以精确子路径为根;~/.claude、~/.ollama 本体永不作根(spec §5)
@Test func aiRuleRootsAreNotUserDataDirectories() throws {
    let lr = try RuleStore().loadBundled()
    let home = ProtectionStore.normalize("~")
    let forbidden = [home + "/.claude", home + "/.ollama"]
    for rule in lr.rules where rule.category == .ai {
        #expect(!forbidden.contains(ProtectionStore.normalize(rule.path)),
                "\(rule.id) 规则根不得为整棵用户数据目录(只允许精确子路径)")
    }
}

// 任何规则(不止 ai)不得以沙盒容器本体为根(spec §5 永不列出;子路径如微信缓存先例允许)
@Test func noRuleRootsAtSandboxContainerItself() throws {
    let lr = try RuleStore().loadBundled()
    let prefix = ProtectionStore.normalize("~/Library/Containers") + "/"
    for rule in lr.rules {
        let std = ProtectionStore.normalize(rule.path)
        guard std.hasPrefix(prefix) else { continue }
        #expect(std.dropFirst(prefix.count).contains("/"),
                "\(rule.id) 不得以容器本体 ~/Library/Containers/<id> 为根")
    }
}

// 「永不列出」清单:不得作规则根;include 全树 glob 也不得指向这些名字(spec §5,防未来误加)
@Test func neverListedPathsAreNotRootsOrIncludes() throws {
    let lr = try RuleStore().loadBundled()
    let home = ProtectionStore.normalize("~")
    let neverRoots: Set<String> = [
        home + "/.claude/projects", home + "/.claude/skills", home + "/.claude/file-history",
        home + "/.claude/todos", home + "/.claude/statsig", home + "/.claude/downloads",
        home + "/.claude/history.jsonl",
        home + "/Library/Application Support/Cursor/User",
        home + "/Library/Application Support/Cursor/AgentStores",
    ]
    let neverIncludeNames: Set<String> = ["user", "agentstores", "projects", "skills",
                                          "file-history", "todos", "statsig", "downloads", "history.jsonl"]
    for rule in lr.rules {
        #expect(!neverRoots.contains(ProtectionStore.normalize(rule.path)),
                "\(rule.id) 把「永不列出」路径当规则根")
        for inc in rule.include ?? [] {
            #expect(!neverIncludeNames.contains(inc.lowercased()),
                    "\(rule.id) 的 include「\(inc)」命中永不列出的名字")
        }
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `Scripts/test.sh --filter BundledRulesTests`
Expected: 新用例全红(无 ai 规则);既有 `bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions` 也红(`cats == Set(RuleCategory.allCases)` 因 `.ai` 无规则不成立)——这正是 spec §4 说的「不加 ai 规则测试即红」。

- [ ] **Step 4: 加 16 条规则与祖先 exclude**

`Sources/ScanKit/Resources/rules.json`:

1. `system.user-caches` 的 `exclude` 数组末尾追加:`"com.anthropic.claudefordesktop", "com.anthropic.claudefordesktop.ShipIt", "com.todesktop.230313mzl4w4u92", "cursor-compile-cache", "com.openai.codex", "com.openai.chat"`。
2. `dev.dot-cache`(现无 exclude 字段)在 `"path": "~/.cache",` 之后新增一行:`"exclude": ["codex-runtimes", "huggingface"],`。
   以上两条由既有 `subRuleExcludedFromAncestorRule` 强制:漏加即在 Step 5 红灯(防双重计数)。
3. 在 `apps.wechat-cache` 与 `cautious.ios-backups` 之间插入 16 条(`description` 沿用本文件半角标点风格):

```json
    {"id": "ai.claude-desktop", "category": "ai", "safety": "safe", "tool": "claude-desktop",
     "path": "~/Library/Application Support/Claude",
     "include": ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache"],
     "description": {"zh-Hans": "Claude 桌面版网页缓存(Electron),重建自动", "en": "Claude Desktop web caches (Electron); rebuilt automatically"}},
    {"id": "ai.claude-desktop-app-cache", "category": "ai", "safety": "safe", "tool": "claude-desktop",
     "path": "~/Library/Caches/com.anthropic.claudefordesktop",
     "description": {"zh-Hans": "Claude 桌面版系统缓存", "en": "Claude Desktop system cache"}},
    {"id": "ai.claude-desktop-updater", "category": "ai", "safety": "safe", "tool": "claude-desktop",
     "path": "~/Library/Caches/com.anthropic.claudefordesktop.ShipIt",
     "description": {"zh-Hans": "Claude 桌面版更新器暂存(Squirrel),可重建", "en": "Claude Desktop updater staging (Squirrel); rebuilt automatically"}},
    {"id": "ai.claude-code-cache", "category": "ai", "safety": "safe", "tool": "claude-code",
     "path": "~/.claude/cache",
     "description": {"zh-Hans": "Claude Code 杂项缓存", "en": "Claude Code misc cache"}},
    {"id": "ai.claude-code-snapshots", "category": "ai", "safety": "safe", "tool": "claude-code",
     "path": "~/.claude/shell-snapshots",
     "description": {"zh-Hans": "Claude Code shell 快照,自动再生", "en": "Claude Code shell snapshots; regenerated automatically"}},
    {"id": "ai.claude-code-telemetry", "category": "ai", "safety": "safe", "tool": "claude-code",
     "path": "~/.claude/telemetry",
     "description": {"zh-Hans": "Claude Code 遥测临时数据", "en": "Claude Code telemetry temp data"}},
    {"id": "ai.claude-code-plugin-cache", "category": "ai", "safety": "safe", "tool": "claude-code",
     "path": "~/.claude/plugins/cache",
     "description": {"zh-Hans": "Claude Code 插件市场缓存,可重新下载", "en": "Claude Code plugin marketplace cache; re-downloadable"}},
    {"id": "ai.cursor", "category": "ai", "safety": "safe", "tool": "cursor",
     "path": "~/Library/Application Support/Cursor",
     "include": ["CachedData", "Cache", "GPUCache", "Code Cache", "DawnGraphiteCache", "DawnWebGPUCache", "CachedProfilesData", "logs"],
     "exclude": ["User", "AgentStores"],
     "description": {"zh-Hans": "Cursor 编辑器缓存与日志(不含设置、扩展与工作区数据)", "en": "Cursor editor caches & logs (no settings, extensions or workspace data)"}},
    {"id": "ai.cursor-app-cache", "category": "ai", "safety": "safe", "tool": "cursor",
     "path": "~/Library/Caches/com.todesktop.230313mzl4w4u92",
     "description": {"zh-Hans": "Cursor 系统缓存(ToDesktop 封装)", "en": "Cursor system cache (ToDesktop wrapper)"}},
    {"id": "ai.cursor-compile-cache", "category": "ai", "safety": "safe", "tool": "cursor",
     "path": "~/Library/Caches/cursor-compile-cache",
     "description": {"zh-Hans": "Cursor 编译缓存", "en": "Cursor compile cache"}},
    {"id": "ai.codex-cli-cache", "category": "ai", "safety": "safe", "tool": "codex",
     "path": "~/Library/Caches/com.openai.codex",
     "description": {"zh-Hans": "Codex CLI 系统缓存", "en": "Codex CLI system cache"}},
    {"id": "ai.codex-runtimes", "category": "ai", "safety": "cautious", "tool": "codex",
     "path": "~/.cache/codex-runtimes",
     "description": {"zh-Hans": "Codex CLI 运行时,可重新下载但体积大(实测 3.6G),请确认后清理", "en": "Codex CLI runtimes; re-downloadable but large, review before cleaning"}},
    {"id": "ai.ollama-logs", "category": "ai", "safety": "safe", "tool": "ollama",
     "path": "~/.ollama/logs",
     "description": {"zh-Hans": "Ollama 日志", "en": "Ollama logs"}},
    {"id": "ai.ollama-models", "category": "ai", "safety": "cautious", "tool": "ollama",
     "path": "~/.ollama/models",
     "description": {"zh-Hans": "已拉取的 Ollama 模型,可重新下载但动辄数 GB", "en": "Pulled Ollama models; re-downloadable but often multi-GB"}},
    {"id": "ai.huggingface-hub", "category": "ai", "safety": "cautious", "tool": "huggingface",
     "path": "~/.cache/huggingface/hub",
     "description": {"zh-Hans": "Hugging Face 模型缓存,可重新下载但代价高", "en": "Hugging Face model cache; re-downloadable at real cost"}},
    {"id": "ai.chatgpt-cache", "category": "ai", "safety": "safe", "tool": "chatgpt",
     "path": "~/Library/Caches/com.openai.chat",
     "description": {"zh-Hans": "ChatGPT 桌面版系统缓存(标准路径,未安装则零命中)", "en": "ChatGPT desktop system cache (standard path; no hits if absent)"}},
```

注(对 spec §5 表的一处精化,实现以本计划为准):`ai.cursor` 增加 `"exclude": ["User", "AgentStores"]`——include 是全树 glob,`"logs"` 等通用名可能命中 `User/` 深层同名目录;exclude 在遍历期剪枝,把 spec 的「`Cursor/User/**` 永不列出」落实为机制。`version` 保持 `1`。

- [ ] **Step 5: 跑测试确认通过**

Run: `Scripts/test.sh`
Expected: 全绿(新增 5 用例 + 既有规则用例全部转绿,含 `subRuleExcludedFromAncestorRule` 与类别覆盖)。

- [ ] **Step 6: Commit**

```bash
git add Sources/ScanKit/Resources/rules.json Sources/ScanKit/RuleModels.swift Sources/Raccoon/CleanupHomeView.swift Tests/ScanKitTests/BundledRulesTests.swift
git commit -m "feat: AI 规则集——RuleCategory.ai、16 条 ai 规则、祖先 exclude 与负向不变量"
```

---

### Task 3: `ScanViewModel.categoryFilter`——两页互不相混

**Files:**
- Modify: `Sources/AppCore/ScanViewModel.swift`(init 加参;`runScan` 过滤)
- Modify: `Tests/AppCoreTests/ScanViewModelTests.swift`(`makeVM`/`hit` 助手加参 + 4 个新用例)

**Interfaces:**
- Consumes: `RuleCategory.ai`(Task 2)、`ScanHit.tool`(Task 1)。
- Produces: `ScanViewModel.init(service:exclusions:history:trash:categoryFilter:)`,其中 `public let categoryFilter: Set<RuleCategory>?`(nil = 不过滤)。Task 5 的 RootView 以此实例化两页。

- [ ] **Step 1: 写会失败的测试**

`Tests/AppCoreTests/ScanViewModelTests.swift`:

1. 助手扩展(默认值保证既有用例不动):

```swift
    func makeVM(service: ScanServicing, trash: TrashServicing,
                categoryFilter: Set<RuleCategory>? = nil) -> ScanViewModel {
        ScanViewModel(service: service,
                      exclusions: ExclusionsStore(defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!),
                      history: JSONHistoryStore(directory: dir),
                      trash: trash, categoryFilter: categoryFilter)
    }
```

`hit` 助手加 `tool: String? = nil` 参数并透传给 `ScanHit`。

2. 新用例:

```swift
    // —— 三期:categoryFilter(spec §4/D3)——

    @Test func categoryFilter_aiPageShowsOnlyAI() async {
        let svc = FakeScanService(result: .init(
            hits: [hit("/ai1", 100, category: .ai), hit("/sys", 400, category: .system)],
            summaries: [.init(category: .ai, totalBytes: 100, hitCount: 1),
                        .init(category: .system, totalBytes: 400, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0))
        let vm = makeVM(service: svc, trash: MockTrash(outcome: .trashed), categoryFilter: [.ai])
        vm.startScan()
        await vm.task?.value
        #expect(vm.hits.map(\.path) == ["/ai1"])
        #expect(vm.summaries.map(\.category) == [.ai])
    }

    @Test func categoryFilter_mainPageExcludesAI() async {
        // 主清理页过滤 = 全集去 .ai(D3):AI 条目与 AI 类别卡片在主页面绝口不提
        let svc = FakeScanService(result: .init(
            hits: [hit("/ai1", 100, category: .ai), hit("/sys", 400)],
            summaries: [.init(category: .ai, totalBytes: 100, hitCount: 1),
                        .init(category: .system, totalBytes: 400, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0))
        let main: Set<RuleCategory> = Set(RuleCategory.allCases).subtracting([.ai])
        let vm = makeVM(service: svc, trash: MockTrash(outcome: .trashed), categoryFilter: main)
        vm.startScan()
        await vm.task?.value
        #expect(vm.hits.map(\.path) == ["/sys"])
        #expect(vm.summaries.map(\.category) == [.system])
    }

    @Test func categoryFilter_nilShowsAll() async {
        // 回归:nil = 旧行为
        let svc = FakeScanService(result: .init(
            hits: [hit("/ai1", 100, category: .ai), hit("/sys", 400)],
            summaries: [.init(category: .ai, totalBytes: 100, hitCount: 1),
                        .init(category: .system, totalBytes: 400, hitCount: 1)],
            permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0))
        let vm = makeVM(service: svc, trash: MockTrash(outcome: .trashed))
        vm.startScan()
        await vm.task?.value
        #expect(Set(vm.hits.map(\.path)) == ["/ai1", "/sys"])
    }

    // 三期端到端(spec §8):AI 页全流程——过滤扫描 → safe 默认勾/cautious 与运行中不默认勾 →
    // 清理 → 被锁跳过项如实进报告并保留(Review Focus #1)
    @Test func aiPage_endToEnd_scanSelectCleanReport() async throws {
        let trash = MockTrash(outcome: .trashed, skippedFor: ["/ai/blocked"])
        let vm = makeVM(service: FakeScanService(result: .init(
            hits: [hit("/ai/cache", 100, category: .ai, tool: "cursor"),
                   hit("/ai/models", 200, safety: .cautious, category: .ai, tool: "ollama"),
                   hit("/ai/blocked", 50, running: true, category: .ai),
                   hit("/sys/other", 400)],
            summaries: [], permissionSkippedCount: 0, truncatedRuleIDs: [], excludedCount: 0)),
            trash: trash, categoryFilter: [.ai])
        vm.startScan()
        await vm.task?.value
        #expect(vm.hits.map(\.path).sorted() == ["/ai/blocked", "/ai/cache", "/ai/models"])
        // 默认只勾 safe 且未运行
        #expect(vm.selectedPaths == ["/ai/cache"])

        vm.toggle("/ai/models")
        vm.cleanSelected()
        await vm.cleanTask?.value

        let calls = await trash.calls
        #expect(calls.sorted() == ["/ai/blocked", "/ai/cache", "/ai/models"])   // /sys/other 绝不提交
        guard case .report(let report) = vm.phase else { Issue.record("应为 report"); return }
        #expect(report.freedBytes == 300)            // 仅成功入废纸篓的 100+200
        #expect(report.skipped.map(\.path) == ["/ai/blocked"])
        // 收敛:skipped 仍在列表、仍勾选可重试;已清项离场
        #expect(vm.hits.map(\.path) == ["/ai/blocked"])
        #expect(vm.selectedPaths.contains("/ai/blocked"))
        #expect(try vm.history.loadAll().count == 1)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter ScanViewModelTests`
Expected: 编译失败(`categoryFilter` 参数不存在)。

- [ ] **Step 3: 实现**

`Sources/AppCore/ScanViewModel.swift`:

1. init 签名追加带默认值参数并存为 `public let categoryFilter: Set<RuleCategory>?`(附注释:主清理页 = 全集去 `.ai`,AI 页 = `[.ai]`;nil = 不过滤,测试与回归用)。
2. `runScan()` 中替换 `hits = ...sorted...; summaries = result.summaries` 两行为:

```swift
            let filtered = categoryFilter.map { f in result.hits.filter { f.contains($0.category) } } ?? result.hits
            hits = filtered.sorted { $0.sizeBytes > $1.sizeBytes }
            summaries = CategorySummary.aggregate(hits)
```

(过滤后重算汇总而非截 `result.summaries`:与 `applyCleanOutcome` 的重算同源同口径;filter 为 nil 时与引擎输出等价。)

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh` → 全量绿。

- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/ScanViewModel.swift Tests/AppCoreTests/ScanViewModelTests.swift
git commit -m "feat: ScanViewModel 类别过滤,主清理页与 AI 页互不相混"
```

---

### Task 4: `AIToolGrouper`——按工具分组(纯逻辑,可测)

**Files:**
- Create: `Sources/AppCore/AIToolGroups.swift`
- Test: `Tests/AppCoreTests/AIToolGroupsTests.swift`

**Interfaces:**
- Consumes: `ScanHit.tool`(Task 1)。
- Produces: `AIToolGroup(tool: String?, hits: [ScanHit])`,`id: String { tool ?? "other" }`;`AIToolGrouper.canonicalOrder: [String]` 与 `AIToolGrouper.groups(in hits: [ScanHit]) -> [AIToolGroup]`。Task 5 的视图消费。

- [ ] **Step 1: 写会失败的测试**

`Tests/AppCoreTests/AIToolGroupsTests.swift`:

```swift
import Testing
import ScanKit
@testable import AppCore

@Suite
final class AIToolGroupsTests {
    private func h(_ path: String, _ size: Int64, tool: String?) -> ScanHit {
        ScanHit(ruleID: "r", category: .ai, safety: .safe, path: path, sizeBytes: size, tool: tool)
    }

    @Test func groups_inCanonicalOrder_sizeDescWithin() {
        let groups = AIToolGrouper.groups(in: [
            h("/c1", 10, tool: "cursor"), h("/c2", 50, tool: "cursor"),
            h("/cd", 30, tool: "claude-desktop"), h("/o", 5, tool: "ollama")])
        #expect(groups.map(\.tool) == ["claude-desktop", "cursor", "ollama"])
        #expect(groups[1].hits.map(\.path) == ["/c2", "/c1"])   // 组内按大小降序
    }

    // 防御:漏带 tool 的 ai 条目落「其他」组,殿后,绝不消失(Review Focus #4)
    @Test func groups_nilToolFallsIntoOtherGroupLast() {
        let groups = AIToolGrouper.groups(in: [h("/x", 1, tool: nil), h("/y", 2, tool: "cursor")])
        #expect(groups.map(\.tool) == ["cursor", nil])
        #expect(groups.map(\.id) == ["cursor", "other"])
    }

    // 未收录的新工具值:按字典序插在已知工具后、「其他」前,保证加规则先于 UI 也不丢条目
    @Test func groups_unknownToolSortedBeforeOther() {
        let groups = AIToolGrouper.groups(in: [
            h("/x", 1, tool: nil), h("/z", 2, tool: "zed"), h("/y", 3, tool: "windsurf")])
        #expect(groups.map(\.tool) == ["windsurf", "zed", nil])
    }

    @Test func groups_emptyInputNoGroups() {
        #expect(AIToolGrouper.groups(in: []).isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `Scripts/test.sh --filter AIToolGroupsTests`
Expected: 编译失败(`AIToolGrouper` 不存在)。

- [ ] **Step 3: 实现 `Sources/AppCore/AIToolGroups.swift`**

```swift
import Foundation
import ScanKit

/// AI 清理页的一个工具分组:组头展示名走 L10n 键 `ai.tool.<id>`(nil 组 = "other")。
public struct AIToolGroup: Identifiable, Equatable, Sendable {
    public let tool: String?          // nil = 「其他」组(防御:ai 规则漏带 tool)
    public let hits: [ScanHit]        // 组内已按 sizeBytes 降序
    public var id: String { tool ?? "other" }
    public init(tool: String?, hits: [ScanHit]) { self.tool = tool; self.hits = hits }
}

public enum AIToolGrouper {
    /// 组的展示顺序;规则新增未收录工具值时按字典序排其后、「其他」殿后。
    public static let canonicalOrder: [String] = [
        "claude-desktop", "claude-code", "cursor", "codex", "ollama", "huggingface", "chatgpt"]

    public static func groups(in hits: [ScanHit]) -> [AIToolGroup] {
        let byTool = Dictionary(grouping: hits, by: \.tool)
        var ordered: [String?] = canonicalOrder.filter { !(byTool[$0] ?? []).isEmpty }
        ordered += byTool.keys
            .filter { $0 != nil && !canonicalOrder.contains($0!) }
            .sorted { $0! < $1! }
        if !(byTool[nil] ?? []).isEmpty { ordered.append(nil) }
        return ordered.map { tool in
            AIToolGroup(tool: tool,
                        hits: (byTool[tool] ?? []).sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `Scripts/test.sh` → 全量绿。

- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/AIToolGroups.swift Tests/AppCoreTests/AIToolGroupsTests.swift
git commit -m "feat: AIToolGrouper 按工具分组(未知工具兜底,其他组殿后)"
```

---

### Task 5: 独立「AI 清理」入口——RootView 分流 + AICleanupHomeView + 双语文案

**Files:**
- Modify: `Sources/Raccoon/RootView.swift`
- Create: `Sources/Raccoon/AICleanupHomeView.swift`
- Modify: `Sources/Raccoon/Resources/en.lproj/Localizable.strings`(+11 键)
- Modify: `Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings`(+11 键)

**Interfaces:**
- Consumes: `ScanViewModel(categoryFilter:)`(Task 3)、`RuleCategory.allCases`(Task 2)、`AIToolGrouper/AIToolGroup`(Task 4);复用既有 `DetailRow`/`ConfirmCleanView`/`ReportView` 与通用键(`common.*`/`home.*`/`detail.selected`/`report.again`)。

**说明**:本仓无视图单测(各期一致);本任务的客观核验 = 全量构建测试绿 + L10n 键集 diff 为空;交互层核对项移交 Task 6 的 QA 清单。

- [ ] **Step 1: 加 L10n 键(en/zh 各 11 条,键集 1:1)**

`en.lproj/Localizable.strings` 追加:

```properties
"category.ai" = "AI Tools";
"ai.startHint" = "Scan AI tools' caches, logs and re-downloadable runtimes or model caches.\nSessions, skills and other personal data are never listed.";
"ai.empty" = "No regenerable AI content found";
"ai.tool.claude-desktop" = "Claude Desktop";
"ai.tool.claude-code" = "Claude Code";
"ai.tool.cursor" = "Cursor";
"ai.tool.codex" = "Codex";
"ai.tool.ollama" = "Ollama";
"ai.tool.huggingface" = "Hugging Face";
"ai.tool.chatgpt" = "ChatGPT";
"ai.tool.other" = "Other";
```

`zh-Hans.lproj/Localizable.strings` 追加(全角标点;`module.aiCleanup` 键一期已存在,勿重复加):

```properties
"category.ai" = "AI 工具";
"ai.startHint" = "扫描 AI 工具的缓存、日志与可重新下载的运行时、模型缓存。\n会话记录、用户技能等个人数据永不列出。";
"ai.empty" = "未发现 AI 工具的可再生内容";
"ai.tool.claude-desktop" = "Claude 桌面版";
"ai.tool.claude-code" = "Claude Code";
"ai.tool.cursor" = "Cursor";
"ai.tool.codex" = "Codex";
"ai.tool.ollama" = "Ollama";
"ai.tool.huggingface" = "Hugging Face";
"ai.tool.chatgpt" = "ChatGPT";
"ai.tool.other" = "其他";
```

- [ ] **Step 2: 新建 `Sources/Raccoon/AICleanupHomeView.swift`**

信息架构与 `CleanupHomeView` 同构(idle/scanning/completed/cleaning/report/failed);差异:completed 不出类别卡片,改为 `AIToolGrouper` 分组平铺 + 底部常驻清理栏;空态 = `ai.empty` + `report.again`。

```swift
import SwiftUI
import ScanKit
import AppCore

/// 三期「AI 清理」首页:专属 ScanViewModel(categoryFilter=[.ai]),按工具分组展示。
/// 确认弹窗、报告页、历史与主清理页同源复用;两页 ViewModel 互不共享状态(spec D3)。
struct AICleanupHomeView: View {
    @Bindable var vm: ScanViewModel

    var body: some View {
        NavigationStack {
            Group {
                switch vm.phase {
                case .idle: idleView
                case .scanning: scanningView
                case .completed: completedView
                case .cleaning:
                    VStack(spacing: 12) {
                        ProgressView(value: Double(vm.cleanProgress.done),
                                     total: Double(max(vm.cleanProgress.total, 1)))
                            .frame(maxWidth: 320)
                        Text(loc("common.clean")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .report(let report): ReportView(report: report, vm: vm)
                case .failed(let message): failedView(message)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(loc("module.aiCleanup"))
        }
        .sheet(isPresented: $vm.confirmPresented) {
            ConfirmCleanView(vm: vm)
        }
    }

    var idleView: some View {
        VStack(spacing: 18) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text(loc("ai.startHint"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(loc("common.scan")) { vm.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            if let last = vm.lastCleanup {
                Text(loc("home.lastCleanup", byteText(last.freedBytes)))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // 扫描中与失败视图与 CleanupHomeView 同构:复用 home.scanning/home.found/common.cancel/
    // home.cancelHint/home.failed/home.retry 键,图标区分入口
    var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(loc("home.scanning", vm.progress.rulesDone, vm.progress.rulesTotal))
                .foregroundStyle(.secondary)
            Text(loc("home.found", byteText(vm.progress.bytesFound)))
                .font(.title3).bold().monospacedDigit()
            Button(loc("common.cancel")) { vm.cancelScan() }
            Text(loc("home.cancelHint")).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    var completedView: some View {
        Group {
            if vm.hits.isEmpty {
                VStack(spacing: 14) {
                    Text(loc("ai.empty")).foregroundStyle(.secondary)
                    Button(loc("report.again")) { vm.startScan() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(AIToolGrouper.groups(in: vm.hits)) { group in
                                toolSection(group)
                            }
                        }
                    }
                    bottomBar
                }
            }
        }
    }

    func toolSection(_ group: AIToolGroup) -> some View {
        let items = vm.selectedItems.filter { $0.tool == group.tool }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(loc("ai.tool.\(group.id)")).font(.headline)
                Spacer()
                // 组头数字 = 本组已选口径(与 DetailListView 底栏「本类口径」同义)
                if !items.isEmpty {
                    Text(loc("detail.selected", items.count,
                             byteText(items.reduce(Int64(0)) { $0 + $1.sizeBytes })))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ForEach(group.hits) { hit in
                DetailRow(hit: hit,
                          selected: vm.selectedPaths.contains(hit.path)) { vm.toggle(hit.path) }
            }
        }
    }

    var bottomBar: some View {
        HStack {
            Text(loc("detail.selected", vm.selectedPaths.count, byteText(vm.selectedBytes)))
                .monospacedDigit()
            Spacer()
            Button(loc("common.clean")) { vm.confirmPresented = true }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedPaths.isEmpty || vm.phase == .cleaning)
        }
        .padding(.top, 8)
    }

    func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40)).foregroundStyle(.yellow)
            Text(loc("home.failed", message)).multilineTextAlignment(.center)
            Button(loc("home.retry")) { vm.startScan() }
        }
    }
}
```

- [ ] **Step 3: RootView 接线**

`Sources/Raccoon/RootView.swift`:

1. 顶部加 `import ScanKit`(`Set<RuleCategory>` 字面量需要)。
2. `Module.availableCases` → `[.cleanup, .uninstall, .aiCleanup]`(comingSoonCases 自动只剩 diskAnalysis/monitor)。
3. 仿 `_uvm` 手写展开加第三个 ViewModel:

```swift
    private var _aiVM: State<ScanViewModel>
    var aiVM: ScanViewModel {
        get { _aiVM.wrappedValue }
        nonmutating set { _aiVM.wrappedValue = newValue }
    }
```

init 内(复用同一 `history` 实例):

```swift
        // 主清理页过滤 = 全集去 .ai;AI 页 = [.ai](spec D3:两页互不见对方类别,互不共享状态)
        _vm = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                exclusions: exclusions,
                                                history: history,
                                                categoryFilter: Set(RuleCategory.allCases).subtracting([.ai])))
        _aiVM = State(wrappedValue: ScanViewModel(service: AppScanService(),
                                                  exclusions: exclusions,
                                                  history: history,
                                                  categoryFilter: [.ai]))
```

4. detail switch 显式分流(不用 default):

```swift
            switch selection {
            case .uninstall:
                UninstallHomeView(vm: uvm)
            case .aiCleanup:
                AICleanupHomeView(vm: aiVM)
                    .onAppear { aiVM.loadLastCleanup() }
            case .cleanup, .diskAnalysis, .monitor:
                // diskAnalysis/monitor 仍为侧边栏占位;显式列全:新增枚举 case 时由编译器强制更新。
                CleanupHomeView(vm: vm)
                    .onAppear { vm.loadLastCleanup() }
            }
```

- [ ] **Step 4: 全量测试 + L10n 键集核验**

Run: `Scripts/test.sh` → 全绿。
Run:

```bash
diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
     <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
```

Expected: 无输出(键集 1:1,与 CI 同口径)。

- [ ] **Step 5: Commit**

```bash
git add Sources/Raccoon
git commit -m "feat: 独立「AI 清理」入口——RootView 分流、按工具分组视图与双语文案"
```

---

### Task 6: 终验 + 文档同步(README / QA 清单 / 规格状态)

**Files:**
- Modify: `README.md`(当前功能、已知限制、Schema(v1)、路线图)
- Create: `docs/superpowers/qa/phase3-qa-checklist.md`(格式仿 `docs/superpowers/qa/phase2-qa-checklist.md`)
- Modify: `docs/superpowers/specs/2026-10-17-raccoon-phase3-design.md:4`(状态行)

**Interfaces:**
- Consumes: 前五个任务的全部成果;无代码改动。

- [ ] **Step 1: 安全终验 grep(证据入 QA 清单「自动核验」区)**

```bash
grep -rn "removeItem\|unlink" Sources/ --include="*.swift"
# 期望:唯一命中 Sources/CleanKit/TrashService.swift 的「绝不 unlink」注释,零实现调用
grep -rn "trashItem" Sources/ --include="*.swift"
# 期望:唯一实现 = FileManagerTrashService.trash(TrashService.swift)
grep -rni "authorization\|osascript\|launchctl\|SMJobBless\|withPrivileged" Sources/ --include="*.swift"
# 期望:零命中(无提权)
```

任何超出预期的命中 = 阻断,回查实现。

- [ ] **Step 2: 全量测试并如实记录**

Run: `Scripts/test.sh` → 记录实测用例总数(基线 183,只增不减;不得虚报)。

- [ ] **Step 3: 更新 README**

1. `## 当前功能(一期 + 二期)` 标题与内容补三期:独立「AI 清理」入口,Claude/Claude Code/Cursor/Codex/Ollama/HuggingFace/ChatGPT 的缓存、日志与可重下的运行时、模型缓存;只列可再生内容,会话/技能等个人数据永不列出;模型与运行时为谨慎项(默认不勾、单独确认)。
2. 安全设计一节末尾的已知限制句:把「系统级 `/Library` 残留与任何提权操作留待三期」改为「继续顺延」;追加 spec §10 的五条三期已知限制(工具覆盖面、用户数据有意不列、chatgpt 标准路径未实测、运行中跳过、cursor-agent-worker 未列)。
3. `### Schema(v1)` 增补 `tool` 字段:可选字符串,`category=ai` 规则必填(AI 页分组依据),由 `aiRulesHaveNonEmptyTool` 强制。
4. 路线图:三期行 → `✅ 已实现(待人工 QA)`。

- [ ] **Step 4: 写 `docs/superpowers/qa/phase3-qa-checklist.md`**

仿二期清单结构,分「✅自动核验」(Step 1 grep 证据 + Step 2 实测用例数 + L10n diff 空)与「⏳待人工」;人工项逐条带预期,不预标绿:A1 侧边栏入口;A2 主清理页无 AI 条目/卡片;A3 两页状态隔离(交替扫描互不串);A4 按工具分组、组内大小降序、组头已选合计;A5 safe 默认勾、cautious 默认不勾+橙色;A6 cautious 确认弹窗单独分区;A7 实清小目录,废纸篓可见且可「放回原处」;A8 报告与历史如实(含 skipped);A9 未装工具空态+再扫一次;A10 排除路径生效(设置里排除 `~/.claude` 后 AI 页对应项消失);A11 运行中 Cursor 清其日志 → skipped 如实;A12 双语文案与全角标点。

- [ ] **Step 5: 规格状态行**

`docs/superpowers/specs/2026-10-17-raccoon-phase3-design.md:4` → `状态:已实施(待人工 QA)`。

- [ ] **Step 6: Commit**

```bash
git status   # 确认只暂存本任务文件
git add README.md docs/superpowers/qa/phase3-qa-checklist.md docs/superpowers/specs/2026-10-17-raccoon-phase3-design.md
git commit -m "docs: 三期收尾——README、QA 清单、规格状态与终验记录"
```

---

## 完成定义(对照 spec §9)

六个任务全绿后向用户汇报:验收标准逐条对照(侧边栏可用/主页面无 AI 项、分组与分级确认、trash-only 与报告历史、grep 复核、测试与 L10n、文档如实),然后**停下等待用户决定**是否合并推送——计划内不含任何 push/merge。
