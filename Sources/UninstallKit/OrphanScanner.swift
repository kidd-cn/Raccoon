import Foundation
import CleanKit

/// 孤儿残留扫描:只扫位置表内的一级子项。
/// 高置信 = 反向域名形状且 Bundle ID 未安装(目录枚举 ∪ LaunchServices 均查不到);
/// 低置信 = Application Support / Logs 下非反向域名、且不等于任何已安装应用名。
public struct OrphanScanner: OrphanScanning {
    let home: URL
    let resolver: InstalledBundleResolving
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager
    let scope: LeftoverScope

    public init(home: URL, resolver: InstalledBundleResolving, fm: FileManager = .default) {
        self.home = home
        self.resolver = resolver
        self.fm = fm
        self.scope = LeftoverScope(home: home)
    }

    public func scan(installedBundleIDs: Set<String>,
                     installedAppNames: Set<String>,
                     exclusions: [String],
                     progress: @Sendable (OrphanScanProgress) -> Void) async -> OrphanScanResult {
        let protection = ProtectionStore(userExclusions: exclusions)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let installedNames = Set(installedAppNames.map(Self.normalizedName))
        var orphans: [AppLeftover] = []
        var seen = Set<String>()
        var failed = Set<String>()
        let locations = LeftoverLocations.all.sorted(by: { $0.id < $1.id })

        for (index, location) in locations.enumerated() {
            if Task.isCancelled { break }
            defer {
                progress(OrphanScanProgress(completedLocations: index + 1,
                                            totalLocations: locations.count))
            }
            let dir = library.appendingPathComponent(location.folder, isDirectory: true)
            // 位置目录的祖先链接不得把枚举带出 ~/Library(末端链接不受影响)。
            guard scope.isLocationContained(dir) else { continue }
            if !fm.fileExists(atPath: dir.path) { continue }
            // 路径形态枚举:穿透位置目录自身的符号链接(URL 形态不跟随末级链接)。
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: dir.path)
            } catch {
                failed.insert(location.id)
                continue
            }
            for name in names {
                if Task.isCancelled { break }
                let entry = dir.appendingPathComponent(name)
                let path = ProtectionStore.normalize(entry.path)
                // 硬保护与用户排除:原始与解析两种形态都拒绝,祖先链接下的解析形态排除方可生效。
                let resolved = entry.resolvingSymlinksInPath().path
                guard !protection.isDenied(path), !protection.isDenied(resolved),
                      scope.isAllowed(path) else { continue }
                switch location.match {
                case .appName:
                    guard let leftover = makeLowConfidence(entry, location: location,
                                                           installedNames: installedNames,
                                                           seen: &seen) else { continue }
                    orphans.append(leftover)
                case .exact, .exactSuffixed, .groupContainer:
                    guard let id = Self.bundleID(fromName: entry.lastPathComponent,
                                                 match: location.match),
                          !id.lowercased().hasPrefix("com.apple.") else { continue }
                    let candidates = location.match == .groupContainer ? Self.candidateIDs(id) : [id]
                    // 组容器可带 TEAMID 前缀:任一候选属于 Apple 即视为系统数据
                    if candidates.contains(where: { $0.lowercased().hasPrefix("com.apple.") }) {
                        continue
                    }
                    if candidates.contains(where: { installedBundleIDs.contains($0) }) { continue }
                    var resolvable = false
                    for candidate in candidates {
                        if await resolver.isResolvable(candidate) { resolvable = true; break }
                    }
                    guard !resolvable else { continue }
                    // 去重先于 FileSize:大小写不敏感,重复条目不白算大小。
                    guard seen.insert(path.lowercased()).inserted else { continue }
                    orphans.append(AppLeftover(
                        path: path,
                        sizeBytes: FileSize.bytes(at: entry, fm: fm),
                        safety: location.safety,
                        ownership: .bundleID,
                        locationID: location.id
                    ))
                }
            }
        }
        return OrphanScanResult(orphans: orphans, failedLocationIDs: failed)
    }

    private func makeLowConfidence(_ entry: URL, location: LeftoverLocation,
                                   installedNames: Set<String>,
                                   seen: inout Set<String>) -> AppLeftover? {
        let name = entry.lastPathComponent
        guard !Self.isReverseDNS(name) else { return nil }
        guard !installedNames.contains(Self.normalizedName(name)) else { return nil }
        let path = ProtectionStore.normalize(entry.path)
        // 去重先于 FileSize:大小写不敏感,重复条目不白算大小。
        guard seen.insert(path.lowercased()).inserted else { return nil }
        return AppLeftover(path: path,
                           sizeBytes: FileSize.bytes(at: entry, fm: fm),
                           safety: location.safety,
                           ownership: .appName,
                           locationID: location.id)
    }

    /// 按位置类型从目录名还原候选 Bundle ID。
    static func bundleID(fromName name: String, match: LeftoverLocation.Match) -> String? {
        switch match {
        case .exact, .groupContainer:
            return isReverseDNS(name) ? name : nil
        case .exactSuffixed(let suffix):
            guard name.hasSuffix(suffix) else { return nil }
            let id = String(name.dropLast(suffix.count))
            return isReverseDNS(id) ? id : nil
        case .appName:
            return nil
        }
    }

    /// 反向域名形状:≥2 段、每段仅 ASCII 字母/数字/-/_、非空。
    static func isReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
            }
        }
    }

    /// 组容器可能是 TEAMID.<id>:逐个点后后缀都当作候选(任一已安装即不算孤儿)。
    static func candidateIDs(_ name: String) -> [String] {
        var out = [name]
        var remaining = Substring(name)
        while let dot = remaining.firstIndex(of: ".") {
            remaining = remaining[remaining.index(after: dot)...]
            if !remaining.isEmpty { out.append(String(remaining)) }
        }
        return out
    }

    /// 名称归一:小写、去首尾空白、去 .app 后缀。
    static func normalizedName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasSuffix(".app") { s = String(s.dropLast(4)) }
        return s
    }
}
