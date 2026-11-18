// SPDX-License-Identifier: MIT

import CoreGraphics

enum AnnotationLineMode: CaseIterable {
    case straight, polyline, curve

    var title: String {
        switch self {
        case .straight: L("直线")
        case .polyline: L("折线")
        case .curve: L("曲线")
        }
    }

    var symbol: String {
        switch self {
        case .straight: "line.diagonal"
        case .polyline: "point.topleft.down.to.point.bottomright.curvepath"
        case .curve: "point.bottomleft.forward.to.point.topright.scurvepath"
        }
    }
}

struct CaptureBezierSegment: Equatable {
    var start: CGPoint
    var firstControl: CGPoint
    var secondControl: CGPoint
    var end: CGPoint
    // 保留参数区间长度，拆分后端点切线和箭头长度仍按整条曲线计算。
    var weight: CGFloat = 1

    private static func interpolate(_ a: CGPoint, _ b: CGPoint, at t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    func split(at t: CGFloat) -> (Self, Self) {
        let a = Self.interpolate(start, firstControl, at: t)
        let b = Self.interpolate(firstControl, secondControl, at: t)
        let c = Self.interpolate(secondControl, end, at: t)
        let d = Self.interpolate(a, b, at: t), e = Self.interpolate(b, c, at: t)
        let point = Self.interpolate(d, e, at: t)
        return (Self(start: start, firstControl: a, secondControl: d, end: point, weight: weight * t),
                Self(start: point, firstControl: e, secondControl: c, end: end, weight: weight * (1 - t)))
    }

    private var points: [CGPoint] { [start, firstControl, secondControl, end] }

    func joined(to next: Self) -> Self {
        let total = weight + next.weight, t = weight / total
        let restored = Self(start: start, firstControl: Self.interpolate(start, firstControl, at: 1 / t),
                            secondControl: Self.interpolate(next.end, next.secondControl, at: 1 / (1 - t)),
                            end: next.end, weight: total)
        let (left, right) = restored.split(at: t)
        let matches = zip(left.points + right.points, points + next.points).allSatisfy { a, b in
            hypot(a.x - b.x, a.y - b.y) < 0.00001
        }
        if matches { return restored }
        return Self(start: start, firstControl: firstControl, secondControl: next.secondControl, end: next.end, weight: total)
    }

    func nearest(to query: CGPoint, within tolerance: CGFloat, includingEndpoints: Bool)
        -> (fraction: CGFloat, point: CGPoint, distance: CGFloat)? {
        var nearest: (fraction: CGFloat, point: CGPoint, distance: CGFloat)?
        var best = tolerance
        let flatness = max(0.01, tolerance / 100)
        func search(_ piece: Self, _ low: CGFloat, _ high: CGFloat, _ depth: Int) {
            let a = piece.start, b = piece.firstControl, c = piece.secondControl, d = piece.end
            guard query.x >= min(a.x, b.x, c.x, d.x) - best, query.x <= max(a.x, b.x, c.x, d.x) + best,
                  query.y >= min(a.y, b.y, c.y, d.y) - best, query.y <= max(a.y, b.y, c.y, d.y) + best else { return }
            let chord1 = Self.interpolate(piece.start, piece.end, at: 1 / 3)
            let chord2 = Self.interpolate(piece.start, piece.end, at: 2 / 3)
            let deviation = max(hypot(chord1.x - piece.firstControl.x, chord1.y - piece.firstControl.y),
                                hypot(chord2.x - piece.secondControl.x, chord2.y - piece.secondControl.y))
            if deviation > flatness, depth < 12 {
                let (left, right) = piece.split(at: 0.5)
                let mid = (low + high) / 2
                search(left, low, mid, depth + 1)
                search(right, mid, high, depth + 1)
                return
            }
            let local = CaptureLineShape.segmentFraction(to: query, from: piece.start, to: piece.end) ?? 0.5
            let fraction = low + (high - low) * min(1, max(0, local))
            guard includingEndpoints || (fraction > 0 && fraction < 1) else { return }
            let actual = fraction == 0 ? start : fraction == 1 ? end : split(at: fraction).0.end
            let distance = hypot(actual.x - query.x, actual.y - query.y)
            if distance <= best {
                best = distance
                nearest = (fraction, actual, distance)
            }
        }
        search(self, 0, 1, 0)
        return nearest
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        return Self(start: move(start), firstControl: move(firstControl), secondControl: move(secondControl),
                    end: move(end), weight: weight)
    }

    func tangentGuide(atStart: Bool, totalWeight: CGFloat) -> CGPoint {
        let origin = atStart ? start : end
        let candidates = atStart ? [firstControl, secondControl, end] : [secondControl, firstControl, start]
        guard let index = candidates.firstIndex(where: { $0 != origin }) else { return origin }
        let scale = pow(totalWeight / weight, CGFloat(index + 1))
        return scale == 1 ? candidates[index] : Self.interpolate(origin, candidates[index], at: scale)
    }
}

enum CaptureLineShape: Equatable {
    case polyline(interior: [CGPoint], closed: Bool)
    case curve([CaptureBezierSegment], closed: Bool = false)

