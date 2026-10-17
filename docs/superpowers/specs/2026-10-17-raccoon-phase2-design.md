# Raccoon(浣熊清理)二期设计文档

- 日期:2026-10-17
- 状态:已经用户确认的设计方案(2026-10-17 设计对话,四项关键决策由用户拍定)
- 范围:二期(应用卸载 + 残留清理)
- 前置:[一期设计](2026-10-13-raccoon-phase1-design.md)、[一期计划](../plans/2026-10-13-raccoon-phase1.md)
- 参考:[Mole](https://mole.fit/zh/)(功能对标对象)

## 1. 背景与目标

一期交付了「扫描 → 预览 → 勾选 → 移入废纸篓」的清理主干与四道安全门。二期在**同一安全叙事**下增加两条能力:

1. **应用卸载**:列出已安装应用,把应用本体与其在 `~/Library` 下的关联数据一并预览、勾选、移入废纸篓。
2. **孤儿残留清理**:应用已不在磁盘上、但 `~/Library` 仍留有它数据目录的「无主残留」,可被发现并清理。

二期的核心不是「删得更多」,而是**在删到用户数据边缘时依然不删错**:关联数据里有用户文档、登录态与本地数据库,所以分级、预览与「只进废纸篓」一条不能少。

## 2. 范围

### 2.1 纳入

- **应用发现**:`/Applications` 与 `~/Applications`(含一层子目录,见 §5.2)中的 `.app`;排除 `com.apple.*` 与 `/System` 下的一切。
- **关联数据**:上述应用在 `~/Library` 已知位置(§6)下的数据目录/文件,按 §6 分级。
- **孤儿残留**:`~/Library` 已知位置中,归属可判定为「已无对应已安装应用」的目录(§7)。
- **执行**:复用一期 `CleanExecutor`(`FileManager.trashItem` 唯一实现),复用 `CleanReport` 与历史落盘。

### 2.2 不纳入(见 §14 的诚实边界)

- 系统级残留(`/Library` 下需管理员权限的部分)与任何提权行为 → 三期候选。
- `~/Library/Preferences`、`~/Library/Cookies` 的关联数据(一期硬保护整棵保护,见 §8.4)。
- Homebrew / 命令行工具、App Store 账号与更新管理、LaunchServices 数据库重建。

## 3. 关键决策

| # | 决策 | 结论 | 理由 |
| - | ---- | ---- | ---- |
| D1 | 「残留清理」范围 | **两者都做**:卸载时连带清理关联数据 + 独立的孤儿残留扫描 | 标题主干是卸载,而孤儿发现与卸载共用同一套位置表,同批实现成本最低 |
| D2 | 关联数据默认勾选 | **分级勾选**:可再生的默认勾选;Application Support / Containers / Group Containers / Application Scripts 默认不勾、橙色、确认弹窗单独分区 | 与一期 cautious 同口径;这些位置可能含用户文档与登录态 |
| D3 | 权限边界 | **只做用户域,不引入任何提权**;系统级残留记为三期 | 提权后无法再走 `trashItem` 的「唯一删除实现」,核心承诺会被迫降级;二期不值得为此改安全模型 |
| D4 | 孤儿判定口径 | **Bundle ID 精确匹配为主;名称相似但无法确认归属的进「未确认归属」分区**,默认不勾 | 误报近零是安全工具的前提;覆盖不全作为已知代价显式声明 |
| D5 | 位置表形态 | **代码内静态表(`LeftoverLocations`)+ 测试强制分级完备**,不用 JSON | 位置是全局 schema 而非逐应用数据,社区无需逐条贡献;类型化+测试比 JSON 更稳 |
| D6 | 执行引擎 | **直接复用 `CleanExecutor`**,不新写删除路径 | 「唯一删除实现」是核心不变量,复用即继承删除前 `isDenied` 复核 |
| D7 | UI 归属 | 侧边栏「卸载」模块内两页:应用列表/详情 + 残留扫描;报告页抽为共用视图 | 六期骨架早已预留该模块;报告形态复用避免第二套文案与逻辑 |

## 4. 总体架构

```
Raccoon(UI)          UninstallHomeView ── AppListView / AppDetailView / OrphanListView
                        │  确认弹窗(复用形态) / 共用 CleanReportView
AppCore              UninstallViewModel(@MainActor @Observable)
                        │  注入:AppDiscovering / LeftoverLocating / OrphanScanning / TrashServicing
UninstallKit(新)     AppDiscovery · LeftoverLocator · OrphanScanner · LeftoverLocations · 模型
                        │  依赖
CleanKit             ProtectionStore · CleanExecutor · FileManagerTrashService · CleanReport · JSONHistoryStore
```

- `Package.swift`:新增 `target UninstallKit`(依赖 `CleanKit`)、`testTarget UninstallKitTests`;`AppCore` 依赖追加 `UninstallKit`;`Raccoon` 依赖追加 `UninstallKit`。
- **可测性硬要求**:主目录与应用根一律注入(`HomeDirectory`/`appRoots` 参数,生产默认 `NSHomeDirectory()` 与 `["/Applications", "~/Applications"]`)。UninstallKit 的代码中不得直接读取 `NSHomeDirectory()` 或硬编码 `/Applications`。
- **离线可测**:测试全部使用临时目录夹具,绝不触碰真实文件系统(与一期 `MockTrash` 同纪律)。

## 5. 领域模型

### 5.1 类型

```swift
public struct InstalledApp: Identifiable, Equatable, Sendable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let version: String?
    public let appPath: String        // 绝对路径,已 resolve 符号链接
    public let sizeBytes: Int64       // .app 本体递归大小(不跟随符号链接)
    public let isRunning: Bool
}

public enum LeftoverSafety: String, Equatable, Sendable {
    case regenerable   // 可再生:缓存/日志/注册项 → 默认勾选
    case userData      // 可能含用户数据/登录态 → 默认不勾、橙色、单独确认
}

public enum LeftoverOwnership: Equatable, Sendable {
    case bundleID      // 精确:目录名即 Bundle ID
    case appName       // 低置信:目录名与某应用名相同,无法确认归属
}

public struct AppLeftover: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let sizeBytes: Int64
    public let safety: LeftoverSafety
    public let ownership: LeftoverOwnership
    public let locationID: String     // 对应 LeftoverLocations 的 id(用于 UI 说明与测试断言)
}

public struct AppDiscoveryResult: Sendable {
    public let apps: [InstalledApp]
    public let unreadableCount: Int   // 无 Info.plist / 无 Bundle ID 而跳过的数量(§11)
}

public struct AppDiscoveryProgress: Sendable {
    public let enumeratedCount: Int   // 总数未知:枚举前无法预知,UI 用不确定进度条
}

public struct OrphanScanResult: Sendable {
    public let orphans: [AppLeftover]
    public let failedLocationIDs: Set<String>   // 枚举失败的位置(§11)
}

public struct OrphanScanProgress: Sendable {
    public let completedLocations: Int
    public let totalLocations: Int
}
```

### 5.1.1 注入接口(UninstallKit 对外边界)

取消语义与一期 `ScanServicing` 对齐:接口不带「是否已取消」参数,调用方取消其 `Task`,实现内部检查 `Task.isCancelled` 并在下一个检查点返回/抛出。

```swift
public protocol AppDiscovering: Sendable {
    func discover(progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult
}

public protocol LeftoverLocating: Sendable {
    func leftovers(for app: InstalledApp) async -> [AppLeftover]
}

public protocol OrphanScanning: Sendable {
    func scan(installedBundleIDs: Set<String>,
              progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult
}

/// 已安装集合的 LaunchServices 侧(生产实现经主线程查询 NSWorkspace;测试注入固定集合)
public protocol InstalledBundleResolving: Sendable {
    func isResolvable(_ bundleID: String) async -> Bool
}

/// 运行中判定(生产读 NSRunningApplication.runningApplications(withBundleIdentifier:);测试注入固定集合)
public protocol RunningAppChecking: Sendable {
    func isRunning(bundleID: String) -> Bool
}
```

### 5.2 应用发现规则

1. 枚举根:调用方给出的 `appRoots`(默认 `/Applications`、`~/Applications`)。**只看根下第一层的 `.app`,以及根下第一层目录内的 `.app`(即最多一层子目录)**;更深层不枚举(避免钻进 `.app` 内部与嵌套 helper)。
2. 只认**包**(`.app` 目录);`LSApplicationCategoryType` 等不参与过滤。
3. 读取 `Contents/Info.plist` 的 `CFBundleIdentifier`(必需)、`CFBundleName`/`CFBundleDisplayName`(缺省回退文件名)、`CFBundleShortVersionString`(可缺)。
4. 排除:`CFBundleIdentifier` 以 `com.apple.` 开头;路径经 `resolvingSymlinksInPath` 后**必须仍位于该根之下**(符号链接逃出根 → 跳过);命中用户排除清单(`ProtectionStore.isUserExcluded`)→ 跳过。
5. `isRunning`:由调用方注入的判定器(生产用 `NSRunningApplication.runningApplications(withBundleIdentifier:)`;测试注入固定集合)。
6. 大小 `.app` 本体递归累计,不跟随符号链接;单条大于 0 字节的文件均计入。
7. **同 Bundle ID 去重**:多个根下出现同一应用时只保留一条,按 `appRoots` 给出的顺序优先(默认 `/Applications` 优先于 `~/Applications`),保证 `Identifiable` 唯一。
8. 列表排序:按名称本地化升序;搜索框对名称与 Bundle ID 做大小写不敏感的包含匹配。

### 5.3 孤儿判定中的「已安装集合」

`已安装集合 = 目录枚举得到的 Bundle ID ∪ LaunchServices 可解析的 Bundle ID`(生产经注入的 `InstalledBundleResolving` 查询 `NSWorkspace.urlForApplication(withBundleIdentifier:)`,可在主线程执行;测试注入固定集合)。二者取并集,避免「应用装在非常规目录但仍在系统中注册」被误判为孤儿。

## 6. 关联数据位置表与分级

位置一律相对 `~/Library`(主目录注入)。`<id>` 指 Bundle ID,`<name>` 指应用名。

| id | 相对路径 | 匹配 | 分级 | 说明 |
| -- | ---- | ---- | ---- | ---- |
| `caches` | `Caches/<id>` | 精确 | 可再生 | 缓存,应用会重建 |
| `logs` | `Logs/<id>` | 精确 | 可再生 | 日志 |
| `webkit` | `WebKit/<id>` | 精确 | 可再生 | 网页数据缓存 |
| `httpstorages` | `HTTPStorages/<id>` | 精确 | 可再生 | HTTP 存储(缓存+部分状态) |
| `saved-state` | `Saved Application State/<id>.savedState` | 精确(`.savedState` 后缀) | 可再生 | 窗口恢复状态 |
| `launch-agents` | `LaunchAgents/<id>.plist` | 精确(`.plist` 后缀) | 可再生 | 用户级登录启动项注册 |
| `app-support` | `Application Support/<id>` | 精确 | 需确认 | 可能含本地数据库、配置、离线内容 |
| `containers` | `Containers/<id>` | 精确 | 需确认 | 沙盒容器;可能含应用文档 |
| `group-containers` | `Group Containers/<id>` 及 `Group Containers/*.<id>` | 精确 + 组容器命名约定 | 需确认 | 应用组共享数据 |
| `app-scripts` | `Application Scripts/<id>` | 精确 | 需确认 | 用户脚本(内容由用户创建) |
| `app-support-name` | `Application Support/<name>` | 低置信(§8.3) | 需确认 | 无法确认归属,恒为未确认分区 |
| `logs-name` | `Logs/<name>` | 低置信(§8.3) | 可再生 | 同上,但日志本身可再生 |
| **不列出** | `Preferences/<id>.plist`、`Cookies/*` | — | — | 见 §8.4:一期硬保护整棵覆盖,列了也删不掉 |

规则:

- `Group Containers` 的精确匹配有二段式约定:目录名等于 `<id>`,**或**目录名以 `.<id>` 结尾(`TEAMID.<id>`)。
- 同一路径被多条位置命中时按 `id` 字典序取第一条(去重);大小按目录递归累计。
- 位置表由测试强制:每条位置必须给出确定分级;`Preferences`/`Cookies` 路径经 `ProtectionStore.isDenied` 复核必须为 `true`(即断言「硬保护封锁」这一事实,防止未来误加)。

## 7. 孤儿扫描口径

扫描范围:§6 表中除 `app-support-name`/`logs-name` 之外的全部位置(即仅扫描**能按名称形状判定**的位置),逐个位置枚举其一级子项:

- **高置信(ownership = .bundleID)**:子项名称形如反向域名 —— 以 `.` 分隔 ≥ 2 段、每段匹配 `[A-Za-z0-9_-]+`(允许 App Store 的 `TEAMID.` 前缀与 `.<id>` 组容器命名),且该 ID **不在**已安装集合(§5.3),且**不以 `com.apple.` 开头**。`Saved Application State` 的 `.savedState` 后缀与 `LaunchAgents` 的 `.plist` 后缀在判定前剥离。
- **低置信(ownership = .appName)**:仅对 `Application Support` 与 `Logs` 两类位置,子项名称**不是**反向域名形状,且与**任何已安装应用名**(大小写不敏感、去首尾空白、去 `.app` 后缀)都不相等 —— 进「未确认归属」分区。
- `com.apple.*` 永不作为孤儿;硬保护命中(`isDenied`)与用户排除命中一律不列。
- 默认勾选:仅「高置信 + 可再生」;低置信全部默认不勾。
- 扫描在后台进行、可取消(取消即丢弃本次结果,与一期一致);进度按「已完成位置数 / 总位置数」上报。
- 条目不做静默截断;UI 用惰性列表承载。

## 8. 安全机制(四道门的二期落位)

### 8.1 门 1:硬保护 + 二期作用域白名单

- 每条候选路径(应用本体与关联数据)在**扫描期**先过 `ProtectionStore.isDenied`(硬保护 + 用户排除),命中即不列;执行期由 `CleanExecutor` 在删除前**再复核一次**(纵深防御,继承一期)。
- **新增作用域白名单**(UninstallKit 内实现,测试覆盖):
  - 应用本体:resolved 后必须位于某个 `appRoots` 之下,且是 `.app`;
  - 关联数据:必须位于注入的主目录的 `Library` 之下,且落在 §6 表内某个位置(即路径必须是「`~/Library` + 位置表」构造出的结果,不接受任意输入);
  - 越界一律不列、不提交执行。
- 符号链接:解析后再次校验作用域;解析后逃出作用域 → 跳过该条。

### 8.2 门 2:用户排除清单

与一期同一 `ExclusionsStore` 实例、同一语义:命中即不扫描、不删除。

### 8.3 门 3:安全分级

- `regenerable` → 明细页与残留页默认勾选;`userData` → 默认不勾、橙色标识、确认弹窗单独分区(沿用一期 `confirm.cautiousSection` 的形态,文案按二期重写)。
- 应用本体**固定包含在清单内且不可取消**:卸载语义即「应用本体 + 已勾选的关联数据」。确认弹窗主按钮为「卸载并移入废纸篓」。
- 运行中应用:列表与详情显示黄色「应用运行中」标识,确认弹窗顶部黄色警告;不硬性阻止(与一期运行中缓存的处理一致,由用户判断)。

### 8.4 门 4:只进废纸篓

- 全部删除经 `CleanExecutor` → `FileManager.trashItem`;无提权、无 `rm`、无 unlink。
- **已知限制(必须写入 README 与 QA 清单)**:`~/Library/Preferences` 与 `~/Library/Cookies` 在一期硬保护中整棵保护,故二期不列出这两处的关联数据。放开需改动门 1(窄口豁免 + 回归测试),列为三期候选,**二期不动安全模型**。

## 9. 核心流程

### 9.1 卸载

1. 进入模块 → 应用列表(`AppDiscovery` 后台执行,进度按已枚举应用数上报;可取消)。
2. 选择应用 → 详情页:本体(固定) + 关联数据(按 §6 分级分组;名称匹配项进「未确认归属」分区)。关联数据在进入详情页时才计算(避免列表页为每个应用遍历 `~/Library`)。
3. 勾选 → 底栏「已选 N 项 · X」→「卸载…」→ 确认弹窗(总数、用户数据分区、运行中警告;默认键=取消)。
4. `CleanExecutor.clean(items, onProgress:)` 执行;进度回投主线程驱动进度条(polish 接线)。
5. 完成 → 报告页(释放量、移入废纸篓数、被应用抢先删除数、跳过与原因);「返回列表」回到列表,「重新扫描」重新枚举。

### 9.2 孤儿残留

1. 残留页 →「扫描残留…」→ 按位置逐一枚举(可取消)。
2. 结果分两组:高置信 / 未确认归属;勾选 →「清理…」→ 确认弹窗(形态同上)。
3. 执行与报告同 §9.1。

### 9.3 执行结果与状态收敛(一期教训的二期落实)

- 每个提交项的结果恰为:`trashed` / `vanished` / `skipped(reason)` 之一(沿用 `TrashOutcome` 稳定代码)。
- **已清理 = 提交路径 − `report.skipped` 路径**。
- 收敛规则:
  - 应用列表:仅当该应用的 **`.app` 本体路径**属于「已清理」时才移出列表;本体被跳过(如无权限)则保留,并在报告中如实显示跳过原因。
  - 详情页关联数据:已清理项移出清单,跳过项保留。
  - 残留页:同「提交 − skipped」收敛。
- 报告页「返回列表」保留收敛后的状态,不强制重扫(沿用一期「部分清理后继续」的设计)。
- 卸载与残留清理的报告与一期共用同一 `JSONHistoryStore` 与同一历史文件;主页「上次清理释放 X」覆盖三类来源,因此 §13 的 200 条上限属于本期的必要配套,而非可选优化。

## 10. UI 设计

- 侧边栏:`Module.availableCases` 增加 `.uninstall`;`NavigationSplitView` 的 detail 按当前选择切换(现在恒为清理页,需改为按选择)。
- **应用列表**:搜索框(按名称/Bundle ID 过滤)、列表行 = 图标(`NSWorkspace` 图标,注入失败回退文件夹图标)+ 名称 + 版本 + `.app` 大小 + 「应用运行中」黄标;空态「没有找到应用」。
- **应用详情**:头部(图标/名称/版本/路径)、分组勾选列表(可再生 / 需确认 / 未确认归属)、底栏「已选 N 项 · X」+「卸载…」,**N 与 X 均含应用本体**(本体常驻且不可取消);工具栏「全选/全不选」(仅作用于可勾选的关联数据项)。
- **残留页**:初始态「扫描残留…」按钮与说明文字;扫描中进度与取消;结果两组勾选列表;底栏「已选 N 项 · X」+「清理…」;空态「没有发现残留」。
- **确认弹窗**:沿用一期形态(总大小/项数、运行中警告、需确认分区、默认键=取消、清理按钮仅点按触发)。
- **报告页**:抽出共用 `CleanReportView`(报告数据 + 剩余项 + 「返回列表」/「重新扫描」回调),一期报告页改为其第一个消费者,行为不变。
- 数值行 `monospacedDigit`;橙=需确认、黄=运行中、绿=成功(与一期语义色轴一致)。
- L10n:新增键统一进两份 `Localizable.strings`,**zh/en 键集 1:1**(CI 已守卫);中文使用全角标点。

## 11. 错误处理原则

- 单项失败不中断整批(继承 `CleanExecutor` 语义);失败原因用稳定代码,UI 经 `reason.<code>` 本地化,未知代码回退 `reason.other`(沿用一期)。
- 应用发现阶段读不到 `Info.plist` 或没有 `CFBundleIdentifier` 的应用:跳过并计数,UI 在列表底部提示「N 个应用无法识别,已跳过」。
- 关联数据计算阶段的权限不足:`~/Library` 下个别目录读不到 → 该条不计入(不列),不阻断其它应用。
- 孤儿扫描中单个位置枚举失败:记录该位置并继续;结果页提示「部分位置未能扫描」。

## 12. 测试策略

- **UninstallKit(纯逻辑,注入临时主目录与假应用根)**
  - 发现:基本枚举、一层子目录、`com.apple.*` 排除、缺 Info.plist 跳过、符号链接逃出根跳过、排除清单命中跳过、应用根恰好是符号链接时的解析。
  - 位置表:每个位置 id 都能被构造并在夹具中命中;`Preferences`/`Cookies` 断言 `isDenied == true`(封锁事实)。
  - 分级:每一类的 `LeftoverSafety` 断言;同名去重。
  - 孤儿:高置信正例/反例(已安装、`com.apple.*`)、低置信正例/反例(与已安装应用名相同则不算孤儿)、后缀剥离、硬保护/排除过滤。
  - 大小:嵌套目录累计、符号链接不计入。
- **AppCore(`UninstallViewModel`,注入 Fake 发现器与 MockTrash)**
  - 状态机:list → detail → cleaning → report → 返回列表;取消扫描回初始态。
  - 默认勾选:可再生勾、用户数据不勾、未确认归属不勾、应用本体固定。
  - 执行:提交项恰为「本体 + 已勾选」;报告写入历史;`skipped` 项保留;本体被跳过则应用留列表。
  - 收敛:已卸载应用移出列表;返回列表后状态保持。
- 用例数不预设;门槛 = `Scripts/test.sh` 全绿 + L10n 键集 1:1(CI 已有)。

## 13. 顺带消费的一期 polish 项

- `CleanExecutor.onProgress` 接线:`UninstallViewModel` 将进度回投主线程,UI 在清理阶段显示确定进度;一期的清理流同步受益(同一接线)。
- `history.json` 增长上限:保留最近 200 条(写入时裁剪),避免二期写入频率上升后的无限增长。

## 14. 二期明确不做(YAGNI / 诚实边界)

1. 系统级残留与任何提权(三期候选;二期不引入管理员授权)。
2. `~/Library/Preferences`、`~/Library/Cookies` 的关联数据(门 1 整棵保护,见 §8.4)。
3. 非标准位置残留的发现(声明式位置表之外一律不扫,不做全盘启发式)。
4. Homebrew / CLI 工具、语言包管理器的包管理、App Store 授权与更新。
5. 卸载前后的 LaunchServices 数据库修复、登录项以外系统状态清理。
6. 每应用社区规则(路线 B)与全盘启发式扫描(路线 C)。

## 15. 验收标准(二期 Done 的定义)

1. `swift run` 下可列出 `/Applications` 与 `~/Applications` 的应用(排除 Apple 与非应用),详情页展示分级后的关联数据,`Preferences`/`Cookies` 不出现。
2. 卸载一个测试应用:本体与勾选数据进入废纸篓(可在废纸篓放回),报告数字与废纸篓项目数一致;用户数据分区默认未勾选。
3. 孤儿扫描在真机发现真实无主残留,高置信/未确认归属分组正确,默认勾选仅限「高置信 + 可再生」。
4. 全程无提权、无 `rm`/unlink;`CleanExecutor` 仍是唯一删除路径。
5. 四道门在二期路径上有自动化测试锚点(硬保护、排除清单、分级、trash-only),恶意/越界路径用例回归通过。
6. 中英双语、浅色/深色适配(结构上复用一期控件与语义色)。
7. `Scripts/test.sh` 全绿、CI 绿、L10n 键集 1:1。
8. README 与 QA 清单如实标注人工项与已知限制(§8.4、§14)。
