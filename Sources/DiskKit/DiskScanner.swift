import Foundation
import Darwin
import CleanKit

/// 磁盘扫描器:只读遍历用户主目录,聚合子树块占用,产出 DiskNode 树。
/// 安全承诺:全程只读(目录枚举 + 属性读取),不含任何删除路径。
public struct DiskScanner: Sendable {
    public let protection: ProtectionStore

    public init(protection: ProtectionStore) {
        self.protection = protection
    }

    /// 遍历 root,返回 DiskNode 树。契约:
    /// - root 必须绝对路径且存在,否则 throws(进 .failed,绝不按 CWD 相对解析)
    /// - root 的直接子项中名为 ".Trash" 的目录整棵剪枝(不遍历不列出)
    /// - symlink 条目直接跳过(不列出、不跟随)
    /// - 文件体量 = fileAllocSize;目录 = 子树文件之和,目录自身块不计
    /// - 列目录遇 I/O 权限错误:该目录标 isDeniedTruncated 并计入 deniedCount,已读部分体量保留
    /// - containsProtected 自底向上:protection.isDenied(node.path) || 任一 child.containsProtected
    /// - 周期检查 Task.isCancelled,取消时 throws CancellationError(丢弃部分结果)
    /// - onProgress 在后台线程回调(bytesScanned 单调不减;deniedCount 单调不减)
    public func scan(root: String, onProgress: (@Sendable (DiskScanProgress) -> Void)? = nil) async throws -> DiskNode {
        let fm = FileManager.default

        // 契约:绝对路径且存在,否则 throws。
        // realpath 把 root 归一到与枚举器产出条目相同的规范形(如 /var/... → /private/var/...):
        // 若两者形态不一,「路径组件计数 = 相对深度」的弹栈/.Trash 剪枝判定会整体错位。
        guard root.hasPrefix("/") else { throw DiskScanError.invalidRoot(root) }
        guard let real = realpath((root as NSString).standardizingPath, nil) else {
            throw DiskScanError.invalidRoot(root)
        }
        let canonicalRoot = String(cString: real)
        free(real)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalRoot, isDirectory: &isDir), isDir.boolValue else {
            throw DiskScanError.invalidRoot(root)
        }
        let rootURL = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
        let rootDepth = rootURL.pathComponents.count

        // errorHandler 由 nextObject 在枚举线程内联回调,以下状态与之串行读写;
        // nonisolated(unsafe) 只为满足形参的 @Sendable 标注,无实际并发。
        nonisolated(unsafe) var deniedPaths = Set<String>()
        nonisolated(unsafe) var deniedCount = 0
        let errorHandler: (URL, Error) -> Bool = { url, _ in
            // 列目录遇 I/O 权限错误:记下该目录,继续枚举其余兄弟——
            // 体量不完整要如实呈现(deniedCount),但不能让一面权限墙打断整场盘点。
            deniedPaths.insert(url.path)
            deniedCount += 1
            return true
        }

        guard let enumerator = fm.enumerator(
            at: rootURL,
            // 新 Foundation 已把 fileAllocSize 更名为 fileAllocatedSize(SDK 内旧名已移除)
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileAllocatedSizeKey],
            options: [],  // 隐藏文件必须包含:.Trash 靠名字剪枝,而非靠 skipsHiddenFiles
            errorHandler: errorHandler
        ) else {
            // root 存在但打不开(根目录本身无读权限)同样按入口不合法处理
            throw DiskScanError.invalidRoot(root)
        }

        var bytesScanned: Int64 = 0
        var entriesSinceCancel = 0
        var entriesSinceProgress = 0

        /// 枚举中的「构造中目录」帧:子树条目尚未集齐,出栈时才聚合成 DiskNode。
        /// DFS 序保证一个目录的全部后代条目连续出现,故「下一条目深度 ≤ 栈顶深度」即子树结束。
        struct Frame {
            let depth: Int
            let path: String
            let name: String
            var pending: [DiskNode] = []
        }
        var stack = [Frame(depth: 0, path: rootURL.path, name: rootURL.lastPathComponent)]

        // 进度节流:目录边界必回调,文件每 64 个回调一次
        func report(_ currentPath: String) {
            entriesSinceProgress = 0
            onProgress?(DiskScanProgress(bytesScanned: bytesScanned, deniedCount: deniedCount, currentPath: currentPath))
        }

        // 落定一帧:目录体量 = 子树文件之和(目录自身块不计);保护标志自底向上派生
        func finish(_ frame: Frame) -> DiskNode {
            let size = frame.pending.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let containsProtected = protection.isDenied(frame.path)
                || frame.pending.contains(where: \.containsProtected)
            return DiskNode(
                path: frame.path, name: frame.name, sizeBytes: size, isDirectory: true,
                children: frame.pending,
                isDeniedTruncated: deniedPaths.contains(frame.path),
                containsProtected: containsProtected)
        }

        try Task.checkCancellation()
        while let entry = enumerator.nextObject() as? URL {
            entriesSinceCancel += 1
            if entriesSinceCancel >= 256 {
                entriesSinceCancel = 0
                try Task.checkCancellation()
            }

            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileAllocatedSizeKey])

            // 契约:symlink 条目直接跳过(不列出、不跟随)
            if values?.isSymbolicLink == true { continue }

            let depth = entry.pathComponents.count - rootDepth
            while let top = stack.last, top.depth >= depth {
                stack.removeLast()
                stack[stack.count - 1].pending.append(finish(top))
            }

            let path = entry.path
            let name = entry.lastPathComponent

            if values?.isDirectory == true {
                // 契约:仅 root 直接子项中名为 ".Trash" 的目录整棵剪枝;深层 .Trash 照常列出
                if depth == 1, name == ".Trash" {
                    enumerator.skipDescendants()
                    continue
                }
                stack.append(Frame(depth: depth, path: path, name: name))
                report(path)
            } else {
                // 文件体量 = fileAllocSize(新 Foundation 名为 fileAllocatedSize);取不到回退 0 并照常计数
                let size = Int64(values?.fileAllocatedSize ?? 0)
                bytesScanned += size
                // 契约第 6 条对叶子同样成立:文件节点 containsProtected = 自身 isDenied(文件可被精确排除)
                stack[stack.count - 1].pending.append(
                    DiskNode(path: path, name: name, sizeBytes: size, isDirectory: false,
                             containsProtected: protection.isDenied(path)))
                entriesSinceProgress += 1
                if entriesSinceProgress >= 64 { report(path) }
            }
        }

        // 清栈:剩余构造中目录逐级落定,直至虚拟根
        while stack.count > 1 {
            let top = stack.removeLast()
            stack[stack.count - 1].pending.append(finish(top))
        }

        // 末次进度:保证调用方拿到最终 bytesScanned / deniedCount 快照
        // (权限墙多发生在收尾阶段,若不发末拍,deniedCount 的最终值永远到不了 UI)
        report(rootURL.path)

        return finish(stack.removeLast())
    }
}
