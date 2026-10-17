import Foundation
import CleanKit

/// 按位置表为单个应用定位关联数据。每条结果都经过:
/// 存在性 → isDenied(硬保护+用户排除,原始与解析两种形态) → 作用域白名单 →
/// 精确父目录 → 去重;同字符串路径(大小写不敏感,与 ProtectionStore 口径一致)
/// 按位置 id 序第一条胜出。
public struct LeftoverLocator: LeftoverLocating {
    let home: URL
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager
    let scope: LeftoverScope

    public init(home: URL, fm: FileManager = .default) {
        self.home = home
        self.fm = fm
        self.scope = LeftoverScope(home: home)
    }

    public func leftovers(for app: InstalledApp, exclusions: [String]) async -> [AppLeftover] {
        let protection = ProtectionStore(userExclusions: exclusions)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let bundleIDSafe = Self.isSinglePathComponent(app.bundleID)
        let nameSafe = Self.isSinglePathComponent(app.name)
        var out: [AppLeftover] = []
        var seen = Set<String>()

        for location in LeftoverLocations.all.sorted(by: { $0.id < $1.id }) {
            if Task.isCancelled { break }
            let dir = library.appendingPathComponent(location.folder, isDirectory: true)
            // 位置目录的祖先链接不得把枚举带出 ~/Library(末端链接不受影响)。
            guard scope.isLocationContained(dir) else { continue }
            let expectedParent = ProtectionStore.normalize(dir.path).lowercased()
            let candidates: [URL]
            switch location.match {
            case .exact:
                guard bundleIDSafe else { continue }
                candidates = [dir.appendingPathComponent(app.bundleID)]
            case .exactSuffixed(let suffix):
                guard bundleIDSafe else { continue }
                candidates = [dir.appendingPathComponent(app.bundleID + suffix)]
            case .groupContainer:
                guard bundleIDSafe else { continue }
                let entries = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
                candidates = entries.filter {
                    $0.lastPathComponent == app.bundleID
                        || $0.lastPathComponent.hasSuffix("." + app.bundleID)
                }
            case .appName:
                guard nameSafe else { continue }
                candidates = [dir.appendingPathComponent(app.name)]
            }
            for candidate in candidates {
                guard let leftover = makeLeftover(candidate, location: location,
                                                  protection: protection,
                                                  expectedParent: expectedParent,
                                                  seen: &seen) else { continue }
                out.append(leftover)
            }
        }
        return out
    }

    private func makeLeftover(_ url: URL, location: LeftoverLocation,
                              protection: ProtectionStore, expectedParent: String,
                              seen: inout Set<String>) -> AppLeftover? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let path = ProtectionStore.normalize(url.path)
        // scope 只看原始形态:末端自身是符号链接时 trash 的是链接本身,安全。
        guard scope.isAllowed(path) else { return nil }
        // 精确父目录不变量:拒绝 bundleID/name 中的 ../ 穿越到同 Library 的另一个
        // 白名单目录(否则会伪造 safety,如把别人的 Containers 标成 Caches)。
        guard (path as NSString).deletingLastPathComponent.lowercased() == expectedParent else {
            return nil
        }
        // 硬保护与用户排除:原始与解析两种形态都拒绝,祖先链接下的解析形态排除方可生效。
        let resolved = url.resolvingSymlinksInPath().path
        guard !protection.isDenied(path), !protection.isDenied(resolved) else { return nil }
        // 去重先于 FileSize:大小写不敏感的同一物理条目只计一次,且重复候选不白算大小。
        guard seen.insert(path.lowercased()).inserted else { return nil }
        return AppLeftover(path: path,
                           sizeBytes: FileSize.bytes(at: url, fm: fm),
                           safety: location.safety,
                           ownership: location.match == .appName ? .appName : .bundleID,
                           locationID: location.id)
    }

    /// Bundle ID / 应用名须为单一路径组件,否则 `../` 等穿越串可以命中其他位置目录。
    private static func isSinglePathComponent(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/")
    }
}
