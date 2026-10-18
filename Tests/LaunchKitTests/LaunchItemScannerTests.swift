import Foundation
import Testing
@testable import LaunchKit

// MARK: - 夹具帮手(自建 temp 子树,测试结束自清——夹具清理允许 removeItem)

private func makeFixtureDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("raccoon-launchkit-scanner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func plistData(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

// MARK: - 用例

@Suite final class LaunchItemScannerTests {

    /// 目录收集是用户/系统三个目录共用的同一函数:这里用 temp 目录充当用户目录,
    /// 系统LaunchAgents/LaunchDaemons 与用户目录仅路径参数不同(等价性由代码审把关)。
    @Test func listsOnlyPlistFilesSortedByFileName() throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        try plistData(["Label": "com.zoo.agent", "Program": "/bin/zoo"])
            .write(to: fx.appendingPathComponent("com.zoo.agent.plist"))
        try plistData(["ProgramArguments": ["/bin/alpha", "--quiet"]])
            .write(to: fx.appendingPathComponent("com.alpha.agent.plist"))
        try Data("notes".utf8).write(to: fx.appendingPathComponent("readme.txt"))
        // 子目录:靠非 .plist 扩展名自然排除,内部 plist 也不得递归出现。
        let sub = fx.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try plistData(["Label": "com.hidden.inner"]).write(to: sub.appendingPathComponent("inner.plist"))

        let items = LaunchItemScanner().items(inDirectoryPath: fx.path)

        #expect(items.map(\.fileName) == ["com.alpha.agent.plist", "com.zoo.agent.plist"])
        let alpha = try #require(items.first { $0.fileName == "com.alpha.agent.plist" })
        #expect(alpha.path == fx.appendingPathComponent("com.alpha.agent.plist").path)
        #expect(alpha.programName == "/bin/alpha")
        #expect(alpha.label == nil && !alpha.parseFailed)
        let zoo = try #require(items.first { $0.fileName == "com.zoo.agent.plist" })
        #expect(zoo.label == "com.zoo.agent" && !zoo.parseFailed)
    }

    /// 目录不存在是常态(全新机器常没有 ~/Library/LaunchAgents)→ 空数组,不抛错。
    @Test func missingDirectoryYieldsEmptyList() throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        let absent = fx.appendingPathComponent("no-such-dir", isDirectory: true)

        #expect(LaunchItemScanner().items(inDirectoryPath: absent.path).isEmpty)
    }

    /// 注入临时用户根 + 空系统根:输入完全确定,不依赖真机 ~/Library/LaunchAgents 内容。
    @Test func injectedRootsDriveScanAndEmptySystemDirectoriesYieldNoSystemItems() throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        try plistData(["Label": "com.zoo.agent"])
            .write(to: fx.appendingPathComponent("com.zoo.agent.plist"))
        try plistData(["Label": "com.alpha.agent"])
            .write(to: fx.appendingPathComponent("com.alpha.agent.plist"))
        try Data("notes".utf8).write(to: fx.appendingPathComponent("readme.txt"))

        let listing = LaunchItemScanner(userAgentsDirectory: fx.path, systemDirectories: []).scan()

        #expect(listing.userItems.map(\.fileName) == ["com.alpha.agent.plist", "com.zoo.agent.plist"])
        #expect(listing.userItems.allSatisfy { $0.path.hasPrefix(fx.path + "/") })
        #expect(listing.systemItems.isEmpty)
    }

    /// 损坏 XML 不静默丢弃:注入目录里的坏文件仍要以 parseFailed=true 出现在结果中。
    @Test func corruptXMLInInjectedDirectoryIsListedAsParseFailed() throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        try Data("<plist><dict><key>Label".utf8)
            .write(to: fx.appendingPathComponent("com.broken.agent.plist"))

        let listing = LaunchItemScanner(userAgentsDirectory: fx.path, systemDirectories: []).scan()

        let broken = try #require(listing.userItems.first)
        #expect(listing.userItems.count == 1)
        #expect(broken.fileName == "com.broken.agent.plist")
        #expect(broken.path == fx.appendingPathComponent("com.broken.agent.plist").path)
        #expect(broken.parseFailed)
        #expect(broken.label == nil)
    }

    /// 真实 scan():不写死机器内容,只约束三类条目各自落在自己的根下、扩展名为 plist、用户序确定。
    @Test func scanRootsEachListUnderItsOwnDirectory() {
        let listing = LaunchItemScanner().scan()

        let homeAgents = (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        #expect(listing.userItems.allSatisfy { item in
            item.path.hasPrefix(homeAgents + "/") && (item.fileName as NSString).pathExtension == "plist"
        })
        #expect(listing.userItems.map(\.fileName) == listing.userItems.map(\.fileName).sorted())

        let systemRoots = ["/Library/LaunchAgents", "/Library/LaunchDaemons"]
        #expect(listing.systemItems.allSatisfy { item in
            (item.fileName as NSString).pathExtension == "plist"
                && systemRoots.contains { item.path.hasPrefix($0 + "/") }
        })
    }
}
