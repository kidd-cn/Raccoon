import Testing
import Foundation
@testable import AppCore

@Suite final class ExclusionsStoreTests {
    let suite: String
    let defaults: UserDefaults

    init() {
        suite = "excl-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    deinit { defaults.removePersistentDomain(forName: suite) }

    @MainActor
    @Test func testAddNormalizeDedupeAndPersist() {
        let store = ExclusionsStore(defaults: defaults)
        store.add("")                                             // 空串守卫:不收录
        #expect(store.exclusions.isEmpty)
        store.add("/tmp/foo/")
        #expect(store.exclusions == ["/tmp/foo"])           // 尾斜杠归一化
        store.add("/tmp/foo")                                     // 去重
        #expect(store.exclusions.count == 1)
        #expect(defaults.stringArray(forKey: "userExclusions") == ["/tmp/foo"])   // 已持久化
    }

    @MainActor
    @Test func testRemoveAndReload() {
        let store = ExclusionsStore(defaults: defaults)
        store.add("/tmp/a"); store.add("/tmp/b")
        store.remove("/tmp/a")
        #expect(store.exclusions == ["/tmp/b"])
        let reloaded = ExclusionsStore(defaults: defaults)        // 从 defaults 重载
        #expect(reloaded.exclusions == ["/tmp/b"])
    }
}
