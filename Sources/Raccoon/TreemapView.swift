import SwiftUI
import AppCore
import DiskKit

/// 磁盘分析 treemap 分段:squarified 布局 + Canvas 绘制,点击矩形下钻到对应节点。
/// 布局只取 `.item` 行;`.others` 聚合行不参与布局,仅在右下角叠加图例。
struct TreemapView: View {
    let rows: [DisplayRow]
    let onTap: (DiskNode) -> Void
    let onRescan: () -> Void

    var body: some View {
        GeometryReader { geo in
            let itemRows = self.itemRows
            let weights = itemRows.map(\.sizeBytes)
            let rects = SquarifiedTreemap.layout(
                in: CGRect(origin: .zero, size: geo.size),
                weights: weights)

            if itemRows.isEmpty || rects.isEmpty {
                emptyView
            } else {
                ZStack(alignment: .bottomTrailing) {
                    treemapCanvas(itemRows: itemRows, rects: rects)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { value in
                            // hit.index 是 weights(即 itemRows)下标,勿用 rows 下标。
                            if let hit = SquarifiedTreemap.hitTest(rects: rects, at: value.location) {
                                onTap(itemRows[hit.index])
                            }
                        })
                    if let others = othersRow {
                        othersLegend(count: others.count, bytes: others.bytes)
                    }
                }
            }
        }
    }

    // MARK: - 数据

    private var itemRows: [DiskNode] {
        rows.compactMap { row in
            if case .item(let node) = row.kind { return node }
            return nil
        }
    }

    private var othersRow: (count: Int, bytes: Int64)? {
        for row in rows {
            if case .others(let count, let bytes) = row.kind {
                return (count, bytes)
            }
        }
        return nil
    }

    // MARK: - 绘制

    private func treemapCanvas(itemRows: [DiskNode], rects: [TreemapRect]) -> some View {
        Canvas { context, _ in
            for entry in rects {
                let node = itemRows[entry.index]
                let rect = entry.rect
                let path = Path(rect)
                context.fill(path, with: .color(rectColor(for: entry.index)))
                context.stroke(path, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)
                if rect.width > 80 && rect.height > 24 {
                    drawLabel(node: node, in: rect, context: &context)
                }
            }
        }
    }

    /// 色相按原下标轮转 12 档,深浅随下标奇偶交替,便于相邻矩形区分。
    private func rectColor(for index: Int) -> Color {
        Color(hue: Double(index % 12) / 12.0,
              saturation: 0.45,
              brightness: (index % 2 == 0) ? 0.8 : 0.62)
    }

    /// 节点名(按宽度截断)+ 体量,白字配轻微暗影保证深色块上可读。
    private func drawLabel(node: DiskNode, in rect: CGRect, context: inout GraphicsContext) {
        let padding: CGFloat = 6
        let maxNameChars = max(1, Int((rect.width - padding * 2) / 7))
        let name = truncated(node.name, maxChars: maxNameChars)

        let nameShadow = Text(name).font(.caption).foregroundStyle(.black.opacity(0.35))
        let nameMain = Text(name).font(.caption).foregroundStyle(.white)
        let sizeShadow = Text(byteText(node.sizeBytes)).font(.caption2).foregroundStyle(.black.opacity(0.35))
        let sizeMain = Text(byteText(node.sizeBytes)).font(.caption2).foregroundStyle(.white.opacity(0.9))

        let namePoint = CGPoint(x: rect.minX + padding, y: rect.minY + padding)
        let sizePoint = CGPoint(x: rect.minX + padding, y: rect.minY + padding + 15)
        let shadowOffset = CGSize(width: 0.5, height: 1.5)

        context.draw(nameShadow,
                     at: CGPoint(x: namePoint.x + shadowOffset.width, y: namePoint.y + shadowOffset.height),
                     anchor: .topLeading)
        context.draw(sizeShadow,
                     at: CGPoint(x: sizePoint.x + shadowOffset.width, y: sizePoint.y + shadowOffset.height),
                     anchor: .topLeading)
        context.draw(nameMain, at: namePoint, anchor: .topLeading)
        context.draw(sizeMain, at: sizePoint, anchor: .topLeading)
    }

    private func truncated(_ s: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard s.count > maxChars else { return s }
        let end = s.index(s.startIndex, offsetBy: maxChars - 1)
        return String(s[..<end]) + "…"
    }

    // MARK: - 图例与空态

    private func othersLegend(count: Int, bytes: Int64) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.gray.opacity(0.6))
                .frame(width: 12, height: 12)
            Text(loc("disk.others", count, byteText(bytes)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Text(loc("disk.empty"))
                .foregroundStyle(.secondary)
            Button(loc("disk.rescan")) { onRescan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
