import Testing
@testable import CleanKit

@Suite struct SystemIntegrationTests {
    // —— bundle id 路径段提取(纯函数)——
    @Test func testBundleIDComponent() {
        func bid(_ p: String) -> String? { AppIdentityResolver.bundleIDComponent(in: p) }
        #expect(bid("/Users/x/Library/Caches/com.google.Chrome/Cache") == "com.google.Chrome")
        #expect(bid("/x/com.tinyspeck.slackmacgap") == "com.tinyspeck.slackmacgap")
        #expect(bid("/Users/x/Library/Caches/Google/Chrome") == nil)   // 无 bundle-id 段
        #expect(bid("/x/Cache") == nil)                                 // 单段
        #expect(bid("/x/a..b") == nil)                                  // 空段非法
        #expect(bid("/x/com.apple.calc$$") == nil)                      // 非法字符
    }

    @Test @MainActor
    func testAppName_knownInstalledApp() {
        let name = AppIdentityResolver().appName(for: "com.apple.Safari")
        #expect(name != nil)                    // Safari 必装
        #expect(!(name?.isEmpty ?? true))
    }

    @Test @MainActor
    func testAppName_unknownFallsBackToNil() {
        #expect(AppIdentityResolver().appName(for: "com.raccoon.notexist") == nil)
    }

    @Test @MainActor
    func testWorkspaceDetector_returnsSet() {
        let ids = WorkspaceRunningAppDetector().runningBundleIDs()
        _ = ids                                 // 冒烟:能取到集合、不崩即过(运行中应用数不定)
    }
}
