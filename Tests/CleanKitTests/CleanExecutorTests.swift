import Foundation
import Testing
@testable import CleanKit

actor MockTrash: TrashServicing {
    let outcome: TrashOutcome
    let vanishedFor: Set<String>   // 指定路径强制返回 .vanished(模拟文件已消失)
    private(set) var calls: [String] = []
    init(outcome: TrashOutcome, vanishedFor: [String] = []) {
        self.outcome = outcome
        self.vanishedFor = Set(vanishedFor)
    }
    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        return vanishedFor.contains(path) ? .vanished : outcome
    }
}

actor MockSnapshots: SnapshotCleanerServicing {
    let listed: [String]
    private(set) var deleted: [String] = []
    init(listed: [String] = []) { self.listed = listed }
    func listSnapshots() -> [String] { listed }
    func deleteSnapshot(_ date: String) -> Bool { deleted.append(date); return true }
}

/// 线程安全进度收集器(onProgress 为 @Sendable,元组数组不可直接 #expect 比较,故逐元素断言)
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func record(_ done: Int, _ total: Int) { lock.withLock { values.append((done, total)) } }
    var snapshot: [(Int, Int)] { lock.withLock { values } }
}

@Suite final class CleanExecutorTests {
    let dir: String

    init() { dir = NSTemporaryDirectory() + "raccoon-exec-\(UUID().uuidString)" }

    func item(_ path: String, size: Int64 = 10, action: CleanAction = .trash) -> CleanItem {
        CleanItem(path: path, sizeBytes: size, action: action)
    }

    @Test func testClean_aggregatesReport_andSkipsProtected() async {
        let trash = MockTrash(outcome: .trashed, vanishedFor: ["/nonexistent/x"])
        let protection = ProtectionStore(userExclusions: [dir + "/excluded"])
        let exec = CleanExecutor(trash: trash, protection: protection, snapshots: MockSnapshots())
        let report = await exec.clean([
            item(dir + "/a", size: 100),
            item(dir + "/excluded", size: 200),          // 用户排除 → 引擎兜底拦截
            item("/nonexistent/x", size: 5),             // vanished
            item(dir + "/snapshot", action: .tmutilThin(date: "2026-10-13-120000")),
        ])
        #expect(report.trashedCount == 1)
        #expect(report.freedBytes == 100)
        #expect(report.vanishedCount == 1)
        #expect(report.snapshotCount == 1)
        #expect(report.skipped.map(\.path) == [dir + "/excluded"])
        let calls = await trash.calls
        #expect(calls == [dir + "/a", "/nonexistent/x"])
    }

    @Test func testClean_securityRegression_neverTrashesProtectedEvenIfInjected() async {
        // 纵深防御:即便上游把受保护路径塞进清理列表,执行器仍拦截
        let trash = MockTrash(outcome: .trashed)
        let exec = CleanExecutor(trash: trash, protection: ProtectionStore(), snapshots: MockSnapshots())
        let report = await exec.clean([item("\(NSHomeDirectory())/Documents/thesis.docx", size: 999)])
        #expect(report.trashedCount == 0)
        #expect(report.skipped.count == 1)
        #expect(report.skipped[0].reason == "protected")
        let calls = await trash.calls
        #expect(calls.isEmpty)
    }

    @Test func clean_rejectsRelativePaths() async {
        // isDenied 契约要求绝对路径:相对路径按 CWD 解析可绕过组件前缀匹配 → 引擎层硬拒
        let trash = MockTrash(outcome: .trashed)
        let exec = CleanExecutor(trash: trash, protection: ProtectionStore(), snapshots: MockSnapshots())
        let report = await exec.clean([
            item("Documents/thesis.docx", size: 999),
            item("", size: 1),
        ])
        #expect(report.trashedCount == 0)
        #expect(report.skipped.count == 2)
        #expect(report.skipped.allSatisfy { $0.reason == "invalid-path" })
        let calls = await trash.calls
        #expect(calls.isEmpty)
    }

    @Test func testClean_progressReportsEachItem() async {
        let exec = CleanExecutor(trash: MockTrash(outcome: .trashed), protection: ProtectionStore(), snapshots: MockSnapshots())
        let seen = ProgressRecorder()
        _ = await exec.clean([item("a"), item("b"), item("c")]) { done, total in seen.record(done, total) }
        let s = seen.snapshot
        #expect(s.count == 3)
        if s.count == 3 {
            #expect(s[0] == (1, 3))
            #expect(s[1] == (2, 3))
            #expect(s[2] == (3, 3))
        }
    }
}