    typealias SegmentHit = (index: Int, point: CGPoint, distance: CGFloat, fraction: CGFloat)

    static func segmentFraction(to point: CGPoint, from a: CGPoint, to b: CGPoint) -> CGFloat? {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return nil }
        return ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
    }

    static func nearestSegment(to point: CGPoint, in nodes: [CGPoint], closed: Bool,
                               within tolerance: CGFloat) -> SegmentHit? {
        guard nodes.count >= 2 else { return nil }
        var nearest: SegmentHit?
        var bestDistance = tolerance
        let segmentCount = closed ? nodes.count : nodes.count - 1
        for index in 0..<segmentCount {
            let a = nodes[index], b = nodes[(index + 1) % nodes.count]
            guard let fraction = segmentFraction(to: point, from: a, to: b),
                  fraction > 0, fraction < 1 else { continue }
            let projected = CGPoint(x: a.x + fraction * (b.x - a.x), y: a.y + fraction * (b.y - a.y))
            let distance = hypot(point.x - projected.x, point.y - projected.y)
            if distance <= bestDistance {
                nearest = (index, projected, distance, fraction)
                bestDistance = distance
            }
        }
        return nearest
    }

    var isClosed: Bool {
        switch self {
        case .polyline(_, let closed), .curve(_, let closed): return closed
        }
    }

    static func point(_ target: CGPoint, from origin: CGPoint, in bounds: CGRect, snap: Bool) -> CGPoint {
        let end = clamped(target, in: bounds)
        guard snap, end != origin else { return end }
        let dx = end.x - origin.x, dy = end.y - origin.y
        let step = CGFloat.pi / 12
        let angle = (atan2(dy, dx) / step).rounded() * step
        let ux = cos(angle), uy = sin(angle)
        var length = hypot(dx, dy)
        if abs(ux) > 1e-9 { length = min(length, ((ux > 0 ? bounds.maxX : bounds.minX) - origin.x) / ux) }
        if abs(uy) > 1e-9 { length = min(length, ((uy > 0 ? bounds.maxY : bounds.minY) - origin.y) / uy) }
        return clamped(CGPoint(x: origin.x + ux * max(0, length), y: origin.y + uy * max(0, length)), in: bounds)
    }

    static func clamped(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    static func curve(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> Self {
        let dx = end.x - start.x, dy = end.y - start.y
        func control(_ fraction: CGFloat, bend: CGFloat) -> CGPoint {
            CGPoint(x: start.x + dx * fraction - dy * bend, y: start.y + dy * fraction + dx * bend)
        }
        let first = control(1 / 3, bend: 0.25), second = control(2 / 3, bend: 0.25)
        let reverseFirst = control(1 / 3, bend: -0.25), reverseSecond = control(2 / 3, bend: -0.25)
        let bend: CGFloat = (!bounds.contains(first) || !bounds.contains(second)) && bounds.contains(reverseFirst)
            && bounds.contains(reverseSecond) ? -0.25 : 0.25
        return .curve([CaptureBezierSegment(start: start, firstControl: clamped(control(1 / 3, bend: bend), in: bounds),
                                            secondControl: clamped(control(2 / 3, bend: bend), in: bounds), end: end)])
    }

    func translated(dx: CGFloat, dy: CGFloat) -> Self {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + dx, y: point.y + dy) }
        switch self {
        case .polyline(let interior, let closed): return .polyline(interior: interior.map(move), closed: closed)
        case .curve(let segments, let closed): return .curve(segments.map { $0.translated(dx: dx, dy: dy) }, closed: closed)
        }
    }
}

extension CaptureMark {
    var isPolyline: Bool {
        if case .polyline = lineShape { return true }
        return false
    }

