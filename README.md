# Raccoon · 浣熊清理 🦝

macOS 原生清理工具:扫描系统垃圾与应用缓存 → 分类统计 → 预览勾选 → 确认后移入废纸篓。开源免费(MIT),吉祥物是浣熊,对标开源清理工具 Mole 的完整功能集,分六期实现。

- **macOS 原生**:Swift 6 + SwiftUI,纯系统控件,自动浅色/深色模式,零第三方依赖
- **中英双语**:简体中文 / English,跟随系统语言
- **核心价值主张:安全**。文件删除只进废纸篓;本地快照经系统 `tmutil` 回收(见谨慎项)、默认只勾选可再生内容、多层保护机制兜底

## 当前功能(一期)

- **四类规则扫描**:系统垃圾 / 开发工具缓存 / 应用缓存 / 谨慎清理项,内置 27 条声明式规则(`rules.json`)
- **实时扫描进度**:逐规则进度反馈,已发现条数与字节量实时跳动,可随时取消(取消即丢弃本轮结果)
- **分类卡片与明细**:按类别汇总大小/项数;明细列表按大小降序,含应用图标、路径、大小、状态标签
- **勾选与清理流**:全选/全不选/取消谨慎项;底部常驻「已选 N 项 · X GB」;确认弹窗(cautious 项单独分区、运行中应用黄色警告)→「移入废纸篓」→ 完成报告(释放量、成功/跳过计数与原因)
- **谨慎项处理**:iOS 设备备份、旧 macOS 安装器、本地 Time Machine 快照(`tmutil-thin`),一律默认不勾选、橙色标识、单独确认
- **用户排除清单**:设置页管理,排除路径永不扫描、永不删除,持久化保存
- **清理历史**:记录于 `~/Library/Application Support/Raccoon/history.json`,主页回显「上次清理释放 X」

## 安全设计:四道门

删除类工具的第一要务是不删错东西。Raccoon 的四道安全门按纵深防御排列,前两道在引擎层,规则文件写错也拦得住:

| 门 | 机制 | 说明 |
| -- | ---- | ---- |
| 1 | **内置硬保护** | 用户内容目录(`~/Desktop`、`~/Documents`、`~/Downloads` 等)与 `~/Library` 关键子目录(Mail、Keychains、Preferences 等)按路径组件级前缀匹配保护,命中即拒绝加载、拒绝展示、删除前再校验一次。**规则可以写错,引擎不许删错。** |
| 2 | **用户排除清单** | 设置页添加的路径在扫描阶段即被过滤,结果中根本不出现 |
| 3 | **安全分级** | `safe` 规则默认勾选;`cautious` 规则默认不勾选、橙色标识、确认弹窗单独分区;运行中应用的缓存项标黄「应用运行中」并默认不勾选 |
| 4 | **只进废纸篓** | 文件删除动作唯一实现是 `FileManager.trashItem`,绝不 unlink、绝不抹除;唯一例外是本地快照清理(`tmutil-thin`),由系统 `tmutil deletelocalsnapshots` 执行、不可经废纸篓恢复——故列为 cautious 单独确认 |

配套保障:规则根作用域白名单(必须位于用户主目录内,唯一例外是 `/Applications` 下的 macOS 安装器)、符号链接解析前后双形态校验(别名指进保护根或逃出主目录均整条拒绝)、单条规则校验失败仅拒绝该条并记录,绝不静默放行。

## 构建与运行

依赖:macOS 14+,Swift 6 工具链(仅 Command Line Tools 即可,无需完整 Xcode)。

```bash
swift build            # 构建
Scripts/test.sh        # 全量测试(76 用例)——唯一合法测试入口,勿直接 swift test
swift run              # 运行应用(开发模式)
Scripts/bundle-app.sh  # 组装 Raccoon.app(adhoc 签名,输出到 build/)
```

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

| 字段 | 必填 | 说明 |
| ---- | ---- | ---- |
| `id` | 是 | 全局唯一,重复即整条拒绝 |
| `category` | 是 | `system` / `dev` / `apps` / `cautious` |
| `safety` | 是 | `safe`(默认勾选)/ `cautious`(默认不勾选、单独确认) |
| `action` | 否 | `trash`(默认)或 `tmutil-thin`(本地快照专用) |
| `path` | 是 | 支持 `~` 展开;必须是具体目录,根不支持 glob |
| `include` | 否 | 文件名 glob 白名单(如 `[".DS_Store"]`),空 = 目录全部内容 |
| `exclude` | 否 | 相对 glob 排除 |
| `description` | 否(推荐) | `zh-Hans` 与 `en` 双语说明,删了什么、有什么后果 |

内置规则由测试强制双语——`bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions` 要求每条含 `zh-Hans` 与 `en` description,PR 缺失会挂测试;提交前跑 `Scripts/test.sh` 确认。

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

| 阶段 | 内容 | 状态 |
| ---- | ---- | ---- |
| 一期 | 应用骨架 + 核心清理 | ✅ 完成 |
| 二期 | 应用卸载 + 残留清理 | 规划 |
| 三期 | AI 工具清理(Claude/Cursor/Ollama 等) | 规划 |
| 四期 | 磁盘分析(treemap) | 规划 |
| 五期 | 状态监控 + 系统优化 | 规划 |
| 六期 | 菜单栏工具集 | 规划 |

后续每期独立走 spec → 计划 → 实现 流程;一期的架构(侧边栏骨架、规则库、ScanKit/CleanKit 拆分)为后续所有期次提供地基。

## 许可证

[MIT](LICENSE) © 2026 Raccoon contributors
