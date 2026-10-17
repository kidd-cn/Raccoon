import Foundation
import Testing
@testable import CleanKit

@Suite struct HistoryStoreTests {
    func makeDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "raccoon-hist-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func append_and_loadAll_roundtrip() throws {
        let store = JSONHistoryStore(directory: makeDir())
        try store.append(CleanReport(freedBytes: 100, trashedCount: 1, vanishedCount: 0, skipped: []))
        try store.append(CleanReport(freedBytes: 250, trashedCount: 2, vanishedCount: 1, skipped: []))
        let all = try store.loadAll()
        #expect(all.count == 2)
        #expect(all.map(\.freedBytes) == [100, 250])
    }

    @Test func append_preservesCorruptFileAside_andRecovers() throws {
        let dir = makeDir()
        let store = JSONHistoryStore(directory: dir)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("history.json"))
        try store.append(CleanReport(freedBytes: 7, trashedCount: 1, vanishedCount: 0, skipped: []))
        let all = try store.loadAll()
        #expect(all.count == 1)
        #expect(all[0].freedBytes == 7)
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let backups = contents.filter { $0.lastPathComponent.hasPrefix("history-corrupted-") }
        #expect(backups.count == 1)
    }

    @Test func keepsOnlyLatest200Reports() throws {
        let dir = makeDir()
        let store = JSONHistoryStore(directory: dir)
        for i in 0..<205 {
            try store.append(CleanReport(date: Date(timeIntervalSince1970: Double(i)),
                                         freedBytes: Int64(i), trashedCount: 1,
                                         vanishedCount: 0, skipped: []))
        }
        let all = try store.loadAll()
        #expect(all.count == 200)
        #expect(all.first?.freedBytes == 5)    // 最早的 5 条被裁剪
        #expect(all.last?.freedBytes == 204)
    }
}
