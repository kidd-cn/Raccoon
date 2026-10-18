# Raccoon 四期 QA / 验收清单

> **诚实性声明**:本文档生成于无 GUI 自动化环境(实现子代理)。本环境无法进行人工目测与 GUI 交互,故每项明确标注「✅ 自动核验」或「⏳ 待人工」,**绝不将待人工项标成已验,也不把代码落位当成测试证据**。
>
> - **✅ 自动核验**:证据为真实运行的命令输出、测试名与文件位置,或明确标注的代码锚点;不包含任何 GUI 目测结论。
> - **⏳ 待人工**:需 GUI 交互或人眼判断,附操作步骤与预期,一律未预标绿。
>
> **实测基线(2026-10-18,分支 `feat/phase4`,HEAD `706cb26`)**:
>
> - `Scripts/test.sh` 全量 **231/231 绿**(三期基线 199 → 四期 231,只增不减,净增 32)。
> - 中英 L10n 各 **121** 键,键集 diff 为空(121:121 1:1)。
> - 终验安全 grep 符合期望:零 unlink/removeItem 实现,唯一删除实现仍为 `TrashService.swift:21` 的 `FileManager.trashItem`。
> - 本文档所有「✅」均以该次实测为准;命令输出逐条留存原文,无编造。

## 一、✅ 自动核验项(6 项)

### 1. 全量测试 231/231 绿 — ✅

```text
$ Scripts/test.sh > /tmp/t7b-full.log 2>&1; echo EXIT=$?
EXIT=0
```

`/tmp/t7b-full.log` 中 5 组结果行原文:

```text
✔ Test run with 66 tests in 6 suites passed after 0.061 seconds.
✔ Test run with 48 tests in 4 suites passed after 0.101 seconds.
✔ Test run with 14 tests in 2 suites passed after 0.192 seconds.
✔ Test run with 29 tests in 8 suites passed after 0.090 seconds.
✔ Test run with 74 tests in 7 suites passed after 0.250 seconds.
```

合计 66 + 48 + 14 + 29 + 74 = **231**,exit 0,无 skip、无 fail。

> 注:每行末尾的秒级计时为当次运行值,因机而异、不可精确复现;测试计数(231)与 exit(0)可复现。

### 2. 删除红线 grep:零 unlink/removeItem 实现,唯一 trashItem 实现 — ✅

```text
$ grep -rn "removeItem\|unlink" Sources/ --include='*.swift'
Sources/CleanKit/TrashService.swift:18:    /// 唯一删除动作:移入废纸篓。绝不 unlink。
# 命中 1 行,且为「绝不 unlink」注释,零实现调用 → 符合期望

$ grep -rn "trashItem" Sources/ --include='*.swift'
Sources/CleanKit/TrashService.swift:21:            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
Sources/CleanKit/TrashService.swift:25:            // /Applications 下 root/admin 归属的应用,直接 trashItem 会报权限不足;
Sources/AppCore/ScanViewModel.swift:34:    // (否则硬编码真实服务会对不存在的 /a 真调 trashItem → .vanished → trashedCount 断言必红)
# 命中 3 行:唯一实现为 TrashService.swift:21(FileManagerTrashService.trash 内的
# FileManager.trashItem);另两行(TrashService.swift:25、ScanViewModel.swift:34)均为注释,非实现调用
# → 符合期望「唯一实现」
```

结论:四期零新增删除路径,`FileManager.trashItem` 仍是唯一删除实现,与 spec §6.4「唯一删除实现仍是 TrashService.swift:21 的 trashItem;零 unlink/removeItem 实现代码」一致。

### 3. 工具链:Swift 6.3、零第三方依赖 — ✅

```text
$ grep -n "swift-tools-version" Package.swift
1:// swift-tools-version: 6.3

$ grep -rn "\.package(" Package.swift
(无输出,grep exit 1)
# → 零第三方依赖 → 符合期望
```

### 4. L10n 键集:121:121,diff 为空 — ✅

