import Foundation

/// 启动项目录扫描:用户级 LaunchAgents 全量解析,系统级 LaunchAgents/LaunchDaemons
/// 只读清单(同样走完整解析,Label 有则展示)。只枚举、只读,不做任何禁用/删除动作。
public struct LaunchItemScanner: Sendable {
    /// 用户级 LaunchAgents 根目录。测试可注入临时目录以获得确定输入。
    let userAgentsDirectory: String
    /// 系统级扫描根,按数组顺序拼接结果。
    let systemDirectories: [String]
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager

    /// 默认根保持原有语义:家目录 LaunchAgents + 两个系统目录,现有调用方无需改动。
    public init(userAgentsDirectory: String = NSHomeDirectory() + "/Library/LaunchAgents",
                systemDirectories: [String] = ["/Library/LaunchAgents", "/Library/LaunchDaemons"],
                fm: FileManager = .default) {
        self.userAgentsDirectory = userAgentsDirectory
        self.systemDirectories = systemDirectories
        self.fm = fm
    }

    public func scan() -> LaunchDirectoryListing {
        LaunchDirectoryListing(
            userItems: items(inDirectoryPath: userAgentsDirectory),
            systemItems: systemDirectories.flatMap { items(inDirectoryPath: $0) }
        )
    }

    /// 单目录收集:用户与系统三个目录共用本函数,行为完全一致,仅路径不同。
    /// contentsOfDirectory 不递归且无排序保证 → 只收 .plist 扩展名(子目录自然排除),
    /// 再按 fileName 排序让快照确定,UI 不依赖文件系统返回顺序。
    func items(inDirectoryPath dirPath: String) -> [LaunchItem] {
        // 先区分「目录不存在」与「目录存在但读不了」:前者是常态,后者是被吞掉的读取失败。
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dirPath, isDirectory: &isDirectory) else {
            // 目录不存在是常态(全新机器常没有 ~/Library/LaunchAgents)→ 视为没有条目,不报错。
            return []
        }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dirPath)
        } catch {
            // 目录存在但枚举失败(权限不足/IO 错误):仍返回空数组、不抛错。此处不引入诊断 API,
            // 因此读取失败的条目会被漏列——属已接受风险,由调用方决定是否展示「无法读取」。
            return []
        }
        return names
            .filter { ($0 as NSString).pathExtension == "plist" }
            .map { name in
                let path = (dirPath as NSString).appendingPathComponent(name)
                return LaunchItemParser.parse(fileURL: URL(fileURLWithPath: path))
            }
            .sorted { $0.fileName < $1.fileName }
    }
}
