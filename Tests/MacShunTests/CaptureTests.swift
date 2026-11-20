// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

func captureTestPhoto(width: Int, height: Int, points: CGSize) throws -> CaptureImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
    return CaptureImage(image: try #require(context.makeImage()), size: points)
}

@Suite("截图")
struct CaptureTests {
    @Test func windowsOnLeftAndAbovePrimary() throws {
        let window = CGRect(x: -500, y: -100, width: 520, height: 160)
        let leftScreen = CGRect(x: -800, y: -180, width: 800, height: 500)
        #expect(CaptureImage.localWindows([window], in: leftScreen) == [CGRect(x: 300, y: 260, width: 500, height: 160)])
        let local = try #require(CaptureImage.localWindows([window], in: CGRect(x: 0, y: 0, width: 800, height: 600)).first)
        let primary = try captureTestPhoto(width: 1600, height: 1200, points: CGSize(width: 800, height: 600))
        #expect(primary.pixelRect(local) == CGRect(x: 0, y: 0, width: 40, height: 120))
    }

    @Test func cropAndRedactionStayAlignedAtRetinaScale() throws {
        let photo = try captureTestPhoto(width: 80, height: 60, points: CGSize(width: 40, height: 30))
        let area = CGRect(x: 8.25, y: 5, width: 12, height: 18.5)
        #expect(photo.pixelRect(area) == CGRect(x: 16, y: 13, width: 25, height: 37))
        #expect(photo.render(CGRect(x: -10, y: 100, width: 5, height: 2), marks: []) == nil)
        let cover = CaptureMark(kind: .cover, start: CGPoint(x: 11, y: 17), end: CGPoint(x: 15, y: 20))
        let image = try #require(photo.render(area, marks: [cover]))
        #expect(image.width == 25 && image.height == 37)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let png = try #require(NSBitmapImageRep(data: data))
        // 读解码后的 PNG（左上原点）：遮挡必须完全不透明，背景上下不可颠倒。
        let hidden = try #require(png.colorAt(x: 8, y: 10)?.usingColorSpace(.sRGB))
        #expect(hidden.redComponent < 0.01 && hidden.blueComponent < 0.01 && hidden.alphaComponent == 1)
        #expect(try #require(png.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)).blueComponent > 0.99)
        #expect(try #require(png.colorAt(x: 0, y: 36)?.usingColorSpace(.sRGB)).redComponent > 0.99)
    }

