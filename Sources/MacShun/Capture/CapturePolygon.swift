// SPDX-License-Identifier: MIT

import CoreGraphics

/// 锚点坐标与矩形选区相同，都是当前显示器内的 AppKit 点。
struct CapturePolygon: Equatable {
    let vertices: [CGPoint]
    let path: CGPath
    var bounds: CGRect { path.boundingBoxOfPath }

    init?(_ vertices: [CGPoint]) {
        guard vertices.count >= 3 else { return nil }
        let first = vertices[0]
        guard let second = vertices.dropFirst().first(where: { $0 != first }),
              vertices.dropFirst().contains(where: { point in
                  let cross = (second.x - first.x) * (point.y - first.y) - (second.y - first.y) * (point.x - first.x)
                  return abs(cross) >= 0.5
              }) else { return nil }
        self.init(closedVertices: vertices)
    }

    private init(closedVertices vertices: [CGPoint]) {
        let outline = CGMutablePath()
        outline.addLines(between: vertices)
        outline.closeSubpath()
        self.vertices = vertices
        self.path = outline.copy() ?? outline
    }

    func contains(_ point: CGPoint) -> Bool { path.contains(point, using: .evenOdd) }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        let transform = CGAffineTransform(translationX: dx, y: dy)
        return Self(closedVertices: vertices.map { $0.applying(transform) })
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.vertices == rhs.vertices }
}
