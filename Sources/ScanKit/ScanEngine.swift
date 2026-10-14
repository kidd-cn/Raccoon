import Foundation
import CleanKit

public struct ScanEngine: Sendable {
    // @unchecked:本 CLT SDK 的 FileManager 未标注 Sendable;其共享实例官方文档保证线程安全,
    // 且 deps 中的 FileManager 仅为 .default 只读使用,故 unchecked 收敛。
    public struct Dependencies: @unchecked Sendable {
        public let protection: ProtectionStore
        public let runningBundleIDs: @Sendable () async -> Set<String>
        public let snapshots: SnapshotCleanerServicing
        public let itemLimitPerRule: Int
        let fileManager: FileManager

        public init(protection: ProtectionStore,
                    runningBundleIDs: @escaping @Sendable () async -> Set<String> = { [] },
                    snapshots: SnapshotCleanerServicing = TmutilSnapshotCleaner(),
                    itemLimitPerRule: Int = 500_000,
                    fileManager: FileManager = .default) {
            self.protection = protection
            self.runningBundleIDs = runningBundleIDs
            self.snapshots = snapshots
            self.itemLimitPerRule = itemLimitPerRule
            self.fileManager = fileManager
        }
    }

    struct RuleOutcome: Sendable {
        var hits: [ScanHit] = []
        var permissionSkipped = 0
        var truncated = false
        var excluded = 0
    }

    let deps: Dependencies
    let identity: AppIdentityResolver

    public init(deps: Dependencies, identity: AppIdentityResolver = AppIdentityResolver()) {
        self.deps = deps; self.identity = identity
    }

    public func scan(rules: [CleanupRule],
                     progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResult {
        let running = await deps.runningBundleIDs()
        let total = max(rules.count, 1)
        var done = 0
        var outcomes = [RuleOutcome?](repeating: nil, count: rules.count)

        try await withThrowingTaskGroup(of: (Int, RuleOutcome).self) { group in
            for (idx, rule) in rules.enumerated() {
                // include 全盘匹配(.DS_Store)属低优先级长任务
                let priority: TaskPriority = (rule.include?.isEmpty == false) ? .low : .userInitiated
                group.addTask(priority: priority) { (idx, try await self.walk(rule: rule, running: running)) }
            }
            for try await (idx, outcome) in group {
                outcomes[idx] = outcome
                done += 1
                let hits = outcomes.compactMap(\.self).flatMap(\.hits)
                progress(ScanProgress(rulesDone: done, rulesTotal: total,
                                      hitsFound: hits.count,
                                      bytesFound: hits.reduce(Int64(0)) { $0 + $1.sizeBytes }))
            }
        }

        // 应用名解析依赖 NSWorkspace(@MainActor):扫描收尾时在主线程批量补齐一次
        let rawHits = outcomes.compactMap(\.self).flatMap(\.hits)
        let hits = await MainActor.run { Self.resolveAppNames(rawHits, resolver: identity) }
        let byCat = Dictionary(grouping: hits, by: \.category)
        let summaries = RuleCategory.allCases.compactMap { cat -> CategorySummary? in
            guard let list = byCat[cat] else { return nil }
            return CategorySummary(category: cat,
                                   totalBytes: list.reduce(Int64(0)) { $0 + $1.sizeBytes },
                                   hitCount: list.count)
        }
        let truncated = Set(zip(rules, outcomes.compactMap(\.self)).filter { $0.1.truncated }.map(\.0.id))
        return ScanResult(hits: hits,
                          summaries: summaries,
                          permissionSkippedCount: outcomes.compactMap(\.self).reduce(0) { $0 + $1.permissionSkipped },
                          truncatedRuleIDs: truncated,
                          excludedCount: outcomes.compactMap(\.self).reduce(0) { $0 + $1.excluded })
    }

    func walk(rule: CleanupRule, running: Set<String>) async throws -> RuleOutcome {
        try Task.checkCancellation()
        guard rule.effectiveAction == .trash else { return await snapshotHits(rule: rule) }
        if let include = rule.include, !include.isEmpty {
            return try walkIncludeMode(rule: rule, include: include, running: running)   // Task 8 实现
        }
        return try await walkDefaultMode(rule: rule, running: running)
    }

    func snapshotHits(rule: CleanupRule) async -> RuleOutcome {
        // SnapshotCleanerServicing.listSnapshots 为 async(tmutil 子进程),
        // 此处必须 await;walk 调用点相应为 `return await snapshotHits(rule: rule)`。
        let hits = await deps.snapshots.listSnapshots()
        return RuleOutcome(hits: hits.map { date in
            ScanHit(ruleID: rule.id, category: rule.category, safety: rule.safety,
                    path: "tmutil://\(date)", sizeBytes: 0, isDirectory: false,
                    bundleID: nil, appName: nil, isAppRunning: false,
                    action: .tmutilThin, snapshotDate: date)
        })
    }

    // MARK: 默认模式:根的一级子项作为删除单元

    func walkDefaultMode(rule: CleanupRule, running: Set<String>) async throws -> RuleOutcome {
        var outcome = RuleOutcome()
        let rootPath = ProtectionStore.normalize(rule.path)
        let fm = deps.fileManager
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else { return outcome }

        let children = ((try? fm.contentsOfDirectory(atPath: rootPath)) ?? []).sorted()
        var count = 0
        for name in children {
            try Task.checkCancellation()
            count += 1
            if count > deps.itemLimitPerRule { outcome.truncated = true; break }

            let full = rootPath + "/" + name
            if deps.protection.isDenied(full) || Self.matchesAny(name, rule.exclude) {
                outcome.excluded += 1; continue
            }
            guard fm.isReadableFile(atPath: full) else { outcome.permissionSkipped += 1; continue }
            var childIsDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &childIsDir) else {
                outcome.permissionSkipped += 1; continue
            }
            // 符号链接:不深入目标,按 0 字节计(删除链接本身无害)
            let symlink = Self.isSymlink(full)
            let size = symlink ? 0 : Self.deepSize(path: full, fm: fm)
            let bid = AppIdentityResolver.bundleIDComponent(in: full)
            outcome.hits.append(ScanHit(ruleID: rule.id, category: rule.category, safety: rule.safety,
                                        path: full, sizeBytes: size, isDirectory: childIsDir.boolValue,
                                        bundleID: bid, appName: nil,
                                        isAppRunning: bid.map { running.contains($0) } ?? false,
                                        action: .trash, snapshotDate: nil))
        }
        return outcome
    }

