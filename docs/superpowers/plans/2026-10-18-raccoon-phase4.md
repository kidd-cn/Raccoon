# 四期:磁盘分析(Disk Analysis)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 侧边栏「磁盘分析」占位转正:扫描用户主目录(或任选文件夹),聚合目录体量,treemap + 列表双视图、点击下钻;显式勾选的项经既有 CleanExecutor 移废纸篓,报告/历史复用。

**Architecture:** 新 SPM target `DiskKit` 承载纯逻辑(DiskScanner 遍历聚合 + SquarifiedTreemap 布局);`AppCore` 新 `DiskAnalysisViewModel` 状态机与删除编排;`Raccoon` 新 `DiskAnalysisHomeView`。删除走 `CleanExecutor`(唯一删除实现 `TrashService.swift:21` 不动),`CleanReport` 加可选 `source` 复用报告与历史。

**Tech Stack:** Swift 6(tools-version 6.3 不升)+ SwiftUI(macOS 14);零第三方依赖;`@Observable` 可用,SwiftUI 属性宏(@State/@Binding)手写展开(本机 CLT 工具链缺 libSwiftUIMacros)。

**Spec:** `docs/superpowers/specs/2026-10-18-raccoon-phase4-design.md`(D1–D8 决策、四道门映射、验收标准以此为准)

## Global Constraints

- **零新删除代码**:`Sources/` 下不得新增 `removeItem`/`unlink` 实现调用;唯一删除动作仍是 `TrashService.swift:21` 的 `FileManager.trashItem`(经 `CleanExecutor`)。测试夹具清理自建 temp 目录可用 `try? FileManager.default.removeItem`(既有例外)。
- 执行期 worktree:`.worktrees/phase4`,分支 `feat/phase4`(自 main 创建);**不推送、不合并、不直接改 main**;每任务至少一个 commit。
- 测试一律经 `Scripts/test.sh`(禁裸 `swift test`);单套件过滤:`Scripts/test.sh --filter <Suite>`。
- L10n:`Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings` 键集 1:1(CI diff 强制);zh 值全角标点。
- `rules.json` 本期零改动(`version` 保持 1)。
- 测试数只增不减;执行首任务先跑全量记录基线(main 当前全量,预计 ≥199)。
- 体量口径:文件 = `URLResourceValues.fileAllocSize`(≈ st_blocks×512,与 `du` 同口径);目录 = 子树文件块占用之和,**目录自身 inode 块不计**(与 du 的差异为每目录 4KB 级,README 已知限制声明)。
- treemap 聚合常量:`maxCount = 120`,`minFraction = 0.003`(相对当前层合计);合并后仅剩 1 项则不合并直接列出。
- 勾选门禁(spec D7):`canSelect(node) = node.path != root.path && !node.containsProtected`;勾选目录时自动移除其后代的勾选;已有更上层祖先被勾选时,后代 toggle 为 no-op。**一律默认不勾**。
- UI 宏限制:`RootView` 等处新增 `@State` 一律手写展开(照抄 `_aiVM` 模式)。

## Review Focus

1. **扫描中权限墙**(TCC 拒绝目录):体量记已读部分、`isDeniedTruncated` 计数如实,不静默、不崩——Task 1 chmod 夹具钉住。
2. **勾选与清理之间目录被外部删除**:走 `vanished` 口径,不计 freedBytes、不崩——Task 4 mock 钉住。
3. **超大目录取消响应**:`Task.isCancelled` 周期检查,取消即抛 `CancellationError` 回 idle——Task 1 钉住;真机百万文件流畅度归 QA。
4. **相对路径/不存在路径作为扫描根**:抛错进 `.failed`,绝不以 CWD 相对语义解析——Task 1 钉住。
5. **旧 history.json 兼容**:缺 `source` 键解码为 nil 不崩——Task 4 钉住。

---

