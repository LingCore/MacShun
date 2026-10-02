// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI
import simd

/// “光标与稻穗”标志（红色版），会动：光标撑开成底板；稻秆从光标后面长出来，结出谷粒；
/// 谷粒越满，穗头越沉，把稻秆压弯，晃两下停稳；最后一道金光扫过。
/// 几何、时间和配色照搬作者的《光标与稻穗-开场动画.html》（48 单位的图标坐标），最后一帧就是静态图标。
/// 点一下会再播放一次。`animated` 为 false 或系统开了“减弱动态效果”时只画静态图标。
struct AuthorMark: View {
    var size: CGFloat = 52
    var animated = true
    /// 动画开头光标的颜色（底板撑开前，光标直接画在背景上）
    var startInk: (Double, Double, Double) = (0.95, 0.93, 0.89)

    @ObservedObject private var clock = AuthorMarkClock.shared

    var body: some View {
        let unit = size / 48
        let margin = AuthorMarkArt.margin * unit
        Group {
            if animated {
                TimelineView(.animation(minimumInterval: 1.0 / 58, paused: !clock.running)) { context in
                    let t = clock.running ? context.date.timeIntervalSince(clock.start) : AuthorMarkArt.restTime
                    Canvas { ctx, _ in AuthorMarkArt.draw(&ctx, unit: unit, t: t, startInk: startInk) }
                }
                .contentShape(Rectangle())
                .onTapGesture { clock.play() }
            } else {
                Canvas { ctx, _ in AuthorMarkArt.draw(&ctx, unit: unit, t: AuthorMarkArt.restTime, startInk: startInk) }
            }
        }
        // 稻秆和谷粒会画到底板外面一点，画布四周多留一圈，布局上仍按 size 算
        .frame(width: size + margin * 2, height: size + margin * 2)
        .padding(-margin)
        .accessibilityLabel(L("光标与稻穗"))
    }
}

/// 动画什么时候开始、是不是还在播。所有标志共用一个，只在主线程上使用。
final class AuthorMarkClock: ObservableObject {
    static let shared = AuthorMarkClock()

    @Published private(set) var start = Date.distantPast
    @Published private(set) var running = false
    private var generation = 0

    func play() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        generation += 1
        let mine = generation
        start = Date()
        running = true
        // 播完就停下，不再每帧重画
        DispatchQueue.main.asyncAfter(deadline: .now() + AuthorMarkArt.duration) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.running = false
        }
    }
}

/// 画图标的每一帧。坐标是 48×48 的图标空间。
enum AuthorMarkArt {
    typealias V = SIMD2<Double>

    /// 动画大约在这时停稳（金光 2.0 秒扫完，穗头的晃动随后衰减到看不出）
    static let duration = 3.2
    /// 静止时画的时刻：弹簧早已停稳，就是静态图标
    static let restTime = 7.9
    /// 画布四周多留的边（图标单位）
    static let margin = 2.0

    // MARK: 几何（照搬 图标/*.svg）

    private static let deg = Double.pi / 180
    private static let s1: [V] = [V(12.5, 41), V(14, 29), V(19, 15.5), V(28.5, 11)]
    private static let s2: [V] = [V(28.5, 11), V(32.92, 9.09), V(36.06, 12.15), V(36.3, 21)]
    private static let w0 = 2.9, w1 = 1.0
    private static let grains: [(p: V, a: Double, s: Double)] = [
        (V(32.25, 10.70), 14, 1.8), (V(32.25, 10.70), -65, 1.5), (V(36.28, 20.30), -1.6, 1.5),
    ]
    private static let cursorPose = (p: V(18.6, 24.4), a: -33.0)
    /// 穗头还空着时往上翘多少度，谷粒长出来后被压下去
    private static let headUp = -28.0

