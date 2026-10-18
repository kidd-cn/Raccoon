import Foundation

/// plist → LaunchItem 的纯解析(无 I/O 副作用,除 fileURL 便捷入口)。
/// 损坏数据与合法但非常规的键(缺 Label、布尔写成字符串)严格区分:
/// 前者判 parseFailed,后者只降级取值——「文件读不了」和「文件很朴素」是两件事。
public enum LaunchItemParser {
    public static func parse(data: Data, path: String, fileName: String) -> LaunchItem {
        // 反序列化失败与顶层非字典(如数组 plist)同罪:统一失败壳,不区分错误细节。
        // 本 SDK 已废弃 .immutable(空选项即不可变读取),语义不变。
        guard let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = raw as? [String: Any] else {
            return LaunchItem(path: path, fileName: fileName, label: nil, programName: nil,
                              runAtLoad: false, keepAlive: false, disabled: false, parseFailed: true)
        }
        // Program 优先于 ProgramArguments 首个——launchd 语义里前者是权威声明。
        // as? [String] 任一元素非字符串即整体失败 → programName 退 nil,不判 parseFailed。
        let programName = (dict["Program"] as? String)
            ?? (dict["ProgramArguments"] as? [String])?.first
        // 三个布尔键缺失或类型不符(字符串 "yes"、字典式 KeepAlive)按 false:
        // 保守展示「未开启」好过把整个文件判成损坏。
        return LaunchItem(
            path: path,
            fileName: fileName,
            label: dict["Label"] as? String,
            programName: programName,
            runAtLoad: dict["RunAtLoad"] as? Bool ?? false,
            keepAlive: dict["KeepAlive"] as? Bool ?? false,
            disabled: dict["Disabled"] as? Bool ?? false,
            parseFailed: false
        )
    }

    /// 便捷入口:读文件失败(不存在/无权限)同样走 parseFailed 壳——
    /// 文件在目录里却读不出内容时,静默丢弃比展示失败更危险。
    public static func parse(fileURL: URL) -> LaunchItem {
        guard let data = try? Data(contentsOf: fileURL) else {
            return LaunchItem(path: fileURL.path, fileName: fileURL.lastPathComponent,
                              label: nil, programName: nil,
                              runAtLoad: false, keepAlive: false, disabled: false, parseFailed: true)
        }
        return parse(data: data, path: fileURL.path, fileName: fileURL.lastPathComponent)
    }
}
