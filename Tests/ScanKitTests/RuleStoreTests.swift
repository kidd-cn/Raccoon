import Foundation
import Testing
import CleanKit
@testable import ScanKit

@Suite final class RuleStoreTests {
    func load(_ json: String) throws -> LoadedRules {
        let store = RuleStore(protection: ProtectionStore())
        return try store.load(data: Data(json.utf8))
    }

    @Test func testLoad_validPack() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Caches"},
          {"id":"b","category":"cautious","safety":"cautious","path":"~/Library/Application Support/MobileSync/Backup"}
        ]}
        """)
        #expect(lr.rules.map(\.id) == ["a", "b"])
        #expect(lr.rejected.isEmpty)
        #expect(lr.warnings.isEmpty)
    }

    @Test func testLoad_unsupportedVersion() {
        do {
            _ = try load(#"{"version":2,"rules":[]}"#)
            Issue.record("should throw")
        } catch {
            guard case RuleStoreError.unsupportedVersion(2) = error else {
                Issue.record("\(error)")
                return
            }
        }
    }

    @Test func testLoad_decodingFailure() {
        do {
            _ = try load("not json")
            Issue.record("should throw")
        } catch {
            guard case RuleStoreError.decodingFailed = error else {
                Issue.record("\(error)")
                return
            }
        }
    }

    @Test func testLoad_duplicateIDRejected_ruleKept() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Logs"},
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Caches"}
        ]}
        """)
        #expect(lr.rules.count == 1)
        #expect(lr.rules.first?.path == "~/Library/Logs")   // 先到先得
        #expect(lr.rejected.count == 1)
        #expect(lr.rejected[0].contains("重复 id"))
    }

    @Test func testLoad_cautiousCategoryRequiresCautiousSafety() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"bad","category":"cautious","safety":"safe","path":"~/Library/Caches/x"}
        ]}
        """)
        #expect(lr.rules.isEmpty)
        #expect(lr.rejected.count == 1)
    }

    @Test func testLoad_tmutilThinRequiresCautious() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"snap","category":"system","safety":"safe","path":"~","action":"tmutil-thin"}
        ]}
        """)
        #expect(lr.rules.isEmpty)
        // tmutil-thin 的 path 不做作用域/保护校验(不参与文件遍历)
    }

    @Test func testLoad_securityRegression_ruleAtProtectedPathRejected() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"evil","category":"system","safety":"safe","path":"~/Documents"},
          {"id":"evil2","category":"system","safety":"safe","path":"~/Library/Preferences"},
          {"id":"good","category":"system","safety":"safe","path":"~/Library/Logs"}
        ]}
        """)
        #expect(lr.rules.map(\.id) == ["good"])
        #expect(lr.rejected.count == 2)
    }

    @Test func testLoad_outOfScopeRejected() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"sys","category":"system","safety":"safe","path":"/Library"},
          {"id":"usr","category":"system","safety":"safe","path":"/usr/local"}
        ]}
        """)
        #expect(lr.rules.isEmpty)
        #expect(lr.rejected.count == 2)
    }

    @Test func testLoad_overlapWarns() throws {
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"a","category":"system","safety":"safe","path":"~/Library/Caches"},
          {"id":"b","category":"system","safety":"safe","path":"~/Library/Caches/"}
        ]}
        """)
        #expect(lr.rules.count == 2)                 // 允许,仅告警
        #expect(lr.warnings.count == 1)              // 尾斜杠归一化后视为同路径
    }

    // I1 回归:符号链接别名指进硬保护根 → 整条拒绝。
    // 别名放在主目录内:原始形态不命中任何硬保护根,只有解析到 ~/Library/Preferences
    // 的形态才会触发冲突 → 锁定 resolved 形态的冲突校验。
    @Test func testLoad_symlinkAliasToProtectedRejected() throws {
        let alias = NSHomeDirectory() + "/raccoon-test-alias-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: NSHomeDirectory() + "/Library/Preferences")
        defer { try? FileManager.default.removeItem(atPath: alias) }
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"sneaky","category":"system","safety":"safe","path":"\(alias)"}
        ]}
        """)
        #expect(lr.rules.isEmpty)
        #expect(lr.rejected.count == 1)
        #expect(lr.rejected[0].contains("硬保护冲突"))
    }

    // I1 回归:家目录内别名解析后逃出主目录 → 解析形态作用域校验拒绝。
    // 原始形态在主目录内过作用域;只有 resolved 形态(/usr)才被拒 → 锁定 resolved 校验。
    @Test func testLoad_symlinkEscapingHomeRejected() throws {
        let alias = NSHomeDirectory() + "/raccoon-test-alias-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: "/usr")
        defer { try? FileManager.default.removeItem(atPath: alias) }
        let lr = try load("""
        {"version":1,"rules":[
          {"id":"escape","category":"system","safety":"safe","path":"\(alias)"}
        ]}
        """)
        #expect(lr.rules.isEmpty)
        #expect(lr.rejected.count == 1)
        #expect(lr.rejected[0].contains("超出允许作用域"))
    }

    @Test func testEffectiveAction_defaultsToTrash() throws {
        let lr = try load("""
        {"version":1,"rules":[{"id":"a","category":"system","safety":"safe","path":"~/Library/Logs"}]}
        """)
        #expect(lr.rules[0].effectiveAction == .trash)
    }
}
