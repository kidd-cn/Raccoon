import Foundation
import Testing
@testable import CleanKit

struct ProtectionStoreTests {
    let home = NSHomeDirectory()

    @Test func testComponentPrefixMatch_notStringPrefix() {
        let s = ProtectionStore(hardRoots: ["\(home)/Library"], userExclusions: [])
        #expect(!s.isHardProtected("\(home)/Library2/Caches"))   // 字符串前缀陷阱
        #expect(s.isHardProtected("\(home)/Library/Preferences/x.plist"))
        #expect(s.isHardProtected("\(home)/Library"))
    }

    @Test func testDefaultHardRoots_coverUserContentAndLibraryKeys() {
        let s = ProtectionStore()
        #expect(s.isHardProtected("\(home)/Desktop/a.txt"))
        #expect(s.isHardProtected("\(home)/Documents"))
        #expect(s.isHardProtected("\(home)/Library/Keychains"))
        #expect(s.isHardProtected("\(home)/Library/Suggestions"))
        // 明确不在清单内(合法清理目标)
        #expect(!s.isHardProtected("\(home)/Library/Caches/com.google.Chrome"))
        #expect(!s.isHardProtected("\(home)/Library/Application Support/MobileSync/Backup"))
    }

    @Test func testUserExclusion_denyAndMerge() {
        let s = ProtectionStore(userExclusions: ["/var/folders/keep-me"])
        #expect(s.isUserExcluded("/var/folders/keep-me/sub"))
        #expect(!s.isHardProtected("/var/folders/keep-me"))
        #expect(s.isDenied("/var/folders/keep-me/sub"))
        #expect(!s.isDenied("/var/folders/other"))
    }

    @Test func testNormalize_tildeAndTrailingSlashAndDotDot() {
        let s = ProtectionStore(userExclusions: ["~/Library/Caches/"])
        #expect(s.isUserExcluded("\(home)/Library/Caches/com.a"))
        #expect(s.isUserExcluded("\(home)/Library/Caches/../Caches/com.b"))
    }

    // —— 规则作用域与冲突校验(供 RuleStore 复用)—

    @Test func testIsAllowedRuleRoot() {
        #expect(ProtectionStore.isAllowedRuleRoot("\(home)/Library/Caches"))
        #expect(ProtectionStore.isAllowedRuleRoot("~", include: [".DS_Store"]))  // 主目录仅在有 include 时允许
        #expect(!ProtectionStore.isAllowedRuleRoot("~"))                          // 裸主目录禁止
        #expect(ProtectionStore.isAllowedRuleRoot("/Applications", include: ["Install macOS *.app"]))
        #expect(!ProtectionStore.isAllowedRuleRoot("/Applications"))
        #expect(ProtectionStore.isAllowedRuleRoot("/Applications/Install macOS Sonoma.app"))
        #expect(!ProtectionStore.isAllowedRuleRoot("/Applications/Xcode.app"))
        #expect(!ProtectionStore.isAllowedRuleRoot("/usr/local/share"))
        #expect(!ProtectionStore.isAllowedRuleRoot("\(home)/../otheruser"))
    }

    @Test func testRulePathConflictsWithProtection() {
        let roots = ["\(home)/Documents", "\(home)/Library/Preferences"]
        #expect(ProtectionStore.rulePathConflictsWithProtection("\(home)/Documents", hardRoots: roots))          // 等于
        #expect(ProtectionStore.rulePathConflictsWithProtection("\(home)/Documents/projects", hardRoots: roots)) // 位于其下
        #expect(ProtectionStore.rulePathConflictsWithProtection("\(home)/Library", hardRoots: roots))            // 是保护根的祖先
        #expect(!ProtectionStore.rulePathConflictsWithProtection("\(home)/Library/Caches", hardRoots: roots))
    }

    @Test func testSecurityRegression_rulePointingAtProtectedRootIsConflict() {
        // 恶意规则:指向用户内容目录 → 引擎层判冲突(RuleStore 据此拒绝该条)
        let s = ProtectionStore()
        for evil in ["\(home)/Desktop", "\(home)/Downloads", "\(home)/Library/Preferences"] {
            #expect(ProtectionStore.rulePathConflictsWithProtection(evil, hardRoots: s.hardRoots), Comment(rawValue: evil))
        }
    }
}
