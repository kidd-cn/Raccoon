import Foundation
import CleanKit

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
        exclusions.removeAll { $0 == path }
        persist()
    }

    func persist() { defaults.set(exclusions, forKey: Self.defaultsKey) }
}
