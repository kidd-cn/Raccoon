import Foundation
@testable import ScanKit

enum ScanFixtures {
    /// 构造固定目录树,返回根路径
    static func makeTree() -> String {
        let root = NSTemporaryDirectory() + "raccoon-scan-\(UUID().uuidString)"
        let fm = FileManager.default
        func mkdir(_ rel: String) { try? fm.createDirectory(atPath: root + "/" + rel, withIntermediateDirectories: true) }
        func write(_ rel: String, _ bytes: Int) {
            try? Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: root + "/" + rel))
        }
        mkdir("Caches/com.google.Chrome/Cache")
        write("Caches/com.google.Chrome/Cache/f1", 100)
        write("Caches/com.google.Chrome/Cache/f2", 200)
        mkdir("Caches/com.spotify.client")
        write("Caches/com.spotify.client/data", 50)
        write("Caches/stray.log", 10)
        mkdir("Logs/app"); write("Logs/app/a.log", 30)
        mkdir("nested/deep"); write("nested/.DS_Store", 3); write("nested/deep/.DS_Store", 7)
        return root
    }

    static func remove(_ root: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
        try? FileManager.default.removeItem(atPath: root)
    }

    static func rule(id: String, path: String, category: RuleCategory = .system,
                     safety: SafetyLevel = .safe, include: [String]? = nil,
                     exclude: [String]? = nil) -> CleanupRule {
        CleanupRule(id: id, category: category, safety: safety, path: path,
                    include: include, exclude: exclude, action: nil, description: nil)
    }

    /// 进度事件累积器:Swift 6 禁止在 @Sendable 闭包里捕获可变局部变量,
    /// 测试用它收集进度回调(progress 回调实际在调用方任务串行触发,锁仅为类型合规兜底)。
    final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ScanProgress] = []
        func append(_ p: ScanProgress) { lock.lock(); defer { lock.unlock() }; items.append(p) }
        var events: [ScanProgress] { lock.lock(); defer { lock.unlock() }; return items }
    }
}
