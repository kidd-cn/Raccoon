import Testing
import CleanKit
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

    // exclude ↔ 子规则一致性:凡无 include 的 trash 规则(默认模式按根的一级子项
    // 整体作删除单元),若另一规则根位于其下,则相对首段组件必须出现在该祖先规则
    // 的 exclude 中——否则两项同选时同一目录被计入两次,释放量虚高。
    @Test func subRuleExcludedFromAncestorRule() throws {
        let lr = try RuleStore().loadBundled()
        let traversal = lr.rules.filter { $0.effectiveAction == .trash && ($0.include ?? []).isEmpty }
        for a in traversal {
            let aComps = ProtectionStore.normalize(a.path).split(separator: "/").map(String.init)
            for b in traversal where b.id != a.id {
                let bComps = ProtectionStore.normalize(b.path).split(separator: "/").map(String.init)
                guard bComps.count > aComps.count, Array(bComps.prefix(aComps.count)) == aComps else { continue }
                let firstRel = bComps[aComps.count]
                #expect(a.exclude?.contains(firstRel) == true,
                        "\(b.id) 位于 \(a.id) 之下但首段 \(firstRel) 不在其 exclude 中,将双重计数")
            }
        }
    }
}
