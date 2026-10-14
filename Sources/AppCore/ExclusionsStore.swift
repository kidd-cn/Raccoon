import Foundation
import CleanKit

/// 用户排除清单:扫描过滤与删除前校验共用的用户侧输入。
/// 契约:单所有者写入(Phase 1 单窗口单实例);多实例并发写同一 defaults 域为整组覆盖,互不感知。
@MainActor
@Observable
public final class ExclusionsStore {
    static let defaultsKey = "userExclusions"
    let defaults: UserDefaults
    public private(set) var exclusions: [String]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.exclusions = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    public func add(_ path: String) {
        let normalized = ProtectionStore.normalize(path)
        guard !normalized.isEmpty, !exclusions.contains(normalized) else { return }
        exclusions.append(normalized)
        persist()
    }

    public func remove(_ path: String) {
        let normalized = ProtectionStore.normalize(path)
        exclusions.removeAll { $0 == normalized }
        persist()
    }

    func persist() { defaults.set(exclusions, forKey: Self.defaultsKey) }
}
