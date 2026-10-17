import Foundation
import CleanKit

/// 二期作用域白名单:关联数据只允许落在「~/Library + 位置表目录」的直接子项。
/// 定位器本身只按位置表构造路径;本类型是执行前对提交通道的最后一道形状校验。
public struct LeftoverScope: Sendable {
    let library: String              // 已归一化、小写
    let allowedParents: Set<String>  // 已归一化、小写

    public init(home: URL) {
        let lib = ProtectionStore.normalize(home.appendingPathComponent("Library").path).lowercased()
        self.library = lib
        self.allowedParents = Set(LeftoverLocations.all.map {
            ProtectionStore.normalize("\(lib)/\($0.folder)").lowercased()
        })
    }

    public func isAllowed(_ path: String) -> Bool {
        let normalized = ProtectionStore.normalize(path).lowercased()
        guard normalized.hasPrefix(library + "/") else { return false }
        let parent = (normalized as NSString).deletingLastPathComponent
        return allowedParents.contains(parent)
    }
}
