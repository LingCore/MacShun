// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// “拾穗”：作者的其他作品，开源的和付费的。作者的每个程序都带这一页。
/// 名字取自米勒的《拾穗者》。内容只写在这里，不联网获取（隐私原则：除了检查更新不联网）。
/// 换到别的程序里用时，把这个文件和 AuthorMark.swift 复制过去，只改 `works`、`authorURL` 和 `feedbackEmail`。
struct Work: Identifiable {
    enum Kind {
        case openSource, paid
    }

    /// 应用标识（没有就随便取个不重复的名字），用来认出“正在使用”的那个。
    let id: String
    let name: String
    /// 一句话介绍，只占一行（十来个字），多出来的会被省略。
    let summary: String
    let kind: Kind
    let symbol: String
    let tint: Color
    /// 主页、仓库或购买页。nil 表示还没有公开地址。
    let url: URL?
    /// 作品自己的彩色标志（不带底板）。有它就直接显示标志，不画方块和 `symbol`。
    var icon: NSImage? = nil
}

enum Gleaning {
    static let title = L("拾穗计划")
    static let symbol = "leaf.fill"
    static let tint = Color(red: 0.80, green: 0.58, blue: 0.20)
    /// 作品图标容器（包括“更多作品”的占位方块）统一的边长。
    static let iconSize: CGFloat = 32
    /// 图标内容离容器边的间隙，四边一样。
    static let iconPadding: CGFloat = 7

    /// 作者的名字和一句话介绍，标志见 AuthorMark。
    static let authorName = "LingCore"
    static let authorMotto = L("为人民服务")

    /// 作者主页。填上后作者那一行会出现“作者主页”按钮。
    static let authorURL: URL? = nil

    /// 收建议的邮箱。nil 时反馈卡片显示“还没有”，按钮不可用。
    static let feedbackEmail: String? = nil

    /// 新作品加在这里，开源的和付费的会自动分开显示。
    static let works: [Work] = [
        Work(
            id: "io.github.lingcore.winshun",
            name: L("Mac顺"),
            summary: L("让 Mac 用得更顺手"),
            kind: .openSource,
            symbol: "keyboard",
            tint: .blue,
            url: nil,
            // 包里不带底板的矢量标志（scripts/make-icon.py 生成），按矢量绘制，任何大小都清楚
            icon: Bundle.main.url(forResource: "AppGlyph", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
        ),
    ]
}

// MARK: - 页面

/// 整页是一幅暖色的场景：天空、麦田、光点和飞鸟，内容浮在上面。
/// 浅色模式是金色的午后，深色模式是暖棕色的黄昏，都不用黑底。
/// 整个设置窗口在“拾穗”页时的背景场景，侧栏也铺在上面。窗口看不见时传 animating: false。
struct GleaningBackdrop: View {
    var animating = true
    /// 场景左边被侧栏占去的宽度。麦田中间留空的那块要对准右边内容区的中线。
    var leadingInset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WarmScene(
            palette: .current(colorScheme),
            paused: !animating || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            leadingInset: leadingInset
        )
    }
}

/// “拾穗”页的内容，背景由 GleaningBackdrop 铺在整个窗口下面。
struct GleaningPage: View {
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarmPalette { .current(colorScheme) }
    private var others: [Work] { Gleaning.works.filter { !isCurrent($0) } }

