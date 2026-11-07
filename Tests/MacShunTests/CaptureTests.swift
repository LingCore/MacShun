// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@Suite("截图")
struct CaptureTests {
    private func photo(width: Int, height: Int, points: CGSize) throws -> CaptureImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return CaptureImage(image: try #require(context.makeImage()), size: points)
    }

    @Test func windowsOnLeftAndAbovePrimary() throws {
        let window = CGRect(x: -500, y: -100, width: 520, height: 160)
        let leftScreen = CGRect(x: -800, y: -180, width: 800, height: 500)
        #expect(CaptureImage.localWindows([window], in: leftScreen) == [CGRect(x: 300, y: 260, width: 500, height: 160)])
        let local = try #require(CaptureImage.localWindows([window], in: CGRect(x: 0, y: 0, width: 800, height: 600)).first)
        let primary = try photo(width: 1600, height: 1200, points: CGSize(width: 800, height: 600))
        #expect(primary.pixelRect(local) == CGRect(x: 0, y: 0, width: 40, height: 120))
    }

    @Test func cropAndRedactionStayAlignedAtRetinaScale() throws {
        let photo = try photo(width: 80, height: 60, points: CGSize(width: 40, height: 30))
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

    @Test func shortcutsAreOptInAndRespectExclusions() throws {
        var config = try JSONDecoder().decode(KeyboardConfig.self, from: Data("{}".utf8))
        #expect(config.captureShortcut == nil && config.captureTextShortcut == nil)
        config.enabled = false
        config.captureShortcut = WinShortcut(keyCode: KeyCode.f6, modifiers: [])
        config.captureTextShortcut = WinShortcut(keyCode: KeyCode.f6, modifiers: .shift)
        let mapper = KeyMapper(config: config)
        var context = KeyContext(appKind: .normal, isBrowser: false, clipboardEnabled: false, focus: { .unknown })
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
        let photo = try photo(width: 1280, height: 840, points: size)
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
            let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
            #expect(buttons.count == 13 && canvas.bounds.contains(toolbar.frame))
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
    @MainActor @Test func toolbarFeedbackAndCompactLayout() throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: CGRect(x: -16000, y: -16000, width: 640, height: 160),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let toolbar = CaptureToolbar()
        panel.contentView?.addSubview(toolbar)
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
        let singleRow = toolbar.frame.size
        toolbar.fit(within: 308)
        #expect(toolbar.frame.width <= 308 && toolbar.frame.height > singleRow.height)
        for (index, button) in buttons.enumerated() {
            #expect(toolbar.bounds.contains(button.frame))
            #expect(buttons.dropFirst(index + 1).allSatisfy { !$0.frame.intersects(button.frame) })
            #expect(toolbar.hitTest(button.convert(NSPoint(x: 16, y: 16), to: toolbar.superview)) === button)
        }
        toolbar.fit(within: 640)
        #expect(toolbar.frame.size == singleRow)

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
        let controller = ScreenCaptureController(pasteboard: pb, freeze: {
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
        func clickWindow(_ panel: NSWindow) throws {
            let point = CGPoint(x: target.midX, y: target.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                            timestamp: 1, windowNumber: panel.windowNumber,
                                                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                panel.sendEvent(event)
            }
        }
        func press(_ key: CGKeyCode, _ char: String, in panel: NSWindow) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
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
        try press(KeyCode.returnKey, "\r", in: panel)
        let data = try #require(pb.data(forType: .png))
        let rep = try #require(NSBitmapImageRep(data: data))
        #expect(!panel.isVisible && rep.pixelsWide == 490 && rep.pixelsHigh == 90)
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
    }

}
