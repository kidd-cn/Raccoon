import Foundation

/// 磁盘树节点:一次子树聚合的结果。体量口径 = 文件块占用(fileAllocSize),
/// 目录自身块不计——treemap 与列表两处视图共用同一口径,避免「数字对不上」。
public struct DiskNode: Sendable, Equatable {
    /// 绝对路径
    public let path: String
    /// 最后一段;根为路径最后一段
    public let name: String
    /// 子树文件块占用合计;文件 = 自身 fileAllocSize
    public let sizeBytes: Int64
    public let isDirectory: Bool
    /// 文件为 []
    public var children: [DiskNode]
    /// 遍历该目录时遇 I/O 权限错误:体量是不完整的,须如实展示而非静默缩水
    public let isDeniedTruncated: Bool
    /// 自身或任一后代 isDenied(保护根/用户排除):自底向上派生,用于 UI 门禁
    public let containsProtected: Bool

    public init(path: String, name: String, sizeBytes: Int64, isDirectory: Bool,
                children: [DiskNode] = [], isDeniedTruncated: Bool = false,
                containsProtected: Bool = false) {
        self.path = path
        self.name = name
        self.sizeBytes = sizeBytes
        self.isDirectory = isDirectory
        self.children = children
        self.isDeniedTruncated = isDeniedTruncated
        self.containsProtected = containsProtected
    }
}

/// 扫描进度快照:bytesScanned / deniedCount 均单调不减,可直接驱动进度条。
public struct DiskScanProgress: Sendable, Equatable {
    public let bytesScanned: Int64
    public let deniedCount: Int
    public let currentPath: String

    public init(bytesScanned: Int64, deniedCount: Int, currentPath: String) {
        self.bytesScanned = bytesScanned
        self.deniedCount = deniedCount
        self.currentPath = currentPath
    }
}

/// 扫描入口参数不合法(root 非绝对路径、不存在、非目录,或根无法打开)。
/// 刻意不按 CWD 相对解析——静默扫错目录比报错危险得多。
public enum DiskScanError: Error, Sendable {
    case invalidRoot(String)
}
