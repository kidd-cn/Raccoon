import Foundation
import Testing
@testable import CleanKit

@Suite final class CleanReportSourceTests {
    @Test func sourceDefaultsToNilAndDecodesOldRecords() throws {
        // 未传 source → nil
        let report = CleanReport(freedBytes: 100, trashedCount: 1, vanishedCount: 0, skipped: [])
        #expect(report.source == nil)

        // 旧格式记录(无 source 键)解码兼容:缺键按 nil 解码
        let date = Date()
        let old = #"{"date":\#(date.timeIntervalSinceReferenceDate),"freedBytes":100,"trashedCount":1,"vanishedCount":0,"snapshotCount":0,"skipped":[]}"#
        let decoded = try JSONDecoder().decode(CleanReport.self, from: Data(old.utf8))
        #expect(decoded.source == nil)
        #expect(decoded.freedBytes == 100)
    }

    @Test func executorPassesSource() async {
        let trash = MockTrash(outcome: .trashed)
        let exec = CleanExecutor(trash: trash, protection: ProtectionStore(), snapshots: MockSnapshots())
        let report = await exec.clean(
            [CleanItem(path: "/tmp/raccoon-src-\(UUID().uuidString)", sizeBytes: 10)],
            source: "disk-analysis")
        #expect(report.source == "disk-analysis")
    }
}