### Task 1: DiskKit target——DiskNode 与 DiskScanner(遍历/聚合/剪枝/保护标志/进度/取消)

**Files:**
- Modify: `Package.swift`(加 target `DiskKit` deps `["CleanKit"]`;加 testTarget `DiskKitTests` deps `["DiskKit", "CleanKit"]`;`AppCore` 与 `Raccoon` 的 dependencies 各加 `"DiskKit"`)
- Create: `Sources/DiskKit/DiskModels.swift`
- Create: `Sources/DiskKit/DiskScanner.swift`
- Test: `Tests/DiskKitTests/DiskScannerTests.swift`

**Interfaces:**
- Consumes: `CleanKit.ProtectionStore`(`init(hardRoots:userExclusions:)`、`isDenied(_:) -> Bool`、`static normalize(_:) -> String`)。
- Produces(后续任务依赖,签名逐字):
```swift
public struct DiskNode: Sendable, Equatable {
    public let path: String          // 绝对路径
    public let name: String          // 最后一段;根为路径最后一段
    public let sizeBytes: Int64      // 子树文件块占用合计;文件 = 自身 fileAllocSize
    public let isDirectory: Bool
    public var children: [DiskNode]  // 文件为 []
    public let isDeniedTruncated: Bool  // 遍历该目录时遇 I/O 权限错误
    public let containsProtected: Bool  // 自身或任一后代 isDenied
    public init(path: String, name: String, sizeBytes: Int64, isDirectory: Bool,
                children: [DiskNode] = [], isDeniedTruncated: Bool = false,
                containsProtected: Bool = false)
}

public struct DiskScanProgress: Sendable, Equatable {
    public let bytesScanned: Int64; public let deniedCount: Int; public let currentPath: String
    public init(bytesScanned: Int64, deniedCount: Int, currentPath: String)
}

public struct DiskScanner: Sendable {
    public let protection: ProtectionStore
    public init(protection: ProtectionStore)
    /// 遍历 root,返回 DiskNode 树。契约:
    /// - root 必须绝对路径且存在,否则 throws(进 .failed,绝不按 CWD 相对解析)
    /// - root 的直接子项中名为 ".Trash" 的目录整棵剪枝(不遍历不列出)
    /// - symlink 条目直接跳过(不列出、不跟随)
    /// - 文件体量 = fileAllocSize;目录 = 子树文件之和,目录自身块不计
    /// - 列目录遇 I/O 权限错误:该目录标 isDeniedTruncated 并计入 deniedCount,已读部分体量保留
    /// - containsProtected 自底向上:protection.isDenied(node.path) || 任一 child.containsProtected
    /// - 周期检查 Task.isCancelled,取消时 throws CancellationError(丢弃部分结果)
    /// - onProgress 在后台线程回调(bytesScanned 单调不减;deniedCount 单调不减)
    public func scan(root: String, onProgress: (@Sendable (DiskScanProgress) -> Void)? = nil) async throws -> DiskNode
}
```

- [ ] **Step 1: 改 Package.swift 并跑一次构建确认 target 存在**

Run: `swift build 2>&1 | head -5`(此步仅为构建,允许;测试仍走 Scripts/test.sh)
Expected: 空目标编译通过。

- [ ] **Step 2: 写失败测试 `Tests/DiskKitTests/DiskScannerTests.swift`**

