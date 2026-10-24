import Testing
import Foundation
import MonitorKit

@Suite struct TrafficMetricsTests {
    // 白名单:en 前缀参与,其余(lo/utun/ipsec/awdl/llw/ap/bridge)全排除
    @Test func whitelistOnlyEnInterfaces() {
        let counters = assembleTrafficCounters([
            (name: "en0", rx: 100, tx: 10),
            (name: "lo0", rx: 5, tx: 5),
            (name: "utun3", rx: 50, tx: 50),
            (name: "ipsec0", rx: 7, tx: 7),
            (name: "awdl0", rx: 9, tx: 9),
            (name: "llw0", rx: 3, tx: 3),
            (name: "ap1", rx: 2, tx: 2),
            (name: "bridge0", rx: 4, tx: 4),
        ])
        #expect(counters == NetworkTrafficCounters(rxBytes: 100, txBytes: 10))
    }

    // 同名去重:getifaddrs 同接口多地址族,只计首条,防双计
    @Test func deduplicatesSameNameEntries() {
        let counters = assembleTrafficCounters([
            (name: "en0", rx: 100, tx: 10),
            (name: "en0", rx: 100, tx: 10),
            (name: "en1", rx: 1, tx: 1),
            (name: "en1", rx: 999, tx: 999),
        ])
        #expect(counters == NetworkTrafficCounters(rxBytes: 101, txBytes: 11))
    }

    @Test func emptyInputIsNil() {
        #expect(assembleTrafficCounters([]) == nil)
    }

    @Test func allExcludedIsNil() {
        #expect(assembleTrafficCounters([(name: "utun0", rx: 1, tx: 1)]) == nil)
    }

    // 差分:正常推进
    @Test func trafficDeltaComputesRates() {
        let t = assembleTraffic(
            current: NetworkTrafficCounters(rxBytes: 2048, txBytes: 2048),
            previous: NetworkTrafficCounters(rxBytes: 1024, txBytes: 512),
            elapsedSeconds: 2)
        #expect(t.receivedBytes == 2048 && t.sentBytes == 2048)
        #expect(t.receivedBPS == 512.0 && t.sentBPS == 768.0)
    }

    // 负 delta(接口重置/计数器清零)该维钳 0,另一维照常
    @Test func negativeDeltaClampsToZeroPerDimension() {
        let t = assembleTraffic(
            current: NetworkTrafficCounters(rxBytes: 10, txBytes: 3000),
            previous: NetworkTrafficCounters(rxBytes: 1000, txBytes: 1000),
            elapsedSeconds: 1)
        #expect(t.receivedBytes == 10 && t.sentBytes == 3000)
        #expect(t.receivedBPS == 0.0 && t.sentBPS == 2000.0)
    }

    // elapsed ≤ 0(同拍/时钟回拨):速率 nil,累计照出
    @Test func nonPositiveElapsedYieldsNilRatesOnly() {
        let counters = NetworkTrafficCounters(rxBytes: 500, txBytes: 600)
        for elapsed in [0.0, -3.0] {
            let t = assembleTraffic(current: counters, previous: NetworkTrafficCounters(rxBytes: 100, txBytes: 100), elapsedSeconds: elapsed)
            #expect(t.receivedBytes == 500 && t.sentBytes == 600)
            #expect(t.receivedBPS == nil && t.sentBPS == nil)
        }
    }
}
