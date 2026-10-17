import Testing
import Foundation
import CleanKit
@testable import UninstallKit

@Suite
final class SmokeTests {
    @Test func modelsAreConstructible() {
        let app = InstalledApp(bundleID: "com.example.foo", name: "Foo", version: "1.2",
                               appPath: "/Applications/Foo.app", sizeBytes: 1024, isRunning: false)
        #expect(app.id == "com.example.foo")
        let leftover = AppLeftover(path: "/tmp/x", sizeBytes: 1, safety: .regenerable,
                                   ownership: .bundleID, locationID: "caches")
        #expect(leftover.id == "/tmp/x")
        #expect(LeftoverSafety.userData.rawValue == "userData")
        #expect(CleanProgress(done: 1, total: 2) == CleanProgress(done: 1, total: 2))
    }
}