测试内私有夹具帮手(本文件内):
```swift
@discardableResult
func makeTree(_ root: URL, _ spec: [String: Any]) throws -> URL
// spec key 为相对路径,值:Data → 文件内容;[String: Any] → 子目录;字符串 "symlink:<target>" → 符号链接
```
用例(Suite 名 `DiskScannerTests`,断言值即规格,不得改松):
1. `sizesAggregateBottomUp`:文件 a(内容 1_000_000 字节)、子目录 b(文件 c 内容 2_000 字节);断言 `root.isDirectory`、`root.sizeBytes == a.sizeBytes + b.sizeBytes`、`b.sizeBytes == c.sizeBytes`、`a.sizeBytes == a 自身 fileAllocSize(读回 resourceValues 对账)`、`b.children.count == 1`。
2. `trashPrunedAndSymlinksSkipped`:root 下建 `.Trash/`(含文件)、`link → root/a`(symlink);断言 root.children 不含 `.Trash` 与 `link`,且遍历未跟随(a 仅出现一次)。
3. `deniedDirectoryIsFlaggedAndCounted`:子目录 `locked/` chmod 0o000;断言 `locked.isDeniedTruncated == true`、`deniedCount` 通过 onProgress 收集的最大值 ≥ 1、root.sizeBytes 仍为其余子树之和;defer 恢复 0o755。
4. `protectedSubtreeMarksAncestors`:ProtectionStore(hardRoots: ["<root>/private"], userExclusions: ["<root>/excluded"]);断言 `root.containsProtected == true`、`private.containsProtected == true`、`excluded.containsProtected == true`、无关兄弟 `normal.containsProtected == false`。
5. `progressMonotonic`:onProgress 收集序列,断言 bytesScanned 与 deniedCount 均单调不减,且序列非空。
6. `cancelThrowsCancellationError`:启动 scan 于 Task,立即 `task.cancel()`;断言 `try await` 抛 `CancellationError`(以 `catch is CancellationError` 断言)。
7. `invalidRootThrows`:scan(root: "relative/path") 与 scan(root: "/definitely/not/existing-xyz") 均 throws。

- [ ] **Step 3: 跑测试确认编译失败(类型不存在)**

Run: `Scripts/test.sh --filter DiskScannerTests`
Expected: FAIL,`DiskNode`/`DiskScanner` 未定义。

- [ ] **Step 4: 实现 `DiskModels.swift` 与 `DiskScanner.swift`**

按 Interfaces 逐字签名。实现要点:`FileManager.enumerator(at:includingPropertiesForOptions:)` 深度优先;每 256 个条目检查 `Task.isCancelled`;进度节流(每 64 个条目或目录边界回调一次);chmod 0o000 目录用 `do/catch` 包住 `contentsOfDirectory` 即得 denied 语义。

- [ ] **Step 5: 跑测试确认通过**

Run: `Scripts/test.sh --filter DiskScannerTests`
Expected: 7/7 PASS。

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/DiskKit Tests/DiskKitTests
git commit -m "feat(DiskKit): DiskScanner 遍历聚合——块占用口径、.Trash 剪枝、symlink 跳过、权限墙如实计数、containsProtected 派生、进度与取消"
```

---

### Task 2: DiskKit——SquarifiedTreemap 布局与命中测试

**Files:**
- Create: `Sources/DiskKit/SquarifiedTreemap.swift`
- Test: `Tests/DiskKitTests/SquarifiedTreemapTests.swift`

**Interfaces:**
- Produces:
```swift
public struct TreemapRect: Sendable, Equatable {
    public let index: Int      // weights 下标
    public let rect: CGRect
    public init(index: Int, rect: CGRect)
}

