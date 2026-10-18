import Foundation

/// 单个 LaunchAgent/LaunchDaemon 条目的解析快照:值语义、可跨并发域传递。
/// parseFailed = true 表示文件损坏/顶层非字典/读不出来——扫描层绝不静默丢弃,
/// 一律以此占位,让 UI 能如实呈现「这个文件有问题」而不是凭空少一行。
public struct LaunchItem: Equatable, Sendable, Identifiable {
    public let path: String
    /// path 的最后组件(含扩展名),列表排序与展示的稳定键
    public let fileName: String
    /// plist 的 Label 键;缺失或解析失败 → nil
    public let label: String?
    /// Program 的值,退而取 ProgramArguments 首个;均无 → nil
    public let programName: String?
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let disabled: Bool
    public let parseFailed: Bool
    public var id: String { path }

    public init(path: String, fileName: String, label: String?, programName: String?,
                runAtLoad: Bool, keepAlive: Bool, disabled: Bool, parseFailed: Bool) {
        self.path = path
        self.fileName = fileName
        self.label = label
        self.programName = programName
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.disabled = disabled
        self.parseFailed = parseFailed
    }
}

/// 两类启动项目录的扫描结果:用户级可操作(禁用/清理),系统级仅只读展示,
/// 分开承载让 UI 不必再按路径前缀猜测条目归属。
public struct LaunchDirectoryListing: Equatable, Sendable {
    /// ~/Library/LaunchAgents/*.plist,按 fileName 排序
    public let userItems: [LaunchItem]
    /// /Library/LaunchAgents + /Library/LaunchDaemons,只读清单(按目录顺序拼接)
    public let systemItems: [LaunchItem]

    public init(userItems: [LaunchItem], systemItems: [LaunchItem]) {
        self.userItems = userItems
        self.systemItems = systemItems
    }
}
