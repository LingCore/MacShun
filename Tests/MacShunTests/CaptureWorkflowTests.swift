// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@Suite("截图交互与工作流", .serialized)
struct CaptureWorkflowTests {
    @MainActor @Test func autoSelectionWheelSteppingTabToggleEdgeResizeStepBackAndDoubleClickCopy() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 640, height: 420)
        let frame = CGRect(origin: CGPoint(x: -16000, y: -16000), size: size)
        let photo = try captureTestPhoto(width: 1280, height: 840, points: size)
        let windowRect = CGRect(x: 80, y: 60, width: 420, height: 300)
        let sidebar = CGRect(x: 80, y: 60, width: 150, height: 300)
        let button = CGRect(x: 100, y: 240, width: 100, height: 32)
        let target = CaptureWindowTarget(
            windowID: 42, ownerPID: 999, bundleID: "com.apple.finder", ownerName: "Finder",
            layer: 0, axFrame: windowRect, localRect: windowRect, isChromium: false, isDock: false, supportsAXProbe: false
        )
        let defaultsName = "MacShunTests.autoSelect.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        let controller = ScreenCaptureController(
            clipboard: CaptureClipboard(pasteboard: pb),
            freeze: { [FrozenScreen(frame: frame, photo: photo, windowRects: [windowRect], windowTargets: [target])] },
            mouseLocation: { CGPoint(x: frame.minX + 600, y: frame.minY + 400) },
            colorDefaults: defaults,
            detectVisualRegions: { _, _ in [] }
        )
        defer { controller.cancel() }

        func begin() async throws -> (NSWindow, CaptureCanvas) {
            controller.start(.image)
            for _ in 0..<100 {
                if let panel = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame }),
                   let canvas = panel.contentView as? CaptureCanvas {
                    return (panel, canvas)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CocoaError(.coderValueNotFound)
        }
        func mouse(_ type: NSEvent.EventType, at p: CGPoint, in panel: NSWindow, clicks: Int = 1) throws {
            let e = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
            panel.sendEvent(e)
        }
        func press(_ key: CGKeyCode, in panel: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: key))
            panel.sendEvent(e)
        }

        var (panel, canvas) = try await begin()
        #expect(canvas.hovered == photo.bounds)
        let dims = try #require(canvas.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("1280 × 840 px") })
        #expect(!dims.isHidden)
        let loupe = try #require(canvas.subviews.compactMap { $0 as? CaptureLoupe }.first)
        #expect(!loupe.displayedCoords.isEmpty)

        canvas.addDiscoveredControls([sidebar, button], for: 42)
        canvas.hover(at: CGPoint(x: 150, y: 256))
        #expect(canvas.hovered == button)
        canvas.stepHoverLevel(1)
        #expect(canvas.hovered == sidebar)
        canvas.stepHoverLevel(1)
        #expect(canvas.hovered == windowRect)
        canvas.stepHoverLevel(1)
        #expect(canvas.hovered == photo.bounds)
        canvas.stepHoverLevel(-2)
        #expect(canvas.hovered == sidebar)

        try press(KeyCode.tab, in: panel)
        #expect(canvas.windowsOnly && canvas.hovered == windowRect)
        #expect(defaults.bool(forKey: "captureWindowsOnly"))
        try press(KeyCode.tab, in: panel)
        #expect(!canvas.windowsOnly && canvas.hovered == button)

        try mouse(.leftMouseDown, at: CGPoint(x: 150, y: 256), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: 150, y: 256), in: panel)
        #expect(canvas.selection == button)
        try mouse(.leftMouseDown, at: CGPoint(x: 115, y: button.maxY), in: panel)
        try mouse(.leftMouseDragged, at: CGPoint(x: 115, y: button.minY - 40), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: 115, y: button.minY - 40), in: panel)
        let flippedSelection = CGRect(x: button.minX, y: button.minY - 40, width: button.width, height: 40)
        #expect(canvas.selection == flippedSelection)

        try mouse(.leftMouseDown, at: CGPoint(x: 560, y: 360), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: 560, y: 360), in: panel)
        #expect(canvas.selection == flippedSelection)

        canvas.toolbar.perform?(.tool(.rectangle))
        try mouse(.leftMouseDown, at: CGPoint(x: flippedSelection.minX + 10, y: flippedSelection.minY + 10), in: panel)
        try mouse(.leftMouseDragged, at: CGPoint(x: flippedSelection.minX + 60, y: flippedSelection.minY + 30), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: flippedSelection.minX + 60, y: flippedSelection.minY + 30), in: panel)
        #expect(canvas.marks.count == 1)
        try press(KeyCode.escape, in: panel)
        try mouse(.leftMouseDown, at: CGPoint(x: 560, y: 360), in: panel)
        try mouse(.leftMouseDragged, at: CGPoint(x: 610, y: 390), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: 610, y: 390), in: panel)
        #expect(canvas.selection == flippedSelection && canvas.marks.count == 1)
        try press(KeyCode.escape, in: panel)
        #expect(panel.isVisible && canvas.selection == nil && canvas.marks.isEmpty)
        try press(KeyCode.z, in: panel, flags: .command)
        #expect(canvas.selection == flippedSelection && canvas.marks.count == 1)

        try mouse(.leftMouseDown, at: CGPoint(x: flippedSelection.maxX - 8, y: flippedSelection.midY), in: panel, clicks: 2)
        #expect(!panel.isVisible && pb.data(forType: .png) != nil)

        (panel, canvas) = try await begin()
        let secondRect = CGRect(x: 300, y: 120, width: 160, height: 100)
        try mouse(.leftMouseDown, at: secondRect.origin, in: panel)
        try mouse(.leftMouseDragged, at: CGPoint(x: secondRect.maxX, y: secondRect.maxY), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: secondRect.maxX, y: secondRect.maxY), in: panel)
        try press(KeyCode.returnKey, in: panel)
        #expect(!panel.isVisible)

        (panel, canvas) = try await begin()
        try press(KeyCode.r, in: panel)
        #expect(canvas.selection == secondRect)
        try press(KeyCode.r, in: panel)
        #expect(canvas.selection == flippedSelection)
        try press(KeyCode.r, in: panel, flags: .shift)
        #expect(canvas.selection == secondRect)
    }

    @MainActor @Test func visualRegionsDetectPanesCardsButtonsAndPillsInAppKitCoordinates() async throws {
        _ = NSApplication.shared
        let screenSize = CGSize(width: 600, height: 400)
        let scale = 2
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try #require(CGContext(
            data: nil,
            width: Int(screenSize.width) * scale,
            height: Int(screenSize.height) * scale,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: screenSize))

        let windowRect = CGRect(x: 40, y: 30, width: 520, height: 340)
        let topBar = CGRect(x: 40, y: 330, width: 520, height: 40)
        let sidebar = CGRect(x: 40, y: 30, width: 150, height: 300)
        let mainPane = CGRect(x: 190, y: 30, width: 370, height: 300)
        let card = CGRect(x: 220, y: 170, width: 300, height: 130)
        let button = CGRect(x: 240, y: 190, width: 110, height: 34)
        let pill = CGRect(x: 220, y: 60, width: 260, height: 28)

        ctx.setFillColor(CGColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1))
        ctx.fill(windowRect)
        ctx.setFillColor(CGColor(srgbRed: 0.149, green: 0.149, blue: 0.153, alpha: 1))
        ctx.fill(topBar)
        ctx.fill(sidebar)
        ctx.setStrokeColor(CGColor(srgbRed: 0.24, green: 0.24, blue: 0.26, alpha: 1))
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 40, y: 330))
        ctx.addLine(to: CGPoint(x: 560, y: 330))
        ctx.move(to: CGPoint(x: 190, y: 30))
        ctx.addLine(to: CGPoint(x: 190, y: 330))
        ctx.strokePath()

        let cardPath = CGPath(roundedRect: card, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(cardPath)
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1))
        ctx.fillPath()
        ctx.addPath(cardPath)
        ctx.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.30, blue: 0.34, alpha: 1))
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1))
        ctx.addPath(CGPath(roundedRect: button, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()

        let pillPath = CGPath(roundedRect: pill, cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(pillPath)
        ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1))
        ctx.fillPath()
        ctx.addPath(pillPath)
        ctx.setStrokeColor(CGColor(srgbRed: 0.36, green: 0.36, blue: 0.40, alpha: 1))
        ctx.setLineWidth(1)
        ctx.strokePath()

        let photo = CaptureImage(image: try #require(ctx.makeImage()), size: screenSize)
        let regions = CaptureVisualRegions.detect(in: photo, windowLocalRect: windowRect)

        func hasMatch(for expected: CGRect, tol: CGFloat = 4) -> Bool {
            regions.contains { r in
                abs(r.minX - expected.minX) <= tol
                    && abs(r.minY - expected.minY) <= tol
                    && abs(r.maxX - expected.maxX) <= tol
                    && abs(r.maxY - expected.maxY) <= tol
            }
        }

        #expect(hasMatch(for: topBar))
        #expect(hasMatch(for: sidebar))
        #expect(hasMatch(for: mainPane))
        #expect(hasMatch(for: card))
        #expect(hasMatch(for: button))
        #expect(hasMatch(for: pill))

        let frame = CGRect(origin: CGPoint(x: -16000, y: -16000), size: screenSize)
        let chromiumTarget = CaptureWindowTarget(
            windowID: 88, ownerPID: 999, bundleID: "com.google.Chrome", ownerName: "Google Chrome",
            layer: 0, axFrame: windowRect, localRect: windowRect, isChromium: true, isDock: false, supportsAXProbe: false
        )
        let defaultsName = "MacShunTests.visual.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        let buttonCenter = CGPoint(x: button.midX, y: button.midY)
        let controller = ScreenCaptureController(
            clipboard: CaptureClipboard(pasteboard: pb),
            freeze: { [FrozenScreen(frame: frame, photo: photo, windowRects: [windowRect], windowTargets: [chromiumTarget])] },
            mouseLocation: { CGPoint(x: frame.minX + buttonCenter.x, y: frame.minY + buttonCenter.y) },
            colorDefaults: defaults
        )
        defer { controller.cancel() }

        controller.start(.image)
        var foundCanvas: CaptureCanvas?
        for _ in 0..<100 {
            if let panel = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame }),
               let canvas = panel.contentView as? CaptureCanvas {
                foundCanvas = canvas
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let canvas = try #require(foundCanvas)
        for _ in 0..<100 {
            if let hovered = canvas.hovered, abs(hovered.width - button.width) <= 4, abs(hovered.height - button.height) <= 4 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let hoveredButton = try #require(canvas.hovered)
        #expect(abs(hoveredButton.minX - button.minX) <= 4 && abs(hoveredButton.minY - button.minY) <= 4)
        #expect(canvas.hoverChain.count >= 5)
        #expect(canvas.hoverChain.last == photo.bounds)
    }

    @MainActor @Test func mosaicPenHighlighterSpotlightShortcutsOCRAndQuickSaveWorkEndToEnd() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 500, height: 320)
        let ctx = try #require(CGContext(data: nil, width: 500, height: 320, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 40, y: 180, width: 60, height: 60))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.85, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 100, y: 180, width: 60, height: 60))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("HELLO MACSHUN" as NSString).draw(at: CGPoint(x: 50, y: 60),
                                           withAttributes: [.font: NSFont.boldSystemFont(ofSize: 38), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let photo = CaptureImage(image: try #require(ctx.makeImage()), size: size)

        let mosaicPixel = CaptureMark(kind: .mosaic, start: CGPoint(x: 40, y: 180), end: CGPoint(x: 160, y: 240),
                                      mosaicStyle: AnnotationMosaicStyle(mode: .pixelate, level: .coarse))
        let mosaicBlur = CaptureMark(kind: .mosaic, start: CGPoint(x: 40, y: 180), end: CGPoint(x: 160, y: 240),
                                     mosaicStyle: AnnotationMosaicStyle(mode: .blur, level: .medium))
        let pen = CaptureMark(kind: .pen, start: CGPoint(x: 200, y: 200), end: CGPoint(x: 260, y: 240),
                              freehandPoints: [CGPoint(x: 200, y: 200), CGPoint(x: 230, y: 230), CGPoint(x: 260, y: 240)],
                              stroke: AnnotationStroke(color: .red, width: .thick))
        let marker = CaptureMark(kind: .highlighter, start: CGPoint(x: 50, y: 80), end: CGPoint(x: 240, y: 80),
                                 freehandPoints: [CGPoint(x: 50, y: 80), CGPoint(x: 240, y: 80)],
                                 stroke: AnnotationStroke(color: .orange, width: .medium))
        let spot = CaptureMark(kind: .spotlight, start: CGPoint(x: 40, y: 50), end: CGPoint(x: 340, y: 130),
                               spotlightStyle: AnnotationSpotlightStyle(shade: .dark))
        for marks in [[mosaicPixel], [mosaicBlur], [pen, marker, spot]] {
            let rendered = try #require(photo.render(photo.bounds, marks: marks))
            #expect(rendered.width == 500 && rendered.height == 320)
        }
        let spotImage = try #require(photo.render(photo.bounds, marks: [spot]))
        let spotRep = NSBitmapImageRep(cgImage: spotImage)
        let dimmedPixel = try #require(spotRep.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        let brightPixel = try #require(spotRep.colorAt(x: 330, y: 200)?.usingColorSpace(.sRGB))
        #expect(dimmedPixel.redComponent < 0.5 && brightPixel.redComponent > 0.95)

        let saveDir = FileManager.default.temporaryDirectory.appendingPathComponent("macshun-quicksave-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: saveDir) }

        let frame = CGRect(origin: CGPoint(x: -16000, y: -16000), size: size)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let defaultsName = "MacShunTests.v2.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let controller = ScreenCaptureController(
            clipboard: CaptureClipboard(pasteboard: pb),
            freeze: { [FrozenScreen(frame: frame, photo: photo, windowRects: [CGRect(x: 20, y: 20, width: 460, height: 280)])] },
            mouseLocation: { CGPoint(x: frame.minX + 250, y: frame.minY + 160) },
            colorDefaults: defaults,
            detectVisualRegions: { _, _ in [] },
            defaultSaveDirectory: { saveDir }
        )
        defer { controller.cancel() }

        func begin() async throws -> (NSWindow, CaptureCanvas) {
            controller.start(.image)
            for _ in 0..<100 {
                if let panel = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame }),
                   let canvas = panel.contentView as? CaptureCanvas {
                    return (panel, canvas)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CocoaError(.coderValueNotFound)
        }
        func press(_ key: CGKeyCode, in panel: NSWindow, flags: NSEvent.ModifierFlags = []) throws {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: key))
            panel.sendEvent(e)
        }

        var (panel, canvas) = try await begin()
        canvas.restoreRegion(CGRect(x: 20, y: 20, width: 420, height: 260))
        try press(KeyCode.nine, in: panel)
        try press(KeyCode.rightBracket, in: panel)
        try press(KeyCode.h, in: panel)
        #expect(canvas.toolbar.isHidden)
        try press(KeyCode.h, in: panel)
        #expect(!canvas.toolbar.isHidden)
        try press(KeyCode.f, in: panel)
        #expect(canvas.isEditingSize)
        canvas.applyPixelSize(width: 300, height: 200)
        #expect(canvas.selection?.width == 300 && canvas.selection?.height == 200)
        canvas.closeSizePopover(focusCanvas: true)
        #expect(!canvas.isEditingSize)

        try press(KeyCode.s, in: panel, flags: .command)
        for _ in 0..<150 {
            let files = (try? FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)) ?? []
            if !files.isEmpty && !panel.isVisible { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let savedFiles = try FileManager.default.contentsOfDirectory(at: saveDir, includingPropertiesForKeys: nil)
        #expect(savedFiles.count == 1 && savedFiles[0].pathExtension == "png")

        (panel, canvas) = try await begin()
        canvas.restoreRegion(CGRect(x: 20, y: 30, width: 440, height: 120))
        try press(KeyCode.c, in: panel, flags: .shift)
        #expect(!panel.isVisible)
        for _ in 0..<400 where pb.string(forType: .string) == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(pb.string(forType: .string)?.uppercased().contains("HELLO") == true)
    }

    @MainActor @Test func captureHistoryStepsBackAndForthWithCommaAndPeriodAndRestoresAnnotations() async throws {
        _ = NSApplication.shared
        let size = CGSize(width: 480, height: 300)
        let frame = CGRect(origin: CGPoint(x: -16000, y: -16000), size: size)
        let photo1 = try captureTestPhoto(width: 480, height: 300, points: size)
        let photo2 = try captureTestPhoto(width: 480, height: 300, points: size)
        let photo3 = try captureTestPhoto(width: 480, height: 300, points: size)
        let photos = [photo1, photo2, photo3]
        var shotIdx = 0

        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let defaultsName = "MacShunTests.history.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let controller = ScreenCaptureController(
            clipboard: CaptureClipboard(pasteboard: pb),
            freeze: {
                let photo = photos[min(shotIdx, photos.count - 1)]
                shotIdx += 1
                return [FrozenScreen(frame: frame, photo: photo, windowRects: [])]
            },
            mouseLocation: { CGPoint(x: frame.midX, y: frame.midY) },
            colorDefaults: defaults,
            detectVisualRegions: { _, _ in [] }
        )
        defer { controller.cancel() }

        func begin() async throws -> (NSWindow, CaptureCanvas) {
            controller.start(.image)
            for _ in 0..<100 {
                if let panel = NSApp.windows.first(where: { $0.isVisible && $0.frame == frame }),
                   let canvas = panel.contentView as? CaptureCanvas {
                    return (panel, canvas)
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw CocoaError(.coderValueNotFound)
        }
        func press(_ key: CGKeyCode, in panel: NSWindow) throws {
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: key))
            panel.sendEvent(e)
        }
        func mouse(_ type: NSEvent.EventType, at p: CGPoint, in panel: NSWindow) throws {
            let e = try #require(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 1,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            panel.sendEvent(e)
        }

        // 第 1 次截图：带矩形标注并复制入历史。
        let rect1 = CGRect(x: 40, y: 40, width: 180, height: 120)
        var (panel, canvas) = try await begin()
        canvas.restoreRegion(rect1)
        try press(KeyCode.one, in: panel)
        try mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60), in: panel)
        try mouse(.leftMouseDragged, at: CGPoint(x: 140, y: 110), in: panel)
        try mouse(.leftMouseUp, at: CGPoint(x: 140, y: 110), in: panel)
        #expect(canvas.marks.count == 1)
        try press(KeyCode.returnKey, in: panel)
        #expect(!panel.isVisible)

        // 第 2 次截图：不同选区并复制入历史。
        let rect2 = CGRect(x: 220, y: 80, width: 200, height: 150)
        (panel, canvas) = try await begin()
        canvas.restoreRegion(rect2)
        try press(KeyCode.returnKey, in: panel)
        #expect(!panel.isVisible)

        // 第 3 次进入截图：按 `,` 翻回第 2 次、再按 `,` 翻回第 1 次（含标注）、按 `.` 回到第 2 次、再按 `.` 回到实时画面。
        (panel, canvas) = try await begin()
        #expect(canvas.selection == nil)
        try press(KeyCode.comma, in: panel)
        #expect(canvas.selection == rect2 && canvas.marks.isEmpty)
        try press(KeyCode.comma, in: panel)
        #expect(canvas.selection == rect1 && canvas.marks.count == 1)
        try press(KeyCode.period, in: panel)
        #expect(canvas.selection == rect2 && canvas.marks.isEmpty)
        try press(KeyCode.period, in: panel)
        #expect(canvas.selection == nil && canvas.marks.isEmpty)
    }

    @MainActor @Test func screenPinClickThroughTransformAndOCRWork() async throws {
        _ = NSApplication.shared
        let ctx = try #require(CGContext(data: nil, width: 320, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 120))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("PIN TEXT 123" as NSString).draw(at: CGPoint(x: 24, y: 36),
                                          withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let cg = try #require(ctx.makeImage())
        let png = try #require(CaptureImage.pngData(cg))
        let picture = try #require(PinPicture(cgImage: cg, png: png))
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }

        let panel = try #require(ScreenPins.shared.show(picture, at: CGRect(x: -16000, y: -16000, width: 320, height: 120), pasteboard: pb))
        defer { panel.close() }

        // 鼠标穿透与菜单栏一键恢复。
        panel.setClickThrough(true)
        #expect(panel.clickThrough && panel.ignoresMouseEvents && ScreenPins.shared.hasClickThroughWindows)
        ScreenPins.shared.disableAllClickThrough()
        #expect(!panel.clickThrough && !panel.ignoresMouseEvents && !ScreenPins.shared.hasClickThroughWindows)

        // 贴图内 OCR 识别文字到剪贴板。
        panel.recognizeText()
        for _ in 0..<400 where pb.string(forType: .string) == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(pb.string(forType: .string)?.uppercased().contains("PIN TEXT") == true)

        // 原地旋转 90° 交换自然宽高。
        panel.transformPicture(.rotate90CW)
        #expect(panel.naturalSize == CGSize(width: 120, height: 320))
    }
}
