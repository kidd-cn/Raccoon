import Foundation

/// 递归累计目录内普通文件字节数;符号链接与不可读条目一律跳过(不跟随链接)。
/// 口径:逻辑大小(非磁盘占用);硬链接按条目累计,不做去重。
/// 根自身为普通文件时直接计入(枚举器对文件根返回 0 个条目)。
enum FileSize {
    static func bytes(at url: URL, fm: FileManager = .default) -> Int64 {
        if let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
           values.isSymbolicLink != true,
           values.isRegularFile == true {
            return Int64(values.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isSymbolicLink != true,
                values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
