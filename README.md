# Raccoon · 浣熊清理 🦝

![CI](https://github.com/kidd-cn/Raccoon/actions/workflows/ci.yml/badge.svg)

macOS 原生清理工具:扫描系统垃圾与应用缓存 → 分类统计 → 预览勾选 → 确认后移入废纸篓。开源免费(MIT),吉祥物是浣熊,对标开源清理工具 Mole 的完整功能集,分六期实现。

- **macOS 原生**:Swift 6 + SwiftUI,纯系统控件,自动浅色/深色模式,零第三方依赖
- **中英双语**:简体中文 / English,跟随系统语言
- **核心价值主张:安全**。文件删除只进废纸篓;本地快照经系统 `tmutil` 回收(见谨慎项)、默认只勾选可再生内容、多层保护机制兜底

## 当前功能(一期 + 二期 + 三期 + 四期 + 五期 + 六期 + 七期)

- **五类规则扫描**:系统垃圾 / 开发工具缓存 / 应用缓存 / 谨慎清理项 / AI 工具,内置 43 条声明式规则(`rules.json`);AI 类规则只在「AI 清理」入口出现,主清理页绝不显示
- **实时扫描进度**:逐规则进度反馈,已发现条数与字节量实时跳动,可随时取消(取消即丢弃本轮结果)
- **分类卡片与明细**:按类别汇总大小/项数;明细列表按大小降序,含应用图标、路径、大小、状态标签
- **勾选与清理流**:全选/全不选/取消谨慎项;底部常驻「已选 N 项 · X GB」;确认弹窗(cautious 项单独分区、运行中应用黄色警告)→「移入废纸篓」→ 完成报告(释放量、成功/跳过计数与原因);报告页可「返回列表」继续处理剩余项(已清理项离开列表,未清理项保留,无需重扫)
- **谨慎项处理**:iOS 设备备份、旧 macOS 安装器、本地 Time Machine 快照(`tmutil-thin`),一律默认不勾选、橙色标识、单独确认
- **用户排除清单**:设置页管理,排除路径永不扫描、永不删除,持久化保存
- **清理历史**:记录于 `~/Library/Application Support/Raccoon/history.json`,主页回显「上次清理释放 X」
- **应用卸载**:应用本体与关联数据一起预览,默认只勾精确归属的可再生数据;本体固定包含,运行中应用有黄色提示
- **孤儿残留**:扫描已卸载应用留在 `~/Library` 已知位置的数据,按高置信/未确认归属分组;未确认项默认不勾选
- **AI 清理**:侧边栏独立入口,扫描 AI 工具(Claude / Claude Code / Cursor / Codex / Ollama / HuggingFace / ChatGPT)的可再生内容——缓存、日志、可重新下载的运行时与模型缓存;结果按工具分组、组内大小降序;只列可再生内容,会话/技能等个人数据永不列出;模型与运行时属谨慎项(默认不勾、单独确认)
- **磁盘分析**:侧边栏「磁盘分析」入口,默认扫描家目录(可「选择文件夹…」重扫任意用户可读目录);treemap 与列表双视图,treemap 点击下钻、面包屑返回;勾选只在列表,递归门禁(受保护/排除项不可勾、含受保护后代的目录不可整目录勾、扫描根永不可勾);默认全不勾、确认弹窗逐项;清理只进废纸篓,复用既有报告与历史,报告页来源标注「磁盘分析」
- **状态监控**:侧边栏「状态监控」入口,只读仪表盘展示五类指标——系统盘大卡(可用/总量条形与 purgeable 提示,其他卷小卡)、内存(已用/压缩/联动/可清除)、CPU(user/system/idle 与 60 点 sparkline)、电池(充电中/使用电池/外接电源)与网络(Wi-Fi/有线/其他/离线);CPU/内存 2s、磁盘/电池 30s 轮询,网络事件驱动,窗口切后台或离开页面即暂停;单个采集器失败只让该卡显示「暂不可用」,不拖垮整页
- **系统优化**:监控页按当前状态给出建议卡——磁盘空间紧张、本地快照可回收、开机自启项待审查、崩溃报告可清理,点击直达磁盘分析/清理/启动项管理(无命中时整区隐藏);用户级启动项管理(`~/Library/LaunchAgents`)支持逐项确认后移入废纸篓、页内排除(受保护项照常列出但禁用按钮置灰),系统级 `/Library/LaunchAgents`、`/Library/LaunchDaemons` 只读展示;禁用记入清理历史(`source: "launch-items"`),需要恢复时从废纸篓放回
- **菜单栏监控仪**:菜单栏常驻只读监控——四选一指标(磁盘/内存/CPU/网络)以图标或图标+数值形式显示,选择与样式持久化;下拉面板含五类指标卡(CPU sparkline)与快捷入口(主窗口各模块、设置、退出),每次打开即时刷新;开机自启经 `SMAppService` 注册(免 root,系统设置可见,需批准状态有说明);阈值通知(低磁盘 <10% 或 <10 GiB、高内存超阈值默认 85%)按类 6 小时至多一次,冷却时间戳持久化、重启不重置,通知只报空间/比例、不含路径文件名。**只读监控 + 导航,不携带任何清理动作**——一切删除仍须进入主窗口,走四道门与确认流
- **网络流量显示**:网络指标从「仅连通性」升级为「连通性 + 实时速率 + 累计使用量」——菜单栏网络标签(「图标 + 数值」样式)显示 ↓/↑ 短格式速率(未就绪回退接口文案);菜单栏面板与状态监控页网络卡展示 ↓/↑ 速率与「收/发」累计(自开机以来,重启归零);数据源为 `sysctl` 接口字节计数(活动监视器同款),仅统计 `en*` 物理链路(loopback/VPN 隧道/AirDrop 链路等天然排除,VPN 下不双计);速率为快循环差分(监控页 2s、菜单栏 5s 粒度),与活动监视器(全接口求和)数字可有口径差

## 安全设计:四道门

删除类工具的第一要务是不删错东西。Raccoon 的四道安全门按纵深防御排列,前两道在引擎层,规则文件写错也拦得住:

| 门 | 机制         | 说明                                                                                                                                                      |
| - | ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | **内置硬保护**  | 用户内容目录(`~/Desktop`、`~/Documents`、`~/Downloads` 等)与 `~/Library` 关键子目录(Mail、Keychains、Preferences 等)按路径组件级前缀匹配保护,命中即拒绝加载、拒绝展示、删除前再校验一次。**规则可以写错,引擎不许删错。** |
| 2 | **用户排除清单** | 设置页添加的路径在扫描阶段即被过滤,结果中根本不出现                                                                                                                              |
| 3 | **安全分级**   | `safe` 规则默认勾选;`cautious` 规则默认不勾选、橙色标识、确认弹窗单独分区;运行中应用的缓存项标黄「应用运行中」并默认不勾选                                                                                 |
| 4 | **只进废纸篓**  | 文件删除动作唯一实现是 `FileManager.trashItem`,绝不 unlink、绝不抹除;唯一例外是本地快照清理(`tmutil-thin`),由系统 `tmutil deletelocalsnapshots` 执行、不可经废纸篓恢复——故列为 cautious 单独确认;磁盘分析入口同样只进废纸篓、复用该唯一删除实现          |

配套保障:规则根作用域白名单(必须位于用户主目录内,唯一例外是 `/Applications` 下的 macOS 安装器)、符号链接解析前后双形态校验(别名指进保护根或逃出主目录均整条拒绝)、单条规则校验失败仅拒绝该条并记录,绝不静默放行。

已知限制:`~/Library/Preferences` 与 `~/Library/Cookies` 因一期硬保护整棵覆盖,至今各入口均不列出;系统级 `/Library` 残留与任何提权操作继续顺延。三期(AI 清理)已知限制:

- 仅覆盖规则表所列工具(Claude、Claude Code、Cursor、Codex、Ollama、HuggingFace、ChatGPT);VS Code Copilot、Windsurf、Zed、LM Studio 等后续按需加规则即扩,本期不含
- 大体积用户数据(会话、技能、agent 工作数据)**有意不列出**;想回收 `~/.claude/skills`、`Cursor/User` 等空间需用户自行处理
- `ai.chatgpt-cache` 为标准路径,未在本机实测,缺失即零命中(无害)
- 运行中工具的缓存项可能因文件锁被跳过,按 skipped 如实报告
- `anysphere.cursor-agent-worker`(3.0G)无法确证可再生,本期不列;后续若确证可再评估

四期(磁盘分析)已知限制:

- 无 FDA 时 `~/Library` 大量子树不可读,体量偏小且如实显示(实测 449 次拒绝)。
- 体量口径为 `du` 同款 512 字节块占用(非 Finder「显示简介」的逻辑大小),小文件森林场景两者差异明显;未做硬链接去重。
- treemap 为单层聚合视图,极小子树需下钻或用列表查看。
- 大目录(如 `~/programs` 内 node_modules 森林)首次扫描为分钟级,进度与取消是缓解而非消除。
- 外置卷、`~/.Trash` 不在本期范围。

五期(状态监控 + 系统优化)已知限制:

- App Store 式会话登录项无法免 root 列举,不展示;启动项管理只覆盖用户级 `~/Library/LaunchAgents`
- 系统级 `/Library/LaunchAgents`、`/Library/LaunchDaemons` 只读,修改需用户自行处理
- 不展示 SSID;网络状态只表示连通性与接口类型(macOS 14+ 获取 SSID 需定位权限)
- CPU sparkline 首个轮询周期为空(无 tick 差值);磁盘/电池数据 30s 才刷新一次
- 内存「已用」为 Mach 统计口径,与活动监视器「内存压力」不一一对应

六期(菜单栏工具集)已知限制:

- 菜单栏文字受系统可用宽度限制,长数值可能被截断;可切「仅图标」样式保住图标
- 应用未运行时无法采样或发通知,需开启开机自启才能常驻;自启注册可能要求用户在「系统设置 → 通用 → 登录项」手动批准
- 菜单栏采样独立节奏:CPU/内存 5s、磁盘/电池 30s;通知只在 30s 慢循环评估,阈值触发最长延迟 30s(内存 Mach 口径同五期既有条目,不重复列出)
- 下拉面板曲线仅 CPU sparkline(60 点环形历史);内存/网络为数值摘要,无曲线(七期网络新增的速率与累计仍属数值摘要,网络不做 sparkline)
- 不做仅菜单栏模式(未启用 `LSUIElement`),退出主窗口后 Dock 图标仍在

七期(网络流量显示)已知限制:

- 口径为 `en*` 物理链路:与活动监视器(全接口求和)数字不同;VPN 下本口径不含隧道重复计数
- 休眠唤醒后第一个速率样本跨了休眠时长,可能失真;下一拍恢复
- 速率粒度 = 快循环间隔(监控页 2s、菜单栏 5s),非实时抖动级
- 累计为「自开机以来」,重启归零;不做今日口径与持久化

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
| `tool`        | 否     | 工具标识;`category = ai` 时必填且非空(AI 清理页按它分组),由内置规则测试 `aiRulesHaveNonEmptyTool` 强制 |
| `safety`      | 是     | `safe`(默认勾选)/ `cautious`(默认不勾选、单独确认)       |
| `action`      | 否     | `trash`(默认)或 `tmutil-thin`(本地快照专用)         |
| `path`        | 是     | 支持 `~` 展开;必须是具体目录,根不支持 glob                |
| `include`     | 否     | 文件名 glob 白名单(如 `[".DS_Store"]`),空 = 目录全部内容 |
| `exclude`     | 否     | 相对 glob 排除                                 |
| `description` | 否(推荐) | `zh-Hans` 与 `en` 双语说明,删了什么、有什么后果           |

内置规则由测试强制双语——`bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions` 要求每条含 `zh-Hans` 与 `en` description,PR 缺失会挂测试;提交前跑 `Scripts/test.sh` 确认。`tool` 字段另有三道内置规则测试门:`aiRulesHaveNonEmptyTool`(`category=ai` 必带非空 `tool`)、`aiRuleToolsAreKnownValues`(取值须在已知白名单内,新工具须先补 `canonicalOrder` 与 `ai.tool.*` 双语键)、`noRuleToolUsesReservedOtherId`(`other` 为「其他」组保留 id)。

### 校验规则(加载时逐条执行,以 `Sources/ScanKit/RuleStore.swift` 为准)

- `version` 必须为 `1`,否则整体拒绝
- 单条规则校验失败只拒绝该条(进 `rejected` 列表并记录原因),其余合法规则照常加载,绝不静默
- `category == "cautious"` 时 `safety` 必须为 `cautious`;`action == "tmutil-thin"` 仅允许 `safety == "cautious"` 的规则使用
- **规则根必须位于用户主目录 `~/` 内**(作用域白名单);唯一例外:`/Applications` 下精确匹配 `Install macOS *.app` 的安装器规则(`include` glob 形式)
- 符号链接别名按解析前后双形态校验:别名指进硬保护根、或解析后逃出主目录,整条拒绝
- 规则根与硬保护根冲突(含组件级前缀判断)整条拒绝;多条 trash 规则根路径重叠时产生告警

### 规则目标原则

**只指向可再生内容**(缓存、日志、编译产物、可重新下载的包缓存)。凡含用户数据的目录(如微信容器整体、`Application Support` 整体)永不作为规则根——微信缓存精确到 `…/Containers/com.tencent.xinWeChat/Data/Library/Caches`,聊天记录不在其内。

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
