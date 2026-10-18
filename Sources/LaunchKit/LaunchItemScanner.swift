import Foundation

/// 启动项目录扫描:用户级 LaunchAgents 全量解析,系统级 LaunchAgents/LaunchDaemons
/// 只读清单(同样走完整解析,Label 有则展示)。只枚举、只读,不做任何禁用/删除动作。
public struct LaunchItemScanner: Sendable {
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager

    public init(fm: FileManager = .default) {
        self.fm = fm
    }

    public func scan() -> LaunchDirectoryListing {
        LaunchDirectoryListing(
            userItems: items(inDirectoryPath: (NSHomeDirectory() as NSString)
                .appendingPathComponent("Library/LaunchAgents")),
            systemItems: items(inDirectoryPath: "/Library/LaunchAgents")
                + items(inDirectoryPath: "/Library/LaunchDaemons")
        )
    }

    /// 单目录收集:用户与系统三个目录共用本函数,行为完全一致,仅路径不同。
    /// contentsOfDirectory 不递归且无排序保证 → 只收 .plist 扩展名(子目录自然排除),
    /// 再按 fileName 排序让快照确定,UI 不依赖文件系统返回顺序。
    func items(inDirectoryPath dirPath: String) -> [LaunchItem] {
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: dirPath)
        } catch {
            // 目录不存在是常态(全新机器常没有 ~/Library/LaunchAgents)→ 视为没有条目,不报错。
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
