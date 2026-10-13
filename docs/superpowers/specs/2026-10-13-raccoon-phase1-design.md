# Raccoon(浣熊清理)一期设计文档

- 日期:2026-10-13
- 状态:已经用户确认的设计方案
- 范围:一期(应用骨架 + 核心清理)
- 参考:[Mole](https://mole.fit/zh/)(功能对标对象)

## 1. 项目概述

**Raccoon · 浣熊清理** 是一款 macOS 原生清理工具,开源免费(MIT),吉祥物为浣熊 🦝。对标 Mole 的完整功能集,分六期实现;一期交付应用骨架与核心清理能力:扫描系统垃圾与应用缓存 → 分类统计 → 预览勾选 → 确认后移入废纸篓。

核心价值主张:**安全**。所有删除只进废纸篓、默认只勾选可再生内容、多层保护机制兜底。

## 2. 分期路线图(总览)

| 阶段 | 内容                              | 状态  |
| -- | ------------------------------- | --- |
| 一期 | 应用骨架 + 核心清理(本文档)                | 设计中 |
| 二期 | 应用卸载 + 残留清理                     | 规划  |
| 三期 | AI 工具清理(Claude/Cursor/Ollama 等) | 规划  |
| 四期 | 磁盘分析(treemap)                   | 规划  |
| 五期 | 状态监控 + 系统优化                     | 规划  |
| 六期 | 菜单栏工具集                          | 规划  |

后续每期独立走 spec → 计划 → 实现 流程。一期的架构决策(侧边栏骨架、规则库、ScanKit/CleanKit 拆分)为后续所有期次提供地基。

## 3. 技术决策

| 决策项       | 选择                                                                    | 理由                                                     |
| --------- | --------------------------------------------------------------------- | ------------------------------------------------------ |
| 技术栈       | Swift 6 + SwiftUI                                                     | 文件扫描性能敏感;系统能力(MenuBarExtra、ServiceManagement)开箱即用;原生质感 |
| 最低系统      | macOS 14 Sonoma                                                       | SwiftUI API 成熟,覆盖绝大多数活跃设备                              |
| 项目结构      | SwiftPM 单包多 target:`Sources/Raccoon`(可执行)+ `AppCore` / `ScanKit` / `CleanKit`;`Scripts/bundle-app.sh` 组装 .app | 开发机仅有 Command Line Tools(无完整 Xcode),`swift build / test / run` 全流程 CLI 可用;target 间依赖显式声明,与多包解耦等价 |
| 第三方依赖     | 一期为零                                                                  | 全部使用系统框架                                               |
| 界面语言      | 简体中文 + English(`zh-Hans.lproj` / `en.lproj` 的 Localizable.strings)     | 开源项目基本要求;.lproj 结构对纯 SwiftPM 构建最稳妥 |
| 许可证       | MIT                                                                   |                                                        |
| Bundle ID | `com.raccooncleaner.Raccoon`                                          | 可调整                                                    |
| 视觉风格      | 原生极简:纯系统控件 + SF Symbols,自动浅色/深色模式                                     | 维护成本最低(用户已确认)                                          |
| 发布签名      | 一期本地开发用 adhoc;正式发布需 Developer ID 签名 + 公证(需要 Apple Developer 账号,发布前再定) | 开源免费,无授权/支付体系                                          |

## 4. 总体架构

四层结构,依赖方向自上而下,核心引擎层不 import SwiftUI:

```
界面层(SwiftUI)   AppShell(NavigationSplitView+路由) · 清理主页 · 明细列表页 · 设置页
状态层(@Observable) ScanViewModel · CleanupFlow
核心引擎层(SPM)    ScanKit:RuleStore · ScanEngine · ProgressStream · SizeEstimator
                   CleanKit:ProtectionStore · TrashService · RunningAppDetector · CleanReporter
数据层             rules.json(App 内置) · UserDefaults + JSON(用户排除、清理历史)
```

- **AppShell**:侧边栏列出 清理(可用)、卸载 / AI 清理 / 磁盘分析 / 监控(禁用,标注"即将推出")。骨架从第一天就是六期的形状。
- **ScanViewModel**:发起扫描、消费进度事件流、聚合类别小计、管理勾选状态与"已选大小"联动。
- **CleanupFlow**:确认弹窗、逐项删除编排、结果报告。
- **ScanKit / CleanKit**:独立 target(SPM 依赖显式声明),纯 Foundation + Concurrency,不依赖任何 UI。

## 5. 规则库设计(核心资产)

垃圾识别规则不写死在代码里,而是随 App 内置一份声明式 `rules.json`。规则与代码分离,社区可通过 PR 贡献规则(对标 Mole 核实 824 款软件的方式)。

### 5.1 Schema(v1)

```json
{
  "version": 1,
  "rules": [
    {
      "id": "xcode.deriveddata",
      "category": "dev",              // system | dev | apps | cautious
      "safety": "safe",               // safe(默认勾选) | cautious(默认不勾选)
      "path": "~/Library/Developer/Xcode/DerivedData",
      "include": [],                  // 可选:文件名 glob 白名单(如 [".DS_Store"]);空 = 目录全部内容
      "exclude": [],                  // 可选:相对 glob 排除
      "action": "trash",              // trash(默认) | tmutil-thin(本地快照专用)
      "description": {
        "zh-Hans": "Xcode 编译产物,删除后首次编译会变慢",
        "en": "Xcode build artifacts; first build after cleanup will be slower"
      }
    }
  ]
}
```

约束:`path` 支持 `~` 展开与绝对路径;根必须是具体目录(不支持 glob 作根),目录内匹配用 `include`(文件名白名单)与 `exclude`;`category == "cautious"` 时 `safety` 必须为 `cautious`;`action == "tmutil-thin"` 仅允许 `cautious` 规则使用。规则根必须位于用户主目录 `~/` 内,唯一例外:`/Applications` 下精确匹配 `Install macOS *.app` 的安装器规则(见 5.3)。

### 5.2 校验(启动时 + 规则加载时)

- JSON 可解码、`version` 兼容
- id 全局唯一、category/safety/action 合法
- `path` 展开后**不得命中或包含任何硬保护根**(见 6.1),冲突规则整条拒绝加载并在日志记录
- 规则间根路径重叠检测:同一路径出现在多条规则时告警(允许,但去重展示)

### 5.3 首发内置规则清单(初版,实现期可增删)

**system(系统垃圾,safe)**

- `~/Library/Caches`(用户应用缓存总目录)
- `~/Library/Logs`、`~/Library/Logs/DiagnosticReports`(日志与用户级崩溃报告;系统级 `/Library` 在硬保护清单内,一期不扫)
- 用户主目录下的 `.DS_Store`(匹配型规则:`include: [".DS_Store"]`;遍历整个主目录耗时较长,安排为扫描中的低优先级任务,受条目上限约束)

**dev(开发工具缓存,safe 为主)**

- Xcode:`~/Library/Developer/Xcode/DerivedData`、`~/Library/Developer/Xcode/iOS DeviceSupport`
- Xcode Archives:`~/Library/Developer/Xcode/Archives`(**cautious**,含历史 ipa 归档)
- 模拟器:`~/Library/Developer/CoreSimulator/Devices`(**cautious**,模拟器数据)
- 包管理缓存:`~/.npm`、`~/Library/Caches/pip`、`~/.gradle/caches`、`~/Library/Caches/Homebrew`、`~/Library/Caches/org.swift.swiftpm`、`~/Library/Caches/CocoaPods`、`~/.cache`(含 uv/pip 新版缓存,**cautious**,该目录也被部分工具用作数据目录)

**apps(常见应用缓存,safe 为主)**

- 浏览器:Chrome / Edge / Brave / Firefox 的 `~/Library/Caches/<bundle>`(safe)
- Spotify、Slack、Discord、VS Code(`~/Library/Application Support/Code/Cache*` 与 `CachedData`)
- 微信:`~/Library/Containers/com.tencent.xinWeChat` 下缓存子目录(**cautious**,聊天记录同容器,必须精确到缓存子目录并默认不勾选)

**cautious(谨慎清理项,一律默认不勾选、橙色标识、单独确认)**

- iOS 设备备份:`~/Library/Application Support/MobileSync/Backup`
- 旧 macOS 安装器:`/Applications/Install macOS *.app`(唯一的非主目录规则根,见 5.1 例外)
- 本地 Time Machine 快照:`action: "tmutil-thin"`,经 `tmutil` 列出/清理,专用 cautious 处理器,不逐文件删除

规则目标原则:**只指向可再生内容**(缓存、日志、编译产物、可重新下载的包缓存)。凡含用户数据的目录(微信容器整体、Application Support 整体)永不作为规则根。

## 6. 安全机制(四道门)

### 6.1 内置硬保护(引擎层,规则无法绕过)

**作用域白名单**:规则根必须位于用户主目录内(唯一例外见 5.1),作用域之外的路径一律拒绝。

**硬保护根**(作用域内仍被拒绝的路径,**按路径组件级前缀匹配**,非字符串前缀——`~/Library` 不等于 `~/Library2`):命中即拒绝删除、拒绝展示:

- 用户内容目录:`~/Desktop`、`~/Documents`、`~/Downloads`、`~/Movies`、`~/Music`、`~/Pictures`、`~/Public`
- `~/Library` 下关键子目录:`Mail`、`Keychains`、`Preferences`、`Cookies`、`Accounts`、`Safari`、`Suggestions`
- 特意**不在**清单内的:`~/Library/Application Support/MobileSync`(iOS 备份是合法 cautious 目标,由 cautious 流程把关)、`~/Library/Caches`、`~/Library/Logs` 等可再生目录

语义:删除前对每一项再做一次硬保护校验(纵深防御)。**规则可以写错,引擎不许删错。**

### 6.2 用户排除清单

设置页管理,添加方式:文件选择器或拖入。生效于扫描阶段(结果中根本不出现),持久化在 UserDefaults。扫描记录中显示"被排除 N 项"。

### 6.3 安全级别与运行中应用

- `safe`:默认勾选
- `cautious`:默认不勾选,单独分组、橙色标识;确认弹窗中单独分区列出
- 运行中应用检测(`NSWorkspace.runningApplications`,按 bundle id 匹配路径段):其缓存项标黄"应用运行中"、默认不勾选,提示"建议退出后清理"

### 6.4 只进废纸篓

删除动作唯一实现:`FileManager.trashItem`。绝不 unlink、绝不抹除。用户反悔可从废纸篓恢复。其他用户目录/无权限目标 `trashItem` 失败 → 跳过并计入报告,不中断整批。

## 7. 核心流程

### 7.1 扫描管线

```
RuleStore 加载 rules.json → 校验(5.2) → 合法规则集
   ↓ 用户点击「开始扫描」
ScanEngine:每条合法规则展开为一个遍历任务 → TaskGroup 并行执行
   遍历约束:不跟随符号链接;权限不足目录跳过并计数;单规则条目上限 50 万,超出截断并标注"未完全扫描"
   ↓ 每个命中
ProtectionStore 过滤(硬保护 + 用户排除,命中即丢弃)
   ↓
归类聚合:category 小计、safety 标记、运行中检测、AppIdentity(路径中 bundle id → 应用名+图标,查不到则显示目录名)
   ↓ 进度事件(AsyncStream)
ScanViewModel:UI 实时显示已发现条数与字节量
```

`AppIdentity`:从命中路径提取 bundle id 形态的路径段,与运行中应用及 `/Applications` 已装应用匹配,取应用名与图标;匹配失败回退目录名。

### 7.2 清理流程(用户视角)

1. 主页:大扫描按钮 + 上次清理回显
2. 扫描中:进度指示 + 已发现大小实时跳动;可取消(取消 = 丢弃本轮结果)
3. 类别卡片:四类各自大小/项数;cautious 卡片橙色描边
4. 明细列表:按大小降序;行 = 勾选框 · 应用图标/名称 · 路径(中段截断)· 大小 · 状态标签;工具栏 全选/反选/取消全选;底部常驻 已选 N 项 · X GB + 「清理」按钮
5. 确认弹窗:总大小/项数;cautious 项单独分区;运行中应用项提示;确认按钮「移入废纸篓」
6. 执行:逐项 `trashItem`,进度反馈;单项失败跳过并记录原因(权限/被占用/已消失)
7. 完成报告:释放 X GB、成功 N 项、跳过 M 项(可展开原因);写入清理历史

清理历史:`~/Library/Application Support/Raccoon/history.json`(时间、各类别释放量、成败计数)。主页回显"上次清理释放 X GB"。

## 8. 错误处理原则

**任何异常都不中断、不丢数据。**

| 场景                 | 处理                                      |
| ------------------ | --------------------------------------- |
| 目录权限拒绝(TCC)        | 跳过并计数;失败面过大时,完成报告引导授予"完全磁盘访问权限"(深链系统设置) |
| 扫描后文件被应用自行删除       | `trashItem` 报不存在 → 计为"已消失",不算错误         |
| 用户中途取消扫描           | 丢弃本轮结果,状态回 idle                         |
| 清理中用户退出            | 逐项执行语义保证已完成项安全;无"半删状态",重扫即可             |
| 单规则条目超上限           | 截断 + "未完全扫描"标注                          |
| rules.json 损坏/校验失败 | 整体解码或版本不兼容 → 抛错并由调用方回退 bundle 内置权威副本;单条规则校验失败 → 仅拒绝该条并记录(`rejected` 列表),其余合法规则照常加载,绝不静默 |
| tmutil 不可用/失败      | 该 cautious 项标记不可用,不影响其他项                |

## 9. 测试策略

测试核心:**不能删错东西**。ScanKit/CleanKit 全部单测覆盖,UI 层 Preview + 手动 QA 清单。

- **ScanEngine**(fixture 临时目录树):规则命中、`~` 展开、`exclude` glob、符号链接不跟随、权限目录跳过、大小统计正确、条目上限截断、取消语义
- **RuleStore**:解码、校验规则逐条(重复 id / 非法 category / cautious 约束 / action 约束)、**路径与硬保护根冲突检测**
- **ProtectionStore**:硬保护前缀匹配边界用例(`~/Library` vs `~/Library2` 类陷阱)、用户排除合并
- **安全回归(最高优先)**:构造"规则故意指向硬保护路径"的恶意规则集,断言加载被拒、即便注入成功删除前校验仍拦截;断言用户内容目录在任何规则下都不会出现在结果中
- **TrashService**:protocol 抽象 + mock 单测(成功/失败/已消失三态);真实废纸篓行为列入手动集成验证清单
- **CleanReporter / 历史**:报告聚合、history.json 读写
- **ViewModel 状态机**:idle → scanning(progress) → completed / failed / cancelled;勾选联动已选大小;cautious 默认不勾选
- UI:SwiftUI Preview(浅色/深色、中英文)+ 手动 QA 清单(随实现计划给出)

## 10. 一期明确不做(YAGNI)

- 菜单栏(MenuBarExtra)、开机启动、定时/后台自动清理
- 规则在线更新(仅预留 RuleStore 加载接口)
- 系统维护(Quick Look 重建、Spotlight 重建等)→ 五期
- 应用卸载与残留 → 二期;AI 工具清理 → 三期;磁盘分析 → 四期;状态监控与系统优化 → 五期;菜单栏工具 → 六期
- 命令行版、Windows/Linux
- 授权、支付、试用机制(开源免费)

## 11. 验收标准(一期 Done 的定义)

1. 四类规则扫描全流程可用,非开发目录亦能安全运行
2. 全部安全机制生效,恶意规则回归测试通过
3. 清理仅产生废纸篓入项,可恢复
4. 中英文、浅色深色完整适配
5. ScanKit/CleanKit 单测覆盖核心路径,CI(macOS runner)绿
6. 在本机完成一次真实扫描+清理演练,人工核对结果无误
