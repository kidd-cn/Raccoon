import Foundation

public struct SkippedItem: Codable, Equatable, Sendable {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) { self.path = path; self.reason = reason }
}

public struct CleanReport: Codable, Equatable, Sendable {
    public let date: Date
    public let freedBytes: Int64
    public let trashedCount: Int
    public let vanishedCount: Int
    public let snapshotCount: Int
    public let skipped: [SkippedItem]
    public init(date: Date = Date(), freedBytes: Int64, trashedCount: Int,
                vanishedCount: Int, snapshotCount: Int = 0, skipped: [SkippedItem]) {
        self.date = date; self.freedBytes = freedBytes; self.trashedCount = trashedCount
        self.vanishedCount = vanishedCount; self.snapshotCount = snapshotCount; self.skipped = skipped
    }
}

public protocol HistoryStoring: Sendable {
    func append(_ report: CleanReport) throws
    func loadAll() throws -> [CleanReport]
}

/// ~/Library/Application Support/Raccoon/history.json(测试可注入目录)
public struct JSONHistoryStore: HistoryStoring {
    /// 静态锁:跨实例互斥,防多实例并发写互相覆盖(read-modify-write 竞态)。
    private static let lock = NSLock()

    let url: URL
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager

    public init(directory: URL? = nil, fm: FileManager = .default) {
        self.fm = fm
        let dir = directory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Raccoon", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("history.json")
    }

    public func append(_ report: CleanReport) throws {
        try Self.lock.withLock {
            // 锁内不可调用 self.loadAll()(NSLock 非重入 → 死锁),此处内联读取。
            var all: [CleanReport] = []
            do {
                if fm.fileExists(atPath: url.path) {
                    all = try JSONDecoder().decode([CleanReport].self, from: Data(contentsOf: url))
                }
            } catch {
                // 损坏文件留存侧旁备份,不静默清史;以空历史继续。
                let stamp = ISO8601DateFormatter().string(from: Date())
                let backup = url.deletingLastPathComponent()
                    .appendingPathComponent("history-corrupted-\(stamp).json")
                try? fm.moveItem(at: url, to: backup)
                all = []
            }
            all.append(report)
            let data = try JSONEncoder().encode(all)
            try data.write(to: url, options: .atomic)
        }
    }

    public func loadAll() throws -> [CleanReport] {
        try Self.lock.withLock {
            guard fm.fileExists(atPath: url.path) else { return [] }
            return try JSONDecoder().decode([CleanReport].self, from: Data(contentsOf: url))
        }
    }
}