    var body: some View {
        // 一屏放下：作品在上，建议和落款贴在下面的麦田里，中间的空隙随窗口高度伸缩。
        // 只有以后作品多到放不下时才能滚动，平时不滚也不回弹。
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 0) {
                hero
                author
                    .padding(.top, 18)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 200), spacing: 24, alignment: .topLeading)],
                    alignment: .leading, spacing: 18
                ) {
                    // 付费的排在开源的后面
                    ForEach(Gleaning.works.sorted { $0.kind == .openSource && $1.kind == .paid }) {
                        WorkItem(work: $0, isCurrent: isCurrent($0), palette: palette)
                    }
                    if others.isEmpty {
                        ComingSoonItem(palette: palette)
                    }
                }
                .settingsAnchor(.works)
                .padding(.top, 22)
                Spacer(minLength: 20)
                FeedbackNote(palette: palette)
                    .settingsAnchor(.feedback)
                footer
                    .padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .padding(.top, 10)
            .padding(.bottom, 16)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("GLEANING")
                .font(.system(size: 10, weight: .bold))
                .tracking(4)
                .foregroundStyle(palette.inkSoft)
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(Gleaning.title)
                    .font(.system(size: 40, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .shadow(color: palette.glow, radius: 12)
                HStack(spacing: 6) {
                    let works = Gleaning.works
                    let open = works.filter { $0.kind == .openSource }.count
                    StatChip(text: L("%ld 个作品", works.count), palette: palette)
                    if open > 0 { StatChip(text: L("%ld 个开源", open), palette: palette) }
                    if works.count > open { StatChip(text: L("%ld 个付费", works.count - open), palette: palette) }
                }
            }
            Text(L("每一个作品，都是认真生活留下的痕迹"))
                .font(.system(size: 13.5))
                .foregroundStyle(palette.inkSoft)
        }
    }

    /// 作者：头像、名字和一句话。每次打开这一页头像都会弹出来打个招呼，点它可以再来一次。
    private var author: some View {
        HStack(spacing: 14) {
            AuthorAvatar(size: 56)
                .shadow(color: Color(red: 0.55, green: 0.25, blue: 0.08).opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(Gleaning.authorName)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(palette.ink)
                    Tag(text: L("作者"), palette: palette)
                }
                Text(Gleaning.authorMotto)
                    .font(.system(size: 24, weight: .black))
                    .foregroundStyle(palette.inkSoft)
            }
            Spacer(minLength: 12)
            if let url = Gleaning.authorURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L("作者主页"), systemImage: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(palette.chip))
                        .contentShape(Capsule())
                }
                .buttonStyle(HoverTintStyle(shape: Capsule()))
            }
        }
        .onAppear { AuthorMarkClock.shared.play() }
    }

    private var footer: some View {
        Text(L("“拾穗计划”的名字取自米勒的名画《拾穗者》"))
            .font(.caption)
            .foregroundStyle(palette.ink.opacity(0.8))
            .shadow(color: palette.halo, radius: 4)
            .shadow(color: palette.halo, radius: 2)
            .frame(maxWidth: .infinity)
    }

    private func isCurrent(_ work: Work) -> Bool {
        work.id == Bundle.main.bundleIdentifier || work.name == Bundle.main.infoDictionary?["CFBundleName"] as? String
    }
}

/// 一套暖色：天空、文字、卡片、麦子的颜色。
struct WarmPalette {
    let sky: [Color]
    let glow: Color
    let ink: Color
    let inkSoft: Color
    let chip: Color
    /// 作品图标的底色和描边
    let iconFill: Color
    let iconStroke: Color
    let wheatBack: Color
    let wheatFront: Color
    let mote: Color
    let bird: Color
    let accent: Color
    /// 浮在场景上的文字周围的光晕，压在麦穗上也看得清
    let halo: Color

    static func current(_ scheme: ColorScheme) -> WarmPalette {
        scheme == .dark ? .dusk : .day
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color {
        Color(red: r, green: g, blue: b)
    }

    /// 金色的午后
    static let day: WarmPalette = {
        let ink = rgb(0.36, 0.19, 0.06)
        return WarmPalette(
            sky: [rgb(1.00, 0.96, 0.87), rgb(1.00, 0.86, 0.63), rgb(0.98, 0.70, 0.43)],
            glow: .white.opacity(0.7),
            ink: ink,
            inkSoft: rgb(0.55, 0.34, 0.17),
            chip: .white.opacity(0.55),
            iconFill: .white.opacity(0.6),
            iconStroke: .white.opacity(0.9),
            wheatBack: rgb(0.92, 0.66, 0.32).opacity(0.6),
            wheatFront: rgb(0.80, 0.50, 0.18).opacity(0.85),
            mote: .white,
            bird: ink.opacity(0.4),
            accent: rgb(0.93, 0.42, 0.22),
            halo: rgb(1.00, 0.90, 0.72)
        )
    }()

    /// 晚霞：砖红到橘红再到琥珀，饱和度高，不发灰
    static let dusk: WarmPalette = {
        let ink = rgb(1.00, 0.96, 0.90)
        return WarmPalette(
            sky: [rgb(0.58, 0.23, 0.17), rgb(0.80, 0.36, 0.19), rgb(0.96, 0.58, 0.27)],
            glow: rgb(1.00, 0.70, 0.40).opacity(0.6),
            ink: ink,
            inkSoft: rgb(1.00, 0.86, 0.72),
            chip: .white.opacity(0.2),
            iconFill: .white.opacity(0.16),
            iconStroke: .white.opacity(0.35),
            wheatBack: rgb(1.00, 0.78, 0.46).opacity(0.5),
            wheatFront: rgb(1.00, 0.86, 0.58).opacity(0.85),
            mote: rgb(1.00, 0.95, 0.80),
            bird: ink.opacity(0.4),
            accent: rgb(0.95, 0.38, 0.22),
            halo: rgb(0.86, 0.42, 0.20)
        )
    }()
}

private struct StatChip: View {
    let text: String
    let palette: WarmPalette

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(palette.chip))
    }
}

