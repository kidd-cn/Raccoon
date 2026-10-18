import SwiftUI

/// CPU 占用 sparkline:把 0...100 的百分比序列画成折线。
/// 空数组不绘制任何内容——首轮采样前 `cpuHistory` 为空,由调用方显示
/// `monitor.cpu.pending`,本视图只负责「没有数据就不画」。
/// 纵轴固定以 100% 为顶(异常超出值夹到顶端),不做自适应缩放,避免小幅波动被放大误读。
struct SparklineView: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let points = normalizedPoints(in: size)
            guard let first = points.first else { return }
            guard points.count > 1 else {
                // 单点无折线可画,给一个可见圆点,避免看起来像空态。
                let dot = CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)
                context.fill(Path(ellipseIn: dot), with: .color(tint))
                return
            }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path,
                           with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }

    /// 归一化到画布坐标:x 均匀铺满宽度,y 以 100% 为顶、0% 为底。
    /// 单点无跨度,居中绘制(否则 x=0 会把圆点裁掉左半)。
    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let stepX = values.count > 1 ? size.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, raw in
            let clamped = min(max(raw, 0), 100)
            let x = values.count > 1 ? CGFloat(index) * stepX : size.width / 2
            return CGPoint(x: x,
                           y: size.height - CGFloat(clamped / 100) * size.height)
        }
    }
}
