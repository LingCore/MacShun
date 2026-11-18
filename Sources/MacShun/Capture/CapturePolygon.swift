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

    func nearestEdge(to point: CGPoint, within tolerance: CGFloat) -> CaptureLineShape.SegmentHit? {
        CaptureLineShape.nearestSegment(to: point, in: vertices, closed: true, within: tolerance)
    }

    func insertingVertex(_ point: CGPoint, after edge: Int) -> Self? {
        guard !vertices.contains(point) else { return nil }
        var updated = vertices
        updated.insert(point, at: edge + 1)
        return Self(updated)
    }

    func removingVertex(_ index: Int) -> Self? {
        var updated = vertices
        updated.remove(at: index)
        return Self(updated)
    }

    func movingVertex(_ index: Int, to target: CGPoint, in bounds: CGRect, snap: Bool,
                      clippedTo mask: CapturePolygon? = nil) -> Self? {
        let candidate = CaptureLineShape.clamped(target, in: bounds)
        guard mask?.contains(candidate) != false else { return nil }
        let reference = vertices[index == 0 ? 1 : index - 1]
        let point = CaptureLineShape.point(candidate, from: reference, in: bounds, snap: snap)
        guard mask?.contains(point) != false,
              !vertices.enumerated().contains(where: { $0.offset != index && $0.element == point }) else { return nil }
        var updated = vertices
        updated[index] = point
        return Self(updated)
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        let transform = CGAffineTransform(translationX: dx, y: dy)
        return Self(closedVertices: vertices.map { $0.applying(transform) })
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.vertices == rhs.vertices }
}
