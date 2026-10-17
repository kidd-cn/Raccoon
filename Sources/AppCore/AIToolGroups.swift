import Foundation
import ScanKit

/// AI 清理页的一个工具分组:组头展示名走 L10n 键 `ai.tool.<id>`(nil 组 = "other")。
public struct AIToolGroup: Identifiable, Equatable, Sendable {
    public let tool: String?          // nil = 「其他」组(防御:ai 规则漏带 tool)
    public let hits: [ScanHit]        // 组内已按 sizeBytes 降序
    public var id: String { tool ?? "other" }
    public init(tool: String?, hits: [ScanHit]) { self.tool = tool; self.hits = hits }
}

public enum AIToolGrouper {
    /// 组的展示顺序;规则新增未收录工具值时按字典序排其后、「其他」殿后。
    public static let canonicalOrder: [String] = [
        "claude-desktop", "claude-code", "cursor", "codex", "ollama", "huggingface", "chatgpt"]

    public static func groups(in hits: [ScanHit]) -> [AIToolGroup] {
        let byTool = Dictionary(grouping: hits, by: \.tool)
        var ordered: [String?] = canonicalOrder.filter { !(byTool[$0] ?? []).isEmpty }
        ordered += byTool.keys
            .filter { $0 != nil && !canonicalOrder.contains($0!) }
            .sorted { $0! < $1! }
        if !(byTool[nil] ?? []).isEmpty { ordered.append(nil) }
        return ordered.map { tool in
            AIToolGroup(tool: tool,
                        hits: (byTool[tool] ?? []).sorted { $0.sizeBytes > $1.sizeBytes })
        }
    }
}
