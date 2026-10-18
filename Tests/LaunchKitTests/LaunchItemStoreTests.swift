import Foundation
import Testing
import CleanKit
@testable import LaunchKit

// MARK: - 假体(只记录调用,绝不触达文件系统)

private actor RecordingTrash: TrashServicing {
    let outcome: TrashOutcome
    private(set) var calls: [String] = []

    init(outcome: TrashOutcome) { self.outcome = outcome }

    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        return outcome
    }
}

private func launchItem(at path: String) -> LaunchItem {
    LaunchItem(path: path, fileName: (path as NSString).lastPathComponent,
               label: "com.test.agent", programName: "/bin/true",
               runAtLoad: false, keepAlive: false, disabled: false, parseFailed: false)
}

// MARK: - 用例

@Suite final class LaunchItemStoreTests {

    /// 硬保护命中:先门禁后触达——isDenied 为真时假体必须零调用。
    @Test func hardProtectedItemIsDeniedWithoutTouchingTrash() async {
        let path = "/Users/x/Library/LaunchAgents/com.hard.agent.plist"
        let trash = RecordingTrash(outcome: .trashed)
        let store = LaunchItemStore(
            trash: trash,
            protection: ProtectionStore(hardRoots: ["/Users/x/Library/LaunchAgents"],
                                        userExclusions: [])
        )

        let outcome = await store.disable(launchItem(at: path))

        guard case .denied = outcome else {
            Issue.record("expected denied, got \(outcome)")
            return
        }
        let calls = await trash.calls
        #expect(calls.isEmpty)
    }

    /// 用户排除命中:与硬保护同一门禁路径,零调用。
    @Test func userExcludedItemIsDeniedWithoutTouchingTrash() async {
        let path = "/Users/x/Library/LaunchAgents/com.excluded.agent.plist"
        let trash = RecordingTrash(outcome: .trashed)
        let store = LaunchItemStore(
            trash: trash,
            protection: ProtectionStore(hardRoots: [], userExclusions: [path])
        )

        let outcome = await store.disable(launchItem(at: path))

        guard case .denied = outcome else {
            Issue.record("expected denied, got \(outcome)")
            return
        }
        let calls = await trash.calls
        #expect(calls.isEmpty)
    }

    /// 正常项:恰一次调用该 path,报告带 source 记账,skipped 为空。
    @Test func normalItemIsTrashedOnceWithLaunchItemsSource() async {
        let path = "/Users/x/Library/LaunchAgents/com.normal.agent.plist"
        let trash = RecordingTrash(outcome: .trashed)
        let store = LaunchItemStore(trash: trash,
                                    protection: ProtectionStore(hardRoots: [], userExclusions: []))

        let outcome = await store.disable(launchItem(at: path))

        guard case .trashed(let report) = outcome else {
            Issue.record("expected trashed, got \(outcome)")
            return
        }
        #expect(report.trashedCount == 1)
        #expect(report.skipped.isEmpty)
        #expect(report.source == "launch-items")
        let calls = await trash.calls
        #expect(calls == [path])
    }

    /// 下层拒绝 → failed;skipped 原因透传,vanished 走 "not trashed" 兜底,均不崩溃。
    @Test func trashRefusalMapsToFailedWithoutCrashing() async {
        let path = "/Users/x/Library/LaunchAgents/com.refused.agent.plist"
        let item = launchItem(at: path)
        let protection = ProtectionStore(hardRoots: [], userExclusions: [])

        let refused = RecordingTrash(outcome: .skipped(reason: "no-permission"))
        let first = await LaunchItemStore(trash: refused, protection: protection).disable(item)
        guard case .failed(let reason) = first else {
            Issue.record("expected failed, got \(first)")
            return
        }
        #expect(reason == "no-permission")

        let vanished = RecordingTrash(outcome: .vanished)
        let second = await LaunchItemStore(trash: vanished, protection: protection).disable(item)
        guard case .failed(let fallback) = second else {
            Issue.record("expected failed, got \(second)")
            return
        }
        #expect(fallback == "not trashed")
    }

    /// 安装路径不在硬保护根内:默认硬保护不得误伤 LaunchAgents。
    @Test func installPathUnderLaunchAgentsIsNotFalselyDenied() async {
        let path = "/Users/x/Library/LaunchAgents/foo.plist"
        let trash = RecordingTrash(outcome: .trashed)
        let store = LaunchItemStore(trash: trash, protection: ProtectionStore())

        let outcome = await store.disable(launchItem(at: path))

        guard case .trashed = outcome else {
            Issue.record("expected trashed, got \(outcome)")
            return
        }
        let calls = await trash.calls
        #expect(calls == [path])
    }
}
