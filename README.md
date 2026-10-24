# Raccoon · 浣熊清理 🦝

[English](README.en.md) · 简体中文

![CI](https://github.com/kidd-cn/Raccoon/actions/workflows/ci.yml/badge.svg)

macOS 原生清理工具:扫描系统垃圾与应用缓存 → 分类统计 → 预览勾选 → 确认后移入废纸篓。开源免费(MIT),吉祥物是浣熊,对标开源清理工具 Mole 的完整功能集,分多期迭代实现。

- **macOS 原生**:Swift 6 + SwiftUI,纯系统控件,零第三方依赖
- **中英双语**:简体中文 / English,跟随系统语言
- **核心价值主张:安全**。文件删除只进废纸篓、默认只勾可再生内容、四道安全门兜底

## 当前功能(一至七期)

- **五类规则扫描**:系统垃圾 / 开发工具缓存 / 应用缓存 / 谨慎清理项 / AI 工具,内置 43 条声明式规则(`rules.json`);逐规则实时进度,可随时取消
- **勾选与清理流**:分类卡片与明细(按大小降序);确认弹窗(cautious 项单独分区、运行中应用黄色警告)→「移入废纸篓」→ 完成报告;报告页可返回列表继续处理剩余项,无需重扫
- **谨慎项处理**:iOS 设备备份、旧 macOS 安装器、本地 Time Machine 快照——一律默认不勾、橙色标识、单独确认
- **用户排除清单**:排除路径永不扫描、永不删除,持久化保存
- **清理历史**:主页回显「上次清理释放 X」
- **应用卸载**:应用本体与关联数据一起预览;默认只勾精确归属的可再生数据,运行中应用有黄色提示
- **孤儿残留**:扫描已卸载应用留在 `~/Library` 已知位置的数据,按高置信/未确认分组,未确认项默认不勾
- **AI 清理**:扫描 AI 工具(Claude / Claude Code / Cursor / Codex / Ollama / HuggingFace / ChatGPT)的可再生内容——缓存、日志、可重新下载的运行时与模型缓存;会话、技能等个人数据永不列出
- **磁盘分析**:treemap 与列表双视图,点击下钻、面包屑返回;勾选只在列表、递归门禁;默认全不勾、确认弹窗逐项,清理只进废纸篓
- **状态监控**:系统盘/内存/CPU/电池/网络五类只读仪表盘;轮询随窗口前后台暂停;单个采集器失败只影响本卡
- **系统优化**:按当前状态给出建议卡(磁盘紧张、快照可回收、启动项待审查、崩溃报告可清理),直达对应模块;用户级启动项(`~/Library/LaunchAgents`)可逐项确认后移入废纸篓,系统级只读
- **菜单栏监控仪**:常驻只读监控——菜单栏四选一指标,下拉面板五类指标卡与快捷入口;开机自启经 `SMAppService` 注册;阈值通知每类 6 小时至多一次,只报空间/比例、不含路径
- **网络流量显示**:菜单栏标签、下拉面板与监控页网络卡展示 ↓/↑ 实时速率与自开机累计;数据为 `sysctl` 接口字节计数(活动监视器同款),仅 `en*` 物理链路,VPN 下不双计

## 安全设计:四道门

删除类工具的第一要务是不删错东西。四道门按纵深防御排列,前两道在引擎层,规则文件写错也拦得住:

| 门 | 机制         | 说明                                                                                                                                                      |
| - | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | **内置硬保护**  | 用户内容目录(`~/Desktop`、`~/Documents`、`~/Downloads` 等)与 `~/Library` 关键子目录(Mail、Keychains、Preferences 等)按路径组件级前缀匹配保护,命中即拒绝加载、拒绝展示、删除前再校验一次。**规则可以写错,引擎不许删错。** |
| 2 | **用户排除清单** | 设置页添加的路径在扫描阶段即被过滤,结果中根本不出现                                                                                                                              |
| 3 | **安全分级**   | `safe` 规则默认勾选;`cautious` 规则默认不勾选、橙色标识、确认弹窗单独分区;运行中应用的缓存项标黄「应用运行中」并默认不勾选                                                                                 |
| 4 | **只进废纸篓**  | 文件删除动作唯一实现是 `FileManager.trashItem`,绝不 unlink、绝不抹除;唯一例外是本地快照清理(`tmutil-thin`),由系统 `tmutil deletelocalsnapshots` 执行、不可经废纸篓恢复——故列为 cautious 单独确认;磁盘分析入口同样只进废纸篓、复用该唯一删除实现          |

配套保障:规则根作用域白名单(必须位于用户主目录内)、符号链接解析前后双形态校验、单条规则校验失败仅拒绝该条并记录,绝不静默放行。

## 已知限制(摘要)

- 无「完全磁盘访问」时,磁盘分析对 `~/Library` 部分子树不可读,体量如实偏小;体量口径为 512 字节块占用(`du` 同款),非 Finder 逻辑大小
- `~/Library/Preferences`、`~/Library/Cookies` 被一期硬保护整棵覆盖,各入口均不列出;系统级 `/Library` 残留与提权操作不在范围
- 启动项管理仅覆盖用户级 `~/Library/LaunchAgents`,系统级只读;App Store 式会话登录项无法免 root 列举
- 菜单栏监控在应用未运行时不采样、不通知;自启注册可能需在系统设置手动批准
- 网络速率口径为 `en*` 物理链路,与活动监视器(全接口求和)可有差异;累计自开机起算,重启归零
- 阈值通知有 6 小时冷却;不做仅菜单栏模式;内存为 Mach 统计口径,与活动监视器「内存压力」不一一对应

各期完整已知限制见 `docs/superpowers/` 下对应设计文档与 QA 清单。

## 构建与运行

依赖:macOS 14+,Swift 6.3+ 工具链(仅 Command Line Tools 即可,无需完整 Xcode);CI 在 GitHub macOS runner 上以 Xcode 工具链验证。

```bash
swift build            # 构建
Scripts/test.sh        # 全量测试(396 用例)——唯一合法测试入口,勿直接 swift test
swift run              # 运行应用(开发模式)
Scripts/bundle-app.sh  # 组装 Raccoon.app(adhoc 签名,输出到 build/)
```

CI:GitHub Actions(`macos-latest`)跑 `swift build` + `Scripts/test.sh` + L10n 键集一致性比对,见 `.github/workflows/ci.yml`。`Scripts/test.sh` 会按活动工具链自动决定是否加载 CLT 的测试宏插件库,本地与 CI 共用同一入口。

## 贡献清理规则

垃圾识别规则不写死在代码里,而是随 App 内置一份声明式 `rules.json`(`Sources/ScanKit/Resources/rules.json`),欢迎通过 PR 贡献规则。

### Schema(v1)

```json
{
  "version": 1,
  "rules": [
    {
      "id": "xcode.deriveddata",
      "category": "dev",
      "safety": "safe",
      "action": "trash",
      "path": "~/Library/Developer/Xcode/DerivedData",
      "include": [],
      "exclude": [],
      "description": {
        "zh-Hans": "Xcode 编译产物,删除后首次编译会变慢",
        "en": "Xcode build artifacts; first build after cleanup will be slower"
      }
    }
  ]
}
```

| 字段            | 必填    | 说明                                         |
| ------------- | ----- | ------------------------------------------ |
| `id`          | 是     | 全局唯一,重复即整条拒绝                               |
| `category`    | 是     | `system` / `dev` / `apps` / `cautious` / `ai` |
| `tool`        | 否     | 工具标识;`category = ai` 时必填且非空(AI 清理页按它分组)    |
| `safety`      | 是     | `safe`(默认勾选)/ `cautious`(默认不勾选、单独确认)       |
| `action`      | 否     | `trash`(默认)或 `tmutil-thin`(本地快照专用)         |
| `path`        | 是     | 支持 `~` 展开;必须是具体目录,根不支持 glob                |
| `include`     | 否     | 文件名 glob 白名单(如 `[".DS_Store"]`),空 = 目录全部内容 |
| `exclude`     | 否     | 相对 glob 排除                                 |
| `description` | 否(推荐) | `zh-Hans` 与 `en` 双语说明,删了什么、有什么后果           |

校验规则加载时逐条执行,以 `Sources/ScanKit/RuleStore.swift` 为准:`version` 必须为 `1`,否则整体拒绝;单条失败仅拒绝该条(进 `rejected` 列表并记录原因),绝不静默;**规则根必须位于用户主目录 `~/` 内**,唯一例外是 `/Applications` 下匹配 `Install macOS *.app` 的安装器规则;与硬保护根冲突整条拒绝。**规则只指向可再生内容**(缓存、日志、编译产物、可重新下载的包缓存),含用户数据的目录(如微信容器整体、`Application Support` 整体)永不作为规则根。内置规则由测试强制双语 `description`;`category = ai` 须带非空且在已知白名单内的 `tool`(测试门:`aiRulesHaveNonEmptyTool`、`aiRuleToolsAreKnownValues`、`noRuleToolUsesReservedOtherId`)。提交前跑 `Scripts/test.sh`。

## 路线图

| 阶段 | 内容                              | 状态   |
| -- | ------------------------------- | ---- |
| 一期 | 应用骨架 + 核心清理                     | ✅ 完成 |
| 二期 | 应用卸载 + 残留清理                     | ✅ 已实现(待人工 QA) |
| 三期 | AI 工具清理(Claude/Cursor/Ollama 等) | ✅ 已实现(待人工 QA) |
| 四期 | 磁盘分析(treemap)                   | ✅ 已实现(待人工 QA) |
| 五期 | 状态监控 + 系统优化                     | ✅ 已实现(待人工 QA) |
| 六期 | 菜单栏工具集                          | ✅ 已实现(人工 QA 完成) |
| 七期 | 网络流量显示                              | ✅ 已实现(人工 QA 完成)|

后续每期独立走 spec → 计划 → 实现 流程;一期的架构(侧边栏骨架、规则库、ScanKit/CleanKit 拆分)为后续所有期次提供地基。

## 许可证

[MIT](LICENSE) © 2026 Raccoon contributors
