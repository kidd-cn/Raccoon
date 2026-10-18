import CleanKit

/// 启动项禁用的唯一编排入口:先门禁、后触达,删除动作一律经 CleanExecutor → TrashServicing,
/// 本类型不直接触碰文件系统(全仓 trash-only 承诺)。
public enum DisableOutcome: Sendable {
    /// isDenied 命中(硬保护或用户排除),未触达文件系统
    case denied(reason: String)
    /// 下层已成功移入废纸篓;报告完整,供 VM 记入历史
    case trashed(report: CleanReport)
    /// 其余失败(下层拒绝/文件消失/路径非法),报告未产生 trashed
    case failed(reason: String)
}

public struct LaunchItemStore: Sendable {
    // 公开只读:UI 层的 VM 需要在每次 load/disable 时用实时的用户排除清单重建 store
    // (本类型在构造期把 ProtectionStore 快照在值里,后加的排除对它不可见)。
    public let trash: TrashServicing
    public let protection: ProtectionStore

    public init(trash: TrashServicing, protection: ProtectionStore) {
        self.trash = trash
        self.protection = protection
    }

    /// 禁用 = 把 LaunchAgent/Daemon plist 移入废纸篓。
    /// 门禁短路保证受保护项连假体都不会调用;门禁通过后仍由 CleanExecutor 做
    /// 纵深防御式的二次 isDenied 校验(与路径绝对性守卫)。
    public func disable(_ item: LaunchItem) async -> DisableOutcome {
        if protection.isDenied(item.path) {
            return .denied(reason: "protected")
        }
        let report = await CleanExecutor(trash: trash, protection: protection)
            .clean([CleanItem(path: item.path, sizeBytes: 0)], source: "launch-items")
        if report.trashedCount > 0 {
            return .trashed(report: report)
        }
        return .failed(reason: report.skipped.first?.reason ?? "not trashed")
    }
}
