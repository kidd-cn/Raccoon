import Foundation

public protocol SnapshotCleanerServicing: Sendable {
    /// 返回快照日期串,形如 "2026-10-13-120000"
    func listSnapshots() async -> [String]
    @discardableResult func deleteSnapshot(_ date: String) async -> Bool
}

public struct TmutilSnapshotCleaner: SnapshotCleanerServicing {
    public init() {}

    public func listSnapshots() async -> [String] {
        // tmutil 是阻塞子进程:detached 移出协作池线程,避免占死 Swift 并发线程
        let out = await Task.detached(priority: .utility) {
            Self.run(["listlocalsnapshots", "/"])
        }.value
        return out
            .split(separator: "\n")
            .compactMap { Self.parseSnapshotDate(String($0)) }
    }

    public func deleteSnapshot(_ date: String) async -> Bool {
        let out = await Task.detached(priority: .utility) {
            Self.run(["deletelocalsnapshots", date])
        }.value
        return out.localizedCaseInsensitiveContains("deleted")
    }

    /// 纯函数,Task 4 补测:"com.apple.TimeMachine.2026-10-13-120000.local" → "2026-10-13-120000"
    public static func parseSnapshotDate(_ line: String) -> String? {
        let prefix = "com.apple.TimeMachine."
        let suffix = ".local"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { return nil }
        return String(line.dropFirst(prefix.count).dropLast(suffix.count))
    }

    static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice   // 排空 stderr,防 64KB 管道写满阻塞死锁
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
