import Testing
@testable import MonitorKit

@Suite struct MemoryMetricsTests {

    @Test func regularAssemblyComputesUsedExcludingFreeInactivePurgeable() {
        let stats = assembleMemoryStats(
            totalBytes: 16_000_000_000,
            freeBytes: 2_000_000_000,
            inactiveBytes: 1_000_000_000,
            purgeableBytes: 500_000_000,
            wiredBytes: 1_200_000_000,
            compressedBytes: 800_000_000
        )
        // used = 16G - 2G - 1G - 0.5G = 12.5G;compressed 是外部页,计入 used 而非从总量扣除
        #expect(stats.totalBytes == 16_000_000_000)
        #expect(stats.usedBytes == 12_500_000_000)
        #expect(stats.compressedBytes == 800_000_000)
        #expect(stats.wiredBytes == 1_200_000_000)
        #expect(stats.purgeableFreeBytes == 500_000_000)
    }

    @Test func usedClampedToZeroWhenFreeSideExceedsTotal() {
        // free+inactive+purgeable = 140 > total = 100,裸算得 -40,必须夹到 0 而非呈现负占用
        let stats = assembleMemoryStats(
            totalBytes: 100,
            freeBytes: 80,
            inactiveBytes: 50,
            purgeableBytes: 10,
            wiredBytes: 5,
            compressedBytes: 5
        )
        #expect(stats.usedBytes == 0)
    }
}

@Suite struct SampleRingTests {

    @Test func overflowDropsOldestAndKeepsOrder() {
        var ring = SampleRing<Int>(capacity: 3)
        ring.append(1)
        ring.append(2)
        ring.append(3)
        #expect(ring.values == [1, 2, 3])
        ring.append(4)
        #expect(ring.values == [2, 3, 4])
    }

    @Test func valuesAreOldestFirstBelowCapacity() {
        var ring = SampleRing<Int>(capacity: 5)
        ring.append(10)
        ring.append(20)
        #expect(ring.values == [10, 20])
    }

    @Test func nonPositiveCapacityIgnoresAppends() {
        var zero = SampleRing<Int>(capacity: 0)
        zero.append(1)
        #expect(zero.values.isEmpty)

        var negative = SampleRing<Int>(capacity: -3)
        negative.append(1)
        #expect(negative.values.isEmpty)
    }
}
