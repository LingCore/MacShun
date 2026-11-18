// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@Suite("截图取色会话")
struct CaptureColorShortcutTests {
    @MainActor @Test func colorShortcutUsesDisplayUnderPointerAndKeepsAnnotations() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 640, height: 420)
        let primary = CGRect(origin: CGPoint(x: -16000, y: -16000), size: size)
        let retina = primary.offsetBy(dx: size.width, dy: 0)
        let standardPhoto = try captureTestPhoto(width: 640, height: 420, points: size)
        let retinaPhoto = try captureTestPhoto(width: 1280, height: 840, points: size)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let defaultsName = "MacShunTests.captureColor.\(UUID())"
        let colorDefaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { colorDefaults.removePersistentDomain(forName: defaultsName) }
        #expect(CaptureCursorImage.magnification(in: colorDefaults) == 1)
        colorDefaults.set(2.25, forKey: "mouseDriverCursorSize")
        #expect(CaptureCursorImage.magnification(in: colorDefaults) == 2.25)
        let multiResolutionCursor = NSImage(size: CGSize(width: 24, height: 24))
        for side in [24, 48, 108, 144] {
            let bitmap = try #require(retinaPhoto.image.cropping(to: CGRect(x: 0, y: 0, width: side, height: side)))
            multiResolutionCursor.addRepresentation(NSBitmapImageRep(cgImage: bitmap))
        }
        let testCursor = NSCursor(image: multiResolutionCursor, hotSpot: CGPoint(x: 11, y: 11))
        let enlarged = try #require(CaptureCursorImage(cursor: testCursor, magnification: 2.25, backingScale: 2))
        #expect(enlarged.bitmap.width == 108 && enlarged.bitmap.height == 108 && enlarged.size.width == 54)
        let standard = try #require(CaptureCursorImage(cursor: testCursor, magnification: 1, backingScale: 2))
        #expect(standard.bitmap.width == 48 && standard.size.width == 24)
        var mouse = CGPoint(x: primary.midX, y: primary.minY + 100)
        let controller = ScreenCaptureController(clipboard: CaptureClipboard(pasteboard: pb), freeze: {
            [FrozenScreen(frame: primary, photo: standardPhoto, windowRects: []),
             FrozenScreen(frame: retina, photo: retinaPhoto, windowRects: [])]
        }, mouseLocation: { mouse }, warpPointer: { point in
            // WindowServer 可把键盘移动后的光标吸附到整点。
            mouse = CGPoint(x: floor(point.x), y: ceil(point.y))
            return .success
        }, colorDefaults: colorDefaults)
        defer { controller.cancel() }
        func begin() async throws -> NSWindow {
            controller.start(.image)
            for _ in 0..<100 {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame == primary && $0.contentView is CaptureCanvas }) {
                    return window
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CocoaError(.coderValueNotFound)
        }
        func sendKey(_ type: NSEvent.EventType, _ key: CGKeyCode, in window: NSWindow,
                     flags: NSEvent.ModifierFlags = [], repeating: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                                       timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                                       characters: "", charactersIgnoringModifiers: "", isARepeat: repeating,
                                                       keyCode: key))
            window.sendEvent(event)
        }
        func press(_ key: CGKeyCode, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
            try sendKey(.keyDown, key, in: window, flags: flags)
            try sendKey(.keyUp, key, in: window, flags: flags)
        }
        func tapShift(in window: NSWindow, key: CGKeyCode = KeyCode.shift) throws {
            try sendKey(.flagsChanged, key, in: window, flags: .shift)
            try sendKey(.flagsChanged, key, in: window)
        }
        func sendMouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                       clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        var window = try await begin()
        let retinaWindow = try #require(NSApp.windows.first { $0.isVisible && $0.frame == retina })
        let retinaCanvas = try #require(retinaWindow.contentView as? CaptureCanvas)
        let loupe = try #require(retinaCanvas.subviews.compactMap { $0 as? CaptureLoupe }.first)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            retinaWindow.appearance = NSAppearance(named: appearance)
            for index in 0..<24 {
                let blue = index.isMultiple(of: 2)
                retinaCanvas.hover(at: CGPoint(x: 250 + index, y: blue ? 230 : 190))
                loupe.layoutSubtreeIfNeeded()
                retinaWindow.displayIfNeeded()
                CATransaction.flush()
                let hex = blue ? "#0000FF" : "#FF0000"
                let label = try #require(loupe.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == hex })
                #expect(!loupe.isHidden && label.frame.width >= label.intrinsicContentSize.width)
            }
        }
        mouse = CGPoint(x: retina.midX, y: retina.midY)
        let keyboardCanvas = try #require(window.contentView as? CaptureCanvas)
        try sendKey(.keyDown, KeyCode.d, in: window)
        #expect(loupe.sample?.pixel == CGPoint(x: 641, y: 420))
        let cursorLayer = try #require(retinaCanvas.layer?.sublayers?.first { $0.zPosition == 1 })
        let nativeCursor = NSCursor.crosshair
        let scale = CaptureCursorImage.magnification(in: UserDefaults(suiteName: "com.apple.universalaccess"))
        let backingScale = retinaWindow.backingScaleFactor
        #expect(cursorLayer.bounds.width == (nativeCursor.image.size.width * scale * backingScale).rounded() / backingScale)
        #expect(cursorLayer.bounds.height == (nativeCursor.image.size.height * scale * backingScale).rounded() / backingScale)
        #expect(abs(cursorLayer.anchorPoint.x * nativeCursor.image.size.width - nativeCursor.hotSpot.x) < 1e-7)
        #expect(abs((1 - cursorLayer.anchorPoint.y) * nativeCursor.image.size.height - nativeCursor.hotSpot.y) < 1e-7)
        let backingOrigin = retinaCanvas.convertToBacking(cursorLayer.frame.origin)
        #expect(abs(backingOrigin.x - backingOrigin.x.rounded()) < 1e-7 && abs(backingOrigin.y - backingOrigin.y.rounded()) < 1e-7)
        let bitmap = try #require(cursorLayer.contents) as! CGImage
        #expect(bitmap.width >= 48 && cursorLayer.magnificationFilter == .nearest)
        try sendKey(.keyDown, KeyCode.d, in: window, repeating: true)
        #expect(loupe.sample?.pixel == CGPoint(x: 641, y: 420))
        let nextFrame = CACurrentMediaTime() + 1
        keyboardCanvas.advanceDirectionRepeat(at: nextFrame)
        #expect(loupe.sample?.pixel == CGPoint(x: 642, y: 420))
        #expect(abs(retinaCanvas.convertToBacking(cursorLayer.frame.origin).x - backingOrigin.x - 0.5 * backingScale) <= 0.5)
        try sendKey(.keyUp, KeyCode.d, in: window)
        keyboardCanvas.advanceDirectionRepeat(at: nextFrame + 1 / 60)
        #expect(loupe.sample?.pixel == CGPoint(x: 642, y: 420))
        let first = CaptureLoupe.frame(near: CGPoint(x: 320.25, y: 209.75), in: retinaPhoto.bounds, avoiding: [], scale: 2)
        let second = CaptureLoupe.frame(near: CGPoint(x: 320.75, y: 209.75), in: retinaPhoto.bounds, avoiding: [], scale: 2)
        #expect(first.map { $0.offsetBy(dx: 0.5, dy: 0) } == second)
        let compactBounds = CGRect(x: 0, y: 0, width: 420, height: 320)
        let obstacles = [CGRect(x: 23, y: 194, width: 347, height: 120), CGRect(x: 38, y: 63, width: 114, height: 30)]
        let compactFrame = try #require(CaptureLoupe.frame(near: CGPoint(x: 285, y: 158), in: compactBounds,
                                                          avoiding: obstacles, scale: 2))
        #expect(compactBounds.contains(compactFrame) && !obstacles.contains { $0.intersects(compactFrame) })
        try press(KeyCode.s, in: window, flags: .shift)
        try press(KeyCode.w, in: window, flags: .shift)
        try press(KeyCode.a, in: window)
        #expect(loupe.sample?.pixel == CGPoint(x: 641, y: 420))

        #expect(loupe.displayedColor == "#FF0000")
        try tapShift(in: window)
        #expect(loupe.displayedColor == "rgb(255, 0, 0)")
        try tapShift(in: window, key: KeyCode.rightShift)
        #expect(loupe.displayedColor == "hsl(0, 100%, 50%)")
        try tapShift(in: window)
        #expect(loupe.displayedColor == "#FF0000")

        try sendKey(.flagsChanged, KeyCode.shift, in: window, flags: .shift)
        try press(KeyCode.upArrow, in: window, flags: .shift)
        try press(KeyCode.downArrow, in: window, flags: .shift)
        try sendKey(.flagsChanged, KeyCode.shift, in: window)
        #expect(loupe.displayedColor == "#FF0000")
        try sendKey(.flagsChanged, KeyCode.shift, in: window, flags: .shift)
        try sendKey(.flagsChanged, KeyCode.control, in: window, flags: [.shift, .control])
        try sendKey(.flagsChanged, KeyCode.control, in: window, flags: .shift)
        try sendKey(.flagsChanged, KeyCode.shift, in: window)
        #expect(loupe.displayedColor == "#FF0000")
        try tapShift(in: window)
        let shown = loupe.displayedColor
        #expect(shown == "rgb(255, 0, 0)")
        try press(KeyCode.c, in: window)
        #expect(pb.string(forType: .string) == shown && !window.isVisible)
        #expect(loupe.sample?.pixel == CGPoint(x: 641, y: 420))
        #expect(cursorLayer.superlayer == nil && colorDefaults.string(forKey: "captureColorFormat") == "rgb")

        mouse = CGPoint(x: primary.midX, y: primary.minY + 190)
        window = try await begin()
        let canvas = try #require(window.contentView as? CaptureCanvas)
        let nextLoupe = try #require(canvas.subviews.compactMap { $0 as? CaptureLoupe }.first)
        #expect(nextLoupe.displayedColor == "rgb(255, 0, 0)")
        let start = CGPoint(x: 270, y: 190)
        mouse = window.convertPoint(toScreen: start)
        try sendMouse(.leftMouseDown, at: start, in: window)
        try press(KeyCode.d, in: window)
        try press(KeyCode.upArrow, in: window)
        try sendMouse(.leftMouseUp, at: window.convertPoint(fromScreen: mouse), in: window)
        let smallSelection = try #require(canvas.selection)
        #expect(smallSelection.width > 0 && smallSelection.width < 3)
        #expect(smallSelection.height > 0 && smallSelection.height < 3)

        canvas.restoreRegion(CGRect(x: 36, y: 58, width: 500, height: 300))
        try press(KeyCode.rightArrow, in: window)
        try press(KeyCode.upArrow, in: window, flags: .shift)
        #expect(canvas.selection == CGRect(x: 37, y: 58, width: 500, height: 301))
        let cover = try #require(canvas.toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == CaptureMark.Kind.cover.title })
        cover.performClick(nil)
        let a = CGPoint(x: 270, y: 165), b = CGPoint(x: 370, y: 200)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, a), (.leftMouseDragged, b), (.leftMouseUp, b)] {
            try sendMouse(type, at: point, in: window)
        }
        let select = try #require(canvas.toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == L("选择标注或调整选区") })
        select.performClick(nil)
        #expect(canvas.marks.count == 1)
        mouse = CGPoint(x: retina.midX, y: retina.maxY)
        let previousCount = pb.changeCount
        try press(KeyCode.c, in: window)
        #expect(pb.changeCount == previousCount && window.isVisible)
        mouse = CGPoint(x: primary.midX, y: primary.minY + 190)
        try tapShift(in: window)
        #expect(nextLoupe.displayedColor == "hsl(0, 100%, 50%)")
        try press(KeyCode.c, in: window)
        #expect(pb.string(forType: .string) == nextLoupe.displayedColor && window.isVisible && canvas.marks.count == 1)
        try press(KeyCode.c, in: window, flags: .command)
        #expect(pb.data(forType: .png) != nil && !window.isVisible)
    }
}
