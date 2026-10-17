import Foundation

/// 关联数据位置表(声明式,代码内静态表)。位置一律相对 ~/Library;
/// `<id>` = Bundle ID,`.appName` 表示按应用名匹配的低置信位置。
public struct LeftoverLocation: Equatable, Sendable {
    public enum Match: Equatable, Sendable {
        case exact                        // <id>
        case exactSuffixed(String)        // <id><suffix>,如 .savedState / .plist
        case groupContainer               // <id> 或 *.<id>
        case appName                      // <name>(低置信)
    }
    public let id: String
    public let folder: String
    public let match: Match
    public let safety: LeftoverSafety
    public init(id: String, folder: String, match: Match, safety: LeftoverSafety) {
        self.id = id
        self.folder = folder
        self.match = match
        self.safety = safety
    }
}

public enum LeftoverLocations {
    /// 按 id 字典序排列:同一路径被多条位置命中时,先命中者胜出(去重口径)。
    public static let all: [LeftoverLocation] = [
        .init(id: "app-scripts", folder: "Application Scripts", match: .exact, safety: .userData),
        .init(id: "app-support", folder: "Application Support", match: .exact, safety: .userData),
        .init(id: "app-support-name", folder: "Application Support", match: .appName, safety: .userData),
        .init(id: "caches", folder: "Caches", match: .exact, safety: .regenerable),
        .init(id: "containers", folder: "Containers", match: .exact, safety: .userData),
        .init(id: "group-containers", folder: "Group Containers", match: .groupContainer, safety: .userData),
        .init(id: "httpstorages", folder: "HTTPStorages", match: .exact, safety: .regenerable),
        .init(id: "launch-agents", folder: "LaunchAgents", match: .exactSuffixed(".plist"), safety: .regenerable),
        .init(id: "logs", folder: "Logs", match: .exact, safety: .regenerable),
        .init(id: "logs-name", folder: "Logs", match: .appName, safety: .regenerable),
        .init(id: "saved-state", folder: "Saved Application State", match: .exactSuffixed(".savedState"), safety: .regenerable),
        .init(id: "webkit", folder: "WebKit", match: .exact, safety: .regenerable),
    ]

    /// 明确不列出的受保护位置:一期硬保护整棵覆盖(Preferences / Cookies)。
    /// 放开需改动门 1(窄口豁免 + 回归测试),已列为三期候选。
    public static let excludedFolders = ["Preferences", "Cookies"]
}
