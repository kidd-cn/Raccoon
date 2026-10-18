# 四期设计:磁盘分析(Disk Analysis)

日期:2026-10-18
状态:已实施(待人工 QA)
前置:一期(规则扫描清理)、二期(应用卸载+残留清理)、三期(AI 工具清理)已合并

## 1. 背景与目标

本机实测盘点(2026-10-18,只读 `du`,无提权):

- home 总量 ≈ **61 GiB**;一级大头:`programs` 14.9G、`Library` 13.0G、`.hermes` 10.4G、`.workbuddy` 5.1G、`.cache` 2.4G、`Movies` 2.4G、`.claude` 2.1G、`.bun` 1.9G、`Downloads` 1.8G、`.codex` 1.5G、`.npm` 1.2G、`.agents` 1.05G、`.pyenv` 1.0G、`.local` 0.94G、`Documents` 0.64G。空间散落在大量工具状态目录与用户媒体中,没有全局视图很难定位。
- Terminal 级权限(无 Full Disk Access)即遇 **449 次**「Operation not permitted」,集中在 `~/Library` 内部子树——权限墙是常态,必须如实呈现而非静默。
- 全量 home `du` 为分钟级 → 扫描必须**异步 + 进度 + 可取消**。

目标:侧边栏「磁盘分析」占位转正。扫描用户主目录,聚合目录体量,以 **treemap + 列表**双视图呈现,支持点击钻取;对用户**显式勾选**的项,经既有 trash 通道移入废纸篓。分析本身只读、零删除。

**用户已确认的三项决策**:
1. 范围 = 默认扫 home;支持「选择文件夹…」对任意用户可读目录重扫。
2. 可删但保守:默认全不勾、逐项确认、只进废纸篓;硬保护与用户排除照常生效。
3. treemap 自研 squarified 布局 + SwiftUI Canvas 渲染,零新依赖。

## 2. 非目标(本期不做)

- 系统级 `/Library`、任何提权或 Full Disk Access 申请(继续顺延)。
- 实时监控、清理调度自动化(五期)。
- APFS purgeable/本地快照核算;文件类型着色与过滤;重复文件查找。
- 扫描 `~/.Trash` 自身(防自吞产出);外置卷(单卷 `-x` 语义)。

## 3. 关键决策

| # | 决策 | 结论 | 理由 |
| - | ---- | ---- | ---- |
| D1 | 扫描范围 | 默认 `~`;「选择文件夹…」可重扫任意用户可读目录 | 开箱即扫;工具状态目录长尾正是实测痛点 |
| D2 | 删除通道 | 逐项经 `TrashServicing.trash`(`FileManager.trashItem`,含 Finder 降级)→ 结果聚合为 `CleanReport` 追加共享 `JSONHistoryStore`;`CleanReport` 增加可选 `source: String?`(缺省 nil,旧记录解码不受影响),本期写 `"disk-analysis"` | 唯一删除实现不变(`TrashService.swift:21`);报告页/历史/「上次清理释放 X」自动复用 |
| D3 | treemap 实现 | 自研 squarified:纯函数 `(Rect, [Int64]) -> [Rect]`,SwiftUI Canvas 绘制;**只渲染当前层**,子项超出上限聚合为「其他 N 项」(上限 120 项或单项 <0.3%,由计划钉精确值) | 零依赖;布局算法纯函数可单测钉死;单层渲染天然控制复杂度 |
| D4 | 交互分工 | treemap 矩形点击=**下钻**,面包屑返回;**勾选只在列表**(大小降序);矩形不承担勾选 | 矩形多选易误触;列表是小目标好点与无障碍兜底 |
| D5 | 权限墙 | 遍历遇 denied 子树:计入已读到的体量,节点标「无权限(部分)」,并计入 skipped 口径如实显示 | 实测 449 次拒绝是常态;不静默、不假装扫全 |
| D6 | 模块边界 | 新 SPM target **DiskKit**(遍历聚合 + squarify,纯逻辑全可测);VM 进 AppCore;视图进 Raccoon | 沿用 ScanKit/CleanKit/UninstallKit 分层惯例;逻辑与 UI 分离可测 |
| D7 | 勾选门禁(递归) | 节点可勾选 = 自身路径未被 `isDenied` 拒绝 **且** 子树内不含任何受保护/已排除路径(DiskScanner 自底向上派生 `containsProtected` 标志,零额外遍历成本);**扫描根永不可勾选** | 防止「勾 `~/Library` 整体」绕过硬保护——一至三期引擎从不进入 denied 路径,此类提交本不可能发生,本期必须等价封堵 |
| D8 | 清理后就地更新 | 清理完成后树**就地更新**:已清节点移除、体量差值上溯全部祖先;skipped 节点保留并保持勾选;若被清节点是当前下钻目录或其面包屑祖先,视图回退至最近存活祖先;报告「返回列表」回到更新后的树 | 复用一/二期「移除非 skipped、保留 skipped、返回结果」口径;分钟级扫描不能强迫重扫 |

## 4. 总体架构

