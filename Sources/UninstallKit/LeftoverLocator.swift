import Foundation
import CleanKit

/// 按位置表为单个应用定位关联数据。每条结果都经过:
/// 存在性 → isDenied(硬保护+用户排除) → 作用域白名单;同路径按位置 id 序第一条胜出。
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
        var out: [AppLeftover] = []
        var seen = Set<String>()

        for location in LeftoverLocations.all.sorted(by: { $0.id < $1.id }) {
            if Task.isCancelled { break }
            let dir = library.appendingPathComponent(location.folder, isDirectory: true)
            let candidates: [URL]
            switch location.match {
            case .exact:
                candidates = [dir.appendingPathComponent(app.bundleID)]
            case .exactSuffixed(let suffix):
                candidates = [dir.appendingPathComponent(app.bundleID + suffix)]
            case .groupContainer:
                let entries = (try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil, options: [])) ?? []
                candidates = entries.filter {
                    $0.lastPathComponent == app.bundleID
                        || $0.lastPathComponent.hasSuffix("." + app.bundleID)
                }
            case .appName:
                candidates = [dir.appendingPathComponent(app.name)]
            }
            for candidate in candidates {
                guard let leftover = makeLeftover(candidate, location: location,
                                                  protection: protection) else { continue }
                guard seen.insert(leftover.path).inserted else { continue }
                out.append(leftover)
            }
        }
        return out
    }

    private func makeLeftover(_ url: URL, location: LeftoverLocation,
                              protection: ProtectionStore) -> AppLeftover? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let path = ProtectionStore.normalize(url.path)
        guard !protection.isDenied(path), scope.isAllowed(path) else { return nil }
        return AppLeftover(path: path,
                           sizeBytes: FileSize.bytes(at: url, fm: fm),
                           safety: location.safety,
                           ownership: location.match == .appName ? .appName : .bundleID,
                           locationID: location.id)
    }
}
