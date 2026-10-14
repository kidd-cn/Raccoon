import Foundation
import CleanKit

public enum RuleStoreError: Error, Equatable, Sendable {
    case fileNotFound
    case unsupportedVersion(Int)
    case decodingFailed(String)
}

public struct LoadedRules: Sendable {
    public let rules: [CleanupRule]
    public let warnings: [String]     // 如规则根重叠
    public let rejected: [String]     // "id: 原因",单条拒绝,绝不静默
}

public struct RuleStore: Sendable {
    let protection: ProtectionStore
    public init(protection: ProtectionStore = ProtectionStore()) { self.protection = protection }

    /// 整体解码/版本错误抛异常;单条规则错误进 rejected,其余照常加载。
    public func load(data: Data) throws -> LoadedRules {
        let pack: RulePack
        do { pack = try JSONDecoder().decode(RulePack.self, from: data) }
        catch { throw RuleStoreError.decodingFailed(error.localizedDescription) }
        guard pack.version == 1 else { throw RuleStoreError.unsupportedVersion(pack.version) }

        var valid: [CleanupRule] = []
        var rejected: [String] = []
        var seen = Set<String>()
        for rule in pack.rules {
            if seen.contains(rule.id) {
                rejected.append("\(rule.id): 重复 id"); continue
            }
            if let problem = Self.validate(rule, protection: protection) {
                rejected.append("\(rule.id): \(problem)"); continue
            }
            seen.insert(rule.id)
            valid.append(rule)
        }

        // 重叠告警只比较文件遍历(trash)规则——tmutil-thin 不产生文件条目,无"重复展示"问题;
        // 且快照规则的天然写法就是 path:"~",不该与 ds-store 误报
        let comparable = valid.filter { $0.effectiveAction == .trash }
        var warnings: [String] = []
        for i in comparable.indices {
            for j in comparable.indices where j > i {
                if ProtectionStore.normalize(comparable[i].path) == ProtectionStore.normalize(comparable[j].path) {
                    warnings.append("规则根重叠: \(comparable[i].id) / \(comparable[j].id)")
                }
            }
        }
        return LoadedRules(rules: valid, warnings: warnings, rejected: rejected)
    }

    static func validate(_ rule: CleanupRule, protection: ProtectionStore) -> String? {
        if rule.category == .cautious && rule.safety != .cautious {
            return "category=cautious 要求 safety=cautious"
        }
        guard rule.effectiveAction == .trash else {
            // tmutil-thin:不参与文件遍历,仅要求 cautious
            return rule.safety == .cautious ? nil : "tmutil-thin 仅允许 cautious 规则"
        }
        let std = ProtectionStore.normalize(rule.path)
        // I1(Task 2 审查):符号链接别名按解析前后双形态校验——别名指进硬保护根、或解析后逃出主目录,都整条拒绝
        let resolved = ProtectionStore.normalize((std as NSString).resolvingSymlinksInPath)
        guard ProtectionStore.isAllowedRuleRoot(std, include: rule.include),
              ProtectionStore.isAllowedRuleRoot(resolved, include: rule.include) else {
            return "规则根超出允许作用域: \(rule.path)"
        }
        if ProtectionStore.rulePathConflictsWithProtection(std, hardRoots: protection.hardRoots, include: rule.include)
            || ProtectionStore.rulePathConflictsWithProtection(resolved, hardRoots: protection.hardRoots, include: rule.include) {
            return "规则根与硬保护冲突: \(rule.path)"
        }
        return nil
    }

    /// bundle 参数默认取本模块资源包(SwiftPM 生成的 Bundle.module 为 internal,
    /// 不可用于 public 默认实参表达式,故以 nil 占位、函数体内解析——调用形状不变)。
    public func loadBundled(bundle: Bundle? = nil) throws -> LoadedRules {
        guard let url = (bundle ?? .module).url(forResource: "rules", withExtension: "json") else {
            throw RuleStoreError.fileNotFound
        }
        return try load(data: try Data(contentsOf: url))
    }
}
