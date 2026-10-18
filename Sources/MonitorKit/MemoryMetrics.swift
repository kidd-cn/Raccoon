import Foundation

/// 内存构成快照:内存压力条与构成明细的展示单元,值语义、可跨并发域传递。
public struct MemoryStats: Equatable, Sendable {
    /// 物理内存总量
    public let totalBytes: Int64
    /// 已用口径 = total - free - inactive - purgeable;外部页(压缩器等)计入 used
    public let usedBytes: Int64
    /// 压缩器承载的页(属外部页,是 used 的子集,展示层据此画「已压缩」区段)
    public let compressedBytes: Int64
    /// 联动器/wired 常驻页(不可换出,是 used 的子集)
    public let wiredBytes: Int64
    /// 可清除空间:内存压力上来时可被回收的部分
    public let purgeableFreeBytes: Int64
}

/// 纯函数组装。used = total - free - inactive - purgeable,负值夹到 0——
/// 各口径来自不同统计接口,错位时宁可显示 0 也不呈现负占用。
/// 入参为页计数 × 页大小换算后的字节;真实 host_statistics64 采集不在本层,
/// 保持可无副作用测试。
public func assembleMemoryStats(totalBytes: Int64, freeBytes: Int64, inactiveBytes: Int64,
                                purgeableBytes: Int64, wiredBytes: Int64, compressedBytes: Int64) -> MemoryStats {
    MemoryStats(
        totalBytes: totalBytes,
        usedBytes: max(0, totalBytes - freeBytes - inactiveBytes - purgeableBytes),
        compressedBytes: compressedBytes,
        wiredBytes: wiredBytes,
        purgeableFreeBytes: purgeableBytes
    )
}

/// 定长环形缓冲:监控历史曲线(内存压力/CPU 占用)只关心最近 N 个采样,
/// 溢出即弃最旧,不随运行时间无限增长。泛型刻意不约束 Sendable/Equatable,
/// 由使用方按承载类型自行决定并发与比较语义。
public struct SampleRing<T> {
    private let capacity: Int
    private var storage: [T] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// capacity ≤ 0 视为「不保留历史」,直接忽略写入。
    public mutating func append(_ value: T) {
        guard capacity > 0 else { return }
        storage.append(value)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// 最旧在前、最新在后,至多 capacity 个;返回副本,不暴露内部存储。
    public var values: [T] { storage }
}
