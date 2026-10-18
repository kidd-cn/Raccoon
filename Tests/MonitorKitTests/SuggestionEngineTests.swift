import Testing
@testable import MonitorKit

@Suite struct SuggestionEngineTests {

    /// 无任何命中的健康输入:阈值之上、无快照、无启动项、无崩溃报告。
    private func healthy(
        fraction: Double = 0.45,
        bytes: Int64 = 400_000_000_000,
        snapshots: Bool = false,
        agents: Int = 0,
        crashes: Int = 0
    ) -> SuggestionsInput {
        SuggestionsInput(
            minVolumeFreeFraction: fraction,
            minVolumeFreeBytes: bytes,
            hasSnapshots: snapshots,
            userLaunchAgentCount: agents,
            crashReportCount: crashes
        )
    }

    // MARK: - 磁盘规则(双阈值「或」)

    @Test func lowFractionAloneTriggersDiskSuggestion() {
        let out = suggestions(for: healthy(fraction: 0.05))
        #expect(out == [Suggestion(id: "disk", destination: .cleanup)])
    }

    @Test func lowBytesAloneTriggersDiskSuggestion() {
        let out = suggestions(for: healthy(bytes: 5_000_000_000))
        #expect(out == [Suggestion(id: "disk", destination: .cleanup)])
    }

    @Test func fractionExactlyAtThresholdYieldsNoDiskSuggestion() {
        let out = suggestions(for: healthy(fraction: 0.10))
        #expect(out == [])
    }

    @Test func bytesExactlyAtThresholdYieldsNoDiskSuggestion() {
        let out = suggestions(for: healthy(bytes: 10_737_418_240))
        #expect(out == [])
    }

    // MARK: - 其余三条规则

    @Test func snapshotsRule() {
        #expect(suggestions(for: healthy(snapshots: true))
                == [Suggestion(id: "snapshots", destination: .cleanup)])
        #expect(suggestions(for: healthy(snapshots: false)) == [])
    }

    @Test func launchItemsRule() {
        #expect(suggestions(for: healthy(agents: 3))
                == [Suggestion(id: "launchitems", destination: .launchItems)])
        #expect(suggestions(for: healthy(agents: 0)) == [])
    }

    @Test func crashReportsRule() {
        #expect(suggestions(for: healthy(crashes: 12))
                == [Suggestion(id: "crashreports", destination: .cleanup)])
        #expect(suggestions(for: healthy(crashes: 0)) == [])
    }

    // MARK: - 组合与顺序

    @Test func allRulesHitKeepsStableOrder() {
        let out = suggestions(for: healthy(fraction: 0.03, bytes: 1_000_000_000,
                                          snapshots: true, agents: 7, crashes: 42))
        #expect(out.map(\.id) == ["disk", "snapshots", "launchitems", "crashreports"])
    }

    @Test func nothingHitReturnsEmpty() {
        #expect(suggestions(for: healthy()).isEmpty)
    }
}
