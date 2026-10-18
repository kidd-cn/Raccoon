import Foundation

/// 网络接口归类:决定侧栏网络图标按哪种形态呈现。
public enum NetworkInterface: Equatable, Sendable {
    case wifi
    case wired
    case other
}

/// 网络状态快照:值语义、可跨并发域传递。
public struct NetworkStatus: Equatable, Sendable {
    public let online: Bool
    public let interface: NetworkInterface

    /// 显式 memberwise:合成的仅 internal,而 AppCore/Raccoon 是独立模块,
    /// 采样假体/预览需在 MonitorKit 之外直接构造快照。
    public init(online: Bool, interface: NetworkInterface) {
        self.online = online
        self.interface = interface
    }
}

/// 纯组装。!satisfied → online=false 且 interface 一律 .other——离线时接口
/// 标志可能来自陈旧缓存,不据此分类。在线时 wired 优先,两者皆非归 .other
/// (VPN/虚拟接口等,UI 以通用图标兜底)。真实 NWPathMonitor 采集不在本层。
public func assembleNetworkStatus(satisfied: Bool, isWiFi: Bool, isWired: Bool) -> NetworkStatus {
    guard satisfied else { return NetworkStatus(online: false, interface: .other) }
    let interface: NetworkInterface = isWired ? .wired : (isWiFi ? .wifi : .other)
    return NetworkStatus(online: true, interface: interface)
}
