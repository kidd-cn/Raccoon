import Foundation

/// 网络流量计数快照:自开机以来累计收发字节数(各维独立、单调递增,
/// 接口重置/计数器清零时可能回退)。值语义、可跨并发域传递。
public struct NetworkTrafficCounters: Equatable, Sendable {
    public let rxBytes: Int64
    public let txBytes: Int64

    /// 显式 memberwise:合成的仅 internal,而 AppCore/Raccoon 是独立模块,
    /// 采样假体/预览需在 MonitorKit 之外直接构造(理由同 NetworkStatus)。
    public init(rxBytes: Int64, txBytes: Int64) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
    }
}

/// 一拍流量:两维累计 + 可选速率。速率为 nil 表示本拍不可信
/// (elapsed ≤ 0:同拍/时钟回拨),累计照出。
public struct NetworkTraffic: Equatable, Sendable {
    public let receivedBytes: Int64
    public let sentBytes: Int64
    public let receivedBPS: Double?
    public let sentBPS: Double?

    public init(receivedBytes: Int64, sentBytes: Int64, receivedBPS: Double?, sentBPS: Double?) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
        self.receivedBPS = receivedBPS
        self.sentBPS = sentBPS
    }
}

/// 纯组装:白名单累加接口计数条目。仅 `en*` 物理接口参与——
/// lo/utun/ipsec/awdl/llw/ap/bridge 等会与真实网卡双计(VPN 隧道、
/// 链路本地副本、桥接扇出),全部排除。同名接口只计首条:sysctl
/// NET_RT_IFLIST2 采集每接口恰一条 RTM_IFINFO2 消息,同名重复在
/// 现采集中并不出现;按名去重保留为纯函数层的防御性约束(采集层
/// 若给出同名条目,只计首条,累加即翻倍)。无任何匹配返回 nil。
/// 真实 sysctl NET_RT_IFLIST2 采集不在本层(见 AppCore LiveSystemSampler)。
public func assembleTrafficCounters(_ entries: [(name: String, rx: Int64, tx: Int64)]) -> NetworkTrafficCounters? {
    var seen = Set<String>()
    var rx: Int64 = 0
    var tx: Int64 = 0
    for e in entries where e.name.hasPrefix("en") {
        guard seen.insert(e.name).inserted else { continue }
        rx += e.rx
        tx += e.tx
    }
    guard !seen.isEmpty else { return nil }
    return NetworkTrafficCounters(rxBytes: rx, txBytes: tx)
}

/// 纯组装:两拍差分出速率。累计两维直接取 current;某维 delta < 0
/// (接口重置/计数器清零)该维速率钳 0,另一维照常;elapsed ≤ 0
/// (同拍/时钟回拨)速率双维 nil,累计照出。
public func assembleTraffic(current: NetworkTrafficCounters, previous: NetworkTrafficCounters, elapsedSeconds: TimeInterval) -> NetworkTraffic {
    let rxRate: Double?
    let txRate: Double?
    if elapsedSeconds <= 0 {
        rxRate = nil
        txRate = nil
    } else {
        let rxDelta = current.rxBytes - previous.rxBytes
        let txDelta = current.txBytes - previous.txBytes
        rxRate = Double(max(rxDelta, 0)) / elapsedSeconds
        txRate = Double(max(txDelta, 0)) / elapsedSeconds
    }
    return NetworkTraffic(
        receivedBytes: current.rxBytes,
        sentBytes: current.txBytes,
        receivedBPS: rxRate,
        sentBPS: txRate)
}