public enum SquarifiedTreemap {
    /// 经典 squarified(Bruls et al.):weights 降序贪心成行,行内最差纵横比最小化。
    /// 契约:
    /// - weights 为空 → []
    /// - 面积守恒:∑rect 面积 == area 面积(全零 weights 时均分)
    /// - 两两不重叠;每个 rect 完全落在 area 内
    /// - 稳定:相同 weights 输入输出逐位一致;并列值按原下标序
    /// - 非全零输入中,面积 > 0 的矩形纵横比 ≤ 4.0(容差 +1e-6)
    public static func layout(in area: CGRect, weights: [Int64]) -> [TreemapRect]
    /// 命中:返回包含 point 的第一个 rect(按下标序);无则 nil。
    public static func hitTest(rects: [TreemapRect], at point: CGPoint) -> TreemapRect?
}
```

- [ ] **Step 1: 写失败测试(断言以上契约)**

Suite `SquarifiedTreemapTests`,用例:
1. `emptyWeightsYieldNoRects`;2. `areaConserved`(随机 weights,面积和 == area 面积,Double 比较 +1e-6);3. `noOverlapAndInsideArea`;4. `aspectRatioBounded`(如 weights [81, 27, 27, 9, 9, 3, 3, 1] 于 640×480,全部纵横比 ≤ 4.0);5. `stableForIdenticalInput`(跑两次逐位相等;全零 weights 均分);6. `hitTestFindsContainingRectAndMisses`。

- [ ] **Step 2: Run `Scripts/test.sh --filter SquarifiedTreemapTests` → FAIL(未定义)**
- [ ] **Step 3: 实现(标准 squarify;row 的 worst-ratio 比较用 Double)**
- [ ] **Step 4: Run 同上 → 6/6 PASS**
- [ ] **Step 5: Commit**

```bash
git add Sources/DiskKit/SquarifiedTreemap.swift Tests/DiskKitTests/SquarifiedTreemapTests.swift
git commit -m "feat(DiskKit): squarified treemap 纯函数——面积守恒/无重叠/纵横比上限/稳定,hitTest 命中"
```

---

### Task 3: AppCore——DiskAnalysisViewModel(状态机/面包屑/勾选门禁/displayRows 聚合)

**Files:**
- Create: `Sources/AppCore/DiskAnalysisViewModel.swift`
- Test: `Tests/AppCoreTests/DiskAnalysisViewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `DiskScanner.scan(root:onProgress:)`、`DiskNode`;`ExclusionsStore`(init `init(defaults:)`、`exclusions: [String]`);`HistoryStoring`。
- Produces:
```swift
public struct DisplayRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case item(DiskNode)
        case others(count: Int, bytes: Int64)   // 聚合行
    }
    public let id: String          // item → node.path;others → "__others__"
    public let kind: Kind
    public init(id: String, kind: Kind)
}

@MainActor @Observable public final class DiskAnalysisViewModel {
    public enum Phase: Equatable { case idle, scanning, completed, cleaning, report(CleanReport), failed(String) }
    public private(set) var phase: Phase
    public private(set) var root: DiskNode?
    public private(set) var progress: DiskScanProgress?
    public private(set) var cleanProgress: CleanProgress
    public private(set) var lastCleanup: CleanReport?
    public var selectedPaths: Set<String>
    public var confirmPresented: Bool
    public private(set) var drillPath: [DiskNode]          // [0] = root;面包屑
    public let scanner: DiskScanner
    public let exclusions: ExclusionsStore
    public let history: HistoryStoring
    public let trash: TrashServicing
    public init(scanner: DiskScanner, exclusions: ExclusionsStore, history: HistoryStoring,
                trash: TrashServicing = FileManagerTrashService())
    public func startScan(rootPath: String = NSHomeDirectory())   // normalize;失败 → .failed
    public func cancelScan()                                       // → .idle,丢弃部分结果
    public func drill(into node: DiskNode)                         // 仅目录;push
    public func drillTo(depth: Int)                                // 面包屑跳转,截断到该层
    public func toggle(_ path: String)                             // Global Constraints 门禁
    public var canSelectRoot: Bool { false }
    public var currentChildren: [DiskNode]                         // drillPath.last.children 降序;root 为 nil 时 []
    public var displayRows: [DisplayRow]                           // 聚合常量见 Global Constraints
    public var selectedNodes: [DiskNode]                           // 树内被勾选的最上层节点,深度优先序
    public var selectedBytes: Int64
    public var remainingCount: Int                                 // 存活树除根外节点数
    public var remainingBytes: Int64                               // 存活树除根外体量合计
    public func loadLastCleanup()
}
```
扫描注入点:测试用**子类或协议?都不用**——`DiskScanner` 为 struct,测试以**真实 scanner + 临时目录夹具**走全真路径(与 DiskKitTests 同款 makeTree 复制进本测试文件);进度回调经 `Task { @MainActor }` 回主线程(照抄 ScanViewModel.runScan 模式)。

