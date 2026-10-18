import Testing
@testable import DiskKit
import CoreGraphics

@Suite struct SquarifiedTreemapTests {

    @Test func emptyWeightsYieldNoRects() {
        let rects = SquarifiedTreemap.layout(
            in: CGRect(x: 0, y: 0, width: 640, height: 480),
            weights: []
        )
        #expect(rects == [])
    }

    @Test func areaConserved() {
        let area = CGRect(x: 0, y: 0, width: 640, height: 480)
        let weights: [Int64] = [7, 3, 9, 1, 4, 8, 2, 6, 5]
        let rects = SquarifiedTreemap.layout(in: area, weights: weights)
        let total = rects.reduce(0.0) { $0 + Double($1.rect.width * $1.rect.height) }
        #expect(abs(total - Double(area.width * area.height)) < 1e-6)
    }

    @Test func noOverlapAndInsideArea() {
        let area = CGRect(x: 10, y: 5, width: 300, height: 200)
        let weights: [Int64] = [50, 33, 21, 13, 8, 5]
        let rects = SquarifiedTreemap.layout(in: area, weights: weights)

        for (i, a) in rects.enumerated() {
            #expect(a.rect.minX >= area.minX - 1e-6)
            #expect(a.rect.minY >= area.minY - 1e-6)
            #expect(a.rect.maxX <= area.maxX + 1e-6)
            #expect(a.rect.maxY <= area.maxY + 1e-6)
            for b in rects.dropFirst(i + 1) {
                let inter = a.rect.intersection(b.rect)
                #expect(inter.width * inter.height < 1e-9)
            }
        }
    }

    @Test func aspectRatioBounded() {
        let area = CGRect(x: 0, y: 0, width: 640, height: 480)
        let weights: [Int64] = [81, 27, 27, 9, 9, 3, 3, 1]
        let rects = SquarifiedTreemap.layout(in: area, weights: weights)
        for r in rects {
            let w = r.rect.width
            let h = r.rect.height
            if w * h > 0 {
                let ratio = max(w, h) / min(w, h)
                #expect(ratio <= 4.0 + 1e-6)
            }
        }
    }

    @Test func stableForIdenticalInput() {
        let area = CGRect(x: 0, y: 0, width: 640, height: 480)
        let weights: [Int64] = [7, 3, 9, 1, 4, 8, 2, 6, 5]
        let a = SquarifiedTreemap.layout(in: area, weights: weights)
        let b = SquarifiedTreemap.layout(in: area, weights: weights)
        #expect(a == b)

        let zeroArea = CGRect(x: 0, y: 0, width: 500, height: 400)
        let zeroWeights: [Int64] = [0, 0, 0, 0]
        let z = SquarifiedTreemap.layout(in: zeroArea, weights: zeroWeights)
        #expect(z.count == 4)
        let quarter = Double(zeroArea.width * zeroArea.height) / 4.0
        for r in z {
            #expect(abs(Double(r.rect.width * r.rect.height) - quarter) < 1e-6)
        }

        // 并列权重按原下标序(降序权重,并列取较小下标在前)
        let tiedWeights: [Int64] = [3, 81, 3, 27, 9, 9, 27]
        let tied = SquarifiedTreemap.layout(in: area, weights: tiedWeights)
        #expect(tied.map(\.index) == [1, 3, 6, 4, 5, 0, 2])
    }

    @Test func hitTestFindsContainingRectAndMisses() {
        let area = CGRect(x: 0, y: 0, width: 640, height: 480)
        let weights: [Int64] = [7, 3, 9, 1, 4, 8, 2, 6, 5]
        let rects = SquarifiedTreemap.layout(in: area, weights: weights)
        let target = rects[0]
        let center = CGPoint(x: target.rect.midX, y: target.rect.midY)
        #expect(SquarifiedTreemap.hitTest(rects: rects, at: center) == target)
        let outside = CGPoint(x: area.maxX + 10, y: area.maxY + 10)
        #expect(SquarifiedTreemap.hitTest(rects: rects, at: outside) == nil)
    }
}
