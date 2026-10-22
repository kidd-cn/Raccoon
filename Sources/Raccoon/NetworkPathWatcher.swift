import Foundation
import Network
import MonitorKit

/// 事件驱动监听:`NWPathMonitor` 回调在后台队列,组装成 `NetworkStatus` 后
/// 切回主 actor 交给 VM。`cancel()` 后实例不可复用(Apple 文档),故每次 start 新建。
/// 锁保护 monitor 的创建/取消与跨队列可见性;类本身无隔离,可在 View init 中构造。
///
/// 监控页与菜单栏共用同一实现:两处都需要「路径变化 → 主 actor 回调」,
/// 复制两份会让取消/重建语义各自漂移。
final class NetworkPathWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.raccoon.monitor.network-path")
    private var monitor: NWPathMonitor?

    func start(onUpdate: @escaping @MainActor @Sendable (NetworkStatus) -> Void) {
        lock.lock()
        if monitor != nil {
            lock.unlock()
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        lock.unlock()

        monitor.pathUpdateHandler = { path in
            let status = assembleNetworkStatus(
                satisfied: path.status == .satisfied,
                isWiFi: path.usesInterfaceType(.wifi),
                isWired: path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in
                onUpdate(status)
            }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        let monitor = self.monitor
        self.monitor = nil
        lock.unlock()
        monitor?.cancel()
    }
}