- [ ] **Step 1: 写失败测试**。Suite `DiskAnalysisViewModelTests`,夹具:makeTree 造 3 层树。用例:
1. `scanLifecycleIdleToCompleted`:startScan → 等待 → phase == .completed、root != nil、drillPath == [root]。
2. `cancelDiscardsAndReturnsIdle`:扫描中途 cancel → phase == .idle、root == nil。
3. `failedRootGoesToFailed`:startScan(rootPath: "relative") → .failed。
4. `drillAndBreadcrumb`:drill(into: 子目录) 后 drillPath.count == 2、currentChildren 为该目录子项降序;drillTo(depth: 0) 回 [root]。
5. `displayRowsAggregatesTail`:单层造 125 个子项(权重递减),断言 displayRows.count == 121、最后一行 `.others(count: 5, …)`;再断言 121 个子项时不产生 others 行。
6. `toggleGates`:勾选 root → no-op;勾选 containsProtected 节点 → no-op;勾选目录后其子孙路径从 selectedPaths 移除;祖先已勾选时 toggle 后代 → no-op。
7. `selectionSurvivesDrill`:在 A 层勾选,A 下钻 B 再回 A,selectedPaths 保持。
8. `defaultsUnselected`:完成扫描后 selectedPaths 为空。
9. `remainingCountsWholeTree`:跨层节点计数与体量合计正确。

- [ ] **Step 2: Run `Scripts/test.sh --filter DiskAnalysisViewModelTests` → FAIL(未定义)**
- [ ] **Step 3: 实现**(状态机照抄 ScanViewModel 形状;门禁按 Global Constraints 逐字)
- [ ] **Step 4: Run 同上 → 9/9 PASS**
- [ ] **Step 5: Commit**

```bash
git add Sources/AppCore/DiskAnalysisViewModel.swift Tests/AppCoreTests/DiskAnalysisViewModelTests.swift
git commit -m "feat(AppCore): DiskAnalysisViewModel——扫描状态机、面包屑下钻、勾选门禁(根/受保护/祖先链)与其他项聚合"
```

---

### Task 4: 删除编排——CleanReport.source、就地更新、历史与报告

**Files:**
- Modify: `Sources/CleanKit/CleanReport.swift`(`CleanReport` 加 `public let source: String?`,init 末位带默认 `nil`;`CleanExecutor.clean` 加末位参数 `source: String? = nil` 透传进报告)
- Modify: `Sources/AppCore/DiskAnalysisViewModel.swift`(cleanSelected/applyCleanOutcome/returnToResults/dismissReport)
- Test: `Tests/CleanKitTests/CleanReportSourceTests.swift`(新建或并入现有 Suite 均可,Suite 名固定)
- Test: `Tests/AppCoreTests/DiskAnalysisViewModelTests.swift`(追加用例)

**Interfaces:**
- Consumes: Task 3 全部;`CleanExecutor(trash:protection:)`、`CleanItem(path:sizeBytes:action:)`、`TrashOutcome`(`trashed`/`vanished`/`skipped(reason:)`)、`JSONHistoryStore(directory: URL? = nil)`。
- Produces: `CleanReport` 新字段 `source: String?`;`CleanExecutor.clean(_:onProgress:source:)`。

- [ ] **Step 1: 写失败测试**

Suite `CleanReportSourceTests`(CleanKitTests):
1. `sourceDefaultsToNilAndDecodesOldRecords`:`CleanReport(freedBytes: 0, trashedCount: 0, vanishedCount: 0, snapshotCount: 0, skipped: [])` 的 `source == nil`;把**无 source 键的 JSON**(一期格式 `{"date":…,"freedBytes":…,…}`)解码成功且 source == nil。
2. `executorPassesSource`:`CleanExecutor(trash: mock, protection: …).clean([CleanItem(path: "/t/a", sizeBytes: 1)], source: "disk-analysis")` 返回报告 `source == "disk-analysis"`(mock trash 返回 .trashed; ProtectionStore 硬根清空传 `hardRoots: []` 以免误拦)。

