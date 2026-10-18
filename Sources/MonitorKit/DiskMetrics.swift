import Foundation

/// 单卷信息快照:卷列表/存储条的展示单元,值语义、可跨并发域传递。
public struct VolumeInfo: Equatable, Sendable {
    /// 卷名,如 "Macintosh HD"
    public let name: String
    public let totalBytes: Int64
    /// 可用容量(urlResourceValues.volumeAvailableCapacityForImportantUsageKey 之外的口径由采集器决定,此处只承载)
    public let availableBytes: Int64
    /// 可清除空间:系统可自动释放的部分,展示层据此画「可清理」区段
    public let purgeableBytes: Int64
    /// 是否用户主卷(系统盘),UI 据此决定是否给出系统卷警示
    public let isSystemDisk: Bool

    public init(name: String, totalBytes: Int64, availableBytes: Int64,
                purgeableBytes: Int64, isSystemDisk: Bool) {
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.purgeableBytes = purgeableBytes
        self.isSystemDisk = isSystemDisk
    }
}

/// 纯函数组装。purgeable = max(0, importantUsageBytes - availableBytes);
/// isSystemDisk = (name == homeVolumeName)。
/// 真实 FileManager 采集不在本层——保持可无副作用测试。
public func assembleVolumeInfo(name: String, totalBytes: Int64, availableBytes: Int64,
                               importantUsageBytes: Int64, homeVolumeName: String) -> VolumeInfo {
    VolumeInfo(
        name: name,
        totalBytes: totalBytes,
        availableBytes: availableBytes,
        purgeableBytes: max(0, importantUsageBytes - availableBytes),
        isSystemDisk: name == homeVolumeName
    )
}
