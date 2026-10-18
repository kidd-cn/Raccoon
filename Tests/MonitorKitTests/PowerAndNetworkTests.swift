import Testing
@testable import MonitorKit

@Suite struct PowerAndNetworkTests {

    // MARK: - 电池

    @Test func batteryWithSourcePassesThroughAllFields() {
        let info = assembleBatteryInfo(hasSource: true, percent: 88.5, charging: true, onBattery: false)
        #expect(info == BatteryInfo(hasBattery: true, percentage: 88.5, charging: true, onBattery: false))
    }

    @Test func emptyPowerSourceMeansNoBatteryAndZeroPercentage() {
        let info = assembleBatteryInfo(hasSource: false, percent: 77, charging: false, onBattery: false)
        #expect(info.hasBattery == false)
        #expect(info.percentage == 0)
        #expect(!info.percentage.isNaN)
    }

    @Test func missingPercentTreatedAsNoBattery() {
        let info = assembleBatteryInfo(hasSource: true, percent: nil, charging: false, onBattery: true)
        #expect(info.hasBattery == false)
        #expect(info.percentage == 0)
        #expect(!info.percentage.isNaN)
    }

    @Test func percentClampedIntoClosedRange() {
        let low = assembleBatteryInfo(hasSource: true, percent: -5, charging: false, onBattery: true)
        #expect(low.hasBattery == true)
        #expect(low.percentage == 0)

        let high = assembleBatteryInfo(hasSource: true, percent: 150, charging: true, onBattery: false)
        #expect(high.hasBattery == true)
        #expect(high.percentage == 100)
    }

    // MARK: - 网络

    @Test func offlineAlwaysReportsOtherInterface() {
        let status = assembleNetworkStatus(satisfied: false, isWiFi: true, isWired: true)
        #expect(status.online == false)
        #expect(status.interface == .other)
    }

    @Test func onlineOverWiFiMapsToWifi() {
        let status = assembleNetworkStatus(satisfied: true, isWiFi: true, isWired: false)
        #expect(status == NetworkStatus(online: true, interface: .wifi))
    }

    @Test func onlineOverCableMapsToWired() {
        let status = assembleNetworkStatus(satisfied: true, isWiFi: false, isWired: true)
        #expect(status == NetworkStatus(online: true, interface: .wired))
    }

    @Test func onlineButNeitherFlagMapsToOther() {
        let status = assembleNetworkStatus(satisfied: true, isWiFi: false, isWired: false)
        #expect(status.online == true)
        #expect(status.interface == .other)
    }
}
