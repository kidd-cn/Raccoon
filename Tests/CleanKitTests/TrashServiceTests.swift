import Foundation
import Testing
@testable import CleanKit

@Suite final class TrashServiceTests {
    // 纯映射逻辑:错误码 → 结果三态
    @Test func testMapError_threeOutcomes() {
        let vanished = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        guard case .vanished = TrashService.map(error: vanished) else { Issue.record("unexpected"); return }
        let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        guard case .skipped(let reason) = TrashService.map(error: denied), reason == "no-permission" else {
            Issue.record("unexpected"); return
        }
        let other = NSError(domain: NSPOSIXErrorDomain, code: 16)   // EBUSY
        guard case .skipped = TrashService.map(error: other) else { Issue.record("unexpected"); return }
    }

    // 真实 trash:临时文件 → 原位置消失(进入用户废纸篓,手动核对可恢复)
    @Test func testFileManagerTrashService_trashesTempFile() async {
        let path = NSTemporaryDirectory() + "raccoon-trash-\(UUID().uuidString).txt"
        try! Data("x".utf8).write(to: URL(fileURLWithPath: path))
        let outcome = await FileManagerTrashService().trash(path)
        #expect(outcome == .trashed)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func testFileManagerTrashService_vanishedForMissing() async {
        let outcome = await FileManagerTrashService().trash("/nonexistent/raccoon/xx")
        #expect(outcome == .vanished)
    }
}