    private static let cursorPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: -4.2, y: -10.4)); p.addLine(to: CGPoint(x: 4.2, y: -10.4))
        p.move(to: CGPoint(x: 0, y: -10.4)); p.addLine(to: CGPoint(x: 0, y: 10.4))
        p.move(to: CGPoint(x: -4.2, y: 10.4)); p.addLine(to: CGPoint(x: 4.2, y: 10.4))
        return p
    }()

    private static let leafPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 13.4, y: 38.2))
        p.addCurve(to: CGPoint(x: 32.8, y: 38.9), control1: CGPoint(x: 18.5, y: 35.4), control2: CGPoint(x: 26.5, y: 35.2))
        p.addCurve(to: CGPoint(x: 13.6, y: 39.9), control1: CGPoint(x: 26.8, y: 37.4), control2: CGPoint(x: 19.8, y: 37.5))
        p.closeSubpath()
        return p
    }()

    private static let grainPath: Path = {
        var p = Path()
        p.move(to: .zero)
        p.addCurve(to: CGPoint(x: 0, y: 6.6), control1: CGPoint(x: 2.3, y: 0.4), control2: CGPoint(x: 2.2, y: 4.6))
        p.addCurve(to: .zero, control1: CGPoint(x: -2.2, y: 4.6), control2: CGPoint(x: -2.3, y: 0.4))
        p.closeSubpath()
        return p
    }()

    private static let seamPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 0.5, y: 1.1))
        p.addCurve(to: CGPoint(x: 0.2, y: 5.6), control1: CGPoint(x: 1.1, y: 2.6), control2: CGPoint(x: 0.9, y: 4.4))
        return p
    }()

    // MARK: 红色版配色

    private static func hex(_ v: UInt32, _ alpha: Double = 1) -> Color {
        Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: alpha)
    }

    private static let bg = [hex(0xE8412F), hex(0xA5171A)]
    private static let gold = [hex(0xFFE08A), hex(0xF2B53C)]
    private static let grainColors = [hex(0xFFF0B8), hex(0xFFD460), hex(0xEDA92E)]
    private static let leafColors = [hex(0xE9AE3A), hex(0xFFD877, 0.9)]
    private static let seamColor = hex(0xB5621A, 0.5)
    private static let cursorInk = (1.0, 0xF6 / 255.0, 0xE2 / 255.0)

    // MARK: 曲线工具

    private static func bez(_ q: [V], _ t: Double) -> V {
        let u = 1 - t
        return u * u * u * q[0] + 3 * u * u * t * q[1] + 3 * u * t * t * q[2] + t * t * t * q[3]
    }

    private static func dbez(_ q: [V], _ t: Double) -> V {
        let u = 1 - t
        return 3 * u * u * (q[1] - q[0]) + 6 * u * t * (q[2] - q[1]) + 3 * t * t * (q[3] - q[2])
    }

    private static func rotate(_ p: V, around c: V, _ th: Double) -> V {
        let s = sin(th), k = cos(th), d = p - c
        return V(c.x + d.x * k - d.y * s, c.y + d.x * s + d.y * k)
    }

    /// 穗头绕弯顶转：两段曲线接上的地方切线不变。
    private static func bentS2(_ degrees: Double) -> [V] {
        [s2[0], s2[1], rotate(s2[2], around: s2[0], degrees * 0.55 * deg), rotate(s2[3], around: s2[0], degrees * deg)]
    }

    private static func polyline(_ q: [V], _ n: Int) -> [V] { (0...n).map { bez(q, Double($0) / Double(n)) } }

    private static func length(_ p: [V]) -> Double {
        zip(p, p.dropFirst()).reduce(0) { $0 + simd_length($1.1 - $1.0) }
    }

    private static func tangentDegrees(_ q: [V], _ t: Double) -> Double {
        let d = dbez(q, t)
        return atan2(d.y, d.x) / deg
    }

    private static func point(_ v: V) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    /// 把一串点连成平滑曲线（和网页里的 smooth() 一样）。
    private static func addSmooth(_ path: inout Path, _ p: [V]) {
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(to: point(p2), control1: point(p1 + (p2 - p0) / 6), control2: point(p2 - (p3 - p1) / 6))
        }
    }

    /// 由粗到细的稻秆轮廓，做法同 源文件/gen.py 的 stem_path()。
    private static func stemOutline(_ a: [V], _ b: [V]) -> (path: Path, points: [V]) {
        var samples: [(V, V)] = (0...6).map { (bez(a, Double($0) / 6), dbez(a, Double($0) / 6)) }
        samples += (1...5).map { (bez(b, Double($0) / 5), dbez(b, Double($0) / 5)) }
        var left: [V] = [], right: [V] = []
        for (i, (p, d)) in samples.enumerated() {
            let f = Double(i) / Double(samples.count - 1)
            let w = (w0 * (1 - f) + w1 * f) / 2
            let n = V(-d.y, d.x) / simd_length(d)
            left.append(p + n * w)
            right.append(p - n * w)
        }
        right.reverse()
        var path = Path()
        path.move(to: point(left[0]))
        addSmooth(&path, left)
        path.addLine(to: point(right[0]))   // 稻秆顶端只有 1 个单位宽，圆头用直线代替看不出差别
        addSmooth(&path, right)
        path.closeSubpath()
        return (path, left + right)
    }

    /// SVG 的 objectBoundingBox 渐变 (0,0)→(1,1) 换算到用户坐标：等色线沿着框的对角线。
    private static func boxGradient(_ r: CGRect, _ stops: [Gradient.Stop]) -> GraphicsContext.Shading {
        let w = r.width, h = r.height, k = 2 * w * h / (w * w + h * h)
        return .linearGradient(Gradient(stops: stops), startPoint: r.origin,
                               endPoint: CGPoint(x: r.minX + h * k, y: r.minY + w * k))
    }

    /// 金色渐变的框 = 长好的稻秆的外框（固定不动，稻秆弯的时候颜色不会跟着游走）
    private static let goldBox: CGRect = {
        let pts = stemOutline(s1, s2).points
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }()

    /// 每粒谷钉在弯钩曲线的某个参数上，穗头弯的时候跟着走、跟着转。
    private static let pins: [(t: Double, off: V, rel: Double, s: Double)] = grains.map { g in
        var bestT = 0.0, bestD = Double.infinity
        for k in 0...2000 {
            let d = simd_length(bez(s2, Double(k) / 2000) - g.p)
            if d < bestD { bestD = d; bestT = Double(k) / 2000 }
        }
        let p = bez(s2, bestT), phi = tangentDegrees(s2, bestT), r = -phi * deg, d = g.p - p
        return (bestT, V(d.x * cos(r) - d.y * sin(r), d.x * sin(r) + d.y * cos(r)), g.a - phi, g.s)
    }

    private static func grainPose(_ i: Int, _ curve: [V]) -> (p: V, a: Double) {
        let pin = pins[i], p = bez(curve, pin.t), phi = tangentDegrees(curve, pin.t), r = phi * deg
        return (V(p.x + pin.off.x * cos(r) - pin.off.y * sin(r), p.y + pin.off.x * sin(r) + pin.off.y * cos(r)), pin.rel + phi)
    }

    // MARK: 时间

    private static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
    private static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
    private static func outQuad(_ p: Double) -> Double { 1 - (1 - p) * (1 - p) }
    private static func outCubic(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
    private static func inOutCubic(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }
    private static func outExpo(_ p: Double) -> Double { p >= 1 ? 1 : 1 - pow(2, -10 * p) }
    private static func outBack(_ p: Double, _ s: Double = 1.70158) -> Double {
        p <= 0 ? 0 : 1 + (s + 1) * pow(p - 1, 3) + s * pow(p - 1, 2)
    }
    private static func inOutSine(_ p: Double) -> Double { -(cos(Double.pi * p) - 1) / 2 }

    private static let grow = (0.5, 1.1), popLength = 0.28

    /// 嫩芽一开始长得快，弯成穗头时慢下来。
    private static func growAt(_ t: Double) -> Double { outQuad(seg(t, grow.0, grow.1)) }

    /// 长到谷粒的根部时，那粒谷冒出来。
    private static let pops: [Double] = {
        let curve = bentS2(headUp), line2 = polyline(curve, 400)
        let l1 = length(polyline(s1, 400)), l2 = length(line2)
        func at(_ frac: Double) -> Double {
            var lo = grow.0, hi = grow.1
            for _ in 0..<40 {
                let m = (lo + hi) / 2
                if growAt(m) < frac { lo = m } else { hi = m }
            }
            return lo
        }
        return pins.enumerated().map { i, pin in
            let upTo = Array(line2[0...Int((pin.t * 400).rounded())])
            return at((l1 + length(upTo)) / (l1 + l2)) + (i == 1 ? 0.08 : 0)
        }
    }()

    private static func popAt(_ i: Int, _ t: Double) -> Double { seg(t, pops[i], pops[i] + popLength) }

    /// 穗头的弯是一个带阻尼的弹簧，谷粒的重量一到，平衡位置就往下沉。预先按毫秒算好。
    private static let bend: [Double] = {
        let dt = 1.0 / 1000, w = 2 * Double.pi * 1.6, z = 0.32
        let mass = grains.map { $0.s * $0.s }, total = mass.reduce(0, +)
        var th = headUp, v = 0.0, out = [Double](repeating: 0, count: 8000)
        for k in 0..<8000 {
            let t = Double(k) * dt
            let m = mass.enumerated().reduce(0) { $0 + $1.element * outCubic(popAt($1.offset, t)) }
            let target = headUp * (1 - m / total)
            v += (-w * w * (th - target) - 2 * z * w * v) * dt
            th += v * dt
            out[k] = th
        }
        return out
    }()

    private static func bendAt(_ t: Double) -> Double { bend[min(max(Int((t * 1000).rounded()), 0), bend.count - 1)] }

    // MARK: 画一帧

    static func draw(_ ctx: inout GraphicsContext, unit: Double, t: Double, startInk: (Double, Double, Double)) {
        ctx.translateBy(x: margin * unit, y: margin * unit)
        ctx.scaleBy(x: unit, y: unit)

        // 底板从光标处撑开
        let bp = outExpo(seg(t, 0.25, 0.65)), bph = outExpo(seg(t, 0.31, 0.71))
        let cp = seg(t, 0.28, 0.7)
        let cursorAt = V(24, 24) + (cursorPose.p - V(24, 24)) * inOutCubic(cp)
        let cursorAngle = cursorPose.a * outBack(cp, 1.4)
        if bp > 0 {
            let bw = 3 + 45 * bp, bh = 23.8 + 24.2 * bph, rx = 1.5 + 9.5 * bp
            var badge = ctx
            badge.opacity = seg(t, 0.25, 0.37)
            let rect = CGRect(x: 24 - bw / 2, y: 24 - bh / 2, width: bw, height: bh)
            badge.fill(Path(roundedRect: rect, cornerRadius: rx),
                       with: .radialGradient(Gradient(colors: bg), center: CGPoint(x: 14.4, y: 10.56), startRadius: 0, endRadius: 45.6))
            badge.opacity *= 0.12
            badge.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, rx - 0.5)),
                         with: .color(.white), lineWidth: 1)
        }

        // 叶子、稻秆、谷粒画在一层里，被光标切开，最后金光扫过
        let g = growAt(t)
        if g > 0 {
            let curve = bentS2(bendAt(t))
            ctx.drawLayer { art in
                let lp = seg(t, 0.58, 0.95)
                if lp > 0 {
                    let le = outBack(lp, 1.3)
                    var leaf = art
                    leaf.translateBy(x: 13.5, y: 39)
                    leaf.rotate(by: .degrees(-(1 - min(le, 1)) * 38))
                    leaf.scaleBy(x: le, y: 0.35 + 0.65 * min(le, 1))
                    leaf.translateBy(x: -13.5, y: -39)
                    leaf.fill(leafPath, with: .linearGradient(Gradient(colors: leafColors),
                                                              startPoint: CGPoint(x: 13.4, y: 0), endPoint: CGPoint(x: 32.8, y: 0)))
                }

                art.drawLayer { stalk in
                    if g < 1 {   // 沿中线一点点露出来，圆头就是正在长的嫩尖
                        let line = polyline(s1, 120) + polyline(curve, 120).dropFirst()
                        let want = length(line) * g
                        var reveal = Path(), acc = 0.0
                        reveal.move(to: point(line[0]))
                        for i in 1..<line.count {
                            let d = simd_length(line[i] - line[i - 1])
                            if acc + d >= want {
                                reveal.addLine(to: point(line[i - 1] + (line[i] - line[i - 1]) * ((want - acc) / d)))
                                break
                            }
                            acc += d
                            reveal.addLine(to: point(line[i]))
                        }
                        stalk.clip(to: reveal.strokedPath(StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round)))
                    }
                    stalk.fill(stemOutline(s1, curve).path,
                               with: boxGradient(goldBox, [.init(color: gold[0], location: 0), .init(color: gold[1], location: 1)]))
                }

                for i in grains.indices {
                    let p = popAt(i, t)
                    guard p > 0 else { continue }
                    let pose = grainPose(i, curve), k = outBack(p, 1.2) * pins[i].s
                    var grain = art
                    grain.translateBy(x: pose.p.x, y: pose.p.y)
                    grain.rotate(by: .degrees(pose.a))
                    grain.scaleBy(x: k, y: k)
                    grain.fill(grainPath, with: boxGradient(CGRect(x: -1.7, y: 0, width: 3.4, height: 6.6), [
                        .init(color: grainColors[0], location: 0),
                        .init(color: grainColors[1], location: 0.55),
                        .init(color: grainColors[2], location: 1),
                    ]))
                    grain.stroke(seamPath, with: .color(seamColor), style: StrokeStyle(lineWidth: 0.32, lineCap: .round))
                }

                var cut = art
                cut.blendMode = .destinationOut
                cut.translateBy(x: cursorAt.x, y: cursorAt.y)
                cut.rotate(by: .degrees(cursorAngle))
                cut.stroke(cursorPath, with: .color(.black), style: StrokeStyle(lineWidth: 5.6, lineCap: .round, lineJoin: .round))

                let gp = seg(t, 1.5, 2.0)
                if gp > 0 && gp < 1 {
                    let c = -0.3 + 1.6 * inOutSine(gp), w = 0.2
                    var glint = art
                    glint.blendMode = .sourceAtop
                    glint.fill(Path(CGRect(x: -margin, y: -margin, width: 48 + 2 * margin, height: 48 + 2 * margin)),
                               with: .linearGradient(Gradient(stops: [
                                   .init(color: .white.opacity(0), location: clamp01(c - w)),
                                   .init(color: .white.opacity(0.85), location: clamp01(c)),
                                   .init(color: .white.opacity(0), location: clamp01(c + w)),
                               ]), startPoint: CGPoint(x: 6, y: 6), endPoint: CGPoint(x: 42, y: 42)))
                }
            }
        }

        // 光标：先淡入，颜色随底板撑开从背景上的颜色过渡到奶白
        let ca = seg(t, 0, 0.1)
        if ca > 0 {
            let r = startInk.0 + (cursorInk.0 - startInk.0) * bp
            let gr = startInk.1 + (cursorInk.1 - startInk.1) * bp
            let b = startInk.2 + (cursorInk.2 - startInk.2) * bp
            var cursor = ctx
            cursor.opacity = ca
            cursor.translateBy(x: cursorAt.x, y: cursorAt.y)
            cursor.rotate(by: .degrees(cursorAngle))
            cursor.stroke(cursorPath, with: .color(Color(red: r, green: gr, blue: b)),
                          style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
    }
}

