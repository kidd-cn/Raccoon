import Foundation
import Testing
import CleanKit
@testable import DiskKit

// MARK: - 夹具帮手(本文件私有;自建 temp 子树,测试结束自清——夹具清理允许 removeItem)

private func makeFixtureDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("raccoon-diskkit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// spec key 为相对路径,值:Data → 文件内容;[String: Any] → 子目录;字符串 "symlink:<target>" → 符号链接
@discardableResult
private func makeTree(_ root: URL, _ spec: [String: Any]) throws -> URL {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    for (rel, value) in spec {
        let target = root.appendingPathComponent(rel)
        switch value {
        case let data as Data:
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        case let sub as [String: Any]:
            try makeTree(target, sub)
        case let dest as String where dest.hasPrefix("symlink:"):
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: String(dest.dropFirst("symlink:".count)))
        default:
            Issue.record("makeTree 不支持的夹具值类型: \(rel)")
        }
    }
    return root
}

private func allNodes(_ node: DiskNode) -> [DiskNode] {
    [node] + node.children.flatMap(allNodes)
}

/// onProgress 回调发生在扫描任务所在线程,跨线程收集自带上锁。
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DiskScanProgress] = []
    func record(_ p: DiskScanProgress) {
        lock.lock(); defer { lock.unlock() }
        items.append(p)
    }
    var all: [DiskScanProgress] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

private func makeScanner(hardRoots: [String] = [], userExclusions: [String] = []) -> DiskScanner {
    DiskScanner(protection: ProtectionStore(hardRoots: hardRoots, userExclusions: userExclusions))
}

// MARK: - 用例

@Suite final class DiskScannerTests {

    @Test func sizesAggregateBottomUp() async throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        _ = try makeTree(fx, [
            "a": Data(repeating: 0x41, count: 1_000_000),
            "b": ["c": Data(repeating: 0x42, count: 2_000)],
        ])

        let scanned = try await makeScanner().scan(root: fx.path)

        #expect(scanned.isDirectory)
        let a = try #require(scanned.children.first { $0.name == "a" })
        let b = try #require(scanned.children.first { $0.name == "b" })
        let c = try #require(b.children.first { $0.name == "c" })

