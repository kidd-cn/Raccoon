import Foundation
import CleanKit

/// 二期作用域白名单:关联数据只允许落在「~/Library + 位置表目录」的直接子项。
/// 定位器本身只按位置表构造路径;本类型是执行前对提交通道的最后一道形状校验。
public struct LeftoverScope: Sendable {
    let library: String              // 已归一化、小写
    let resolvedLibrary: String      // ~/Library 解析符号链接后的归一化、小写形态
    let allowedParents: Set<String>  // 已归一化、小写

    public init(home: URL) {
        let libURL = home.appendingPathComponent("Library")
        let lib = ProtectionStore.normalize(libURL.path).lowercased()
        self.library = lib
        self.resolvedLibrary = ProtectionStore.normalize(
            libURL.resolvingSymlinksInPath().path).lowercased()
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

    /// 位置目录解析祖先符号链接后必须仍在 ~/Library 之内:否则 trash 会沿祖先链接
    /// 删到库外目标。只校验位置目录,不解析末端候选——末端自身是链接时 trash 的是
    /// 链接本身,安全。
    public func isLocationContained(_ directory: URL) -> Bool {
        let resolved = ProtectionStore.normalize(
            directory.resolvingSymlinksInPath().path).lowercased()
        return resolved == resolvedLibrary || resolved.hasPrefix(resolvedLibrary + "/")
    }

    /// 位置目录自身的符号链接会把槽位的分级带偏(如 Caches → Application Support):
    /// 解析后若落在位置表的某个目录上,取该目录所有位置中最严格的 safety
    /// (userData 优先于 regenerable);否则沿用槽位分级。
    /// 穿透扫描行为不变,只修正结果分级。
    public func effectiveSafety(for directory: URL, fallback: LeftoverSafety) -> LeftoverSafety {
        let resolved = ProtectionStore.normalize(
            directory.resolvingSymlinksInPath().path).lowercased()
        let prefix = resolvedLibrary + "/"
        guard resolved.hasPrefix(prefix) else { return fallback }
        let folder = String(resolved.dropFirst(prefix.count))
        // 只认位置表的一级目录;更深的解析目标不属于任何已知槽位。
        guard !folder.isEmpty, !folder.contains("/") else { return fallback }
        let matching = LeftoverLocations.all.filter { $0.folder.lowercased() == folder }
        guard !matching.isEmpty else { return fallback }
        return matching.contains { $0.safety == .userData } ? .userData : .regenerable
    }
}