// MARK: - 场景

/// 背景场景。窗口看不见、或者系统开了“减弱动态效果”时不动。
private struct WarmScene: View {
    let palette: WarmPalette
    let paused: Bool
    let leadingInset: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: palette.sky, startPoint: .top, endPoint: .bottom)
            SceneCanvas(palette: palette, paused: paused, leadingInset: leadingInset)
        }
        .allowsHitTesting(false)
    }
}

/// 用 Canvas 画的麦田、光点和飞鸟，每秒最多画 58 次。只在“拾穗”页显示、窗口看得见时才动。
private struct SceneCanvas: View {
    let palette: WarmPalette
    let paused: Bool
    let leadingInset: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 58, paused: paused)) { context in
            let t = paused ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                Self.drawBirds(&ctx, size, t, palette.bird)
                let clearing = Self.clearing(size, leadingInset: leadingInset)
                Self.drawStalks(&ctx, size, t, layer: 0, color: palette.wheatBack, clearing: clearing)
                Self.drawMotes(&ctx, size, t, palette.mote)
                Self.drawStalks(&ctx, size, t, layer: 1, color: palette.wheatFront, clearing: clearing)
            }
            // 几百个小图形，交给 GPU 一次画完，比逐个合成省很多。
            .drawingGroup()
        }
    }

    /// 麦粒的形状，只算一次。
    private static let grain = Path(ellipseIn: CGRect(x: -2.6, y: -5.5, width: 5.2, height: 11))

    /// 固定的伪随机数，0..<1。同一个参数每次都一样，麦子的位置才不会乱跳。
    private static func rnd(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 127 + salt * 311)) * 43758.5453
        return x - floor(x)
    }

    /// 麦田中间留空的一段（中线和半宽）：底部居中的建议、按钮和落款就在这里，麦穗长在后面也看不清，
    /// 只会让文字显得乱。
    private static func clearing(_ size: CGSize, leadingInset: CGFloat) -> (center: Double, half: Double) {
        let contentWidth = size.width - leadingInset
        return (leadingInset + contentWidth / 2, min(170, contentWidth * 0.32))   // 刚好盖住那段文字和按钮
    }

    /// 铺满底部的麦田，中间留空。layer 0 在后面，矮一些、密一些；layer 1 在前面。
    private static func drawStalks(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, layer: Int, color: Color,
                                   clearing: (center: Double, half: Double)) {
        // 稀疏一些，每根的位置和高矮都错开，不像排队。
        let spacing: Double = layer == 0 ? 60 : 84
        let count = Int(size.width / spacing) + 2
        let maxHeight = min(size.height * (layer == 0 ? 0.2 : 0.25), layer == 0 ? 150 : 190)
        let salt = layer * 100
        for i in 0..<count {
            let x = (Double(i) - 0.5 + rnd(i, salt + 1) * 1.3) * spacing
            // 留空的那段不长麦子；靠近它的几根渐渐变矮，边界不生硬
            let gap = abs(x - clearing.center) - clearing.half
            guard gap > 0 else { continue }
            let taper = min(gap / 90, 1)
            let height = maxHeight * (0.5 + rnd(i, salt + 2) * 0.5) * (0.45 + 0.55 * taper)
            let sway = sin(t * (0.7 + rnd(i, salt + 3) * 0.4) + x * 0.012) * 0.08 + 0.04
            let base = CGPoint(x: x, y: size.height + 8)
            let tip = CGPoint(x: x + height * sin(sway), y: base.y - height * cos(sway))
            let control = CGPoint(x: x, y: base.y - height * 0.55)

            var stem = Path()
            stem.move(to: base)
            stem.addQuadCurve(to: tip, control: control)
            ctx.stroke(stem, with: .color(color), lineWidth: layer == 0 ? 1.2 : 1.7)

            // 麦穗：靠近顶端的一段，左右交替排着麦粒。
            let angle = Angle.radians(sway * 1.4)
            let grains = 7
            let headLength = min(height * 0.24, 44)
            let scale = layer == 0 ? 0.85 : 1.1
            for k in 0...grains {
                let f = Double(k) / Double(grains)
                let p = CGPoint(
                    x: tip.x - sin(angle.radians) * headLength * (1 - f),
                    y: tip.y + cos(angle.radians) * headLength * (1 - f)
                )
                let side: Double = k == grains ? 0 : (k.isMultiple(of: 2) ? 1 : -1)
                var g = ctx
                g.translateBy(x: p.x, y: p.y)
                g.rotate(by: angle + .degrees(side * 28))
                g.scaleBy(x: scale, y: scale)
                g.fill(Self.grain, with: .color(color))
                // 后排看不清麦芒，省掉。
                if side != 0 && layer == 1 {
                    var awn = Path()
                    awn.move(to: CGPoint(x: 0, y: -5.5))
                    awn.addLine(to: CGPoint(x: side * 2.5, y: -16))
                    g.stroke(awn, with: .color(color.opacity(0.6)), lineWidth: 0.6)
                }
            }
        }
    }

    /// 从麦田里往上飘的光点，忽明忽暗，越高越淡。
    private static func drawMotes(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ color: Color) {
        let count = Int(size.width / 30)
        for i in 0..<count {
            let speed = 6 + rnd(i, 7) * 10
            let travel = size.height * 0.75
            let rise = (t * speed + rnd(i, 8) * travel).truncatingRemainder(dividingBy: travel)
            let y = size.height - rise
            let x = rnd(i, 9) * size.width + sin(t * 0.5 + Double(i)) * 12
            let r = 0.8 + rnd(i, 10) * 1.4
            let twinkle = 0.5 + 0.5 * sin(t * (1.2 + rnd(i, 11)) + Double(i))
            let fade = 1 - rise / travel
            let alpha = (0.35 + 0.65 * twinkle) * fade
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .color(color.opacity(alpha)))
        }
    }

    /// 天上慢慢飞过的几只小鸟，翅膀一扇一扇。
    private static func drawBirds(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double, _ color: Color) {
        for i in 0..<3 {
            let speed = 14 + rnd(i, 21) * 8
            let travel = size.width + 120
            let x = (t * speed + rnd(i, 22) * travel).truncatingRemainder(dividingBy: travel) - 60
            let y = size.height * 0.1 + Double(i) * 22 + sin(t * 0.6 + Double(i) * 2) * 8
            // 左边是标题，小鸟飞到那里之前慢慢隐去。
            let fade = min(max((x - size.width * 0.4) / (size.width * 0.15), 0), 1)
            guard fade > 0 else { continue }
            let flap = sin(t * 5 + Double(i) * 1.7)
            let span = 7.0 - Double(i)
            var bird = Path()
            bird.move(to: CGPoint(x: x - span, y: y - flap * 4))
            bird.addQuadCurve(to: CGPoint(x: x, y: y), control: CGPoint(x: x - span * 0.4, y: y - 3 - flap * 2))
            bird.addQuadCurve(to: CGPoint(x: x + span, y: y - flap * 4), control: CGPoint(x: x + span * 0.4, y: y - 3 - flap * 2))
            ctx.stroke(bird, with: .color(color.opacity(fade)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 内容

/// 一个作品：不加框，直接放在麦田上。有链接时整块可以点。
private struct WorkItem: View {
    let work: Work
    let isCurrent: Bool
    let palette: WarmPalette
    @ObservedObject private var hover = WorkLinkHover.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 有自己的标志就放标志；没有的用 `symbol`，不用它的彩色底（蓝色在暖色场景里太跳）
            WorkIconTile(palette: palette) {
                if let icon = work.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: work.symbol)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .fontWeight(.semibold)
                        .foregroundStyle(palette.ink)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                title
                Text(work.summary)
                    .font(.callout)
                    .foregroundStyle(palette.inkSoft)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Tag(text: work.kind == .openSource ? L("开源") : L("付费"), palette: palette)
                    if isCurrent { Tag(text: L("正在使用"), palette: palette) }
                }
                .padding(.top, 3)
            }
        }
    }

    private var name: some View {
        Text(work.name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.ink)
    }

    /// 作品名。有地址时是超链接：鼠标移上去出现下划线、变成手形，点了用浏览器打开。
    @ViewBuilder
    private var title: some View {
        if let url = work.url {
            let hovered = hover.id == work.id
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    name
                        .underline(hovered, color: palette.ink.opacity(0.7))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(hovered ? palette.ink : palette.inkSoft)
                        .offset(x: hovered ? 1 : 0, y: hovered ? -1 : 0)
                }
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: hovered)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
            .onHover { inside in
                if inside {
                    hover.id = work.id
                    NSCursor.pointingHand.push()
                } else {
                    if hover.id == work.id { hover.id = nil }
                    NSCursor.pop()
                }
            }
        } else {
            name
        }
    }
}

