import Foundation
import Testing
import CleanKit
@testable import ScanKit

@Suite final class ScanEngineTests {
    var root: String!

    init() { root = ScanFixtures.makeTree() }
    deinit { ScanFixtures.remove(root) }

    func engine(protection: ProtectionStore = ProtectionStore(),
                running: Set<String> = [],
                limit: Int = 500_000) -> ScanEngine {
        ScanEngine(deps: .init(protection: protection,
                               runningBundleIDs: { running },
                               snapshots: MockSnapshots(),
                               itemLimitPerRule: limit))
    }

    // MARK: 默认模式(根的一级子项 = 删除单元)

    @Test func defaultMode_childrenAreHits_withDeepSize() async throws {
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let hits = result.hits
        #expect(hits.count == 3)   // com.google.Chrome / com.spotify.client / stray.log
        let chrome = try #require(hits.first { $0.path.hasSuffix("com.google.Chrome") })
        #expect(chrome.sizeBytes == 300)
        #expect(chrome.isDirectory)
        #expect(chrome.ruleID == "c")
        #expect(chrome.category == .system)
        #expect(chrome.safety == .safe)
        #expect(chrome.action == .trash)
    }

    @Test func defaultMode_excludeMatchesLastComponent() async throws {
        let result = try await engine().scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches", exclude: ["com.spotify.client", "*.log"])])
        #expect(result.hits.map(\.path).sorted() == [root + "/Caches/com.google.Chrome"])
        #expect(result.excludedCount == 2)
    }

    @Test func defaultMode_userExclusionFiltersHit() async throws {
        let protection = ProtectionStore(userExclusions: [root + "/Caches/com.google.Chrome"])
        let result = try await engine(protection: protection).scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        #expect(result.hits.count == 2)
        #expect(result.excludedCount == 1)
    }

    @Test func defaultMode_runningAppFlagged() async throws {
        let result = try await engine(running: ["com.google.Chrome"]).scan(
            rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let chrome = try #require(result.hits.first { $0.bundleID == "com.google.Chrome" })
        #expect(chrome.isAppRunning)
        let spotify = try #require(result.hits.first { $0.path.hasSuffix("com.spotify.client") })
        #expect(!spotify.isAppRunning)
    }

    @Test func defaultMode_tildeExpansion() async throws {
        // ~ 展开正确性:用真实 ~/Library/Logs 目录存在与否都应安全返回(0 条或若干条,不抛错)
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "l", path: "~/Library/Logs_nonexistent")])
        #expect(result.hits.count == 0)
    }

    @Test func defaultMode_missingRootYieldsEmpty() async throws {
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "x", path: root + "/nope")])
        #expect(result.hits.count == 0)
    }

    @Test func defaultMode_symlinkChildNotBlownUp() async throws {
        let target = root + "/Caches/com.google.Chrome"
        try FileManager.default.createSymbolicLink(atPath: root + "/Caches/loop", withDestinationPath: target)
        let result = try await engine().scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        let loop = try #require(result.hits.first { $0.path.hasSuffix("/loop") })
        #expect(loop.sizeBytes == 0)   // 符号链接按 0 计,不深入目标
    }

    @Test func defaultMode_itemLimitTruncates() async throws {
        let result = try await engine(limit: 2).scan(rules: [ScanFixtures.rule(id: "c", path: root + "/Caches")])
        #expect(result.hits.count == 2)
        #expect(result.truncatedRuleIDs == Set(["c"]))   // truncatedRuleIDs 是 Set<String>
    }

    @Test func progress_eventsPerRule() async throws {
        let log = ScanFixtures.ProgressLog()
        _ = try await engine().scan(rules: [
            ScanFixtures.rule(id: "a", path: root + "/Caches"),
            ScanFixtures.rule(id: "b", path: root + "/Logs"),
        ]) { log.append($0) }
        let events = log.events
        #expect(events.count == 2)
        #expect(events.last?.rulesDone == 2)
        #expect(events.last?.rulesTotal == 2)
    }

    @Test func summaries_aggregatedByCategory() async throws {
        let result = try await engine().scan(rules: [
            ScanFixtures.rule(id: "c", path: root + "/Caches"),
            ScanFixtures.rule(id: "l", path: root + "/Logs", category: .dev),
        ])
        #expect(result.summaries.count == 2)
        let system = try #require(result.summaries.first { $0.category == .system })
        #expect(system.totalBytes == 360)
        #expect(system.hitCount == 3)
    }
}
