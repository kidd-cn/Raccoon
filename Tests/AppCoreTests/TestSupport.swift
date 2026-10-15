import Foundation
import CleanKit
import ScanKit
@testable import AppCore

struct FakeScanService: ScanServicing {
    var result: ScanResult
    func scan(exclusions: [String],
              progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        progress(ScanProgress(rulesDone: 1, rulesTotal: 1,
                              hitsFound: result.hits.count,
                              bytesFound: result.hits.reduce(Int64(0)) { $0 + $1.sizeBytes }))
        return result
    }
}

actor MockTrash: TrashServicing {
    let outcome: TrashOutcome
    let vanishedFor: Set<String>   // 预留:指定路径强制返回 .vanished(报告态 vanishedCount 测试将用;当前 AppCore 用例未传)
    let skippedFor: Set<String>    // 指定路径强制 skipped:混合结果轮用(仅被跳过的项须留在列表与选择集)
    private(set) var calls: [String] = []
    init(outcome: TrashOutcome, vanishedFor: [String] = [], skippedFor: [String] = []) {
        self.outcome = outcome
        self.vanishedFor = Set(vanishedFor)
        self.skippedFor = Set(skippedFor)
    }
    func trash(_ path: String) async -> TrashOutcome {
        calls.append(path)
        if skippedFor.contains(path) { return .skipped(reason: "no-permission") }
        return vanishedFor.contains(path) ? .vanished : outcome
    }
}