DiskAnalysisViewModelTests 追加(夹具 mock:`MockTrash: TrashServicing`,记录 path,按字典返回 outcome):
3. `cleanSelectedTrashesTopmostSelection`:勾选两个顶层节点 → trash 收到的 path 恰为这两者(无后代)、报告态 phase == .report、history(directory 注入 temp)追加 1 条且 source == "disk-analysis"。
4. `inPlaceUpdateRemovesAndPropagates`:清理一个目录(子树 2 节点)后:root.children 不含它、父目录 sizeBytes 精确减去该子树、remainingCount 减少 2、selectedPaths 已扣减。
5. `skippedStaysSelectedAndInTree`:mock 对一节点返回 `.skipped(reason: "no-permission")` → 该节点仍在树、仍被勾选、出现在 report.skipped、不计入 freedBytes。
6. `vanishedNotCountedAsFreed`:mock 返回 `.vanished` → 节点移除、freedBytes 不含其体量、vanishedCount == 1。
7. `drillPathFallsBackToSurvivingAncestor`:下钻至被清目录内,清理后 drillPath 截断至最近存活祖先,crash-free 且 currentChildren 可用。
8. `returnToResultsAndDismiss`:`returnToResults()` 报告态 → completed(树保留);`dismissReport()` → idle 且 root == nil、selectedPaths 空。

- [ ] **Step 2: Run `Scripts/test.sh --filter CleanReportSourceTests` 与 `--filter DiskAnalysisViewModelTests` → 新用例 FAIL**
- [ ] **Step 3: 实现**(applyCleanOutcome 语义照 ScanViewModel:提交且未进 skipped 即移除;被移除节点 containsProtected 必为 false,祖先标志无需重算——把这句写成注释)
- [ ] **Step 4: Run 两个 filter → 全 PASS;再跑 `Scripts/test.sh --filter CleanKitTests` 确认既有 CleanKit 用例零回归**
- [ ] **Step 5: Commit**

```bash
git add Sources/CleanKit/CleanReport.swift Sources/AppCore/DiskAnalysisViewModel.swift Tests/CleanKitTests Tests/AppCoreTests/DiskAnalysisViewModelTests.swift
git commit -m "feat: 磁盘清理编排——CleanReport.source 透传、树就地更新(差值上溯/skipped 保留/面包屑回退)、历史入库"
```

---

### Task 5: UI——侧边栏转正、DiskAnalysisHomeView(列表态)、确认弹窗、报告来源标注、L10n

**Files:**
- Modify: `Sources/Raccoon/RootView.swift`(`availableCases` 加 `.diskAnalysis`;detail switch 加 `case .diskAnalysis:`;手写展开 `_diskVM: State<DiskAnalysisViewModel>` + 计算属性 `diskVM`,照抄 `_aiVM` 模式;`RaccoonApp` 无需改)
- Create: `Sources/Raccoon/DiskAnalysisHomeView.swift`
- Create: `Sources/Raccoon/DiskConfirmView.swift`(vm: DiskAnalysisViewModel;照抄 `ConfirmCleanView` 版式:标题、已选计数、默认键给取消、onExitCommand)
- Modify: `Sources/Raccoon/CleanReportView.swift`(加 `var sourceLabel: String? = nil`;非 nil 时在 `report.done` 下方以 `.secondary` 显示)
- Modify: `Sources/Raccoon/Resources/{en,zh-Hans}.lproj/Localizable.strings`(新增键两两同步)