```text
$ diff <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/zh-Hans.lproj/Localizable.strings | sort) \
       <(grep -o '^"[^"]*"' Sources/Raccoon/Resources/en.lproj/Localizable.strings | sort)
(无输出,exit 0)
zh_keys=121
en_keys=121
```

### 5. swift build — ✅

```text
$ swift build 2>&1 | grep -E "error:|Build complete" | tail -3
Build complete! (2.35秒)
```

> 注:构建耗时因机而异;`Build complete` 与零 error 可复现。

### 6. 本分支四期提交序列 — ✅

```text
$ git log --oneline
706cb26 fix(Raccoon): 确认弹窗逐项列出已选节点与体积(与设计一致)
a9af7a8 feat(Raccoon): treemap 渲染——squarified 布局 Canvas 绘制、点击下钻、空态
4f73374 fix(AppCore): 磁盘分析按当前排除清单重建保护层;补排除新增回归测试;others 计数格式改 %ld
4998509 feat(Raccoon): 磁盘分析入口转正——phase 驱动主页、列表视图、面包屑、确认弹窗与报告来源标注(双语文案)
7ebec77 feat: 磁盘清理编排——CleanReport.source 透传、树就地更新(差值上溯/skipped 保留/面包屑回退)、历史入库
d042404 feat(AppCore): DiskAnalysisViewModel——扫描状态机、面包屑下钻、勾选门禁(根/受保护/祖先链)与其他项聚合
7a2362e test(DiskKit): 补并列权重按下标保序断言(契约稳定性条款)
59c7872 feat(DiskKit): squarified treemap 纯函数——面积守恒/无重叠/纵横比上限/稳定,hitTest 命中
f4c4a82 fix(DiskKit): 文件叶子节点 containsProtected 直评 isDenied(契约第 6 条补全);补文件级测试
32e7e98 feat(DiskKit): DiskScanner 遍历聚合——块占用口径、.Trash 剪枝、symlink 跳过、权限墙如实计数、containsProtected 派生、进度与取消
49a0350 docs(plan): 四期实施计划——磁盘分析 7 任务 TDD 拆解
03671c2 docs(spec): 四期设计——磁盘分析(只读盘点定预算,treemap 自研,递归勾选门禁)
```

## 二、⏳ 待人工项(13 项,一律未预标绿)

### A1. 真实家目录扫描与权限墙计数展示 — ⏳ 待人工

- [ ] 步骤:启动应用,进「磁盘分析」,点「开始扫描」。
- 预期:异步扫描有进度(已扫描字节 + 当前目录);完成后 treemap + 列表双视图;无 FDA 环境下 `~/Library` 大量子树显示「无权限(部分)」/受保护标识并计入 skipped 口径(如实呈现,不静默、不假装扫全)。

### A2. 选择文件夹重扫 — ⏳ 待人工

- [ ] 步骤:空态或完成态点「选择文件夹…」,挑一个用户可读目录(如 `~/Documents`)。
- 预期:重扫所选目录,面包屑根切换为该目录,结果只含该目录树;取消/再扫均回到正确状态。

### A3. 扫描中取消 — ⏳ 待人工

- [ ] 步骤:大目录(如 `~/programs`)扫描进行中点「取消」。
- 预期:扫描停止、回到 idle 空态,部分结果丢弃,不残留半成品状态;扫描中删除入口禁用。

### A4. treemap 点击下钻与面包屑 — ⏳ 待人工

- [ ] 步骤:结果态点 treemap 某矩形。
- 预期:下钻到该目录,treemap 重绘当前层;面包屑逐级回退到扫描根;极小矩形(其他 N 项)下钻后可见明细。

### A5. 列表勾选门禁(受保护/根不可选)— ⏳ 待人工

- [ ] 步骤:列表视图检查各节点勾选框。
- 预期:受保护/排除项勾选框禁用并标注;含受保护后代的目录不可整目录勾;扫描根永不可勾;祖先链上只允许勾最上层节点(勾目录后后代禁勾)。

### A6. 确认弹窗默认键为取消 — ⏳ 待人工