```
RootView(.diskAnalysis 转正,图标 chart.pie.fill)
 └─ DiskAnalysisHomeView(vm: DiskAnalysisViewModel)
     ├─ idle:说明 + 「开始扫描」+「选择文件夹…」
     ├─ scanning:进度(已扫描字节 + 当前目录)+ 取消
     └─ done:面包屑 + [treemap | 列表] 切分 + 底部「已选 N 项 · X」+「清理…」+ 确认弹窗
DiskKit:   DiskScanner(async 遍历、进度回调、可取消)、DiskNode 树、squarify 纯函数
AppCore:   DiskAnalysisViewModel(状态机、勾选门禁、删除编排、历史追加)
CleanKit:  TrashServicing / CleanReport(+source) / JSONHistoryStore(仅类型扩展,删除实现不动)
```

- `DiskNode`:path、name、sizeBytes、children、isDeniedTruncated、containsProtected(扫描期自底向上派生)。体量口径:512 字节**块占用**(与 `du` 一致,非 `st_size` 逻辑大小),不做硬链接去重。删除单元 = 用户勾选的**任意节点(文件或目录)**;**勾选集约束:同一祖先链上只允许勾选最上层节点**——勾选某目录后其后代自动禁勾(防双重删除与体量重复计数),由 VM 强制。
- 遍历规则:symlink 不跟随(防环);`.Trash` 剪枝;`ProtectionStore.isDenied` 路径**可入不可删**——只读遍历无害,删除被门禁拦下,节点标「受保护」;I/O denied 子树按 D5 如实计数。
- 扫描进行中删除入口禁用;取消扫描 = 丢弃部分结果、回 idle(如实、简单)。

## 5. UI 设计

- 空态:说明文案(「扫描磁盘占用,只读分析;清理需显式勾选并只进废纸篓」)+「开始扫描」+「选择文件夹…」。
- 扫描态:进度 = 已扫描字节数 + 当前目录路径(截断显示);「取消」按钮。
- 结果态:顶部面包屑(根 = 本次扫描根);treemap 默认视图,列表切换;矩形显示名称 + 人读体积,选中高亮;列表行含勾选框(受保护/排除项勾选禁用并标注)。
- 底部条与三期一致:「已选 N 项 · X」+「清理…」;确认弹窗逐项列出体积;清理后复用报告页并按 D8 就地更新树。报告页页头显示来源标注:`source == "disk-analysis"` 显示「磁盘分析」,其余(含旧记录 nil)**不显示**来源标注、不冒称;history.json 始终写入 source(机器可读)。
- L10n:新增键 en/zh 1:1,zh 值全角标点。

## 6. 安全与四道门映射

1. **硬保护**:`ProtectionStore.isDenied` 项节点可见,但不可勾选删除;且按 D7 **递归生效**——子树含任何受保护/排除内容的目录不可整目录勾选,扫描根永不可勾选。
2. **用户排除**:同上(isDenied 已含用户排除,递归门禁同样适用)。
3. **安全分级**:分析结果无「safe 默认勾」概念——**一律默认不勾 + 显式确认**,比规则库更保守。
4. **trash-only**:唯一删除实现仍是 `TrashService.swift:21` 的 `trashItem`;零 `unlink`/`removeItem` 实现代码;终验 grep 守卫沿用(测试夹具自清 temp 例外)。

附加:`.Trash` 不扫不列;symlink 不跟随;无提权、无 FDA 依赖。

## 7. 测试策略(TDD 锚点)

- **DiskKit**:squarify 性质测试(面积守恒、无重叠、纵横比上限、输入顺序稳定、退化输入);目录体量聚合正确性;`.Trash` 剪枝、symlink 不跟随、denied 子树计数;进度回调与取消。
- **AppCore**:VM 状态机(idle→scanning→done、取消回 idle);勾选门禁(受保护/排除项不可勾、祖先链只允许最上层节点、`containsProtected` 目录不可整目录勾选、扫描根不可勾);删除编排(mock `TrashServicing` 记录调用,不真删);清理后就地更新(节点移除、差值上溯、skipped 保持勾选、当前目录被清回退最近存活祖先);`CleanReport.source` 写入与旧记录解码兼容。
- **守卫**:unlink/removeItem 零实现 grep;L10n 键集 en/zh 1:1;`Scripts/test.sh` 全绿;测试数只增不减。

## 8. 验收标准(Done)

1. 侧边栏「磁盘分析」可用(占位组移除该 case);既有三页(清理/卸载/AI)不受影响。
2. 默认 home 扫描:进度可见、可取消;完成后 treemap + 列表双视图,可下钻/面包屑返回。
3. 权限墙如实:denied 节点有标识并计入 skipped 口径。
4. 删除流:默认全不勾;确认弹窗逐项;只进废纸篓;报告与历史如实(报告页来源标注「磁盘分析」+ history.json 含 `"source":"disk-analysis"`);受保护与排除项不可勾,含受保护后代的目录不可整目录勾选。
5. 零新依赖;`Scripts/test.sh` 全绿;L10n 1:1;CI 推送后实测绿。
6. README(功能/路线图/已知限制)与四期 QA 清单如实更新,人工项不预标绿。

## 9. 已知限制

- 无 FDA 时 `~/Library` 大量子树不可读,体量偏小且如实显示(实测 449 次拒绝)。
- 体量口径为 `du` 同款 512 字节块占用(非 Finder「显示简介」的逻辑大小),小文件森林场景两者差异明显;未做硬链接去重。
- treemap 为单层聚合视图,极小子树需下钻或用列表查看。
- 大目录(如 `~/programs` 内 node_modules 森林)首次扫描为分钟级,进度与取消是缓解而非消除。
- 外置卷、`~/.Trash` 不在本期范围。
