import Foundation
import MonitorKit

func loc(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle.module, comment: "")
}

func loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: Bundle.module, comment: ""), arguments: args)
}

/// 字节人性化显示;Task 12 起被主页/明细/报告消费(基线阶段暂无调用方)。
func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// 0...100 整数百分比文案。先夹取再取整,与 MenuBarLabelFormatter 同口径;
/// 非有限值经 max/min 归零,不产生 Int(NaN) 陷阱。
/// 菜单栏标签/面板与五期监控页共用,避免各写各的四舍五入。
func percentText(_ value: Double) -> String {
    "\(Int(min(100, max(0, value.rounded()))))%"
}

/// 速率文本:无值(首拍/失败拍)显示采集占位;有值按既有 byteText 口径 + "/s"。
/// 差分层已钳 0 且结构上有限;NaN 经归零兜底,与 MenuBarLabelFormatter.shortBytesPerSecond 同口径;inf 若不设防会令 Int64 陷阱。
func rateText(_ bps: Double?) -> String {
    guard let bps else { return loc("monitor.network.pending") }
    return byteText(Int64(bps.isFinite ? max(0, bps) : 0)) + "/s"
}

/// 网络状态 → 标题。nil(尚未采集)显示「暂不可用」,离线显示「离线」——
/// 与五期监控页原私有实现的分支语义逐一对应,离线时不看接口标志(可能是陈旧缓存)。
func interfaceTitle(_ status: NetworkStatus?) -> String {
    guard let status else { return loc("monitor.unavailable") }
    guard status.online else { return loc("monitor.network.offline") }
    switch status.interface {
    case .wifi: return loc("monitor.network.wifi")
    case .wired: return loc("monitor.network.wired")
    case .other: return loc("monitor.network.other")
    }
}

/// 网络状态 → SF Symbol 名,分支语义与 interfaceTitle 一一对应。
func interfaceIcon(_ status: NetworkStatus?) -> String {
    guard let status else { return "network" }
    guard status.online else { return "wifi.slash" }
    switch status.interface {
    case .wifi: return "wifi"
    case .wired: return "cable.connector"
    case .other: return "network"
    }
}
