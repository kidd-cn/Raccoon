import Foundation
import Testing
import LaunchKit

// MARK: - 夹具帮手(代码内生成 plist,不提交二进制 fixture)

/// 字典/数组 → XML plist Data,与解析侧同一序列化器,保证夹具本身合法。
private func plistData(_ value: Any) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
}

private func makeFixtureDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("raccoon-launchkit-parser-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 统一的「全空失败体」断言:parseFailed 项必须 label/programName 皆 nil、布尔皆 false。
private func expectFailedShell(_ item: LaunchItem, path: String, fileName: String) {
    #expect(item.parseFailed)
    #expect(item.label == nil)
    #expect(item.programName == nil)
    #expect(!item.runAtLoad && !item.keepAlive && !item.disabled)
    #expect(item.path == path)
    #expect(item.fileName == fileName)
}

// MARK: - 用例

@Suite final class LaunchItemParserTests {

    @Test func parsesFullPlist() throws {
        // Program 与 ProgramArguments 并存时取 Program——launchd 语义里前者是权威声明。
        let data = try plistData([
            "Label": "com.raccoon.full",
            "Program": "/usr/local/bin/fulld",
            "ProgramArguments": ["/usr/local/bin/fulld", "--verbose"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "Disabled": true,
        ])

        let item = LaunchItemParser.parse(data: data,
                                          path: "/agents/com.raccoon.full.plist",
                                          fileName: "com.raccoon.full.plist")

        #expect(item == LaunchItem(
            path: "/agents/com.raccoon.full.plist",
            fileName: "com.raccoon.full.plist",
            label: "com.raccoon.full",
            programName: "/usr/local/bin/fulld",
            runAtLoad: true,
            keepAlive: true,
            disabled: true,
            parseFailed: false
        ))
    }

    @Test func parsesProgramOnly() throws {
        let data = try plistData([
            "Label": "com.raccoon.progonly",
            "Program": "/usr/local/bin/solod",
        ])

        let item = LaunchItemParser.parse(data: data,
                                          path: "/agents/solo.plist",
                                          fileName: "solo.plist")

        #expect(item.label == "com.raccoon.progonly")
        #expect(item.programName == "/usr/local/bin/solod")
        #expect(!item.runAtLoad && !item.keepAlive && !item.disabled)
        #expect(!item.parseFailed)
    }

    @Test func parsesFirstProgramArgumentWhenNoProgram() throws {
        let data = try plistData([
            "ProgramArguments": ["/opt/tool/bin/toold", "--flag", "value"],
        ])

        let item = LaunchItemParser.parse(data: data,
                                          path: "/agents/args.plist",
                                          fileName: "args.plist")

        #expect(item.label == nil)
        #expect(item.programName == "/opt/tool/bin/toold")
        #expect(!item.parseFailed)
    }

    @Test func missingLabelKeepsOtherFields() throws {
        let data = try plistData([
            "Program": "/usr/local/bin/nolabel",
            "RunAtLoad": true,
        ])

        let item = LaunchItemParser.parse(data: data,
                                          path: "/agents/nolabel.plist",
                                          fileName: "nolabel.plist")

        // 缺 Label 只降级展示,不算解析失败。
        #expect(item.label == nil)
        #expect(item.programName == "/usr/local/bin/nolabel")
        #expect(item.runAtLoad)
        #expect(!item.parseFailed)
    }

    @Test func nonBoolOrMissingFlagsFallBackToFalse() throws {
        // 真实世界里 RunAtLoad 写成字符串并不罕见;类型不符按 false,不判失败。
        let data = try plistData([
            "Label": "com.raccoon.strbool",
            "Program": "/usr/local/bin/strbool",
            "RunAtLoad": "yes",
            "KeepAlive": ["SuccessfulExit": false],
        ])

        let item = LaunchItemParser.parse(data: data,
                                          path: "/agents/strbool.plist",
                                          fileName: "strbool.plist")

        #expect(!item.runAtLoad && !item.keepAlive && !item.disabled)
        #expect(!item.parseFailed)
    }

    @Test func corruptedXMLMarksParseFailed() {
        let garbage = Data("this is not a plist at all <".utf8)

        let item = LaunchItemParser.parse(data: garbage,
                                          path: "/agents/broken.plist",
                                          fileName: "broken.plist")

        // 损坏文件绝不静默丢弃:必须以 parseFailed 项占位,让 UI 能如实呈现。
        expectFailedShell(item, path: "/agents/broken.plist", fileName: "broken.plist")
    }

    @Test func nonDictionaryTopLevelMarksParseFailed() throws {
        let data = try plistData(["just", "an", "array"])

        let item = LaunchItemParser.parse(data: data,
                                          path: "/agents/array.plist",
                                          fileName: "array.plist")

        expectFailedShell(item, path: "/agents/array.plist", fileName: "array.plist")
    }

    @Test func fileURLParsesExistingFile() throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        let url = fx.appendingPathComponent("com.raccoon.onDisk.plist")
        try plistData(["Label": "com.raccoon.onDisk", "Program": "/bin/ondisk"])
            .write(to: url)

        let item = LaunchItemParser.parse(fileURL: url)

        #expect(item == LaunchItem(
            path: url.path,
            fileName: "com.raccoon.onDisk.plist",
            label: "com.raccoon.onDisk",
            programName: "/bin/ondisk",
            runAtLoad: false,
            keepAlive: false,
            disabled: false,
            parseFailed: false
        ))
    }

    @Test func fileURLOfMissingFileMarksParseFailed() throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        let url = fx.appendingPathComponent("ghost.plist")

        let item = LaunchItemParser.parse(fileURL: url)

        expectFailedShell(item, path: url.path, fileName: "ghost.plist")
    }
}