        // 自底向上聚合:目录 = 子树文件之和
        #expect(scanned.sizeBytes == a.sizeBytes + b.sizeBytes)
        #expect(b.sizeBytes == c.sizeBytes)
        #expect(b.children.count == 1)
        // 文件体量口径 = 自身 fileAllocSize(读回 resourceValues 对账;新 Foundation 名为 fileAllocatedSize)
        let alloc = try URL(fileURLWithPath: a.path).resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize
        #expect(a.sizeBytes == Int64(alloc ?? 0))
    }

    @Test func trashPrunedAndSymlinksSkipped() async throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        _ = try makeTree(fx, [
            "a": Data(repeating: 0x41, count: 100),
            ".Trash": ["junk": Data(repeating: 0x00, count: 50)],
            "link": "symlink:a",
        ])

        let scanned = try await makeScanner().scan(root: fx.path)

        let names = scanned.children.map(\.name)
        #expect(!names.contains(".Trash"), "root 直接子项 .Trash 目录必须整棵剪枝")
        #expect(!names.contains("link"), "symlink 条目必须跳过不列出")
        // 遍历未跟随、未列出:整棵树里 a 只出现一次,.Trash 内的 junk 完全不出现
        let nodes = allNodes(scanned)
        #expect(nodes.filter { $0.name == "a" }.count == 1)
        #expect(nodes.filter { $0.name == "junk" }.isEmpty)
    }

    @Test func deniedDirectoryIsFlaggedAndCounted() async throws {
        let fx = try makeFixtureDir()
        let locked = fx.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        _ = try makeTree(fx, ["kept": Data(repeating: 0x43, count: 1_000)])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            // 先恢复权限再清理,否则夹具自身删不掉
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: fx)
        }

        let recorder = ProgressRecorder()
        let scanned = try await makeScanner().scan(root: fx.path, onProgress: { recorder.record($0) })

        let lockedNode = try #require(scanned.children.first { $0.name == "locked" })
        #expect(lockedNode.isDeniedTruncated, "权限墙目录须如实标 isDeniedTruncated")
        #expect(lockedNode.sizeBytes == 0)
        let kept = try #require(scanned.children.first { $0.name == "kept" })
        #expect(scanned.sizeBytes == kept.sizeBytes, "权限墙不贡献体量,其余子树照常聚合")
        #expect((recorder.all.map(\.deniedCount).max() ?? 0) >= 1, "deniedCount 须经 onProgress 如实计数")
    }

    @Test func protectedSubtreeMarksAncestors() async throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        _ = try makeTree(fx, [
            "private": ["secret": Data(repeating: 0x01, count: 10)],
            "excluded": ["skipped": Data(repeating: 0x02, count: 10)],
            "normal": ["plain": Data(repeating: 0x03, count: 10)],
        ])

        let scanner = makeScanner(hardRoots: ["\(fx.path)/private"],
                                  userExclusions: ["\(fx.path)/excluded"])
        let scanned = try await scanner.scan(root: fx.path)

        let privateNode = try #require(scanned.children.first { $0.name == "private" })
        let excludedNode = try #require(scanned.children.first { $0.name == "excluded" })
        let normalNode = try #require(scanned.children.first { $0.name == "normal" })

        // containsProtected 自底向上:保护根/排除根的全体祖先被传染,无关兄弟不误标
        #expect(scanned.containsProtected)
        #expect(privateNode.containsProtected)
        #expect(excludedNode.containsProtected)
        #expect(!normalNode.containsProtected)
    }

    @Test func progressMonotonic() async throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        var spec: [String: Any] = [:]
        for i in 0..<130 { spec["f\(i)"] = Data(repeating: UInt8(i % 255), count: 100) }
        spec["dir"] = ["nested": Data(repeating: 0x00, count: 100)]
        _ = try makeTree(fx, spec)

        let recorder = ProgressRecorder()
        _ = try await makeScanner().scan(root: fx.path, onProgress: { recorder.record($0) })

        let seq = recorder.all
        #expect(!seq.isEmpty, "进度序列非空")
        let bytes = seq.map(\.bytesScanned)
        #expect(zip(bytes, bytes.dropFirst()).allSatisfy { $0 <= $1 }, "bytesScanned 单调不减")
        let denied = seq.map(\.deniedCount)
        #expect(zip(denied, denied.dropFirst()).allSatisfy { $0 <= $1 }, "deniedCount 单调不减")
    }

    @Test func cancelThrowsCancellationError() async throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        // 造足够多小文件,保证取消窗口稳定(枚举期间必然尚有大量条目未处理)
        var spec: [String: Any] = [:]
        for i in 0..<2_000 { spec["f\(i)"] = Data(count: 8) }
        _ = try makeTree(fx, spec)

        let scanner = makeScanner()
        let task = Task { try await scanner.scan(root: fx.path) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("scan 应被取消抛 CancellationError,却正常完成")
        } catch is CancellationError {
            // 期望路径
        } catch {
            Issue.record("期望 CancellationError,实际:\(error)")
        }
    }

    @Test func protectedFileNodeIsMarkedDirectly() async throws {
        let fx = try makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: fx) }
        _ = try makeTree(fx, [
            "plain.txt": Data(repeating: 0x01, count: 10),
            "other.txt": Data(repeating: 0x02, count: 10),
            "priv": ["inner.txt": Data(repeating: 0x03, count: 10)],
        ])

        let scanner = makeScanner(hardRoots: ["\(fx.path)/priv"],
                                  userExclusions: ["\(fx.path)/plain.txt"])
        let scanned = try await scanner.scan(root: fx.path)

        let plain = try #require(scanned.children.first { $0.name == "plain.txt" })
        let other = try #require(scanned.children.first { $0.name == "other.txt" })
        let priv = try #require(scanned.children.first { $0.name == "priv" })
        let inner = try #require(priv.children.first { $0.name == "inner.txt" })

        // 文件叶子直评 isDenied:被精确排除的文件、硬保护目录内文件都要标上
        #expect(plain.containsProtected, "userExclusion 精确命中的文件节点须标 containsProtected")
        #expect(inner.containsProtected, "硬保护目录内文件节点须标 containsProtected")
        #expect(!other.containsProtected, "无关文件不得误标")
        #expect(priv.containsProtected)
    }

    @Test func invalidRootThrows() async throws {
        // 相对路径:绝不按 CWD 相对解析,直接 throws
        await #expect(throws: (any Error).self) {
            try await makeScanner().scan(root: "relative/path")
        }
        // 不存在的绝对路径
        await #expect(throws: (any Error).self) {
            try await makeScanner().scan(root: "/definitely/not/existing-xyz")
        }
    }
}