/// 作者 LingCore 的头像：手拿光标的 Q 版小人（Resources/AuthorAvatar.png，打包时放进程序的 Resources）。
/// 打开页面时弹出来，再像打招呼一样左右歪一歪；点一下再来一次。找不到图片时退回“光标与稻穗”标志。
struct AuthorAvatar: View {
    var size: CGFloat = 60

    @ObservedObject private var clock = AuthorMarkClock.shared

    private static let image = Bundle.main.image(forResource: "AuthorAvatar")

    var body: some View {
        if let image = Self.image {
            TimelineView(.animation(minimumInterval: 1.0 / 58, paused: !clock.running)) { context in
                let t = clock.running ? context.date.timeIntervalSince(clock.start) : 10
                avatar(image)
                    .scaleEffect(Self.scale(t))
                    .rotationEffect(.degrees(Self.tilt(t)), anchor: .bottom)
            }
            .contentShape(Circle())
            .onTapGesture { clock.play() }
            .accessibilityLabel(L("作者 LingCore 的头像"))
        } else {
            AuthorMark(size: size)
        }
    }

    private func avatar(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(red: 1, green: 0.96, blue: 0.9)))
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
    }

    /// 0.45 秒内从 0.6 倍弹到原大，带一点回弹
    private static func scale(_ t: Double) -> Double {
        let p = min(max(t / 0.45, 0), 1), s = 1.9
        return 0.6 + 0.4 * (1 + (s + 1) * pow(p - 1, 3) + s * pow(p - 1, 2))
    }

    /// 弹出来以后左右歪两下，越来越轻，像在打招呼
    private static func tilt(_ t: Double) -> Double {
        let u = t - 0.35
        guard u > 0 else { return 0 }
        return 9 * sin(2 * Double.pi * 1.5 * u) * exp(-2.6 * u)
    }
}
