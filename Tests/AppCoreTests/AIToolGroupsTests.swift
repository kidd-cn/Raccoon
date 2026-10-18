import Testing
import ScanKit
@testable import AppCore

@Suite
final class AIToolGroupsTests {
    private func h(_ path: String, _ size: Int64, tool: String?) -> ScanHit {
        ScanHit(ruleID: "r", category: .ai, safety: .safe, path: path, sizeBytes: size, tool: tool)
    }

    @Test func groups_inCanonicalOrder_sizeDescWithin() {
        let groups = AIToolGrouper.groups(in: [
            h("/c1", 10, tool: "cursor"), h("/c2", 50, tool: "cursor"),
            h("/cd", 30, tool: "claude-desktop"), h("/o", 5, tool: "ollama"),
            h("/g", 7, tool: "chatgpt")])
        #expect(groups.map(\.tool) == ["claude-desktop", "cursor", "ollama", "chatgpt"])
        #expect(groups[1].hits.map(\.path) == ["/c2", "/c1"])   // 组内按大小降序
    }

    // 防御:漏带 tool 的 ai 条目落「其他」组,殿后,绝不消失(Review Focus #4)
    @Test func groups_nilToolFallsIntoOtherGroupLast() {
        let groups = AIToolGrouper.groups(in: [h("/x", 1, tool: nil), h("/y", 2, tool: "cursor")])
        #expect(groups.map(\.tool) == ["cursor", nil])
        #expect(groups.map(\.id) == ["cursor", "other"])
    }

    // 未收录的新工具值:按字典序插在已知工具后、「其他」前,保证加规则先于 UI 也不丢条目
    @Test func groups_unknownToolSortedBeforeOther() {
        let groups = AIToolGrouper.groups(in: [
            h("/x", 1, tool: nil), h("/z", 2, tool: "zed"), h("/y", 3, tool: "windsurf")])
        #expect(groups.map(\.tool) == ["windsurf", "zed", nil])
    }

    @Test func groups_emptyInputNoGroups() {
        #expect(AIToolGrouper.groups(in: []).isEmpty)
    }
}