- [ ] 步骤:勾选若干项点「清理…」,观察确认弹窗。
- 预期:逐项列出体积;默认聚焦键为「取消」,回车/默认操作不触发删除;显式确认后才开始清理。

### A7. 仅废纸篓(到 Finder 核对、无 unlink 迹象)— ⏳ 待人工

- [ ] 步骤:清理一个小目录(自造可弃数据),完成后打开 Finder 废纸篓。
- 预期:被清项出现在废纸篓,可「放回原处」恢复;系统无 unlink 直删迹象(与自动核验项 2 的零 unlink grep 互相印证)。

### A8. skipped 项保持勾选 — ⏳ 待人工

- [ ] 步骤:制造文件锁(如 `chflags uchg` 目标子项)后清理。
- 预期:被锁项进 skipped,报告如实列出原因,该节点保留且保持勾选,无需重扫即可重试;完成后解锁恢复。

### A9. 清理后树就地更新与已选汇总 — ⏳ 待人工

- [ ] 步骤:清理部分项后观察结果树与底部条。
- 预期:已清节点从树移除、体量差值上溯全部祖先;底部「已选 N 项 · X」同步更新;若被清节点是当前下钻目录或其面包屑祖先,视图回退至最近存活祖先。

### A10. 报告来源标注「磁盘分析」与历史记录 — ⏳ 待人工

- [ ] 步骤:完成一次磁盘分析清理,查看报告页与主页历史。
- 预期:报告页头显示来源标注「磁盘分析」;主页「上次清理释放 X」回显;`~/Library/Application Support/Raccoon/history.json` 落条含 `"source":"disk-analysis"`。

### A11. 深浅色模式与窄窗口布局 — ⏳ 待人工

- [ ] 步骤:浅色/深色各过一遍(空态、扫描中、treemap/列表、确认弹窗、报告);拉窄窗口。
- 预期:双模式均无裸键、无截断/重叠/溢出;窄窗口下 treemap 与列表仍可操作、面包屑不溢出。

### A12. 退出重进后历史仍可读 — ⏳ 待人工

- [ ] 步骤:清理一次后退出应用,重新启动进入主页。
- 预期:历史记录仍可读,「上次清理释放 X」回显正确;含旧记录(nil source)的历史不显示来源标注、不报错。

### A13. vanished(清理前文件已被外部删除)— ⏳ 待人工

- [ ] 步骤:勾选某文件/目录后、点「清理」确认前,在 Finder/终端外部删除该路径(或等其自然消失),再确认清理。
- 预期:报告计入 vanished(不计入释放量、不算 trashed);对应节点从树中移除;无报错、无残留勾选;若被清节点是当前下钻目录或其面包屑祖先,视图回退至最近存活祖先。

## 已知限制

引用 spec §9 全部五条(README「已知限制」节已同步):

1. 无 FDA 时 `~/Library` 大量子树不可读,体量偏小且如实显示(实测 449 次拒绝)。
2. 体量口径为 `du` 同款 512 字节块占用(非 Finder「显示简介」的逻辑大小),小文件森林场景两者差异明显;未做硬链接去重。
3. treemap 为单层聚合视图,极小子树需下钻或用列表查看。
4. 大目录(如 `~/programs` 内 node_modules 森林)首次扫描为分钟级,进度与取消是缓解而非消除。
5. 外置卷、`~/.Trash` 不在本期范围。

沿承一至三期的限制不变:`~/Library/Preferences` 与 `~/Library/Cookies` 因硬保护不列出;系统级 `/Library` 残留与任何提权继续顺延。

## 统计

- **✅ 自动核验:6 项**(全量测试、删除红线 grep、工具链、L10n、swift build、提交序列)。
- **⏳ 待人工:13 项**(A1–A13),每项均为 `- [ ]` 未勾选,给出操作步骤与预期,无一预标绿。

**结论**:工程侧自动可核验面全部为绿(231/231、L10n 121:121、安全 grep 符合期望、swift build 通过);四期功能与交互的人工验收尚未执行,本文档不宣称任何未真机验证项为「满足」。
