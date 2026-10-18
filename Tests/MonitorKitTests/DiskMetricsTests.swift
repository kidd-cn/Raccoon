import Testing
@testable import MonitorKit

@Suite struct DiskMetricsTests {

    @Test func regularAssemblyPurgeableIsDifference() {
        let info = assembleVolumeInfo(
            name: "Macintosh HD",
            totalBytes: 500_000_000_000,
            availableBytes: 50_000_000_000,
            importantUsageBytes: 80_000_000_000,
            homeVolumeName: "Macintosh HD"
        )
        #expect(info.name == "Macintosh HD")
        #expect(info.totalBytes == 500_000_000_000)
        #expect(info.availableBytes == 50_000_000_000)
        #expect(info.purgeableBytes == 30_000_000_000)
    }

    @Test func purgeableClampedToZeroWhenUsageBelowAvailable() {
        let info = assembleVolumeInfo(
            name: "External",
            totalBytes: 1_000_000_000,
            availableBytes: 400_000_000,
            importantUsageBytes: 100_000_000,
            homeVolumeName: "Macintosh HD"
        )
        #expect(info.purgeableBytes == 0)
    }

    @Test func isSystemDiskMatchesHomeVolumeName() {
        let same = assembleVolumeInfo(
            name: "Macintosh HD",
            totalBytes: 100,
            availableBytes: 10,
            importantUsageBytes: 20,
            homeVolumeName: "Macintosh HD"
        )
        #expect(same.isSystemDisk == true)

        let other = assembleVolumeInfo(
            name: "Backup",
            totalBytes: 100,
            availableBytes: 10,
            importantUsageBytes: 20,
            homeVolumeName: "Macintosh HD"
        )
        #expect(other.isSystemDisk == false)
    }
}
