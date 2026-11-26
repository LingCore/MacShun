// SPDX-License-Identifier: MIT

import AppKit

enum CaptureColorFormat: String {
    case hex, rgb, hsl

    var next: Self {
        switch self {
        case .hex: .rgb
        case .rgb: .hsl
        case .hsl: .hex
        }
    }
}

struct CaptureLoupeSample {
    static let radius = 7
    static let side = radius * 2 + 1
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let pixel: CGPoint
    let image: CGImage
    let color: NSColor
    let hex: String
    private let rgb: (red: Int, green: Int, blue: Int)

    init?(image source: CGImage, pixel: CGPoint) {
        let side = Self.side, radius = Self.radius
        let requested = CGRect(x: Int(pixel.x) - radius, y: Int(pixel.y) - radius, width: side, height: side)
        let area = requested.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        let format = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let crop = source.cropping(to: area),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: Self.colorSpace, bitmapInfo: format),
              let data = context.data else { return nil }

        // 只转换指针周围的小块。屏幕边缘补黑，中心格仍对应鼠标下的像素。
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        context.draw(crop, in: CGRect(x: area.minX - requested.minX, y: requested.maxY - area.maxY,
                                      width: area.width, height: area.height))
        guard let preview = context.makeImage() else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self).advanced(by: radius * context.bytesPerRow + radius * 4)
        rgb = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
        self.pixel = pixel
        image = preview
        color = NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                        blue: CGFloat(rgb.blue) / 255, alpha: 1)
        hex = String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    func text(in format: CaptureColorFormat) -> String {
        switch format {
        case .hex: return hex
        case .rgb: return "rgb(\(rgb.red), \(rgb.green), \(rgb.blue))"
        case .hsl:
            let (red, green, blue) = (Double(rgb.red) / 255, Double(rgb.green) / 255, Double(rgb.blue) / 255)
            let high = max(red, green, blue), low = min(red, green, blue)
            let lightness = (high + low) / 2
            let chroma = high - low
            let lightnessPercent = Int((lightness * 100).rounded())
            guard chroma > 0 else { return "hsl(0, 0%, \(lightnessPercent)%)" }

            let hue: Double
            if high == red { hue = (green - blue) / chroma }
            else if high == green { hue = (blue - red) / chroma + 2 }
            else { hue = (red - green) / chroma + 4 }
            let degrees = (Int((hue * 60).rounded()) + 360) % 360
            let saturation = chroma / (1 - abs(2 * lightness - 1))
            return "hsl(\(degrees), \(Int((saturation * 100).rounded()))%, \(lightnessPercent)%)"
        }
    }
}

@MainActor
final class CaptureLoupe: NSView {
    private static let inset: CGFloat = 8
    private static let gridBottom: CGFloat = 60
    private static let minimumWidth: CGFloat = 151
    private let grid = CALayer()
    private let horizontalGuide = CALayer()
    private let verticalGuide = CALayer()
    private let darkOutline = CALayer()
    private let lightOutline = CALayer()
    private let swatch = CALayer()
    private let coordsLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let formatShortcutLabel = NSTextField(labelWithString: L("⇧ 格式"))
    private let shortcutLabel = NSTextField(labelWithString: "")

    var colorFormat: CaptureColorFormat = .hex {
        didSet {
            guard oldValue != colorFormat else { return }
            copied = false
            updateValue()
        }
    }
    var displayedColor: String? { sample == nil ? nil : valueLabel.stringValue }
    var displayedCoords: String { coordsLabel.stringValue }