/// 鼠标停在哪个作品名上。不能用 @State（命令行工具缺宏插件），就放在这里共用。
private final class WorkLinkHover: ObservableObject {
    static let shared = WorkLinkHover()
    @Published var id: String?
}

/// 作品图标的容器：跟场景同色调的圆角方块，内容四边留出同样的间隙。占位的那个用虚线边。
private struct WorkIconTile<Content: View>: View {
    let palette: WarmPalette
    var dashed = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Gleaning.iconSize * 0.27, style: .continuous)
        shape
            .fill(palette.iconFill)
            .overlay(
                shape.strokeBorder(palette.iconStroke, style: StrokeStyle(lineWidth: dashed ? 1.2 : 1, dash: dashed ? [3, 3] : []))
            )
            .overlay(content.padding(Gleaning.iconPadding))
            .frame(width: Gleaning.iconSize, height: Gleaning.iconSize)
    }
}

/// 还没有别的作品时的占位：一个虚线方块，和作品排在一起。
private struct ComingSoonItem: View {
    let palette: WarmPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkIconTile(palette: palette, dashed: true) {
                Image(systemName: "sparkles")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.ink)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(L("更多作品正在路上"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.ink.opacity(0.85))
                Text(L("新作品做好就放在这里"))
                    .font(.callout)
                    .foregroundStyle(palette.inkSoft)
            }
        }
    }
}

