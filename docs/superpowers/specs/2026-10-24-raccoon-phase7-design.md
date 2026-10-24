# Raccoon 七期设计:网络流量显示

状态:已实施(人工 QA 完成,2026-10-24)
日期:2026-10-24 · 基于 `main` @ `3aa9e4f`(六期已合入,375 用例)

## 1. 目标与范围

网络指标从「仅连通性」升级为「连通性 + 实时速率 + 累计使用量」:

| 位置 | 展示 |
| --- | --- |
| 菜单栏标签(网络指标) | `wifi ↓12.3K ↑999B`(iconAndValue 样式;速率未就绪时回退现有接口文案;iconOnly 不变) |
| 菜单栏面板网络卡 | 接口状态行 + `↓12.3 KB/s ↑1.2 KB/s` + 累计 `收 1.2 GB / 发 340 MB` |
| 五期监控页网络卡 | 由单行 StatusCard 升级为与其他卡一致的指标卡:接口状态 / ↓速率 ↑速率 / 累计收发 |

明确不做:流量阈值通知(YAGNI)、每进程流量、按 SSID/应用维度统计、历史曲线(网络暂不做 sparkline,与六期「内存/网络为数值摘要」限制一致——速率与累计即数值摘要)。

## 2. 数据口径

- **采集**:`sysctl(CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0)`,零权限;每接口 `if_data64` 的 `ifd_ibytes`/`ifd_obytes` 为自接口 up 以来的 64 位累计字节(活动监视器同款数据源)。不用 `getifaddrs(2)`:其 AF_LINK 条目的 `if_data` 计数器为 32 位(u_int32_t),单接口约 4 GiB 即回绕,撑不住「自开机以来累计」口径。
- **接口白名单**:仅统计名字以 `en` 开头的接口(Wi-Fi/以太网/USB 网卡/iPhone USB 共享皆为 `en*`)。天然排除 loopback(`lo0`)、VPN 隧道(`utun*`/`ipsec*`)、AirDrop 链路(`awdl0`/`llw0`)、热点(`ap1`)等。VPN 场景下即物理链路实际传输量,避免隧道双计。与活动监视器(全接口求和)数字可以有差,以本口径为准并在 QA 清单注明。
- **按接口名去重**:sysctl NET_RT_IFLIST2 下每接口恰一条 RTM_IFINFO2 消息,同名多族重复在采集层即不存在;按名去重仍保留为纯函数层的防御性约束(同名只取首条,防双计)。
- **差分与钳制**(纯函数):任一字节 delta < 0(接口重置、驱动重载)→ 该维度 delta 钳 0,速率照常出(累计维度如实反映计数器现状);`elapsed ≤ 0`(同拍/时钟回拨)→ 速率两维 nil,累计照常显示。
- **速率**:B/s = delta ÷ elapsed(秒,Double)。首个采样无前值 → 速率为 nil,累计照常显示。
- **累计口径**:自开机以来(接口计数器天然给出);重启归零,无需持久化(用户已拍定)。

## 3. 分层与模块改动

沿既有分层:MonitorKit 纯逻辑、AppCore 采集与 VM、MenuBarKit 菜单栏纯逻辑、Raccoon UI。MonitorKit 继续不含真实采集(与 `assembleNetworkStatus` 注释的口径一致)。

- **MonitorKit**(`NetworkMetrics.swift` 扩展或新增 `TrafficMetrics.swift`):
  - `NetworkTrafficCounters { rxBytes: Int64, txBytes: Int64 }`(Sendable+Equatable,显式 memberwise init,理由同 NetworkStatus)
  - `NetworkTraffic { receivedBytes: Int64, sentBytes: Int64, receivedBPS: Double?, sentBPS: Double? }`
  - 纯过滤:`assembleTrafficCounters(_ entries: [(name: String, rx: Int64, tx: Int64)]) -> NetworkTrafficCounters?` — 输入已摊平的接口条目(便于测试),内部做 `en` 前缀白名单 + 按名去重;无匹配接口 → nil
  - 纯差分:`assembleTraffic(current: NetworkTrafficCounters, previous: NetworkTrafficCounters, elapsedSeconds: TimeInterval) -> NetworkTraffic` — 输出累计(即 current)+ 双维速率;elapsed ≤ 0 → 速率两维 nil(累计仍出)
