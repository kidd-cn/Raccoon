import Foundation
import CleanKit

/// 临时主目录夹具:所有测试只在这里造数据,绝不触碰真实 ~/Library。
final class TempHome {
    let url: URL
    let fm = FileManager.default

    init() {
        // 临时目录在 /var(符号链接到 /private/var):必须先解析,
        // 否则 AppDiscovery 的 resolvingSymlinksInPath 结果与断言路径不同形。
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        url = base.appendingPathComponent("raccoon-uninstall-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? fm.removeItem(at: url) }

    @discardableResult
    func makeDir(_ relative: String, bytes: Int = 0) throws -> URL {
        let dir = url.appendingPathComponent(relative, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if bytes > 0 {
            _ = try makeFile("\(relative)/payload-\(UUID().uuidString.prefix(8)).bin", bytes: bytes)
        }
        return dir
    }

    @discardableResult
    func makeFile(_ relative: String, bytes: Int = 1) throws -> URL {
        let file = url.appendingPathComponent(relative)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: file)
        return file
    }

    /// 假 .app:Info.plist + 可计量的本体文件。
    @discardableResult
    func makeApp(_ name: String, bundleID: String, inRoot root: URL,
                 version: String? = "1.0", bodyBytes: Int = 100) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x42, count: bodyBytes).write(to: contents.appendingPathComponent("binary"))
        return app
    }

    func appRoot(_ name: String = "Applications") throws -> URL {
        let root = url.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 测试用保护层:不设硬保护根(硬保护行为由 CleanKit 既有测试覆盖)。
    func protection(userExclusions: [String] = []) -> ProtectionStore {
        ProtectionStore(hardRoots: [], userExclusions: userExclusions)
    }
}