    var sample: CaptureLoupeSample? {
        didSet {
            copied = false
            grid.contents = sample?.image
            if oldValue?.pixel != sample?.pixel {
                if let pixel = sample?.pixel {
                    coordsLabel.stringValue = "\(Int(pixel.x)), \(Int(pixel.y))"
                } else {
                    coordsLabel.stringValue = ""
                }
            }
            if oldValue?.hex != sample?.hex {
                swatch.backgroundColor = sample?.color.cgColor
                updateValue()
            }
        }
    }
    var canCopy = true { didSet { if oldValue != canCopy { updateShortcut() } } }
    var copied = false { didSet { if oldValue != copied { updateShortcut() } } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // 只更新 15×15 的像素纹理。放大、十字准星和中心框交给合成器，色值相同时也无需重画文字。
        grid.contentsGravity = .resize
        grid.magnificationFilter = .nearest
        grid.cornerRadius = 4
        grid.masksToBounds = true
        grid.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        horizontalGuide.actions = grid.actions
        verticalGuide.actions = grid.actions
        darkOutline.borderColor = NSColor.black.cgColor
        darkOutline.borderWidth = 3
        darkOutline.actions = grid.actions
        lightOutline.borderColor = NSColor.white.cgColor
        lightOutline.borderWidth = 1
        lightOutline.actions = grid.actions
        grid.addSublayer(horizontalGuide)
        grid.addSublayer(verticalGuide)
        grid.addSublayer(darkOutline)
        grid.addSublayer(lightOutline)
        layer?.addSublayer(grid)
        swatch.frame = CGRect(x: Self.inset, y: 8, width: 12, height: 12)
        swatch.cornerRadius = 3
        swatch.actions = ["backgroundColor": NSNull()]
        layer?.addSublayer(swatch)
        coordsLabel.font = NSFont(name: "Menlo-Regular", size: 10.5) ?? .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        coordsLabel.textColor = .secondaryLabelColor
        valueLabel.textColor = .labelColor
        shortcutLabel.alignment = .right
        for label in [formatShortcutLabel, shortcutLabel] {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
        }
        for label in [coordsLabel, valueLabel, formatShortcutLabel, shortcutLabel] {
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        updateShortcut()
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L("屏幕取色"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let line = 1 / (window?.backingScaleFactor ?? 1)
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = line
        swatch.borderColor = NSColor.separatorColor.cgColor
        swatch.borderWidth = line
        let guideColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
        horizontalGuide.backgroundColor = guideColor
        verticalGuide.backgroundColor = guideColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let side = max(0, bounds.height - Self.gridBottom - Self.inset)
        grid.frame = CGRect(x: floor((bounds.width - side) / 2), y: Self.gridBottom, width: side, height: side)
        let radius = CGFloat(CaptureLoupeSample.radius) * side / CGFloat(CaptureLoupeSample.side)
        let center = CGRect(origin: .zero, size: grid.bounds.size).insetBy(dx: radius, dy: radius)
        horizontalGuide.frame = CGRect(x: 0, y: center.minY, width: grid.bounds.width, height: center.height)
        verticalGuide.frame = CGRect(x: center.minX, y: 0, width: center.width, height: grid.bounds.height)
        darkOutline.frame = center.insetBy(dx: -1.5, dy: -1.5)
        lightOutline.frame = center.insetBy(dx: -0.5, dy: -0.5)

        let valueSize: CGFloat = bounds.width <= Self.minimumWidth ? 11 : 12
        // 色值只需要 ASCII。用固定字体的原生标签，让 AppKit 管理字形和排版生命周期。
        if valueLabel.font?.pointSize != valueSize {
            valueLabel.font = NSFont(name: "Menlo-Regular", size: valueSize) ?? .systemFont(ofSize: valueSize)
        }
        let formatWidth = ceil(formatShortcutLabel.intrinsicContentSize.width)
        let copyWidth = ceil(shortcutLabel.intrinsicContentSize.width)
        layoutLabel(formatShortcutLabel, x: 26, centerY: 14, width: formatWidth)
        layoutLabel(shortcutLabel, x: bounds.maxX - Self.inset - copyWidth, centerY: 14, width: copyWidth)
        layoutLabel(valueLabel, x: Self.inset, centerY: 32, width: max(0, bounds.width - 2 * Self.inset))
        layoutLabel(coordsLabel, x: Self.inset, centerY: 48, width: max(0, bounds.width - 2 * Self.inset))
    }

    private func layoutLabel(_ label: NSTextField, x: CGFloat, centerY: CGFloat, width: CGFloat) {
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = CGRect(x: x, y: floor(centerY - height / 2), width: width, height: height)
    }

    private func updateValue() {
        let text = sample?.text(in: colorFormat)
        valueLabel.stringValue = text ?? ""
        setAccessibilityValue(text)
    }

    private func updateShortcut() {
        shortcutLabel.isHidden = !canCopy
        formatShortcutLabel.isHidden = !canCopy
        shortcutLabel.stringValue = copied ? L("已复制") : L("C 复制")
        needsLayout = true
    }

    static func frame(near point: CGPoint, in bounds: CGRect, avoiding obstacles: [CGRect], scale: CGFloat) -> CGRect? {
        let available = bounds.insetBy(dx: 6, dy: 6)
        for (cellSize, gap) in [(10, 18), (7, 12), (6, 12), (5, 12), (4, 12)] {
            let grid = CGFloat(CaptureLoupeSample.side * cellSize)
            let size = CGSize(width: max(minimumWidth, grid + 2 * inset), height: grid + gridBottom + inset)
            if let origin = origin(near: point, size: size, gap: CGFloat(gap), in: available, avoiding: obstacles, scale: scale) {
                return CGRect(origin: origin, size: size)
            }
        }
        return nil
    }

    private static func origin(near point: CGPoint, size: CGSize, gap: CGFloat, in available: CGRect,
                               avoiding obstacles: [CGRect], scale: CGFloat) -> CGPoint? {
        guard available.width >= size.width, available.height >= size.height else { return nil }
        func above(_ value: CGFloat) -> CGFloat { ceil(value * scale) / scale }
        func below(_ value: CGFloat) -> CGFloat { floor(value * scale) / scale }
        let xPositions = [above(point.x + gap), below(point.x - gap - size.width)]
        let yPositions = [below(point.y - gap - size.height), above(point.y + gap)]
        func position(x: CGFloat, y: CGFloat) -> CGPoint? {
            let p = CGPoint(x: min(max(x, available.minX), available.maxX - size.width),
                            y: min(max(y, available.minY), available.maxY - size.height))
            let frame = CGRect(origin: p, size: size)
            guard !frame.insetBy(dx: 1 - gap, dy: 1 - gap).contains(point),
                  !obstacles.contains(where: { frame.intersects($0) }) else { return nil }
            return p
        }
        for y in yPositions {
            for x in xPositions {
                if let p = position(x: x, y: y) { return p }
            }
        }
        // 指针两侧都被工具条或提示挡住时，贴着它们的边缘找最近的空位。
        let xs = xPositions + obstacles.flatMap { [below($0.minX - size.width - 1), above($0.maxX + 1)] }
        let ys = yPositions + obstacles.flatMap { [below($0.minY - size.height - 1), above($0.maxY + 1)] }
        func distance(_ p: CGPoint) -> CGFloat {
            hypot(p.x + size.width / 2 - point.x, p.y + size.height / 2 - point.y)
        }
        return ys.flatMap { y in xs.compactMap { x in position(x: x, y: y) } }
            .min { distance($0) < distance($1) }
    }
}