    @Test func loupeSamplesPhysicalPixelsAndConvertsP3() throws {
        let photo = try captureTestPhoto(width: 80, height: 60, points: CGSize(width: 40, height: 30))
        let top = try #require(photo.pixel(at: CGPoint(x: 0, y: 30)))
        let bottom = try #require(photo.pixel(at: CGPoint(x: 39.75, y: 0)))
        #expect(top == CGPoint(x: 0, y: 0))
        #expect(bottom == CGPoint(x: 79, y: 59))
        #expect(photo.pixel(at: CGPoint(x: 10.75, y: 12.25)) == CGPoint(x: 21, y: 35))
        #expect(photo.pixel(at: CGPoint(x: 40, y: 20)) == nil)

        let sample = try #require(CaptureLoupeSample(image: photo.image, pixel: top))
        #expect(sample.hex == "#0000FF")
        #expect(sample.text(in: .rgb) == "rgb(0, 0, 255)")
        #expect(sample.text(in: .hsl) == "hsl(240, 100%, 50%)")
        #expect(CaptureLoupeSample(image: sample.image, pixel: .zero)?.text(in: .hsl) == "hsl(0, 0%, 0%)")
        #expect(CaptureLoupeSample(image: photo.image, pixel: bottom)?.hex == "#FF0000")
        let preview = NSBitmapImageRep(cgImage: sample.image)
        #expect(preview.colorAt(x: 7, y: 7)?.usingColorSpace(.sRGB)?.blueComponent == 1)
        #expect(preview.colorAt(x: 7, y: 6)?.usingColorSpace(.sRGB)?.blueComponent == 0)
        #expect(preview.colorAt(x: 6, y: 7)?.usingColorSpace(.sRGB)?.blueComponent == 0)
        #expect(preview.colorAt(x: 7, y: 8)?.usingColorSpace(.sRGB)?.blueComponent == 1)

        let p3 = NSColor(displayP3Red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: p3.colorSpace.cgColorSpace!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(p3.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let wideGamut = try #require(context.makeImage())
        let converted = try #require(CaptureLoupeSample(image: wideGamut, pixel: .zero))
        let srgb = try #require(p3.usingColorSpace(.sRGB))
        #expect(abs(converted.color.redComponent - srgb.redComponent) <= 1 / 255.0)
        #expect(abs(converted.color.greenComponent - srgb.greenComponent) <= 1 / 255.0)
        #expect(abs(converted.color.blueComponent - srgb.blueComponent) <= 1 / 255.0)
        #expect(converted.hex != "#CC6633")
    }

    @Test func shortcutsAreOptInAndRespectExclusions() throws {
        var config = try JSONDecoder().decode(KeyboardConfig.self, from: Data("{}".utf8))
        #expect(config.captureShortcut == nil && config.captureTextShortcut == nil)
        config.enabled = false
        config.captureShortcut = WinShortcut(keyCode: KeyCode.f6, modifiers: [])
        config.captureTextShortcut = WinShortcut(keyCode: KeyCode.f6, modifiers: .shift)
        let mapper = KeyMapper(config: config)
        var context = KeyContext(appKind: .normal, clipboardEnabled: false, focus: { .unknown })
        #expect(mapper.action(keyCode: KeyCode.f6, flags: [], context: context) == .command(.capture(.image)))
        #expect(mapper.action(keyCode: KeyCode.f6, flags: .maskShift, context: context) == .command(.capture(.text)))
        context.appKind = .excluded
        #expect(mapper.action(keyCode: KeyCode.f6, flags: [], context: context) == .pass)
        let reserved: [(CGKeyCode, CGEventFlags)] = [
                (KeyCode.a, []), (KeyCode.c, .maskShift), (KeyCode.a, .maskAlternate),
                (KeyCode.a, [.maskControl, .maskAlternate]), (KeyCode.four, [.maskCommand, .maskShift])
        ]
        for layout in KeyboardLayoutKind.allCases {
            for (key, flags) in reserved {
                let shortcut = WinShortcut(keyCode: key, modifiers: SideButtons.modifiers(of: flags, layout: layout))
                #expect(!shortcut.canStartCapture(layout: layout))
            }
        }
    }

    /// 使用 AppKit 的真实选区、按钮和鼠标事件，不读取桌面或系统剪贴板。
    @MainActor @Test func selectWindowResizeAnnotateUndoAndReadText() throws {
        _ = NSApplication.shared
        let size = CGSize(width: 640, height: 420)
        let target = CGRect(x: 140, y: 90, width: 320, height: 220)
        let photo = try captureTestPhoto(width: 1280, height: 840, points: size)
        for mode in [CaptureMode.image, .text] {
            let canvas = CaptureCanvas(photo: photo, mode: mode, windowRects: [target])
            let window = NSPanel(contentRect: photo.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = canvas
            var copies = 0, cancellations = 0, saves = 0
            canvas.onCopy = { copies += 1 }
            canvas.onCancel = { cancellations += 1 }
            canvas.onSave = { saves += 1 }
            func mouse(_ type: NSEvent.EventType, _ p: CGPoint) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 1,
                                                windowNumber: window.windowNumber, context: nil,
                                                eventNumber: 1, clickCount: 1, pressure: 1))
            }
            func drag(_ a: CGPoint, _ b: CGPoint) throws {
                canvas.mouseDown(with: try mouse(.leftMouseDown, a))
                canvas.mouseDragged(with: try mouse(.leftMouseDragged, b))
                canvas.mouseUp(with: try mouse(.leftMouseUp, b))
            }
            func key(_ code: CGKeyCode, _ flags: NSEvent.ModifierFlags = []) throws {
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                          timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                                          characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                                          keyCode: code))
                #expect(canvas.handleKey(event))
            }
            let middle = CGPoint(x: target.midX, y: target.midY)
            try drag(middle, middle)
            #expect(canvas.selection == target)
            if mode == .text {
                #expect(copies == 1)
                continue
            }
            #expect(copies == 0)
            try drag(CGPoint(x: target.maxX, y: target.maxY), CGPoint(x: target.maxX + 20, y: target.maxY + 10))
            #expect(canvas.selection?.width == 340 && canvas.selection?.height == 230)
            let toolbar = try #require(canvas.subviews.compactMap { $0 as? CaptureToolbar }.first)
            toolbar.layoutSubtreeIfNeeded()
            let buttons = toolbar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            #expect(buttons.count == CaptureMark.Kind.allCases.count + 10 && canvas.bounds.contains(toolbar.frame))
            #expect(buttons.contains { $0.accessibilityLabel() == CaptureMark.Kind.ellipse.title })
            for button in buttons { #expect(button.frame.width >= 26 && button.accessibilityLabel() != nil) }
            let redact = try #require(buttons.first { $0.toolTip == CaptureMark.Kind.cover.title })
            redact.performClick(nil)
            try drag(middle, CGPoint(x: middle.x + 30, y: middle.y + 20))
            #expect(canvas.marks.count == 1)
            try key(KeyCode.z, .command)
            #expect(canvas.marks.isEmpty)
            try key(KeyCode.s, .command)
            try key(KeyCode.escape)
            #expect(saves == 1 && cancellations == 1 && copies == 0)
            try key(KeyCode.returnKey)
            #expect(copies == 1)
        }
    }
    @Test func polygonExportsTransparentCornersAndClipsMarksAtRetinaScale() throws {
        let photo = try captureTestPhoto(width: 80, height: 60, points: CGSize(width: 40, height: 30))
        let polygon = try #require(CapturePolygon([
            CGPoint(x: 10, y: 5), CGPoint(x: 30, y: 8), CGPoint(x: 20, y: 25)
        ]))
        let mark = CaptureMark(kind: .cover, start: CGPoint(x: 9, y: 18), end: CGPoint(x: 22, y: 23))
        let image = try #require(photo.render(polygon.bounds, marks: [mark], polygon: polygon))
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let png = try #require(NSBitmapImageRep(data: data))
        #expect(png.pixelsWide == 40 && png.pixelsHigh == 40)
        func color(_ x: Int, _ y: Int) throws -> NSColor {
            try #require(png.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        }
        #expect(try color(2, 8).alphaComponent == 0)
        #expect(try color(21, 8).alphaComponent == 1)
        #expect(try color(21, 8).blueComponent < 0.01)
        #expect(try color(20, 17).blueComponent > 0.99)
        #expect(try color(20, 30).redComponent > 0.99)
        let edge = try (0..<png.pixelsWide).map { try color($0, 17).alphaComponent }
        #expect(edge.contains { $0 > 0 && $0 < 1 })
    }

    @MainActor @Test func toolbarFeedbackAndCompactLayout() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: -16000, y: -16000, width: 640, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let toolbar = CaptureToolbar()
        panel.contentView?.addSubview(toolbar)
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        let fullWidth = toolbar.frame.size
        #expect(Set(buttons.map { $0.frame.minY }).count == 2)
        let line = try #require(buttons.first { $0.accessibilityLabel() == CaptureMark.Kind.line.title })
        let copy = try #require(buttons.first { $0.accessibilityLabel() == L("复制图片（Enter）") })
        #expect(copy.frame.maxY < line.frame.minY)
        let besideSecondRow = toolbar.convert(CGPoint(x: copy.frame.midX, y: line.frame.midY), to: toolbar.superview)
        #expect(toolbar.hitTest(besideSecondRow) == nil)
        toolbar.setPrimaryRowOnTop(false)
        #expect(line.frame.maxY < copy.frame.minY)
        toolbar.setPrimaryRowOnTop(true)
        toolbar.fit(within: 408)
        #expect(toolbar.frame.width <= 408 && Set(buttons.map { $0.frame.minY }).count == 2)
        #expect(copy.frame.maxY < line.frame.minY)
        toolbar.fit(within: 308)
        #expect(toolbar.frame.width <= 308 && toolbar.frame.height > fullWidth.height)
        for (index, button) in buttons.enumerated() {
            #expect(toolbar.bounds.contains(button.frame))
            #expect(buttons.dropFirst(index + 1).allSatisfy { !$0.frame.intersects(button.frame) })
            #expect(toolbar.hitTest(button.convert(NSPoint(x: 16, y: 16), to: toolbar.superview)) === button)
        }
        toolbar.fit(within: 640)
        #expect(toolbar.frame.size == fullWidth)

        let arrow = try #require(buttons.first { $0.accessibilityLabel() == CaptureMark.Kind.arrow.title })
        let undo = try #require(buttons.first { $0.accessibilityLabel() == L("撤销标注") })
        func pixels(_ button: NSButton, hover: Bool) throws -> Data {
            let event = try #require(NSEvent.enterExitEvent(with: hover ? .mouseEntered : .mouseExited, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                trackingNumber: 0, userData: nil))
            if hover { button.mouseEntered(with: event) } else { button.mouseExited(with: event) }
            let rep = try #require(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            button.cacheDisplay(in: button.bounds, to: rep)
            return try #require(rep.representation(using: .png, properties: [:]))
        }
        for look in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: look)
            toolbar.update(tool: nil, canUndo: false, canRedo: false, canScroll: true, hasMarks: false)
            let idle = try pixels(arrow, hover: false)
            let hover = try pixels(arrow, hover: true)
            #expect(hover != idle)
            arrow.highlight(true)
            #expect(try pixels(arrow, hover: true) != hover)
            arrow.highlight(false)
            #expect(try pixels(arrow, hover: false) == idle)
            toolbar.update(tool: .arrow, canUndo: false, canRedo: false, canScroll: true, hasMarks: false)
            #expect(try pixels(arrow, hover: false) != idle && arrow.state == .on)
            let disabled = try pixels(undo, hover: false)
            #expect(!undo.isEnabled)
            #expect(try pixels(undo, hover: true) == disabled)
        }
    }

    /// 通过和菜单相同的 start 入口走完整会话：用示例图和独立剪贴板，不碰用户的数据。
    @MainActor @Test func captureSessionCopiesImageAndTextAndCancelsCleanly() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 600, height: 180)
        let ctx = try #require(CGContext(data: nil, width: 600, height: 180, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("Capture example" as NSString).draw(at: CGPoint(x: 55, y: 50),
                                             withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let frame = CGRect(origin: CGPoint(x: -16000, y: -16000), size: size)
        let target = CGRect(x: 36, y: 30, width: 490, height: 90)
        let photo = CaptureImage(image: try #require(ctx.makeImage()), size: size)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let clipboard = CaptureClipboard(pasteboard: pb)
        let controller = ScreenCaptureController(clipboard: clipboard, freeze: {
            [FrozenScreen(frame: frame, photo: photo, windowRects: [target])]
        })
        defer { controller.cancel() }
        func begin(_ mode: CaptureMode) async throws -> NSWindow {
            controller.start(mode)
            for _ in 0..<100 {
                if let panel = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame && $0.contentView is CaptureCanvas }) {
                    return panel
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CocoaError(.coderValueNotFound)
        }
        func mouse(_ type: NSEvent.EventType, at point: CGPoint, in panel: NSWindow,
                   modifiers: NSEvent.ModifierFlags = [], clicks: Int = 1) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
            panel.sendEvent(event)
        }
        func clickWindow(_ panel: NSWindow, at point: CGPoint? = nil, clicks: Int = 1) throws {
            let point = point ?? CGPoint(x: target.midX, y: target.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                try mouse(type, at: point, in: panel, clicks: clicks)
            }
        }
        func setShift(_ down: Bool, in panel: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: KeyCode.shift))
            panel.sendEvent(event)
        }
        func press(_ key: CGKeyCode, _ char: String, in panel: NSWindow,
                   modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown) throws {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                                      timestamp: 1, windowNumber: panel.windowNumber, context: nil,
                                                      characters: char, charactersIgnoringModifiers: char,
                                                      isARepeat: false, keyCode: key))
            panel.sendEvent(event)
        }
        pb.setString("original", forType: .string)
        let initialCount = pb.changeCount
        var panel = try await begin(.image)
        try clickWindow(panel)
        try press(KeyCode.escape, "\u{1b}", in: panel)
        #expect(!panel.isVisible && pb.changeCount == initialCount && pb.string(forType: .string) == "original")

        panel = try await begin(.image)
        try clickWindow(panel)
        let canvas = try #require(panel.contentView as? CaptureCanvas)
        let toolbar = try #require(canvas.subviews.compactMap { $0 as? CaptureToolbar }.first)
        let checkmark = try #require(toolbar.subviews.compactMap { $0 as? NSButton }.first {
            $0.toolTip == L("复制图片（Enter）")
        })
        checkmark.performClick(nil)
        let data = try #require(pb.data(forType: .png))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(!panel.isVisible && rep.pixelsWide == 490 && rep.pixelsHigh == 90)
        let mapper = KeyMapper(config: KeyboardConfig())
        var screenshotOnlyConfig = KeyboardConfig()
        screenshotOnlyConfig.ctrlAsCommand = false
        let screenshotOnlyMapper = KeyMapper(config: screenshotOnlyConfig)
        let pasteContext = KeyContext(appKind: .normal, clipboardEnabled: true,
                                      hasCopiedScreenshot: { clipboard.containsScreenshot }, focus: { .text })
        #expect(mapper.action(keyCode: KeyCode.v, flags: .maskControl, context: pasteContext) ==
            .send(KeyStroke(KeyCode.v, .maskCommand)))
        #expect(screenshotOnlyMapper.action(keyCode: KeyCode.v, flags: .maskControl, context: pasteContext) ==
            .send(KeyStroke(KeyCode.v, .maskCommand)))
        #expect(ClipboardWatcher.capture(from: pb, recordImages: false) == nil)
        #expect(ClipboardWatcher.capture(from: pb, recordImages: true)?.kind == .image)

        panel = try await begin(.image)
        try press(KeyCode.r, "r", in: panel)
        let restored = try #require(panel.contentView as? CaptureCanvas)
        #expect(restored.selection == target)
        try press(KeyCode.rightArrow, "\u{f703}", in: panel)
        #expect(restored.selection == target.offsetBy(dx: 1, dy: 0))
        try press(KeyCode.escape, "\u{1b}", in: panel)
        panel = try await begin(.image)
        try press(KeyCode.r, "r", in: panel)
        #expect((panel.contentView as? CaptureCanvas)?.selection == target)
        try press(KeyCode.escape, "\u{1b}", in: panel)

        // 从冻结选区按 F3：关闭选区，贴图保持选区大小，创建时不改剪贴板。
        let beforePin = pb.changeCount
        panel = try await begin(.image)
        try clickWindow(panel)
        try press(KeyCode.f3, "\u{f706}", in: panel)
        let floating = try #require(ScreenPins.shared.windows.last)
        defer { floating.close() }
        #expect(!panel.isVisible && floating.isVisible)
        #expect(floating.naturalSize == target.size && pb.changeCount == beforePin)
        floating.copyPicture()
        #expect(pb.data(forType: .png) == data)
        #expect(mapper.action(keyCode: KeyCode.v, flags: .maskControl, context: pasteContext) ==
            .send(KeyStroke(KeyCode.v, .maskCommand)))
        #expect(screenshotOnlyMapper.action(keyCode: KeyCode.v, flags: .maskControl, context: pasteContext) == .pass)
        try press(KeyCode.escape, "\u{1b}", in: floating)
        #expect(!floating.isVisible)

        panel = try await begin(.text)
        try clickWindow(panel)
        #expect(!panel.isVisible)
        for _ in 0..<200 where pb.string(forType: .string) == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(pb.string(forType: .string)?.lowercased().contains("capture example") == true)
        #expect(pb.data(forType: .png) == nil)

        panel = try await begin(.image)
        let polygonCanvas = try #require(panel.contentView as? CaptureCanvas)
        let vertices = [CGPoint(x: 90, y: 30), CGPoint(x: 350, y: 40), CGPoint(x: 210, y: 140)]
        try clickWindow(panel)
        let anchors = try #require(polygonCanvas.toolbar.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == L("锚点选区")
        })
        anchors.performClick(nil)
        try clickWindow(panel, at: vertices[0])
        try press(KeyCode.escape, "\u{1b}", in: panel)
        #expect(panel.isVisible && polygonCanvas.selection == target && polygonCanvas.polygon == nil)
        try press(KeyCode.p, "p", in: panel)
        for point in vertices { try clickWindow(panel, at: point) }
        try clickWindow(panel, at: CGPoint(x: 270, y: 100))
        try press(KeyCode.backspace, "\u{7f}", in: panel)
        try clickWindow(panel, at: vertices[0])
        #expect(polygonCanvas.polygon?.vertices == vertices)
        let historyButtons = polygonCanvas.toolbar.subviews.compactMap { $0 as? NSButton }
        let undo = try #require(historyButtons.first { $0.accessibilityLabel() == L("撤销") })
        let redo = try #require(historyButtons.first { $0.accessibilityLabel() == L("重做") })
        #expect(!undo.isEnabled && !redo.isEnabled)
        func expectShape(_ shape: CapturePolygon) {
            #expect(polygonCanvas.polygon == shape && polygonCanvas.selection == shape.bounds)
        }
        func undoEdit() throws { try press(KeyCode.z, "z", in: panel, modifiers: .command) }
        func redoEdit() throws { try press(KeyCode.z, "Z", in: panel, modifiers: [.shift, .command]) }

        let first = CGPoint(x: 55, y: 25)
        try mouse(.leftMouseDown, at: CGPoint(x: 88, y: 34), in: panel)
        try mouse(.leftMouseDragged, at: CGPoint(x: 53, y: 29), in: panel)
        #expect(polygonCanvas.polygon?.vertices.first == first && polygonCanvas.selection?.origin == first)
        try mouse(.leftMouseUp, at: CGPoint(x: 53, y: 29), in: panel)
        let firstMoved = try #require(polygonCanvas.polygon)

        let raw = CGPoint(x: 409, y: 80)
        try mouse(.leftMouseDown, at: vertices[1], in: panel)
        try mouse(.leftMouseDragged, at: raw, in: panel)
        #expect(polygonCanvas.polygon?.vertices[1] == raw && polygonCanvas.selection?.maxX == raw.x)
        try setShift(true, in: panel)
        let adjusted = try #require(polygonCanvas.polygon)
        let snapped = adjusted.vertices[1]
        #expect(abs(atan2(snapped.y - first.y, snapped.x - first.x) - .pi / 12) < 1e-7)
        #expect(adjusted.vertices.first == first && adjusted.vertices.last == vertices[2])
        #expect(polygonCanvas.selection == adjusted.bounds)
        try setShift(false, in: panel)
        #expect(polygonCanvas.polygon?.vertices[1] == raw)
        try setShift(true, in: panel)
        try mouse(.leftMouseUp, at: raw, in: panel, modifiers: .shift)
        try setShift(false, in: panel)
        #expect(polygonCanvas.polygon == adjusted && !polygonCanvas.isDragging)

        try mouse(.leftMouseDown, at: first, in: panel)
        try mouse(.leftMouseDragged, at: vertices[2], in: panel)
        #expect(polygonCanvas.polygon == adjusted)
        try mouse(.leftMouseDragged, at: CGPoint(x: 30, y: 18), in: panel)
        #expect(polygonCanvas.selection?.minX == 30)
        try press(KeyCode.escape, "\u{1b}", in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: 30, y: 18), in: panel)
        #expect(panel.isVisible && polygonCanvas.polygon == adjusted && polygonCanvas.selection == adjusted.bounds)

        try press(KeyCode.backspace, "\u{7f}", in: panel)
        #expect(polygonCanvas.polygon == adjusted)
        #expect(undo.isEnabled && !redo.isEnabled)
        try undoEdit()
        expectShape(firstMoved)
        #expect(redo.isEnabled)
        try redoEdit()
        expectShape(adjusted)

        // The first click is just outside the closing edge and must preserve the selection.
        let outsideEdge = CGPoint(x: 99.2, y: 62.6)
        let projection = CGPoint(x: 101.5, y: 59.5)
        #expect(!adjusted.contains(outsideEdge))
        try clickWindow(panel, at: outsideEdge)
        #expect(polygonCanvas.polygon == adjusted)
        try clickWindow(panel, at: outsideEdge, clicks: 2)
        let added = try #require(polygonCanvas.polygon)
        #expect(added.vertices.dropLast().elementsEqual(adjusted.vertices))
        let inserted = try #require(added.vertices.last)
        #expect(hypot(inserted.x - projection.x, inserted.y - projection.y) < 1e-7)
        try clickWindow(panel, at: first)
        try clickWindow(panel, at: inserted)
        try press(KeyCode.forwardDelete, "\u{f728}", in: panel)
        #expect(polygonCanvas.polygon == adjusted)
        try undoEdit()
        expectShape(added)
        undo.performClick(nil)
        expectShape(adjusted)
        redo.performClick(nil)
        expectShape(added)
        try redoEdit()
        expectShape(adjusted)
        try undoEdit()
        try undoEdit()
        expectShape(adjusted)

        try clickWindow(panel, at: outsideEdge)
        try clickWindow(panel, at: outsideEdge, clicks: 2)
        #expect(!redo.isEnabled)
        let movedAnchor = CGPoint(x: 95, y: 104)
        try mouse(.leftMouseDown, at: inserted, in: panel)
        try mouse(.leftMouseDragged, at: movedAnchor, in: panel)
        try mouse(.leftMouseUp, at: movedAnchor, in: panel)
        let edited = try #require(polygonCanvas.polygon)
        #expect(edited.vertices == adjusted.vertices + [movedAnchor])

        try press(KeyCode.rightArrow, "\u{f703}", in: panel)
        polygonCanvas.advanceDirectionRepeat(at: .infinity)
        polygonCanvas.advanceDirectionRepeat(at: .infinity)
        try press(KeyCode.rightArrow, "\u{f703}", in: panel, type: .keyUp)
        expectShape(edited.offsetBy(dx: 3, dy: 0))
        try undoEdit()
        expectShape(edited)

        let scrollButton = try #require(polygonCanvas.toolbar.subviews.compactMap { $0 as? NSButton }.first {
            $0.toolTip == L("长截图需要矩形选区")
        })
        #expect(!scrollButton.isEnabled)
        polygonCanvas.toolbar.perform?(.tool(.polygon))
        for point in [CGPoint(x: 170, y: 90), CGPoint(x: 235, y: 90), CGPoint(x: 214, y: 115)] {
            try clickWindow(panel, at: point)
        }
        try press(KeyCode.returnKey, "\r", in: panel)
        let mark = try #require(polygonCanvas.marks.first)
        #expect(panel.isVisible && mark.kind == .polygon)
        try clickWindow(panel, at: first)
        try press(KeyCode.backspace, "\u{7f}", in: panel)
        #expect(polygonCanvas.polygon?.vertices == Array(edited.vertices.dropFirst()) && polygonCanvas.marks == [mark])
        try undoEdit()
        expectShape(edited)
        #expect(polygonCanvas.marks == [mark])
        try undoEdit()
        #expect(polygonCanvas.marks.isEmpty)
        try undoEdit()
        expectShape(added)
        try redoEdit()
        expectShape(edited)
        try redoEdit()
        #expect(polygonCanvas.marks == [mark])
        try press(KeyCode.returnKey, "\r", in: panel)
        let cutoutData = try #require(pb.data(forType: .png))
        let cutout = try #require(NSBitmapImageRep(data: cutoutData))
        let crop = photo.pixelRect(edited.bounds)
        #expect(!panel.isVisible && cutout.pixelsWide == Int(crop.width) && cutout.pixelsHigh == Int(crop.height) && cutout.hasAlpha)
        let stroke = try #require(cutout.colorAt(x: 151, y: 50)?.usingColorSpace(.sRGB))
        #expect(stroke.redComponent > 0.95 && stroke.greenComponent < 0.35)
        let outside = try #require(cutout.colorAt(x: cutout.pixelsWide - 4, y: cutout.pixelsHigh - 4))
        #expect(outside.alphaComponent < 0.05)
        let addedArea = CGPoint(x: 125, y: 88)
        #expect(!adjusted.contains(addedArea))
        let inside = try #require(cutout.colorAt(x: Int(addedArea.x - crop.minX), y: Int(edited.bounds.maxY - addedArea.y)))
        #expect(inside.alphaComponent > 0.95)
    }

    @Test func extendedRangeRGBColorSpacesRenderAnnotationsAndPolygons() throws {
        for name in [CGColorSpace.extendedSRGB, CGColorSpace.extendedDisplayP3] {
            let space = try #require(CGColorSpace(name: name))
            let info = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            let ctx = try #require(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 32,
                                             bytesPerRow: 0, space: space, bitmapInfo: info))
            ctx.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.5, 0.8, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            let image = try #require(ctx.makeImage())
            let photo = CaptureImage(image: image, size: CGSize(width: 80, height: 60))
            let mark = CaptureMark(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 40))
            let polygon = try #require(CapturePolygon([CGPoint(x: 5, y: 5), CGPoint(x: 75, y: 5), CGPoint(x: 40, y: 55)]))
            let rendered = try #require(photo.render(CGRect(x: 0, y: 0, width: 80, height: 60), marks: [mark], polygon: polygon))
            #expect(rendered.width == 80 && rendered.height == 60)
        }
    }

    @MainActor
    @Test func screenPinClampsExtremeZoomAndAllowsZoomingBackToInitialFit() throws {
        // 模拟一张很长的截图（100×8000 px），初始缩放低于 0.1，放大需受后备像素上限约束且能缩回初始贴合大小。
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 100, height: 8000, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 8000))
        let cg = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        let picture = try #require(PinPicture(png: png))
        let natural = CGSize(width: 50, height: 4000)
        let initialFrame = CGRect(x: 100, y: 100, width: 4, height: 320) // initialZoom = 0.08 < 0.1
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = ScreenPinPanel(picture: picture, frame: initialFrame, natural: natural, pasteboard: board)
        defer { panel.close() }
        #expect(abs(panel.initialZoom - 0.08) < 0.001)
        let center = CGPoint(x: initialFrame.midX, y: initialFrame.midY)
        panel.scale(to: 8, around: center)
        let scaleFactor = max(1, panel.screen?.backingScaleFactor ?? panel.backingScaleFactor)
        let maxDimension = ScreenPinPanel.maxBackingDimension
        #expect(max(panel.frame.width, panel.frame.height) * scaleFactor <= maxDimension + scaleFactor)
        panel.scale(to: 0.08, around: center)
        #expect(abs(panel.zoom - 0.08) < 0.001)
    }

    @MainActor
    @Test func escapeCancelsActiveSelectionDragBeforeCancellingCapture() throws {
        _ = NSApplication.shared
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let cg = try #require(ctx.makeImage())
        let photo = CaptureImage(image: cg, size: CGSize(width: 200, height: 160))
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        let window = NSWindow(contentRect: CGRect(x: -18000, y: -17000, width: 200, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }

        var cancelled = 0
        canvas.onCancel = { cancelled += 1 }
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let drag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 120, y: 100), modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ))
        let esc = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 3,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: KeyCode.escape
        ))
        canvas.mouseDown(with: down)
        canvas.mouseDragged(with: drag)
        #expect(canvas.selection != nil)
        // 拖动选区期间按 Esc：仅撤销当前拖动，不直接退出整个截图会话
        canvas.keyDown(with: esc)
        #expect(cancelled == 0)
        #expect(canvas.selection == nil)
        // 空闲态再按 Esc：正常退出截图
        canvas.keyDown(with: esc)
        #expect(cancelled == 1)
    }

    @MainActor
    @Test func tallPinPictureBuildsWithoutNSImageDuplicationAndRendersTiled() throws {
        _ = NSApplication.shared
        // 高度超过 Metal/单张纹理 16384 像素上限的超长图，验证直接由 CGImage 构造并走分块绘制路径不崩溃
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(data: nil, width: 16, height: 17000, bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 17000))
        let cg = try #require(ctx.makeImage())
        let png = try #require(CaptureImage.pngData(cg))
        let picture = try #require(PinPicture(cgImage: cg, png: png))
        #expect(picture.cgImage.height == 17000)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let frame = CGRect(x: 100, y: 100, width: 8, height: 400)
        let panel = ScreenPinPanel(picture: picture, frame: frame, natural: CGSize(width: 8, height: 8500), pasteboard: board)
        defer { panel.close() }
        let view = try #require(panel.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
    }

}
