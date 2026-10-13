import Testing
@testable import CleanKit

@Suite final class SnapshotCleanerTests {
    @Test func testParseSnapshotDate() {
        #expect(TmutilSnapshotCleaner.parseSnapshotDate("com.apple.TimeMachine.2026-10-13-120000.local") == "2026-10-13-120000")
        #expect(TmutilSnapshotCleaner.parseSnapshotDate("Snapshots for /:") == nil)
        #expect(TmutilSnapshotCleaner.parseSnapshotDate("com.apple.TimeMachine..local") == nil)
    }

    // M1 回归:删除不存在的快照,tmutil exit 70 → false(以退出码判定,真实子进程集成测试)
    @Test func testDeleteSnapshot_bogusDateReturnsFalse() async {
        let ok = await TmutilSnapshotCleaner().deleteSnapshot("2000-01-01-000000")
        #expect(!ok)
    }
}