- **AppCore**:
  - `SystemSampling` 协议加 `func traffic() -> NetworkTrafficCounters?`,以 extension 默认实现返回 nil(五期所有既有测试假体零改动不破);`LiveSystemSampler` 覆盖真实实现(sysctl NET_RT_IFLIST2 遍历 + RTM_IFINFO2 消息解析 + sockaddr_dl 名字提取;系统调用失败或解析异常 → nil)
  - `MenuBarMonitorViewModel`(六期):refreshFast 每拍采样;私有 `previousCounters`/`previousAt` 差分记忆;`updateSnapshot(traffic:)`;首拍速率 nil
  - `MonitorViewModel`(五期):快循环(2s)同样接入;新增 `private(set) var traffic: NetworkTraffic?`
- **MenuBarKit**:
  - `MenuBarSnapshot` 加 `traffic: NetworkTraffic?`(默认 nil)
  - `MenuBarLabelFormatter` 新 case `.traffic(down: String, up: String)`:`.network` 指标下 `traffic != nil` 时优先产出短格式速率;traffic 为 nil 回退现有 `.network(status)` 行为
  - 短格式纯函数(1024 进制,与 `ByteCountStyle .file` 同口径):`< 1024 B/s` → `999B`(整数);`≥ 1024` → `1.0K`/`12.3K`/`1.2M`/`3.4G`(统一一位小数,单位单字符无空格;负值按 0 计)
- **Raccoon**:
  - 标签视图:`.traffic` 渲染 `↓{down} ↑{up}`;面板/监控页全格式速率 = `byteText(Int64(bps)) + "/s"`(复用现有 ByteCountFormatter,无新格式化代码);速率 nil → 复用「正在采集首个样本…」口径的新键(收发/速率共用)
  - 面板网络卡加速率行与累计行;监控页网络卡升级 MetricCard;`interfaceTitle`/`interfaceIcon` 继续承担状态行

## 4. 并发与生命周期

- 采样挂在两 VM 各自的快循环内(五期 2s、六期 5s 粒度),与内存/CPU 同拍,不新增循环。
- 失败隔离:`traffic()` 返回 nil → 本拍速率与累计都不更新(快照保留上次值,与「采集失败冻结」既有语义一致);不拖垮同拍其他指标。
- 差分基准仅在成功采样时前移(nil 不清基准),与 CPU tick 差分同语义。
- 无新锁:VM 全部 @MainActor 串行;`NetworkTrafficCounters`/`NetworkTraffic` 为值类型,跨域传递安全。

## 5. L10n

新增键(实施时定稿,en/zh 1:1,CI 强制):速率未就绪占位、面板「收/发」累计文案、监控页网络卡各行为文案。单位符号(`B`/`K`/`M`/`G`、`KB/s`、`%`)为通用符号不翻译;`↓`/`↑` 箭头通用。zh 全角标点惯例不变。

## 6. 测试计划(锚点)

- MonitorKit:白名单/去重(同名多族只计一次、非 en 前缀全排除、空输入 nil)、差分(首拍、正常推进、负 delta 钳 0、elapsed ≤ 0 速率 nil 而累计仍在)(约 10 用例)
- MenuBarKit:短格式边界(1023B/1024B/1023.9K/1024K、0、大数)、`.traffic` case 产出与 traffic nil 回退、snapshot 默认值(约 8 用例)
- AppCore:两 VM 各覆盖首拍速率 nil → 次拍出速率 → 失败冻结 → 假时钟回拨(约 8 用例);既有 375 用例零改动通过(SystemSampling 默认实现保证旧假体兼容)
- 测试只增不减:375 → 约 400;`Scripts/test.sh` 为唯一入口

## 7. 已知限制(实施后同步 README/QA 清单)

1. 口径为 `en*` 物理链路:与活动监视器(全接口)数字不同;VPN 下本口径不含隧道重复计数
2. 休眠唤醒后第一个速率样本跨了休眠时长,可能失真;下一拍恢复
3. 速率粒度 = 快循环间隔(监控页 2s、菜单栏 5s),非实时抖动级
4. 累计为「自开机以来」,重启归零(用户拍定);不做今日口径与持久化
5. 网络不做 sparkline(延续六期限制第 8 条口径)

## 8. 全局约束(沿承,不变)

零新增删除代码(`trashItem` 唯一实现)· 零第三方依赖 · tools-version 6.3 · L10n en/zh 1:1 · 本地化文案只在 Raccoon 层 · CLT-only(`@State`/`@Binding`/`@Environment` 手写展开)· 测试只经 `Scripts/test.sh` · 测试计数只增不减。
