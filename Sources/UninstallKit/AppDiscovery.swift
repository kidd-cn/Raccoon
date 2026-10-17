import Foundation
import CleanKit

/// 枚举应用根下的 .app(最多一层子目录),读取 Info.plist,过滤 Apple 应用、
/// 越界符号链接与用户排除项;同 Bundle ID 按根顺序去重。
public struct AppDiscovery: AppDiscovering {
    let appRoots: [URL]
    let running: RunningAppChecking
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager

    public init(appRoots: [URL], running: RunningAppChecking, fm: FileManager = .default) {
        self.appRoots = appRoots
        self.running = running
        self.fm = fm
    }

    public func discover(exclusions: [String],
                         progress: @Sendable (AppDiscoveryProgress) -> Void) async throws -> AppDiscoveryResult {
        let protection = ProtectionStore(userExclusions: exclusions)
        var apps: [InstalledApp] = []
        var seenIDs = Set<String>()
        var seenRoots = Set<String>()
        var unreadable = 0
        var enumerated = 0
        for root in appRoots {
            let rootPath = root.resolvingSymlinksInPath().path
            // 根按解析后路径去重:~/Applications 链接到 /Applications 时不整套重复枚举。
            // 根本身可以是符号链接——枚举按字符串路径进行,会跟随末级链接。
            guard seenRoots.insert(rootPath).inserted else { continue }
            for candidate in Self.appCandidates(in: root, fm: fm) {
                try Task.checkCancellation()
                enumerated += 1
                progress(AppDiscoveryProgress(enumeratedCount: enumerated))
                let resolved = candidate.resolvingSymlinksInPath()
                guard Self.isUnder(resolved.path, rootPath: rootPath) else { continue }
                // 只认 .app 目录:同名普通文件不是应用,不应计入「无法识别」提示。
                let isDir = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                // 原始与解析后两种形态都校验:用户排除项常是未解析路径(如经 NSOpenPanel),
                // isDenied 契约要求路径与规则同形,这里对两种形态都问一次。
                guard !protection.isDenied(candidate.path),
                      !protection.isDenied(resolved.path) else { continue }
                guard let meta = Self.bundleMetadata(at: resolved) else {
                    unreadable += 1
                    continue
                }
                guard !meta.bundleID.lowercased().hasPrefix("com.apple.") else { continue }
                guard !seenIDs.contains(meta.bundleID) else { continue }
                seenIDs.insert(meta.bundleID)
                apps.append(InstalledApp(
                    bundleID: meta.bundleID,
                    name: meta.name,
                    version: meta.version,
                    appPath: resolved.path,
                    sizeBytes: FileSize.bytes(at: resolved, fm: fm),
                    isRunning: running.isRunning(bundleID: meta.bundleID)
                ))
            }
        }
        apps.sort {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.bundleID.localizedStandardCompare($1.bundleID) == .orderedAscending
        }
        return AppDiscoveryResult(apps: apps, unreadableCount: unreadable)
    }

    struct BundleMetadata {
        let bundleID: String
        let name: String
        let version: String?
    }

    static func bundleMetadata(at app: URL) -> BundleMetadata? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty else { return nil }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        return BundleMetadata(bundleID: bundleID, name: name,
                              version: dict["CFBundleShortVersionString"] as? String)
    }

    /// 根下第一层的 .app + 根下第一层目录内的 .app(不超过一层子目录)。
    /// 按字符串路径枚举以跟随「根本身是符号链接」的情形(`contentsOfDirectory(at:)` 不跟随末级链接);
    /// 第一层目录若是符号链接则不向下枚举——只认根内真实容器目录。
    static func appCandidates(in root: URL, fm: FileManager) -> [URL] {
        guard let level1 = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var out: [URL] = []
        for name in level1 {
            let entry = root.appendingPathComponent(name)
            if entry.pathExtension.lowercased() == "app" {
                out.append(entry)
                continue
            }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let level2 = (try? fm.contentsOfDirectory(atPath: entry.path)) ?? []
            out += level2
                .filter { ($0 as NSString).pathExtension.lowercased() == "app" }
                .map { entry.appendingPathComponent($0) }
        }
        return out
    }

    /// 解析链接后仍须位于该根之下。根先解析一次、循环内复用;
    /// 根为 `/` 时特判,避免拼出 `//` 前缀。
    static func isUnder(_ path: String, rootPath: String) -> Bool {
        if rootPath == "/" { return path.hasPrefix("/") }
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}