**Interfaces:**
- Consumes: Task 3/4 的 `DiskAnalysisViewModel` 全部公开面;`loc`/`byteText`;版式参照 `AICleanupHomeView.swift`(phase 驱动 + 底栏 + `.sheet(isPresented: $vm.confirmPresented)`)。

- [ ] **Step 1: 新增 L10n 键(en/zh 同步,缺一即 CI 红)**

`module.diskAnalysis` 已存在,勿重复添加。新增(zh 值全角标点):
`disk.idle.hint`、`disk.start`、`disk.chooseFolder`、`disk.progress.scanned`、`common.cancel`(已有则复用)、`disk.view.treemap`、`disk.view.list`、`disk.others`(格式 "%d 项 · %@")、`disk.list.protected`、`disk.root.home`、`disk.empty`、`disk.rescan`、`report.source.diskAnalysis`。en/zh 文案各自成对,语义见 spec §5。

- [ ] **Step 2: 实现 RootView 转正 + DiskAnalysisHomeView**

idle:提示文案 + 「开始扫描」(`vm.startScan()`)+「选择文件夹…」(`.fileImporter(isPresented:allowedContentTypes: [.folder])` 选中后 `startScan(rootPath:)`;`import UniformTypeIdentifiers`)。
scanning:`disk.progress.scanned` + `byteText(vm.progress?.bytesScanned ?? 0)` + 当前路径截断显示 + 取消按钮。
completed:面包屑(HStack,首项文案 `loc("disk.root.home")`,其余 `node.name`;点击 `drillTo(depth:)`);视图切换 Picker(treemap 本 task 先放占位 Text,Task 6 替换)+ List(displayRows:`.item` 行 = 勾选框(不可选时 disabled + `disk.list.protected` 标注)+ name + byteText(sizeBytes),点击行 drill;`.others` 行 = `loc("disk.others", count, byteText(bytes))` 灰色);底栏「已选 N 项 · X + 清理…」(无勾选时 disabled);`.sheet { DiskConfirmView(vm: vm) }`。
report:复用 `CleanReportView(report: vm.phase 报告, remainingCount: vm.remainingCount, remainingBytes: vm.remainingBytes, onBack: { vm.returnToResults() }, onRescan: { vm.startScan() }, sourceLabel: report.source == "disk-analysis" ? loc("report.source.diskAnalysis") : nil)`。
failed:错误文案 + 再扫按钮。
所有 `@State`/`@Binding` 手写展开(本文件如需)。

- [ ] **Step 3: 构建与 L10n 校验**

Run: `swift build 2>&1 | tail -3`(构建允许;测试走脚本)
Expected: 编译零错误。
Run: `diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort) <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort)`
Expected: 无输出。

- [ ] **Step 4: 全量测试零回归**

Run: `Scripts/test.sh`
Expected: 全绿,数量 ≥ Task 4 后计数。

- [ ] **Step 5: Commit**

```bash
git add Sources/Raccoon Tests
git commit -m "feat(Raccoon): 磁盘分析入口转正——phase 驱动主页、列表视图、面包屑、确认弹窗与报告来源标注(双语文案)"
```

---

### Task 6: UI——TreemapView(Canvas 渲染 + 点击下钻)

**Files:**
- Create: `Sources/Raccoon/TreemapView.swift`
- Modify: `Sources/Raccoon/DiskAnalysisHomeView.swift`(Task 5 的 treemap 占位替换为 `TreemapView(rows: vm.displayRows, onTap: { vm.drill(into: $0) })`)

**Interfaces:**
- Consumes: Task 2 `SquarifiedTreemap.layout(in:weights:)` / `hitTest(rects:at:)`、`TreemapRect`;Task 3 `DisplayRow`。

- [ ] **Step 1: 实现 TreemapView**

