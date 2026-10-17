import Foundation

public enum TrashOutcome: Equatable, Sendable {
    case trashed
    case vanished
    case skipped(reason: String)   // 稳定代码:"no-permission" / "protected" / "invalid-path" / "snapshot-failed" / "other"
}

public protocol TrashServicing: Sendable {
    func trash(_ path: String) async -> TrashOutcome
}

public struct FileManagerTrashService: TrashServicing {
    // FileManager 官方文档保证线程安全且此处不可变,但 ObjC 类未标注 Sendable → 显式豁免。
    nonisolated(unsafe) let fm: FileManager
    public init(fm: FileManager = .default) { self.fm = fm }

    /// 唯一删除动作:移入废纸篓。绝不 unlink。
    public func trash(_ path: String) async -> TrashOutcome {
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return .trashed
        } catch {
            let mapped = TrashService.map(error: error as NSError)
            // /Applications 下 root/admin 归属的应用,直接 trashItem 会报权限不足;
            // 降级经 Finder 删除:与用户手动拖入废纸篓同路径,系统会按需弹管理员授权框。
            if case .skipped(let reason) = mapped, reason == "no-permission",
               await Self.trashViaFinder(path) {
                return .trashed
            }
            return mapped
        }
    }

    /// 经 Finder 移入废纸篓(osascript)。Finder 需要授权时会自行弹系统弹窗;
    /// 授权等待可能很长,故在后台队列阻塞等待,不占用协作线程池。
    static func trashViaFinder(_ path: String) async -> Bool {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete POSIX file \"\(escaped)\""
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                do { try proc.run() } catch { continuation.resume(returning: false); return }
                proc.waitUntilExit()
                continuation.resume(returning: proc.terminationStatus == 0)
            }
        }
    }
}

public enum TrashService {
    public static func map(error: NSError) -> TrashOutcome {
        guard error.domain == NSCocoaErrorDomain else { return .skipped(reason: "other") }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .vanished
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return .skipped(reason: "no-permission")
        default:
            return .skipped(reason: "other")
        }
    }
}

public enum CleanAction: Equatable, Sendable {
    case trash
    case tmutilThin(date: String?)
}

public struct CleanItem: Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let action: CleanAction
    public init(path: String, sizeBytes: Int64, action: CleanAction = .trash) {
        self.path = path; self.sizeBytes = sizeBytes; self.action = action
    }
}

public struct CleanExecutor: Sendable {
    let trash: TrashServicing
    let protection: ProtectionStore
    let snapshots: SnapshotCleanerServicing

    public init(trash: TrashServicing, protection: ProtectionStore, snapshots: SnapshotCleanerServicing = TmutilSnapshotCleaner()) {
        self.trash = trash; self.protection = protection; self.snapshots = snapshots
    }

    /// 逐项执行;任何单项失败不中断整批。
    public func clean(_ items: [CleanItem], onProgress: (@Sendable (Int, Int) -> Void)? = nil) async -> CleanReport {
        var freed: Int64 = 0, trashed = 0, vanished = 0, snapshotCount = 0
        var skipped: [SkippedItem] = []
        for (i, item) in items.enumerated() {
            switch item.action {
            case .trash:
                // 绝对路径守卫:isDenied 契约要求绝对路径,相对路径按 CWD 解析可绕过组件前缀匹配。
                // 仅作用于 .trash 分支:tmutilThin 项的 path 是 "tmutil://<date>" 伪标签,不触达文件系统。
                guard item.path.hasPrefix("/") else {
                    skipped.append(SkippedItem(path: item.path, reason: "invalid-path"))
                    onProgress?(i + 1, items.count)
                    continue
                }
                // 纵深防御:删除前最后一道硬保护校验
                if protection.isDenied(item.path) {
                    skipped.append(SkippedItem(path: item.path, reason: "protected"))
                    onProgress?(i + 1, items.count); continue
                }
                switch await trash.trash(item.path) {
                case .trashed: trashed += 1; freed += item.sizeBytes
                case .vanished: vanished += 1
                case .skipped(let reason): skipped.append(SkippedItem(path: item.path, reason: reason))
                }
            case .tmutilThin(let date):
                if let date, await snapshots.deleteSnapshot(date) { snapshotCount += 1 }
                else { skipped.append(SkippedItem(path: item.path, reason: "snapshot-failed")) }
            }
            onProgress?(i + 1, items.count)
        }
        return CleanReport(freedBytes: freed, trashedCount: trashed, vanishedCount: vanished,
                           snapshotCount: snapshotCount, skipped: skipped)
    }
}
