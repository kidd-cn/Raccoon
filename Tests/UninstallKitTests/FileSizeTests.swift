import Testing
import Foundation
@testable import UninstallKit

@Suite
final class FileSizeTests {
    let home = TempHome()

    @Test func sumsNestedRegularFiles() throws {
        let root = try home.makeDir("a", bytes: 10)
        _ = try home.makeFile("a/nested/b.bin", bytes: 25)
        #expect(FileSize.bytes(at: root) == 35)
    }

    @Test func doesNotFollowSymlinks() throws {
        let root = try home.makeDir("a", bytes: 10)
        let outside = try home.makeFile("outside.bin", bytes: 99)
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("a/link.bin"), withDestinationURL: outside)
        #expect(FileSize.bytes(at: root) == 10)
    }

    @Test func missingPathIsZero() {
        #expect(FileSize.bytes(at: home.url.appendingPathComponent("nope")) == 0)
    }

    @Test func singleFileRootCountsItsOwnBytes() throws {
        let file = try home.makeFile("single.bin", bytes: 7)
        #expect(FileSize.bytes(at: file) == 7)
    }

    @Test func doesNotDescendIntoSymlinkedDirectory() throws {
        let root = try home.makeDir("a", bytes: 10)
        let outside = try home.makeDir("outside", bytes: 77)   // outside/payload.bin
        try FileManager.default.createSymbolicLink(
            at: home.url.appendingPathComponent("a/dirlink"), withDestinationURL: outside)
        #expect(FileSize.bytes(at: root) == 10)
    }

    @Test func countsHiddenFiles() throws {
        let root = try home.makeDir("a", bytes: 10)
        _ = try home.makeFile("a/.hidden", bytes: 5)
        #expect(FileSize.bytes(at: root) == 15)
    }
}