结构:`GeometryReader` → weights = rows 中 `.item` 的 sizeBytes(`.others` 行不参与布局,固定渲染于右下角图例);`SquarifiedTreemap.layout` → `Canvas { context, _ in for tr in rects { fill + stroke,色相按 index 轮转 } }`;命中:`.gesture(SpatialTapGesture().onEnded { g in if let tr = SquarifiedTreemap.hitTest(rects: rects, at: g.location) { onTap(rows[tr.index]) } })`;矩形内文字(name + byteText)仅在 rect 足够大时绘制(阈值:宽 >80 且高 >24,渲染层细节)。空 rows 显示 `disk.empty` + `disk.rescan`。

- [ ] **Step 2: 构建绿 + L10n diff 无输出(同 Task 5 Step 3 两条命令)**
- [ ] **Step 3: 全量 `Scripts/test.sh` 绿**
- [ ] **Step 4: Commit**

```bash
git add Sources/Raccoon/TreemapView.swift Sources/Raccoon/DiskAnalysisHomeView.swift
git commit -m "feat(Raccoon): treemap 渲染——squarified 布局 Canvas 绘制、点击下钻、空态"
```

---

### Task 7: 文档、守卫终验与收尾

**Files:**
- Modify: `README.md`(路线图四期 → `✅ 已实现(待人工 QA)`;当前功能加「磁盘分析」段;已知限制加 spec §9 五条;删除动作说明补「磁盘分析入口同样只进废纸篓」)
- Create: `docs/superpowers/qa/phase4-qa-checklist.md`(自动核验项附真实证据原文;待人工项 A1–An 不预标绿:入口可用、真机 home 扫描性能与进度、treemap 钻取目测、实清小目录废纸篓可放回、权限墙目测、双语文案)
- Modify: `docs/superpowers/specs/2026-10-18-raccoon-phase4-design.md`(第 4 行状态 → `已实施(待人工 QA)`)

- [ ] **Step 1: 守卫 grep(逐条留原文进 QA 清单)**

Run: `grep -rn "unlink\|removeItem" Sources/ --include='*.swift' | grep -v "^\s*//" | grep -v "// "`
Expected: 仅测试夹具自清 temp 的既有例外与注释,零新增实现调用。
Run: `grep -rn "trashItem" Sources/ --include='*.swift'`
Expected: 实现 `TrashService.swift:21` 唯一,其余为注释。

- [ ] **Step 2: 全量 `Scripts/test.sh` 绿,记录总测试数(只增不减)**

- [ ] **Step 3: 按上述文件清单更新文档(QA 清单引用 Step 1/2 的真实输出,人工项一律 ⏳)**

- [ ] **Step 4: Commit**

```bash
git add README.md docs
git commit -m "docs: 四期收尾——README、QA 清单、规格状态"
```

---

## Self-Review 记录

1. **Spec 覆盖**:D1→T5(fileImporter);D2→T4(executor source + history);D3→T2+T6;D4→T5 面包屑/列表 + T6 点击下钻;D5→T1 deniedTruncated + T5 进度展示;D6→T1/T3/T5 分层;D7→T3 门禁用例 6;D8→T4 用例 4–8;验收 1→T5;2→T5+T6;3→T1+T5;4→T3/T4/T5;5→T7;6→T7。无缺口。
2. **Step 扫描**:每步单一动作;实现步骤只给签名与契约,算法仅 squarify 给了引用(标准 Bruls)。
3. **类型一致**:`DiskNode`/`DiskScanProgress`/`TreemapRect`/`DisplayRow`/`DiskAnalysisViewModel` 签名在 T1→T3→T5→T6 间逐字一致;`CleanReport.source` 与 `clean(_:onProgress:source:)` 在 T4 内自洽。
4. **Review Focus**:权限墙→T1 用例 3;外部删除 vanished→T4 用例 6;取消响应→T1 用例 6 + T3 用例 2;非法扫描根→T1 用例 7;旧 history.json 兼容→T4 用例 1。
5. **比例**:计划 ≈ 规格两倍余,代码只出现在测试断言与签名,未写实现本体。
