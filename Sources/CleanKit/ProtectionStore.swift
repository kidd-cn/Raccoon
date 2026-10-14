import Foundation

/// 硬保护 + 用户排除。扫描过滤与删除前校验两处调用(纵深防御)。
///
/// 所有匹配均为**组件级、大小写不敏感**前缀匹配(默认 APFS 不区分大小写,
/// 宁可多拦不可漏放)。
public struct ProtectionStore: Sendable {
    /// 硬保护根:组件级前缀匹配,命中即拒绝删除与展示。
    public let hardRoots: [String]
    /// 用户排除:组件级前缀匹配。
    public let userExclusions: [String]

    /// 预计算:各根经 normalize + 折叠小写后的组件数组(避免每次匹配重复 standardizingPath)。
    private let hardRootPrefixes: [[String]]
    private let userExclusionPrefixes: [[String]]

    public init(hardRoots: [String]? = nil, userExclusions: [String] = []) {
        let roots = hardRoots ?? ProtectionStore.defaultHardRoots()
        self.hardRoots = roots
        self.userExclusions = userExclusions
        self.hardRootPrefixes = ProtectionStore.foldedComponents(of: roots)
        self.userExclusionPrefixes = ProtectionStore.foldedComponents(of: userExclusions)
    }

    static func defaultHardRoots() -> [String] {
        let home = NSHomeDirectory()
        let content = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public"]
        let libraryKeys = ["Mail", "Keychains", "Preferences", "Cookies", "Accounts", "Safari", "Suggestions"]
        return content.map { "\(home)/\($0)" } + libraryKeys.map { "\(home)/Library/\($0)" }
    }

    public func isHardProtected(_ path: String) -> Bool { Self.isUnder(path, anyOf: hardRootPrefixes) }
    public func isUserExcluded(_ path: String) -> Bool { Self.isUnder(path, anyOf: userExclusionPrefixes) }

    /// 命中即拒绝。契约:path 必须为绝对路径,且与规则根同形(同为原始形式,或同为
    /// resolvingSymlinksInPath 形式);规则根的符号链接别名由 RuleStore 校验时以原始与
    /// resolvingSymlinksInPath 两种形式一并拒绝(后续任务的义务)。
    /// isDenied→trash 之间的 TOCTOU 窗口为已接受风险(微秒级,最坏后果是受保护文件进废纸篓可恢复,非销毁)。
    public func isDenied(_ path: String) -> Bool { isHardProtected(path) || isUserExcluded(path) }

    /// 组件级前缀(大小写不敏感):path == root 或 path 位于 root 之下。
    /// 在预计算的折叠组件数组上做纯数组前缀比较;空组件数组(根 `/`)是一切路径的前缀。
    static func isUnder(_ path: String, anyOf foldedRoots: [[String]]) -> Bool {
        let comps = foldedComponents(of: path)
        return foldedRoots.contains { rc in
            rc.count <= comps.count && Array(comps.prefix(rc.count)) == rc
        }
    }

    /// 展开 ~、解析绝对路径中的 ..、去尾斜杠;**不解析符号链接**。
    public static func normalize(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 归一化 + 折叠小写后的路径组件数组。
    static func foldedComponents(of path: String) -> [String] {
        normalize(path).split(separator: "/").map { $0.lowercased() }
    }

    static func foldedComponents(of roots: [String]) -> [[String]] {
        roots.map { foldedComponents(of: $0) }
    }

    /// 规则根白名单:主目录内(主目录本身仅当带 include 时允许),或
    /// `/Applications` 限定安装器匹配,或 `/Applications/Install macOS *.app` 直指。
    /// 匹配大小写不敏感;`/Applications` 的每个 include 模式自身必须具安装器形状
    /// (`install macos ` 前缀 + `.app` 后缀),以防 `*` 之类宽通配放行任意应用。
    public static func isAllowedRuleRoot(_ path: String, include: [String]? = nil) -> Bool {
        let std = normalize(path)
        let lower = std.lowercased()
        let home = normalize(NSHomeDirectory()).lowercased()
        if lower == home { return !(include ?? []).isEmpty }
        if lower.hasPrefix(home + "/") { return true }
        if lower == "/applications" {
            let patterns = (include ?? []).map { $0.lowercased() }
            return !patterns.isEmpty && patterns.allSatisfy {
                $0.hasPrefix("install macos ") && $0.hasSuffix(".app")
            }
        }
        let comps = std.split(separator: "/").map(String.init)
        return comps.count == 2 && comps[0].lowercased() == "applications"
            && comps[1].lowercased().hasPrefix("install macos ") && comps[1].lowercased().hasSuffix(".app")
    }

    /// 规则根不得等于、位于硬保护根之内;不得为硬保护根的祖先——除非带 include 白名单。
    /// (祖先方向豁免:规格 §5.3 system.ds-store 以主目录为根的匹配型规则必须能加载;
    /// 硬保护内容仍由扫描命中级过滤 + 删除前 isDenied 兜底,规则级校验是防呆 lint,
    /// 不是安全边界。等于/位于其下方向无条件冲突,include 也救不了。)
    public static func rulePathConflictsWithProtection(_ path: String, hardRoots: [String], include: [String]? = nil) -> Bool {
        let comps = foldedComponents(of: path)
        let ancestorAllowed = !(include ?? []).isEmpty
        return hardRoots.contains { root in
            let rc = foldedComponents(of: root)
            if comps.isEmpty || rc.isEmpty { return true }
            if Array(comps.prefix(rc.count)) == rc { return true }                // 等于/位于其下:一律冲突
            if Array(rc.prefix(comps.count)) == comps { return !ancestorAllowed } // 祖先:无 include 才冲突
            return false
        }
    }
}
