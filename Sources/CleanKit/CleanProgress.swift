import Foundation

/// 清理执行进度(已处理项 / 总项)。扫描页与卸载页共用同一形状,
/// 供 `CleanExecutor.onProgress` 回投主线程后驱动确定进度条。
public struct CleanProgress: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}