/// 请用户写信提建议：居中的一小封“信”，微微歪着的信封，加一个胶囊按钮。
private struct FeedbackNote: View {
    let palette: WarmPalette
    private var email: String? { Gleaning.feedbackEmail }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                IconBadge(symbol: "envelope.fill", tint: palette.accent, size: 32)
                    .rotationEffect(.degrees(-9))
                    .shadow(color: palette.accent.opacity(0.45), radius: 8, y: 4)
                Text(L("您的建议非常重要"))
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(palette.ink)
                    .shadow(color: palette.halo, radius: 5)
                    .shadow(color: palette.halo, radius: 2)
            }
            Text(L("有任何建议，或想对开发者说的话，欢迎写信给我"))
                .font(.callout)
                .foregroundStyle(palette.ink.opacity(0.85))
                .shadow(color: palette.halo, radius: 4)
                .shadow(color: palette.halo, radius: 2)
            HStack(spacing: 12) {
                Button(action: compose) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(email ?? L("还没有"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(palette.accent.gradient))
                    .shadow(color: palette.accent.opacity(0.4), radius: 8, y: 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(HoverTintStyle(shape: Capsule()))
                .help(L("用邮件程序写信"))
                Button(L("复制"), action: copy)
                    .buttonStyle(HoverLinkStyle(color: nil))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.ink.opacity(0.85))
                    .shadow(color: palette.halo, radius: 3)
                    .help(L("复制邮箱地址"))
            }
            .padding(.top, 6)
            // 不用 .disabled：禁用的按钮会被画成半透明，透出后面的麦子。没填邮箱时按钮本来就什么也不做。
            .allowsHitTesting(email != nil)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    /// 用默认的邮件程序新建一封邮件，主题里带上程序名和版本，方便作者分类。
    private func compose() {
        guard let email else { return }
        let info = Bundle.main.infoDictionary
        let app = info?["CFBundleName"] as? String ?? L("Mac顺")
        let version = info?["CFBundleShortVersionString"] as? String ?? L("开发版")
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [URLQueryItem(name: "subject", value: L("%@ %@ 的建议", app, version))]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func copy() {
        guard let email else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
    }
}

private struct Tag: View {
    let text: String
    let palette: WarmPalette

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(palette.chip))
    }
}
