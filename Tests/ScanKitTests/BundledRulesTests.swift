import Testing
@testable import ScanKit

@Suite final class BundledRulesTests {
    @Test func bundledRulesLoadClean() throws {
        let lr = try RuleStore().loadBundled()
        #expect(lr.rules.count >= 20)
        #expect(lr.rejected.isEmpty, "内置规则必须全部合法: \(lr.rejected)")
        #expect(lr.warnings.isEmpty, "内置规则不允许根重叠: \(lr.warnings)")
    }

    @Test func bundledRulesCoverAllCategoriesAndHaveLocalizedDescriptions() throws {
        let lr = try RuleStore().loadBundled()
        let cats = Set(lr.rules.map(\.category))
        #expect(cats == Set(RuleCategory.allCases))
        for rule in lr.rules {
            #expect(rule.description?.zhHans != nil, "\(rule.id) 缺中文描述")
            #expect(rule.description?.en != nil, "\(rule.id) 缺英文描述")
        }
    }

    @Test func bundledRulesKeyRulesPresent() throws {
        let lr = try RuleStore().loadBundled()
        let ids = Set(lr.rules.map(\.id))
        for expected in ["system.user-caches", "system.ds-store", "dev.xcode-deriveddata",
                         "apps.chrome-cache", "apps.wechat-cache", "cautious.ios-backups",
                         "cautious.macos-installers", "cautious.tm-snapshots"] {
            #expect(ids.contains(expected), "缺少关键规则 \(expected)")
        }
    }

    // §5.1 约束:category=cautious 要求 safety=cautious(与 RuleStore.validate 同向)。
    // 反向不成立——dev/apps 类别也允许 safety=cautious(规格 §5.3:Xcode Archives、
    // CoreSimulator、~/.cache 归 dev,微信缓存归 apps);默认不勾选由 safety 驱动,
    // 与类别卡片归属无关,故不断言 safety→category。
    @Test func bundledRulesCautiousCategoryImpliesCautiousSafety() throws {
        let lr = try RuleStore().loadBundled()
        for rule in lr.rules where rule.category == .cautious {
            #expect(rule.safety == .cautious, "\(rule.id) cautious 类别规则必须 safety=cautious")
        }
    }
}
