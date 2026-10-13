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
        var all = (try? loadAll()) ?? []
        all.append(report)
        let data = try JSONEncoder().encode(all)
        try data.write(to: url, options: .atomic)
    }

    public func loadAll() throws -> [CleanReport] {
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CleanReport].self, from: Data(contentsOf: url))
    }
}