    var curveSegments: [CaptureBezierSegment]? {
        if case .curve(let segments, _) = lineShape { return segments }
        return nil
    }

    var ellipsePath: CGPath { CGPath(ellipseIn: bounds, transform: nil) }

    private var editableCurves: [CaptureBezierSegment]? {
        guard kind == .ellipse else { return curveSegments }
        guard !bounds.isEmpty else { return nil }
        var segments: [CaptureBezierSegment] = []
        var start = CGPoint.zero
        ellipsePath.applyWithBlock { element in
            let entry = element.pointee
            switch entry.type {
            case .moveToPoint:
                start = entry.points[0]
            case .addCurveToPoint:
                let end = entry.points[2]
                segments.append(CaptureBezierSegment(start: start, firstControl: entry.points[0],
                                                     secondControl: entry.points[1], end: end))
                start = end
            default: break
            }
        }
        guard segments.count >= 3, segments.first?.start == segments.last?.end else { return nil }
        return segments
    }

    var editableNodes: [CGPoint]? {
        kind.isLine ? lineNodes : polygon?.vertices
    }

    private var segmentNodes: [CGPoint]? {
        guard polygon == nil, kind == .rectangle || kind == .cover else { return editableNodes }
        let rect = bounds
        guard !rect.isEmpty else { return nil }
        return [rect.origin, CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    func nearestEditableSegment(to point: CGPoint, within tolerance: CGFloat) -> CaptureLineShape.SegmentHit? {
        if let segments = editableCurves {
            var nearest: CaptureLineShape.SegmentHit?
            for (index, curve) in segments.enumerated() {
                if let hit = curve.nearest(to: point, within: nearest?.distance ?? tolerance, includingEndpoints: kind == .ellipse) {
                    nearest = (index, hit.point, hit.distance, hit.fraction)
                }
            }
            return nearest
        }
        guard let nodes = segmentNodes else { return nil }
        let closed = kind == .rectangle || kind == .cover || polygon != nil || lineShape?.isClosed == true
        return CaptureLineShape.nearestSegment(to: point, in: nodes, closed: closed, within: tolerance)
    }

    func insertingNode(on segment: CaptureLineShape.SegmentHit) -> Self? {
        if var curves = editableCurves {
            if segment.fraction > 0, segment.fraction < 1 {
                guard !curves.contains(where: { $0.start == segment.point || $0.end == segment.point }) else { return nil }
                let (left, right) = curves[segment.index].split(at: segment.fraction)
                curves.replaceSubrange(segment.index...segment.index, with: [left, right])
            } else if kind != .ellipse {
                return nil
            }
            return replacingCurve(with: curves)
        }
        guard var nodes = segmentNodes, !nodes.contains(segment.point) else { return nil }
        nodes.insert(segment.point, at: segment.index + 1)
        return replacingNodes(with: nodes)
    }

    func removingNode(at index: Int) -> Self? {
        guard var nodes = editableNodes, nodes.indices.contains(index) else { return nil }
        if var curves = curveSegments {
            guard curves.count >= 2 else { return nil }
            if lineShape?.isClosed == true {
                guard curves.count > 3 else { return nil }
                let previous = (index + curves.count - 1) % curves.count
                curves[previous] = curves[previous].joined(to: curves[index])
                curves.remove(at: index)
            } else if index == 0 {
                curves.removeFirst()
            } else if index == curves.count {
                curves.removeLast()
            } else {
                let merged = curves[index - 1].joined(to: curves[index])
                curves.replaceSubrange((index - 1)...index, with: [merged])
            }
            return replacingCurve(with: curves)
        }
        nodes.remove(at: index)
        return replacingNodes(with: nodes)
    }

    private func replacingNodes(with nodes: [CGPoint]) -> Self? {
        if kind == .rectangle {
            return CapturePolygon(nodes).map { Self(polygon: $0, stroke: stroke) }
        }
        if kind == .cover || polygon != nil {
            return CapturePolygon(nodes).map { replacingPolygon(with: $0) }
        }
        let closed = lineShape?.isClosed == true
        guard kind.isLine, nodes.count >= (closed ? 3 : 2),
              !zip(nodes, nodes.dropFirst()).contains(where: { $0.0 == $0.1 }),
              !closed || nodes.first != nodes.last else { return nil }
        var updated = self
        updated.start = nodes[0]
        updated.end = nodes[nodes.count - 1]
        updated.lineShape = .polyline(interior: Array(nodes.dropFirst().dropLast()), closed: closed)
        return updated
    }

    var lineNodes: [CGPoint] {
        if case .polyline(let interior, _) = lineShape { return [start] + interior + [end] }
        if let curves = curveSegments {
            return lineShape?.isClosed == true ? curves.map(\.start) : [start] + curves.map(\.end)
        }
        return [start, end]
    }

    var lineHandles: [CGPoint] {
        if let curves = curveSegments {
            return lineNodes + curves.flatMap { [$0.firstControl, $0.secondControl] }
        }
        return lineNodes
    }

    func linePath(from first: CGPoint, to last: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: first)
        switch lineShape {
        case .curve(let curves, let closed):
            for (index, segment) in curves.enumerated() {
                path.addCurve(to: index == curves.count - 1 ? last : segment.end,
                              control1: segment.firstControl, control2: segment.secondControl)
            }
            if closed { path.closeSubpath() }
        case .polyline(let interior, let closed):
            // 箭头的底边可能跨过同一直线上的新节点。
            var visible = interior[...]
            if first != start {
                let length = hypot(first.x - start.x, first.y - start.y)
                visible = visible.drop(while: { hypot($0.x - start.x, $0.y - start.y) <= length })
            }
            if last != end {
                let length = hypot(last.x - end.x, last.y - end.y)
                while let node = visible.last, hypot(node.x - end.x, node.y - end.y) <= length {
                    visible.removeLast()
                }
            }
            for node in visible { path.addLine(to: node) }
            path.addLine(to: last)
            if closed { path.closeSubpath() }
        case nil: path.addLine(to: last)
        }
        return path
    }

    func reshapedLine(handle: Int, to target: CGPoint, in bounds: CGRect, snap: Bool) -> Self {
        if let curves = curveSegments {
            return reshapedCurve(curves, handle: handle, to: target, in: bounds, snap: snap)
        }
        var points = lineHandles
        let reference = points[handle == 0 ? 1 : handle - 1]
        let point = CaptureLineShape.point(target, from: reference, in: bounds, snap: snap)
        guard point != points[handle], point != reference else { return self }
        points[handle] = point
        if isPolyline { return replacingNodes(with: points) ?? self }
        var result = self
        result.start = points[0]
        result.end = points[points.count - 1]
        return result
    }

    private func replacingCurve(with curves: [CaptureBezierSegment]) -> Self {
        guard let first = curves.first, let last = curves.last else { return self }
        let closed = kind == .ellipse || lineShape?.isClosed == true
        var result = kind == .ellipse ? Self(kind: .line, start: first.start, end: last.end, stroke: stroke) : self
        result.start = first.start
        result.end = last.end
        result.lineShape = .curve(curves, closed: closed)
        return result
    }

    private func reshapedCurve(_ curves: [CaptureBezierSegment], handle: Int, to target: CGPoint,
                               in bounds: CGRect, snap: Bool) -> Self {
        var updated = curves
        let nodes = lineNodes
        if handle < nodes.count {
            let old = nodes[handle]
            let previous = handle > 0 ? handle - 1 : (lineShape?.isClosed == true ? curves.count - 1 : nil)
            let next = handle < curves.count ? handle : nil
            let reference = nodes[handle == 0 ? 1 : handle - 1]
            let point = CaptureLineShape.point(target, from: reference, in: bounds, snap: snap)
            guard point != old, previous.map({ point != curves[$0].start }) != false,
                  next.map({ point != curves[$0].end }) != false else { return self }
            func shifted(_ control: CGPoint) -> CGPoint {
                CaptureLineShape.clamped(CGPoint(x: control.x + (point.x - old.x), y: control.y + (point.y - old.y)), in: bounds)
            }
            if let previous {
                updated[previous].secondControl = shifted(curves[previous].secondControl)
                updated[previous].end = point
            }
            if let next {
                updated[next].firstControl = shifted(curves[next].firstControl)
                updated[next].start = point
            }
        } else {
            let offset = handle - nodes.count, index = offset / 2
            let first = offset.isMultiple(of: 2)
            let reference = first ? curves[index].start : curves[index].end
            let point = CaptureLineShape.point(target, from: reference, in: bounds, snap: snap)
            if first { updated[index].firstControl = point }
            else { updated[index].secondControl = point }
        }
        return replacingCurve(with: updated)
    }
}
