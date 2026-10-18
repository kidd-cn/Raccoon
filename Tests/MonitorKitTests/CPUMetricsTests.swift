import Testing
@testable import MonitorKit

@Suite struct CPUMetricsTests {

    @Test func singleCoreDeltaMath() throws {
        // 差值:user 100、system 50、idle 50、nice 0,总计 200 → 50 / 25 / 25
        let load = try #require(computeCPULoad(previous: [100, 100, 100, 100],
                                               current: [200, 150, 150, 100]))
        #expect(abs(load.userPct - 50) < 0.001)
        #expect(abs(load.systemPct - 25) < 0.001)
        #expect(abs(load.idlePct - 25) < 0.001)
    }

    @Test func multiCoreSumsPerStateAcrossCores() throws {
        // 核 1 差值 (40,20,20,20)、核 2 差值 (60,30,30,30);
        // 跨核合计 user 100、system 50、idle 50、nice 50,总计 250,
        // nice 并入 user 后 (100+50)/250 = 60%
        let load = try #require(computeCPULoad(
            previous: [100, 100, 100, 100, 200, 200, 200, 200],
            current: [140, 120, 120, 120, 260, 230, 230, 230]))
        #expect(abs(load.userPct - 60) < 0.001)
        #expect(abs(load.systemPct - 20) < 0.001)
        #expect(abs(load.idlePct - 20) < 0.001)
        #expect(abs(load.userPct + load.systemPct + load.idlePct - 100) < 0.001)
    }

    @Test func firstSampleReturnsNil() {
        // 首采样没有基准可减,调用方应先落盘 current 再等下一拍
        #expect(computeCPULoad(previous: nil, current: [100, 100, 100, 100]) == nil)
    }

    @Test func countMismatchReturnsNil() {
        #expect(computeCPULoad(previous: [0, 0, 0, 0],
                               current: [0, 0, 0, 0, 0, 0, 0, 0]) == nil)
    }

    @Test func countNotMultipleOfFourReturnsNil() {
        #expect(computeCPULoad(previous: [1, 2, 3, 4, 5],
                               current: [1, 2, 3, 4, 5]) == nil)
    }

    @Test func zeroTotalDeltaReturnsNil() {
        // 两次采样完全一致:区间内无 tick 流逝,占比无意义
        #expect(computeCPULoad(previous: [100, 100, 100, 100],
                               current: [100, 100, 100, 100]) == nil)
    }

    @Test func negativeTotalDeltaReturnsNil() {
        // 计数器回绕/重置会产生负差值,同样视为无效区间
        #expect(computeCPULoad(previous: [200, 200, 200, 200],
                               current: [100, 100, 100, 100]) == nil)
    }
}