    /// 收尾批量补齐 appName(NSWorkspace 限 MainActor)。Task 4 审查义务:NSWorkspace 查询
    /// 昂贵,必须先按 bundleID 去重再查、一次构建 [bundleID: name] 后回填,禁止逐 hit 查询。
    @MainActor
    static func resolveAppNames(_ hits: [ScanHit], resolver: AppIdentityResolver) -> [ScanHit] {
        let bundleIDs = Set(hits.compactMap(\.bundleID))
        guard !bundleIDs.isEmpty else { return hits }
        var names: [String: String] = [:]
        for bid in bundleIDs {
            if let n = resolver.appName(for: bid) { names[bid] = n }
        }
        return hits.map { hit in
            guard let bid = hit.bundleID, let name = names[bid], name != hit.appName else { return hit }
            return ScanHit(ruleID: hit.ruleID, category: hit.category, safety: hit.safety,
                           path: hit.path, sizeBytes: hit.sizeBytes, isDirectory: hit.isDirectory,
                           bundleID: hit.bundleID, appName: name, isAppRunning: hit.isAppRunning,
                           action: hit.action, snapshotDate: hit.snapshotDate)
        }
    }

    // MARK: 工具

    static func matchesAny(_ name: String, _ patterns: [String]?) -> Bool {
        guard let patterns, !patterns.isEmpty else { return false }
        return patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    static func isSymlink(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    /// 递归统计常规文件字节;不跟随目录符号链接。
    /// 根本身为常规文件时返回其自身大小(enumerator(atPath:) 对普通文件产出空序列,
    /// 测试规格要求 stray.log 这类一级子文件按自身字节计入聚合)。
    static func deepSize(path: String, fm: FileManager) -> Int64 {
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType, type == .typeRegular,
           let n = attrs[.size] as? NSNumber {
            return n.int64Value
        }
        guard let en = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let rel = en.nextObject() as? String {
            let attrs = try? fm.attributesOfItem(atPath: path + "/" + rel)
            if let type = attrs?[.type] as? FileAttributeType, type == .typeRegular,
               let n = attrs?[.size] as? NSNumber {
                total += n.int64Value
            }
        }
        return total
    }

    func walkIncludeMode(rule: CleanupRule, include: [String], running: Set<String>) throws -> RuleOutcome {
        // Task 8 实现:include 全盘匹配模式
        RuleOutcome()
    }
}
