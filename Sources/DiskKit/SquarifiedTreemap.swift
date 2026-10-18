import CoreGraphics

/// 带原下标的一片 treemap 矩形。
public struct TreemapRect: Sendable, Equatable {
    /// 对应 weights 中的下标。
    public let index: Int
    public let rect: CGRect

    public init(index: Int, rect: CGRect) {
        self.index = index
        self.rect = rect
    }
}

/// 经典 squarified treemap（Bruls et al.）的纯函数实现。
public enum SquarifiedTreemap {

    public static func layout(in area: CGRect, weights: [Int64]) -> [TreemapRect] {
        guard !weights.isEmpty else { return [] }

        let totalWeight = weights.reduce(0) { $0 + $1 }

        // 全零：N 块沿宽度均分整块面积。
        if totalWeight <= 0 {
            let n = weights.count
            let columnWidth = area.width / CGFloat(n)
            return (0..<n).map { i in
                TreemapRect(
                    index: i,
                    rect: CGRect(
                        x: area.minX + CGFloat(i) * columnWidth,
                        y: area.minY,
                        width: columnWidth,
                        height: area.height
                    )
                )
            }
        }

        // 降序（并列按原下标）；权重 ≤ 0 的项面积贡献为 0，不产生矩形。
        let order = weights.indices
            .filter { weights[$0] > 0 }
            .sorted { a, b in
                if weights[a] != weights[b] { return weights[a] > weights[b] }
                return a < b
            }

        let totalArea = area.width * area.height
        let scale = totalArea / CGFloat(totalWeight)

        var remainingRect = area
        var result: [TreemapRect] = []
        var i = 0

        while i < order.count {
            // 贪心成行：加入下一项若最差纵横比不更差则继续，否则封行。
            var rowWeights: [Int64] = [weights[order[i]]]
            var bestWorst = worst(in: remainingRect, rowWeights: rowWeights, scale: scale)

            var j = i + 1
            while j < order.count {
                let candidate = rowWeights + [weights[order[j]]]
                let candidateWorst = worst(in: remainingRect, rowWeights: candidate, scale: scale)
                if candidateWorst <= bestWorst {
                    rowWeights = candidate
                    bestWorst = candidateWorst
                    j += 1
                } else {
                    break
                }
            }

            let rowCount = rowWeights.count
            let rowIndices = (i..<(i + rowCount)).map { order[$0] }
            let rowRects = layoutRow(in: remainingRect, rowWeights: rowWeights, scale: scale)
            for (idx, rect) in zip(rowIndices, rowRects) {
                result.append(TreemapRect(index: idx, rect: rect))
            }

            // 沿短边成条带，从长边方向削掉该行厚度。
            let rowArea = CGFloat(rowWeights.reduce(0, +)) * scale
            let shortSide = min(remainingRect.width, remainingRect.height)
            let thickness = rowArea / shortSide
            if remainingRect.width >= remainingRect.height {
                remainingRect = CGRect(
                    x: remainingRect.minX + thickness,
                    y: remainingRect.minY,
                    width: remainingRect.width - thickness,
                    height: remainingRect.height
                )
            } else {
                remainingRect = CGRect(
                    x: remainingRect.minX,
                    y: remainingRect.minY + thickness,
                    width: remainingRect.width,
                    height: remainingRect.height - thickness
                )
            }

            i += rowCount
        }

        return result
    }

    /// 命中：按数组顺序返回第一个包含 point 的矩形；无则 nil。
    public static func hitTest(rects: [TreemapRect], at point: CGPoint) -> TreemapRect? {
        for r in rects where r.rect.contains(point) {
            return r
        }
        return nil
    }

    /// 行内最差纵横比（像素面积口径）。
    private static func worst(in rect: CGRect, rowWeights: [Int64], scale: CGFloat) -> CGFloat {
        let s = CGFloat(rowWeights.reduce(0, +)) * scale
        let w = min(rect.width, rect.height)
        let areas = rowWeights.map { CGFloat($0) * scale }
        let rmax = areas.max() ?? 0
        let rmin = areas.min() ?? 0
        return max((w * w * rmax) / (s * s), (s * s) / (w * w * rmin))
    }

    /// 行条带沿短边方向依次切分，最后一块取余量保证条带被精确填满。
    private static func layoutRow(in rect: CGRect, rowWeights: [Int64], scale: CGFloat) -> [CGRect] {
        let areas = rowWeights.map { CGFloat($0) * scale }
        let s = areas.reduce(0, +)
        let shortSide = min(rect.width, rect.height)
        let thickness = s / shortSide
        var offset: CGFloat = 0

        return areas.enumerated().map { k, a in
            let length: CGFloat = (k == areas.count - 1) ? (shortSide - offset) : ((a / s) * shortSide)
            let item: CGRect
            if rect.width >= rect.height {
                item = CGRect(x: rect.minX, y: rect.minY + offset, width: thickness, height: length)
            } else {
                item = CGRect(x: rect.minX + offset, y: rect.minY, width: length, height: thickness)
            }
            offset += length
            return item
        }
    }
}
