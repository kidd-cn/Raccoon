import Foundation

/// 硬保护 + 用户排除。扫描过滤与删除前校验两处调用(纵深防御)。
public struct ProtectionStore: Sendable {
    /// 硬保护根:组件级前缀匹配,命中即拒绝删除与展示。
    public let hardRoots: [String]
    /// 用户排除:组件级前缀匹配。
    public let userExclusions: [String]

    public init(hardRoots: [String]? = nil, userExclusions: [String] = []) {
        self.hardRoots = hardRoots ?? ProtectionStore.defaultHardRoots()
        self.userExclusions = userExclusions
    }

    static func defaultHardRoots() -> [String] {
        let home = NSHomeDirectory()
        let content = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
        let libraryKeys = ["Mail", "Keychains", "Preferences", "Cookies", "Accounts", "Safari", "Suggestions"]
        return content.map { "\(home)/\($0)" } + libraryKeys.map { "\(home)/Library/\($0)" }
    }

    public func isHardProtected(_ path: String) -> Bool { Self.isUnder(path, anyOf: hardRoots) }
    public func isUserExcluded(_ path: String) -> Bool { Self.isUnder(path, anyOf: userExclusions) }
    public func isDenied(_ path: String) -> Bool { isHardProtected(path) || isUserExcluded(path) }

    /// 展开路径 组件级前缀:path == root 或 path 位于 root 之下。
    static func isUnder(_ path: String, anyOf roots: [String]) -> Bool {
        let comps = normalize(path).split(separator: "/").map(String.init)
        return roots.contains { root in
            let rc = normalize(root).split(separator: "/").map(String.init)
            guard rc.count <= comps.count else { return false }
            return Array(comps.prefix(rc.count)) == rc
        }
    }

    /// 展开 ~、解析 ..、去尾斜杠。
    public static func normalize(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 规则根白名单:主目录内(主目录本身仅当带 include 时允许),或
    /// `/Applications` 限定安装器匹配,或 `/Applications/Install macOS *.app` 直指。
    public static func isAllowedRuleRoot(_ path: String, include: [String]? = nil) -> Bool {
        let std = normalize(path)
        let home = normalize(NSHomeDirectory())
        if std == home { return !(include ?? []).isEmpty }
        if std.hasPrefix(home + "/") { return true }
        if std == "/Applications" {
            return (include ?? []).contains { fnmatch($0, "Install macOS Sonoma.app", 0) == 0 }
        }
        let comps = std.split(separator: "/").map(String.init)
        return comps.count == 2 && comps[0] == "Applications"
            && comps[1].hasPrefix("Install macOS ") && comps[1].hasSuffix(".app")
    }

    /// 规则根不得等于、位于、或包含(作为祖先)任何硬保护根。
    public static func rulePathConflictsWithProtection(_ path: String, hardRoots: [String]) -> Bool {
        let std = normalize(path)
        return hardRoots.contains { root in
            let rc = normalize(root)
            return std == rc || std.hasPrefix(rc + "/") || rc.hasPrefix(std + "/")
        }
    }
}
