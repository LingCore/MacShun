// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
@testable import MacShun

@MainActor
@Suite("截图标注和导出")
struct CaptureAnnotationTests {
    private func page() throws -> CGImage {
        _ = NSApplication.shared
        let w = 840, h = 1400
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 固定的演示素材。右侧纹理用于从连续帧恢复实际滚动量。
        for y in 0..<h {
            let g = CGFloat((y * 47 ^ (y / 5) * 83) % 249) / 255
            ctx.setFillColor(CGColor(gray: g, alpha: 1))
            ctx.fill(CGRect(x: 740, y: y, width: 100, height: 1))
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("SECRET ORCHID" as NSString).draw(at: CGPoint(x: 60, y: 750),
            withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return try #require(ctx.makeImage())
    }

    private func gesture(_ canvas: CaptureCanvas, from start: CGPoint, to end: CGPoint? = nil, clicks: Int = 1,
                         modifiers: NSEvent.ModifierFlags = []) throws {
        let win = try #require(canvas.window)
        let steps: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start), (.leftMouseDragged, end ?? start), (.leftMouseUp, end ?? start)]
        for (type, point) in steps {
            let event = try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: modifiers, timestamp: 1, windowNumber: win.windowNumber, context: nil,
                eventNumber: 1, clickCount: clicks, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
    }

    private func chooseStyle(_ title: String, in toolbar: CaptureToolbar, selected: Bool = true) throws {
        let item = try #require(toolbar.makeStyleMenu().items.first { $0.title == title && $0.action != nil })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(toolbar.makeStyleMenu().items.first { $0.title == title && $0.action != nil }?.state == (selected ? .on : .off))
    }

    private func press(_ key: CGKeyCode, on canvas: CaptureCanvas, modifiers: NSEvent.ModifierFlags = []) throws {
        let window = try #require(canvas.window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                                 windowNumber: window.windowNumber, context: nil, characters: "",
                                                 charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
        #expect(canvas.handleKey(event))
    }

    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<250 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(ready())
    }

    @Test func redactionMatchesCommonContactsWithoutTakingPartOfAnIdentifier() {
        let line = "邮箱：a.b+tag@example.test，电话：+86 199-0000-0000；19900000000@example.test A19900000000 919900000000"
        #expect(CaptureRedaction.contactRanges(in: line).map { String(line[$0]) } ==
                ["a.b+tag@example.test", "+86 199-0000-0000", "19900000000@example.test"])
        let spaced = "demo @example. test and other@example.test. Next"
        #expect(CaptureRedaction.contactRanges(in: spaced).map { String(spaced[$0]) } ==
                ["demo @example. test", "other@example.test"])
    }

    @Test func redactionAssistCoversOnlyConfirmedTextAtRetinaScale() async throws {
        _ = NSApplication.shared
        let ctx = try #require(CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        let email = "demo@example.test"
        let phone = "+86 199 0000 0000"
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 36, weight: .regular),
                                                          .foregroundColor: NSColor.black]
        (email as NSString).draw(at: CGPoint(x: 240, y: 480), withAttributes: attributes)
        (phone as NSString).draw(at: CGPoint(x: 240, y: 310), withAttributes: attributes)
        ("outside@example.test" as NSString).draw(at: CGPoint(x: 240, y: 700), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let photo = CaptureImage(image: try #require(ctx.makeImage()), size: CGSize(width: 640, height: 400))
        let selection = CGRect(x: 91.25, y: 111.75, width: 486.5, height: 207)
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        let panel = NSPanel(contentRect: photo.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = canvas
        canvas.restoreRegion(selection)
        let assist = try #require(canvas.toolbar.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == L("辅助打码") })
        let status = try #require(canvas.toolbar.subviews.compactMap { $0 as? NSTextField }.first)
        assist.performClick(nil)
        #expect(status.stringValue == L("正在查找手机号和邮箱…"))
        // 重选之后，后台回来的旧结果不能覆盖新选区的状态。
        canvas.restoreRegion(selection.offsetBy(dx: 0, dy: -10))
        #expect(status.isHidden)
        canvas.restoreRegion(selection)
        assist.performClick(nil)
        try await wait { status.stringValue != L("正在查找手机号和邮箱…") }
        #expect(status.stringValue == L("点橙框遮挡 · %ld 处待确认", 2))
        #expect(canvas.marks.isEmpty)

        let emailPoint = CGPoint(x: 200, y: 250)
        try gesture(canvas, from: emailPoint)
        let cover = try #require(canvas.marks.first)
        #expect(canvas.marks.count == 1 && cover.kind == .cover && cover.fillColor == .black && cover.bounds.contains(emailPoint))
        #expect(status.stringValue == L("点橙框遮挡 · %ld 处待确认", 1))
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks.isEmpty && status.stringValue == L("点橙框遮挡 · %ld 处待确认", 2))
        canvas.toolbar.perform?(.redo)
        #expect(canvas.marks == [cover])

        let partial = try #require(photo.render(selection, marks: canvas.marks))
        let visible = ContentExtractor.recognizeText(in: partial)
        #expect(visible.filter(\.isNumber) == "8619900000000")
        #expect(!visible.contains("@"))
        // 点在号码最后一组数字上也能确认整段号码。
        try gesture(canvas, from: CGPoint(x: 288, y: 165))
        #expect(canvas.marks.count == 2 && status.stringValue == L("已处理所有提示"))
        let covered = try #require(photo.render(selection, marks: canvas.marks))
        #expect(ContentExtractor.recognizeText(in: covered).isEmpty)
        assist.performClick(nil)
        #expect(status.isHidden && canvas.marks.count == 2)
    }

    @Test func retinaNudgesAreExactlyOneExportedPixel() throws {
        let cg = try page()
        let photo = CaptureImage(image: cg, size: CGSize(width: 420, height: 700))
        let rect = CGRect(x: 23.25, y: 15, width: 100.5, height: 88)
        let px = photo.pixelRect(rect)
        let right = photo.adjusted(rect, dx: 1, dy: 0, resize: false)
        #expect(photo.pixelRect(right) == px.offsetBy(dx: 1, dy: 0))
        let taller = photo.pixelRect(photo.adjusted(right, dx: 0, dy: 1, resize: true))
        #expect(taller.height == px.height + 1 && taller.maxY == px.maxY)
        #expect(photo.adjusted(photo.bounds, dx: 1, dy: 1, resize: true) == photo.bounds)
        let scaled = CaptureImage(image: cg, size: CGSize(width: 560, height: 933))
        var region = rect
        let original = scaled.pixelRect(region)
        for offset in 1...30 {
            region = scaled.adjusted(region, dx: 1, dy: 1, resize: false)
            #expect(scaled.pixelRect(region) == original.offsetBy(dx: CGFloat(offset), dy: -CGFloat(offset)))
        }
    }

    @Test(arguments: [false, true])
    func polygonAnnotationCanCloseEditAndExport(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let region = CGRect(x: 20, y: 30, width: 380, height: 560)
        let window = NSPanel(contentRect: CGRect(x: -16000, y: -16000, width: 390, height: 430),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(),
                frame: CGRect(origin: .zero, size: window.frame.size), position: 0,
                onDone: { applied = $0 }, onBack: {})
            window.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            window.setContentSize(photo.size)
            window.contentView = canvas
            canvas.restoreRegion(region)
        }
        var copies = 0
        if !document { canvas.onCopy = { copies += 1 } }
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: repeatKey, keyCode: code))
            #expect(canvas.handleKey(event))
        }
        let toolbar = canvas.toolbar
        let button = try #require(toolbar.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == CaptureMark.Kind.polygon.title })
        let styleButton = try #require(toolbar.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == L("标注样式") })
        #expect(button.image != nil)
        let vertices = [CGPoint(x: 60, y: 490), CGPoint(x: 170, y: 490), CGPoint(x: 210, y: 570),
                        CGPoint(x: 130, y: 550), CGPoint(x: 90, y: 565)]
        let first = try #require(vertices.first)
        let selection = try #require(canvas.selection)
        func expectVertices(_ expected: [CGPoint]) throws {
            let actual = try #require(canvas.marks.first?.polygon?.vertices)
            #expect(actual.count == expected.count)
            for (p, q) in zip(actual, expected) { #expect(hypot(p.x - q.x, p.y - q.y) < 0.001) }
        }

        button.performClick(nil)
        #expect(canvas.isPlacingPolygonMark)
        #expect(!toolbar.isHidden && !styleButton.isHidden)
        window.contentView?.layoutSubtreeIfNeeded()
        if let editor = window.contentView as? LongCaptureEditor {
            #expect(editor.scroller.frame.maxY < toolbar.frame.minY)
        }
        try gesture(canvas, from: first)
        if document { canvas.onCopy?() }
        else { toolbar.perform?(.copy) }
        #expect(applied == nil && copies == 0)
        try key(KeyCode.escape)
        #expect(canvas.marks.isEmpty && canvas.selection == selection && !canvas.isPlacingPolygonMark)

        button.performClick(nil)
        for p in vertices { try gesture(canvas, from: p) }
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        try chooseStyle(AnnotationStroke.Width.heavy.title, in: toolbar)
        let blue = AnnotationStroke(color: .blue, width: .heavy)
        try gesture(canvas, from: CGPoint(x: 270, y: 545))
        try key(KeyCode.backspace)
        if !document { try gesture(canvas, from: CGPoint(x: 8, y: 530)) }
        if document { try key(KeyCode.returnKey) }
        else { try gesture(canvas, from: first) }
        #expect(!canvas.isPlacingPolygonMark && canvas.selection == selection && canvas.polygon == nil)
        #expect(canvas.marks.count == 1)
        #expect(canvas.marks.first?.stroke == blue)
        try expectVertices(vertices)

        let edgeClick = CGPoint(x: 115, y: 486)
        let inserted = CGPoint(x: 115, y: 490)
        var withInserted = vertices
        withInserted.insert(inserted, at: 1)
        try gesture(canvas, from: edgeClick)
        try gesture(canvas, from: edgeClick, clicks: 2)
        try expectVertices(withInserted)
        try key(KeyCode.z, modifiers: .command)
        try expectVertices(vertices)
        toolbar.perform?(.redo)
        try expectVertices(withInserted)
        try gesture(canvas, from: inserted)
        try key(KeyCode.forwardDelete)
        try key(KeyCode.forwardDelete, repeatKey: true)
        try expectVertices(vertices)
        try key(KeyCode.z, modifiers: .command)
        try expectVertices(withInserted)
        try key(KeyCode.z, modifiers: [.command, .shift])
        try expectVertices(vertices)
        #expect(canvas.selection == selection && canvas.marks.first?.stroke == blue)

        let movedVertex = first.applying(.init(translationX: 20, y: 15))
        let edited = [movedVertex] + vertices.dropFirst()
        try gesture(canvas, from: first, to: movedVertex)
        try expectVertices(edited)
        let rawShiftTarget = CGPoint(x: 165, y: 508)
        try gesture(canvas, from: vertices[1], to: rawShiftTarget, modifiers: .shift)
        let snapped = try #require(canvas.marks.first?.polygon?.vertices[1])
        #expect(abs(atan2(snapped.y - movedVertex.y, snapped.x - movedVertex.x)) < 1e-7)
        #expect(snapped != rawShiftTarget)
        toolbar.perform?(.undo)
        try expectVertices(edited)
        toolbar.perform?(.undo)
        try expectVertices(vertices)
        toolbar.perform?(.redo)
        try expectVertices(edited)
        let moveStart = CGPoint(x: 120, y: 520)
        try gesture(canvas, from: moveStart, to: CGPoint(x: 150, y: 510))
        try expectVertices(edited.map { $0.applying(.init(translationX: 30, y: -10)) })
        #expect(canvas.marks.first?.stroke == blue)
        try chooseStyle(AnnotationColor.green.title, in: toolbar)
        #expect(canvas.marks.first?.stroke == AnnotationStroke(color: .green, width: .heavy))
        toolbar.perform?(.undo)
        #expect(canvas.marks.first?.stroke == blue)
        toolbar.perform?(.redo)
        #expect(canvas.marks.first?.stroke == AnnotationStroke(color: .green, width: .heavy))

        canvas.onCopy?()
        #expect(document ? applied?.marks == canvas.marks : copies == 1)
        let exported = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
        let image = NSBitmapImageRep(cgImage: exported)
        func color(at point: CGPoint) throws -> NSColor {
            let px = photo.pixelRect(CGRect(origin: point, size: CGSize(width: 1, height: 1)))
            let origin = photo.pixelRect(selection).origin
            return try #require(image.colorAt(x: Int(px.midX - origin.x), y: Int(px.midY - origin.y))?.usingColorSpace(.sRGB))
        }
        let stroke = try color(at: CGPoint(x: 155, y: 490))
        #expect(stroke.redComponent < 0.05 && stroke.greenComponent > 0.55 && stroke.blueComponent < 0.4)
        let inside = try color(at: CGPoint(x: 155, y: 494))
        #expect(inside.redComponent > 0.95 && inside.greenComponent > 0.95)
    }

    @Test func doubleClickEditsNearestPolygonEdge() throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -16000, y: -16000), size: photo.size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        window.contentView = canvas
        let region = try #require(CapturePolygon([
            CGPoint(x: 35, y: 430), CGPoint(x: 370, y: 430), CGPoint(x: 370, y: 650), CGPoint(x: 35, y: 650)
        ]))
        canvas.restoreRegion(region.bounds, polygon: region)
        canvas.toolbar.perform?(.tool(.polygon))
        for point in [CGPoint(x: 100, y: 434), CGPoint(x: 260, y: 434), CGPoint(x: 180, y: 570)] {
            try gesture(canvas, from: point)
        }
        try press(KeyCode.returnKey, on: canvas)
        let mark = try #require(canvas.marks.first)

        let regionEdge = CGPoint(x: 178, y: 430)
        try gesture(canvas, from: regionEdge)
        try gesture(canvas, from: regionEdge, clicks: 2)
        let regionalEdit = try #require(canvas.polygon)
        #expect(regionalEdit.vertices.count == 5 && regionalEdit.vertices[1] == regionEdge)
        #expect(canvas.marks == [mark])

        let markEdge = CGPoint(x: 213, y: 434)
        try gesture(canvas, from: markEdge)
        try gesture(canvas, from: markEdge, clicks: 2)
        #expect(canvas.polygon == regionalEdit)
        #expect(canvas.marks.first?.polygon?.vertices.count == 4 && canvas.marks.first?.polygon?.vertices[1] == markEdge)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [mark] && canvas.polygon == regionalEdit)
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks.first?.polygon?.vertices.count == 4)
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks == [mark] && canvas.polygon == regionalEdit)
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks == [mark] && canvas.polygon == region)
    }

    @Test(arguments: [false, true])
    func shiftSnapsAnchorPreviewAndPlacement(annotating: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: -16000, y: -16000), size: photo.size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        panel.contentView = canvas
        if annotating {
            canvas.restoreRegion(CGRect(x: 25, y: 40, width: 350, height: 240))
            canvas.toolbar.perform?(.tool(.polygon))
        } else {
            canvas.beginAnchors()
        }
        let first = CGPoint(x: 65, y: 85), raw = CGPoint(x: 205, y: 109), third = CGPoint(x: 190, y: 220)
        try gesture(canvas, from: first, modifiers: .shift)
        canvas.hover(at: raw)

        func setShift(_ down: Bool) throws {
            canvas.needsDisplay = false
            let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: down ? .shift : [],
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: KeyCode.shift))
            canvas.updateDirectionModifiers(event)
            #expect(canvas.needsDisplay)
        }
        func previewPixels() throws -> [NSColor] {
            let ctx = try #require(CGContext(data: nil, width: 420, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            canvas.draw(canvas.bounds)
            let bitmap = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
            return try [96, 102].map { y in try #require(bitmap.colorAt(x: 130, y: 699 - y)) }
        }
        let snappedPreview = try previewPixels()
        try setShift(false)
        let freePreview = try previewPixels()
        #expect(snappedPreview[0] != freePreview[0] && snappedPreview[1] != freePreview[1])
        try setShift(true)
        #expect(try previewPixels() == snappedPreview)

        try gesture(canvas, from: raw, modifiers: .shift)
        try gesture(canvas, from: third)
        try gesture(canvas, from: CGPoint(x: first.x + 4, y: first.y + 2), modifiers: .shift)
        let result = try #require(annotating ? canvas.marks.first?.polygon : canvas.polygon)
        try #require(result.vertices.count == 3)
        #expect(result.vertices.first == first && result.vertices.last == third)
        let snapped = result.vertices[1]
        #expect(abs(atan2(snapped.y - first.y, snapped.x - first.x) - .pi / 12) < 1e-7)
        #expect(abs(hypot(snapped.x - first.x, snapped.y - first.y) - hypot(raw.x - first.x, raw.y - first.y)) < 1e-7)
    }

    @Test(arguments: [false, true])
    func arrowAndRectangleShareStrokeControls(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 430)
        let window = NSPanel(contentRect: bounds.offsetBy(dx: -16000, dy: -16000), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(), frame: bounds,
                                           position: 0, onDone: { applied = $0 }, onBack: {})
            window.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            window.setContentSize(photo.size)
            window.contentView = canvas
            canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 190))
        }
        let toolbar = canvas.toolbar
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
        let style = try #require(buttons.first { $0.accessibilityLabel() == L("标注样式") })
        #expect(style.isHidden)
        func activate(_ kind: CaptureMark.Kind) throws {
            let button = try #require(buttons.first { $0.accessibilityLabel() == kind.title })
            button.performClick(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(!style.isHidden && toolbar.bounds.contains(style.frame))
            #expect(buttons.filter { !$0.isHidden && $0 !== style }.allSatisfy { !$0.frame.intersects(style.frame) })
            if let editor = window.contentView as? LongCaptureEditor {
                #expect(editor.scroller.frame.maxY < toolbar.frame.minY)
                #expect(toolbar.frame.height <= 120)
            }
        }

        try activate(.arrow)
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        try chooseStyle(AnnotationStroke.Width.heavy.title, in: toolbar)
        try gesture(canvas, from: CGPoint(x: 185, y: 550), to: CGPoint(x: 300, y: 550))
        let blue = AnnotationStroke(color: .blue, width: .heavy)
        #expect(canvas.marks.first?.stroke == blue)
        #expect(canvas.marks.first?.hit(CGPoint(x: 279, y: 559)) == true)

        try activate(.rectangle)
        #expect(toolbar.makeStyleMenu().items.first { $0.title == AnnotationColor.blue.title }?.state == .on)
        try chooseStyle(AnnotationColor.green.title, in: toolbar)
        try chooseStyle(AnnotationStroke.Width.thick.title, in: toolbar)
        try gesture(canvas, from: CGPoint(x: 80, y: 495), to: CGPoint(x: 150, y: 540))
        let green = AnnotationStroke(color: .green, width: .thick)
        #expect(canvas.marks.map(\.stroke) == [blue, green])

        toolbar.perform?(.select)
        try gesture(canvas, from: CGPoint(x: 81, y: 515), to: CGPoint(x: 91, y: 515))
        #expect(canvas.marks.last?.stroke == green)
        try chooseStyle(AnnotationStroke.Width.thin.title, in: toolbar)
        let thin = AnnotationStroke(color: .green, width: .thin)
        #expect(canvas.marks.map(\.stroke) == [blue, thin])
        toolbar.perform?(.undo)
        #expect(canvas.marks.map(\.stroke) == [blue, green])
        toolbar.perform?(.redo)
        #expect(canvas.marks.map(\.stroke) == [blue, thin])

        let selection = try #require(canvas.selection)
        canvas.onCopy?()
        if document { #expect(applied?.marks == canvas.marks) }
        let output = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
        let image = NSBitmapImageRep(cgImage: output)
        let crop = photo.pixelRect(selection)
        func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            let point = photo.pixelRect(CGRect(x: x, y: y, width: 0.5, height: 0.5)).origin
            return try #require(image.colorAt(x: Int(point.x - crop.minX), y: Int(point.y - crop.minY))?.usingColorSpace(.sRGB))
        }
        let shaft = try color(225, 553)
        let head = try color(282, 556)
        let rectangle = try color(90, 515)
        #expect(shaft.blueComponent > 0.9 && shaft.redComponent < 0.1)
        #expect(head.blueComponent > 0.9 && head.redComponent < 0.1)
        #expect(rectangle.greenComponent > 0.55 && rectangle.redComponent < 0.1)
        #expect(try color(91, 515).redComponent > 0.95)
    }

    @Test func lineArrowheadMenusEditEndpointsAndExportTheSameGeometry() throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -16000, y: -16000), size: photo.size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        window.contentView = canvas
        let selection = CGRect(x: 25, y: 450, width: 350, height: 190)
        canvas.restoreRegion(selection)
        let toolbar = canvas.toolbar
        let lineButton = try #require(toolbar.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == CaptureMark.Kind.line.title
        })
        lineButton.performClick(nil)
        #expect(toolbar.makeLineEndsMenu().items.first?.state == .on)
        func choose(_ title: String, from menu: NSMenu) throws {
            let item = try #require(menu.items.first { $0.title == title })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
        }
        try choose(AnnotationLineStyle.Ends.both.title, from: toolbar.makeLineEndsMenu())
        try choose(AnnotationLineStyle.Head.outline.title, from: toolbar.makeArrowHeadMenu())
        let a = CGPoint(x: 65, y: 540), b = CGPoint(x: 255, y: 540)
        try gesture(canvas, from: a, to: b)
        #expect(canvas.marks.first?.lineStyle == AnnotationLineStyle(ends: .both, head: .outline))

        toolbar.perform?(.select)
        try gesture(canvas, from: CGPoint(x: 150, y: 540))
        try choose(AnnotationLineStyle.Head.filled.title, from: toolbar.makeArrowHeadMenu())
        #expect(canvas.marks.first?.lineStyle.head == .filled)
        let filled = try #require(photo.render(selection, marks: canvas.marks))
        let end = CGPoint(x: 275, y: 550)
        try gesture(canvas, from: b, to: end)
        #expect(canvas.marks.first?.end == end && canvas.marks.first?.start == a)
        toolbar.perform?(.undo)
        #expect(canvas.marks.first?.end == b)
        toolbar.perform?(.undo)
        #expect(canvas.marks.first?.lineStyle.head == .outline)
        let outline = try #require(photo.render(selection, marks: canvas.marks))
        func green(at point: CGPoint, in image: CGImage) throws -> CGFloat {
            let pixel = try #require(photo.pixel(at: point))
            let crop = photo.pixelRect(selection)
            let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: Int(pixel.x - crop.minX), y: Int(pixel.y - crop.minY)))
            return try #require(color.usingColorSpace(.sRGB)).greenComponent
        }
        #expect(try green(at: CGPoint(x: 76, y: 540), in: filled) < 0.4)
        #expect(try green(at: CGPoint(x: 76, y: 540), in: outline) > 0.9)
    }

    @Test(arguments: [false, true])
    func rectangleBecomesEditablePolygon(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: -16000, y: -16000, width: 390, height: 430)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let region = CGRect(x: 24, y: 440, width: 360, height: 235)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(),
                frame: CGRect(origin: .zero, size: frame.size), position: 0, onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(region)
        }
        canvas.toolbar.perform?(.tool(.rectangle))
        try chooseStyle(AnnotationColor.blue.title, in: canvas.toolbar)
        try chooseStyle(AnnotationStroke.Width.heavy.title, in: canvas.toolbar)
        try gesture(canvas, from: CGPoint(x: 298, y: 620), to: CGPoint(x: 70, y: 486))
        let original = try #require(canvas.marks.first)
        #expect(original.kind == .rectangle && original.stroke == AnnotationStroke(color: .blue, width: .heavy))
        func undo() throws { try press(KeyCode.z, on: canvas, modifiers: .command) }
        func redo() throws { try press(KeyCode.z, on: canvas, modifiers: [.command, .shift]) }
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.001 }

        let click = CGPoint(x: 73, y: 548)
        try gesture(canvas, from: click, to: CGPoint(x: 73.5, y: 549))
        #expect(canvas.marks == [original])
        try gesture(canvas, from: click, clicks: 2)
        let converted = try #require(canvas.marks.first)
        let outline = try #require(converted.polygon)
        let node = try #require(outline.vertices.last)
        #expect(canvas.marks == [converted] && converted.kind == .polygon && converted.stroke == original.stroke)
        #expect(outline.vertices.count == 5 && close(node, CGPoint(x: 70, y: 548)))
        #expect(outline.bounds == original.bounds)
        let before = try #require(photo.render(region, marks: [original])?.dataProvider?.data)
        let after = try #require(photo.render(region, marks: [converted])?.dataProvider?.data)
        #expect(CFEqual(before, after))
        try undo()
        #expect(canvas.marks == [original])
        try redo()
        #expect(canvas.marks == [converted])

        let target = CGPoint(x: 48, y: 546)
        try gesture(canvas, from: node, to: target)
        let edited = try #require(canvas.marks.first)
        let moved = try #require(edited.polygon?.vertices.last)
        #expect(close(moved, target) && edited.stroke == original.stroke)
        try gesture(canvas, from: target)
        try press(KeyCode.forwardDelete, on: canvas)
        let shortened = try #require(canvas.marks.first)
        #expect(shortened.polygon?.vertices == Array(outline.vertices.dropLast()) && shortened.stroke == original.stroke)
        try undo()
        #expect(canvas.marks == [edited])
        try redo()
        #expect(canvas.marks == [shortened])
        if document {
            canvas.onCopy?()
            #expect(applied?.marks == [shortened])
        }
    }

    @Test(arguments: [false, true])
    func ellipseBecomesEditableClosedCurve(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: -16000, y: -16000, width: 390, height: 430)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let region = CGRect(x: 24, y: 440, width: 360, height: 235)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(),
                frame: CGRect(origin: .zero, size: frame.size), position: 0, onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(region)
        }
        let ellipseButton = try #require(canvas.toolbar.subviews.compactMap { $0 as? NSButton }.first {
            $0.accessibilityLabel() == CaptureMark.Kind.ellipse.title
        })
        #expect(ellipseButton.image != nil)
        ellipseButton.performClick(nil)
        try chooseStyle(AnnotationColor.blue.title, in: canvas.toolbar)
        try chooseStyle(AnnotationStroke.Width.heavy.title, in: canvas.toolbar)
        try gesture(canvas, from: CGPoint(x: 290, y: 608), to: CGPoint(x: 70, y: 486))
        let original = try #require(canvas.marks.first)
        #expect(original.kind == .ellipse && original.stroke == AnnotationStroke(color: .blue, width: .heavy))
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.001 }
        func undo() throws { try press(KeyCode.z, on: canvas, modifiers: .command) }
        func redo() throws { try press(KeyCode.z, on: canvas, modifiers: [.command, .shift]) }

        let edge = CGPoint(x: 180 + 110 / sqrt(2), y: 547 + 61 / sqrt(2))
        #expect(original.hit(edge) && !original.hit(CGPoint(x: original.bounds.midX, y: original.bounds.midY)))
        try gesture(canvas, from: edge, to: edge.applying(.init(translationX: 1, y: 0)))
        try gesture(canvas, from: edge, clicks: 2)
        let converted = try #require(canvas.marks.first)
        try #require(converted.lineNodes.count == 5)
        let inserted = converted.lineNodes[1]
        #expect(canvas.marks == [converted] && converted.lineShape?.isClosed == true && converted.stroke == original.stroke)
        #expect(close(inserted, edge) && converted.start == converted.end)
        #expect(close(converted.bounds.origin, original.bounds.origin))
        #expect(abs(converted.bounds.width - original.bounds.width) < 0.001)
        #expect(abs(converted.bounds.height - original.bounds.height) < 0.001)

        // Delete the selected inserted node and check the original four cubic sections rejoin.
        try press(KeyCode.forwardDelete, on: canvas)
        let rejoined = try #require(canvas.marks.first)
        #expect(rejoined.lineNodes.count == 4 && rejoined.lineShape?.isClosed == true)
        let native = try #require(photo.render(region, marks: [original])?.dataProvider?.data)
        let restored = try #require(photo.render(region, marks: [rejoined])?.dataProvider?.data)
        #expect(CFEqual(native, restored))
        try undo()
        #expect(canvas.marks == [converted])
        try undo()
        #expect(canvas.marks == [original])
        try redo()
        #expect(canvas.marks == [converted])

        let moved = CGPoint(x: inserted.x + 11, y: inserted.y + 15)
        try gesture(canvas, from: inserted, to: moved)
        let edited = try #require(canvas.marks.first)
        #expect(close(edited.lineNodes[1], moved) && edited.stroke == original.stroke)
        try gesture(canvas, from: edited.start, to: edited.start.applying(.init(translationX: 8, y: 0)))
        let movedSeam = try #require(canvas.marks.first)
        #expect(movedSeam.start == movedSeam.end && movedSeam.start.x > edited.start.x)
        try press(KeyCode.backspace, on: canvas)
        let shortened = try #require(canvas.marks.first)
        #expect(shortened.lineNodes.count == 4 && shortened.start == shortened.end && shortened.stroke == original.stroke)
        try undo()
        #expect(canvas.marks == [movedSeam])
        try redo()
        #expect(canvas.marks == [shortened])
        if document {
            canvas.onCopy?()
            #expect(applied?.marks == [shortened])
        }

        for _ in 0..<4 { try undo() }
        #expect(canvas.marks == [original])
        let top = CGPoint(x: original.bounds.midX, y: original.bounds.maxY)
        try gesture(canvas, from: top)
        try gesture(canvas, from: top, clicks: 2)
        let atTop = try #require(canvas.marks.first)
        #expect(atTop.lineNodes.count == 4 && atTop.lineShape?.isClosed == true)
        try press(KeyCode.backspace, on: canvas)
        let threeNodes = try #require(canvas.marks.first)
        #expect(threeNodes.lineNodes.count == 3 && !threeNodes.lineNodes.contains(top))
        try gesture(canvas, from: threeNodes.start)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [threeNodes])
    }

    @Test(arguments: [false, true])
    func straightMarkBecomesEditablePolyline(arrow: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: -16000, y: -16000, width: 390, height: 430)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let region = CGRect(x: 24, y: 440, width: 360, height: 235)
        let canvas: CaptureCanvas
        if arrow {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(),
                frame: CGRect(origin: .zero, size: frame.size), position: 0, onDone: { _ in }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(region)
        }
        let kind: CaptureMark.Kind = arrow ? .arrow : .line
        let style = AnnotationLineStyle(ends: arrow ? .both : .none, head: .outline)
        canvas.toolbar.perform?(.tool(kind))
        canvas.toolbar.changeLineStyle?(style)
        try chooseStyle(AnnotationColor.blue.title, in: canvas.toolbar)
        let start = CGPoint(x: 68, y: 503), end = CGPoint(x: 290, y: 503)
        try gesture(canvas, from: start, to: end)
        let original = try #require(canvas.marks.first)
        #expect(original.kind == kind && original.lineShape == nil && original.lineStyle == style)
        func undo() throws { try press(KeyCode.z, on: canvas, modifiers: .command) }
        func redo() throws { try press(KeyCode.z, on: canvas, modifiers: [.command, .shift]) }
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.001 }

        let click = CGPoint(x: 280, y: 504)
        try gesture(canvas, from: click, to: CGPoint(x: 281, y: 504.5))
        #expect(canvas.marks == [original])
        try gesture(canvas, from: click, clicks: 2)
        let inserted = try #require(canvas.marks.first)
        try #require(inserted.lineNodes.count == 3)
        let node = inserted.lineNodes[1]
        #expect(close(node, CGPoint(x: 280, y: 503)) && inserted.isPolyline)
        #expect(inserted.kind == kind && inserted.lineStyle == style && inserted.stroke == original.stroke)
        #expect(inserted.start == original.start && inserted.end == original.end)
        let before = try #require(photo.render(region, marks: [original])?.dataProvider?.data)
        let after = try #require(photo.render(region, marks: [inserted])?.dataProvider?.data)
        #expect(CFEqual(before, after))
        try undo()
        #expect(canvas.marks == [original])
        try redo()
        #expect(canvas.marks == [inserted])

        let target = CGPoint(x: 224, y: 557)
        try gesture(canvas, from: node, to: target)
        let bent = try #require(canvas.marks.first)
        #expect(bent.lineNodes.count == 3 && close(bent.lineNodes[1], target) && bent.lineStyle == style)
        #expect(bent.selectionBounds.maxY > original.selectionBounds.maxY)
        try gesture(canvas, from: target)
        try press(KeyCode.forwardDelete, on: canvas)
        let shortened = try #require(canvas.marks.first)
        #expect(shortened.lineNodes == [original.start, original.end] && shortened.lineStyle == style)
        try undo()
        #expect(canvas.marks == [bent])
        try redo()
        #expect(canvas.marks == [shortened])
        try gesture(canvas, from: shortened.end)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [shortened])
    }

    @Test func polylineFinishesAsOneMarkAndEditsItsNodes() throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: -16000, y: -16000), size: photo.size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        panel.contentView = canvas
        canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 205))
        canvas.toolbar.perform?(.tool(.line))
        try chooseStyle(AnnotationLineMode.polyline.title, in: canvas.toolbar)
        let start = CGPoint(x: 65, y: 500), last = CGPoint(x: 275, y: 605)
        try gesture(canvas, from: start)
        try gesture(canvas, from: CGPoint(x: 181, y: 520), modifiers: .shift)
        try gesture(canvas, from: CGPoint(x: 205, y: 592))
        try press(KeyCode.backspace, on: canvas)
        try gesture(canvas, from: last)
        #expect(canvas.marks.isEmpty)
        try press(KeyCode.returnKey, on: canvas)
        let mark = try #require(canvas.marks.first)
        #expect(mark.lineNodes.count == 3 && mark.end == last && mark.lineShape?.isClosed == false)
        let middle = mark.lineNodes[1]
        #expect(abs(atan2(middle.y - start.y, middle.x - start.x) - .pi / 12) < 1e-7)
        let moved = CGPoint(x: 182, y: 563)
        try gesture(canvas, from: middle, to: moved)
        let edited = try #require(canvas.marks.first)
        #expect(edited.start == start && edited.end == last && edited.lineNodes.count == 3)
        #expect(hypot(edited.lineNodes[1].x - moved.x, edited.lineNodes[1].y - moved.y) < 1e-7)
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks == [mark])
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks.isEmpty)

        try gesture(canvas, from: start)
        try gesture(canvas, from: moved)
        try gesture(canvas, from: last)
        try gesture(canvas, from: start)
        let closed = try #require(canvas.marks.first)
        #expect(closed.lineNodes == [start, moved, last] && closed.lineShape?.isClosed == true)
        try gesture(canvas, from: CGPoint(x: 300, y: 628))
        try press(KeyCode.escape, on: canvas)
        #expect(canvas.marks == [closed])
        canvas.toolbar.perform?(.undo)
        try gesture(canvas, from: start)
        try gesture(canvas, from: last, clicks: 2)
        #expect(canvas.marks.first?.lineNodes == [start, last])

        canvas.toolbar.perform?(.undo)
        try gesture(canvas, from: start)
        try gesture(canvas, from: moved)
        let rightClick = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: moved, modifierFlags: [],
            timestamp: 1, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        canvas.rightMouseDown(with: rightClick)
        #expect(canvas.marks.first?.lineNodes == [start, moved])
    }

    @Test(arguments: [false, true])
    func finishedPolylineCanInsertAndRemoveNodes(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: -16000, y: -16000, width: 390, height: 430)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(),
                frame: CGRect(origin: .zero, size: frame.size), position: 0,
                onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 220))
        }
        let toolbar = canvas.toolbar
        toolbar.perform?(.tool(.line))
        try chooseStyle(AnnotationLineMode.polyline.title, in: toolbar)
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        let style = AnnotationLineStyle(ends: .both, head: .filled)
        toolbar.changeLineStyle?(style)
        func undo() throws { try press(KeyCode.z, on: canvas, modifiers: .command) }
        func redo() throws { try press(KeyCode.z, on: canvas, modifiers: [.command, .shift]) }
        func doubleClick(_ point: CGPoint) throws {
            try gesture(canvas, from: point)
            try gesture(canvas, from: point, clicks: 2)
        }
        func expectNodes(_ mark: CaptureMark, _ expected: [CGPoint]) {
            #expect(mark.lineNodes.count == expected.count)
            for (actual, wanted) in zip(mark.lineNodes, expected) {
                #expect(hypot(actual.x - wanted.x, actual.y - wanted.y) < 0.001)
            }
        }

        let first = CGPoint(x: 60, y: 500), middle = CGPoint(x: 180, y: 500), last = CGPoint(x: 270, y: 595)
        for point in [first, middle, last] { try gesture(canvas, from: point) }
        try press(KeyCode.returnKey, on: canvas)
        let open = try #require(canvas.marks.first)
        expectNodes(open, [first, middle, last])
        #expect(open.lineStyle == style && open.lineShape?.isClosed == false)
        let inserted = CGPoint(x: 120, y: 500)
        try doubleClick(CGPoint(x: 120, y: 504))
        let withInserted = try #require(canvas.marks.first)
        #expect(canvas.marks.count == 1)
        expectNodes(withInserted, [first, inserted, middle, last])
        #expect(withInserted.lineStyle == style && withInserted.stroke == open.stroke)
        try undo()
        #expect(canvas.marks == [open])
        try redo()
        #expect(canvas.marks == [withInserted])
        try gesture(canvas, from: inserted)
        try press(KeyCode.forwardDelete, on: canvas)
        #expect(canvas.marks == [open])
        try undo()
        #expect(canvas.marks == [withInserted])
        try redo()
        #expect(canvas.marks == [open])

        toolbar.perform?(.select)
        try gesture(canvas, from: first)
        try press(KeyCode.backspace, on: canvas)
        let shortened = try #require(canvas.marks.first)
        expectNodes(shortened, [middle, last])
        #expect(shortened.lineStyle == style)
        try gesture(canvas, from: last)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [shortened])

        toolbar.perform?(.tool(.line))
        let a = CGPoint(x: 80, y: 560), b = CGPoint(x: 150, y: 630), c = CGPoint(x: 240, y: 625)
        for point in [a, b, c, a] { try gesture(canvas, from: point) }
        let closed = try #require(canvas.marks.last)
        expectNodes(closed, [a, b, c])
        #expect(closed.lineShape?.isClosed == true)
        let join = CGPoint(x: 160, y: 592.5)
        try doubleClick(join)
        let fourNodes = try #require(canvas.marks.last)
        #expect(canvas.marks.count == 2)
        expectNodes(fourNodes, [a, b, c, join])
        #expect(fourNodes.lineShape?.isClosed == true)
        try gesture(canvas, from: a)
        try press(KeyCode.backspace, on: canvas)
        let threeNodes = try #require(canvas.marks.last)
        expectNodes(threeNodes, [b, c, join])
        #expect(threeNodes.lineShape?.isClosed == true)
        try gesture(canvas, from: b)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [shortened, threeNodes])
        try undo()
        #expect(canvas.marks == [shortened, fourNodes])
        try undo()
        #expect(canvas.marks == [shortened, closed])
        try redo()
        try redo()
        #expect(canvas.marks == [shortened, threeNodes])

        if document {
            canvas.onCopy?()
            #expect(applied?.marks == canvas.marks)
        }
        let selection = try #require(canvas.selection)
        let output = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
        let pixels = NSBitmapImageRep(cgImage: output)
        let crop = photo.pixelRect(selection)
        func color(at point: CGPoint) throws -> NSColor {
            let pixel = try #require(photo.pixel(at: point))
            return try #require(pixels.colorAt(x: Int(pixel.x - crop.minX), y: Int(pixel.y - crop.minY))?.usingColorSpace(.sRGB))
        }
        #expect(try color(at: inserted).redComponent > 0.95)
        #expect(try color(at: CGPoint(x: 225, y: 547.5)).redComponent < 0.1)
    }

    @Test func shiftSnapsLineAndCurveAndCurveControlsStayEditable() throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let panel = NSPanel(contentRect: CGRect(origin: CGPoint(x: -16000, y: -16000), size: photo.size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
        panel.contentView = canvas
        let selection = CGRect(x: 25, y: 450, width: 350, height: 220)
        canvas.restoreRegion(selection)
        let start = CGPoint(x: 65, y: 505), rawEnd = CGPoint(x: 236, y: 555)
        canvas.toolbar.perform?(.tool(.line))
        try gesture(canvas, from: start, to: rawEnd, modifiers: .shift)
        let line = try #require(canvas.marks.first)
        #expect(abs(atan2(line.end.y - start.y, line.end.x - start.x) - .pi / 12) < 1e-7)
        canvas.toolbar.perform?(.undo)

        canvas.toolbar.perform?(.tool(.arrow))
        #expect(!canvas.toolbar.makeStyleMenu().items.contains { $0.title == AnnotationLineMode.polyline.title })
        try chooseStyle(AnnotationLineMode.curve.title, in: canvas.toolbar)
        try gesture(canvas, from: start, to: rawEnd, modifiers: .shift)
        let curve = try #require(canvas.marks.first)
        #expect(curve.end == line.end && curve.lineStyle.ends == .end && curve.lineHandles.count == 4)
        let firstControl = curve.lineHandles[2], secondControl = curve.lineHandles[3]
        let movedControl = CGPoint(x: firstControl.x + 9, y: firstControl.y + 21)
        try gesture(canvas, from: firstControl, to: movedControl)
        let edited = try #require(canvas.marks.first)
        #expect(edited.lineHandles[2] == movedControl && edited.lineHandles[3] == secondControl)
        let end = CGPoint(x: curve.end.x + 14, y: curve.end.y + 11)
        try gesture(canvas, from: curve.end, to: end)
        let movedEnd = try #require(canvas.marks.first)
        #expect(movedEnd.end == end && movedEnd.lineHandles[2] == movedControl)
        #expect(abs(movedEnd.lineHandles[3].x - secondControl.x - 14) < 1e-7)
        #expect(abs(movedEnd.lineHandles[3].y - secondControl.y - 11) < 1e-7)
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks == [edited])
        let mid = CGPoint(x: (edited.start.x + 3 * movedControl.x + 3 * secondControl.x + edited.end.x) / 8,
                          y: (edited.start.y + 3 * movedControl.y + 3 * secondControl.y + edited.end.y) / 8)
        #expect(edited.hit(mid))
        let output = try #require(photo.render(selection, marks: canvas.marks))
        let pixel = try #require(photo.pixel(at: mid))
        let crop = photo.pixelRect(selection)
        let sample = try #require(NSBitmapImageRep(cgImage: output).colorAt(x: Int(pixel.x - crop.minX), y: Int(pixel.y - crop.minY)))
        #expect(try #require(sample.usingColorSpace(.sRGB)).greenComponent < 0.4)
    }

    @Test(arguments: [false, true])
    func finishedCurveCanInsertAndRemoveNodes(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: -16000, y: -16000, width: 390, height: 430)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(),
                frame: CGRect(origin: .zero, size: frame.size), position: 0,
                onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(CGRect(x: 24, y: 440, width: 360, height: 235))
        }
        let toolbar = canvas.toolbar
        toolbar.perform?(.tool(document ? .line : .arrow))
        try chooseStyle(AnnotationLineMode.curve.title, in: toolbar)
        let style = AnnotationLineStyle(ends: .both, head: .outline)
        toolbar.changeLineStyle?(style)
        try gesture(canvas, from: CGPoint(x: 55, y: 482), to: CGPoint(x: 290, y: 544))
        let original = try #require(canvas.marks.first)
        let segment = try #require(original.curveSegments?.first)
        let midpoint = segment.split(at: 0.5).0.end
        func close(_ a: CGPoint, _ b: CGPoint) -> Bool { hypot(a.x - b.x, a.y - b.y) < 0.001 }
        func undo() throws { try press(KeyCode.z, on: canvas, modifiers: .command) }
        func redo() throws { try press(KeyCode.z, on: canvas, modifiers: [.command, .shift]) }

        try gesture(canvas, from: midpoint)
        try gesture(canvas, from: midpoint, clicks: 2)
        let inserted = try #require(canvas.marks.first)
        let parts = try #require(inserted.curveSegments)
        try #require(parts.count == 2)
        #expect(canvas.marks == [inserted] && inserted.lineStyle == style)
        #expect(close(parts[0].end, midpoint) && parts[0].end == parts[1].start)
        let fraction = parts[0].weight / segment.weight
        for step in 0...20 {
            let t = CGFloat(step) / 20
            let point = t <= fraction ? parts[0].split(at: t / fraction).0.end
                                     : parts[1].split(at: (t - fraction) / (1 - fraction)).0.end
            #expect(close(point, segment.split(at: t).0.end))
        }
        #expect(close(inserted.selectionBounds.origin, original.selectionBounds.origin))
        #expect(abs(inserted.selectionBounds.width - original.selectionBounds.width) < 0.001)
        #expect(abs(inserted.selectionBounds.height - original.selectionBounds.height) < 0.001)
        try undo()
        #expect(canvas.marks == [original])
        try redo()
        #expect(canvas.marks == [inserted])

        try gesture(canvas, from: parts[0].end)
        try press(KeyCode.forwardDelete, on: canvas)
        let merged = try #require(canvas.marks.first?.curveSegments?.first)
        #expect(canvas.marks.first?.curveSegments?.count == 1)
        #expect(close(merged.firstControl, segment.firstControl) && close(merged.secondControl, segment.secondControl))
        try undo()
        #expect(canvas.marks == [inserted])

        let movedNode = CGPoint(x: parts[0].end.x, y: parts[0].end.y + 20)
        try gesture(canvas, from: parts[0].end, to: movedNode)
        let moved = try #require(canvas.marks.first)
        let movedParts = try #require(moved.curveSegments)
        try #require(movedParts.count == 2)
        #expect(close(movedParts[0].end, movedNode) && movedParts[0].end == movedParts[1].start)
        #expect(close(movedParts[0].secondControl, parts[0].secondControl.applying(.init(translationX: 0, y: 20))))
        #expect(close(movedParts[1].firstControl, parts[1].firstControl.applying(.init(translationX: 0, y: 20))))
        try gesture(canvas, from: movedParts[0].secondControl)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [moved])

        try gesture(canvas, from: moved.start)
        try press(KeyCode.backspace, on: canvas)
        let shortened = try #require(canvas.marks.first)
        #expect(shortened.curveSegments == [movedParts[1]] && shortened.lineStyle == style)
        try gesture(canvas, from: shortened.end)
        try press(KeyCode.backspace, on: canvas)
        #expect(canvas.marks == [shortened])
        try undo()
        #expect(canvas.marks == [moved])
        try redo()
        #expect(canvas.marks == [shortened])

        if document {
            canvas.onCopy?()
            #expect(applied?.marks == canvas.marks)
        }
        let selection = try #require(canvas.selection)
        let output = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
        let pixels = NSBitmapImageRep(cgImage: output)
        let crop = photo.pixelRect(selection)
        func color(at point: CGPoint) throws -> NSColor {
            let pixel = try #require(photo.pixel(at: point))
            return try #require(pixels.colorAt(x: Int(pixel.x - crop.minX), y: Int(pixel.y - crop.minY))?.usingColorSpace(.sRGB))
        }
        #expect(try color(at: movedParts[0].split(at: 0.5).0.end).greenComponent > 0.95)
        #expect(try color(at: movedParts[1].split(at: 0.5).0.end).greenComponent < 0.4)
    }

    @Test(arguments: [false, true])
    func textAndStepNumbersKeepTheirStylesInTheEditorAndExport(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: 0, y: 0, width: 300, height: 430)
        let window = NSPanel(contentRect: frame.offsetBy(dx: -16000, dy: -16000), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(), frame: frame,
                                           position: 0, onDone: { applied = $0 }, onBack: {})
            window.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            window.setContentSize(photo.size)
            window.contentView = canvas
            canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 200))
        }
        let selection = try #require(canvas.selection)
        let toolbar = canvas.toolbar
        let style = try #require(toolbar.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == L("标注样式") })
        let colors = Set(AnnotationColor.allCases.map(\.title))
        toolbar.perform?(.tool(.text))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!style.isHidden && toolbar.bounds.contains(style.frame))
        let menu = toolbar.makeStyleMenu()
        #expect(Set(menu.items.map(\.title)).isSuperset(of: colors))
        #expect(menu.items.contains { $0.title == L("字号") } && !menu.items.contains { $0.title == L("线宽") })

        let textOrigin = CGPoint(x: 55, y: 615)
        try gesture(canvas, from: textOrigin)
        let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextInput }.first)
        input.insertText("MARK", replacementRange: NSRange(location: NSNotFound, length: 0))
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        try chooseStyle(AnnotationLettering.Size.largest.title, in: toolbar)
        #expect(canvas.isEditingText && input.string == "MARK" && input.font?.pointSize == 48)
        let liveColor = try #require(input.textColor?.usingColorSpace(.sRGB))
        #expect(liveColor.blueComponent > 0.9 && liveColor.redComponent < 0.1)
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let text = try #require(canvas.marks.first)
        #expect(text.text == "MARK" && text.lettering == AnnotationLettering(color: .blue, size: .largest))
        #expect(text.bounds.height > 55 && selection.contains(text.bounds))

        toolbar.perform?(.tool(.number))
        #expect(!toolbar.makeStyleMenu().items.contains { $0.title == L("文字对齐") || $0.title == L("粗体") })
        try chooseStyle(AnnotationColor.orange.title, in: toolbar)
        try chooseStyle(AnnotationLettering.Size.regular.title, in: toolbar)
        let badgeCenter = CGPoint(x: 270, y: 550)
        try gesture(canvas, from: badgeCenter)
        try gesture(canvas, from: CGPoint(x: 350, y: 500))
        let original = try #require(canvas.marks.last)
        #expect(canvas.marks.filter { $0.kind == .number }.map(\.number) == [1, 2])
        #expect(original.lettering == AnnotationLettering(color: .orange))
        toolbar.perform?(.select)
        try gesture(canvas, from: original.start)
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        try chooseStyle(AnnotationLettering.Size.extraLarge.title, in: toolbar)
        let resized = try #require(canvas.marks.last)
        #expect(resized.bounds.height > original.bounds.height && selection.contains(resized.bounds))
        #expect(canvas.marks[1].lettering.color == .orange)
        #expect(resized.number == 2 && resized.lettering == AnnotationLettering(color: .blue, size: .extraLarge))
        toolbar.perform?(.undo)
        #expect(canvas.marks.last?.lettering == AnnotationLettering(color: .blue))
        toolbar.perform?(.redo)
        #expect(canvas.marks.last == resized)

        canvas.onCopy?()
        if document { #expect(applied?.marks == canvas.marks) }
        let exported = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
        let bitmap = NSBitmapImageRep(cgImage: exported)
        let crop = photo.pixelRect(selection)
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            let p = photo.pixelRect(CGRect(x: x, y: y, width: 0.5, height: 0.5)).origin
            return bitmap.colorAt(x: Int(p.x - crop.minX), y: Int(p.y - crop.minY))?.usingColorSpace(.sRGB)
        }
        let badgeColor = try #require(color(resized.start.x + 13, resized.start.y))
        #expect(badgeColor.blueComponent > 0.9 && badgeColor.redComponent < 0.1)
        let textPixels = stride(from: Int(text.bounds.minY + 5), to: Int(text.bounds.maxY - 4), by: 2)
            .flatMap { y in stride(from: Int(text.bounds.minX + 5), to: Int(text.bounds.maxX - 4), by: 2)
                .compactMap { x in color(CGFloat(x), CGFloat(y)) } }
        #expect(textPixels.contains { $0.blueComponent > 0.9 && $0.redComponent < 0.1 })

        toolbar.perform?(.tool(.number))
        try gesture(canvas, from: CGPoint(x: 325, y: 610))
        let third = try #require(canvas.marks.last)
        let originalMarks = canvas.marks
        #expect(third.number == 3)
        try gesture(canvas, from: resized.start)
        try gesture(canvas, from: resized.start, clicks: 2)
        let numberInput = try #require(window.firstResponder as? AnnotationTextInput)
        #expect(numberInput.string == "2" && numberInput.selectedRange() == NSRange(location: 0, length: 1))
        #expect(numberInput.font?.pointSize == resized.lettering.size.points && selection.contains(numberInput.frame))
        #expect(canvas.marks == originalMarks)
        numberInput.string = "0"
        numberInput.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(window.firstResponder === numberInput && canvas.marks == originalMarks)
        numberInput.string = "８"
        numberInput.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let editedMarks = canvas.marks
        #expect(editedMarks.map(\.kind) == originalMarks.map(\.kind))
        #expect(editedMarks[2].number == 8 && editedMarks[2].lettering == resized.lettering)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == originalMarks)
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == editedMarks)
        try press(KeyCode.z, on: canvas, modifiers: .command)

        toolbar.perform?(.select)
        try gesture(canvas, from: resized.start, clicks: 2)
        let cancelledInput = try #require(window.firstResponder as? AnnotationTextInput)
        cancelledInput.string = "9"
        cancelledInput.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(canvas.marks == originalMarks && !canvas.isEditingText)
        try gesture(canvas, from: resized.start)
        try press(KeyCode.backspace, on: canvas)
        var shifted = third
        shifted.number = 2
        let compacted = [text, originalMarks[1], shifted]
        #expect(canvas.marks == compacted)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == originalMarks)
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == compacted)
        if document {
            canvas.onCopy?()
            #expect(applied?.marks == compacted)
        }
        toolbar.perform?(.tool(.number))
        try gesture(canvas, from: resized.start)
        #expect(canvas.marks.last?.number == 3)
    }

    @Test(arguments: [false, true])
    func textBoxEdgesResizeAndReflowWithUndo(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: 0, y: 0, width: 300, height: 430)
        let panel = NSPanel(contentRect: frame.offsetBy(dx: -16000, dy: -16000), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(), frame: frame,
                                           position: 0, onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 200))
        }
        let toolbar = canvas.toolbar
        toolbar.perform?(.tool(.text))
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        try gesture(canvas, from: CGPoint(x: 65, y: 613))
        let input = try #require(panel.firstResponder as? AnnotationTextInput)
        input.insertText("Starting text", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let original = try #require(canvas.marks.first)
        toolbar.perform?(.select)
        let center = CGPoint(x: original.bounds.midX, y: original.bounds.midY)
        try gesture(canvas, from: center, clicks: 2)
        let reopened = try #require(panel.firstResponder as? AnnotationTextInput)
        #expect(reopened.string == original.text)
        let words = "Alpha beta gamma delta echo"
        reopened.selectAll(nil)
        reopened.insertText(words, replacementRange: NSRange(location: NSNotFound, length: 0))
        reopened.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let edited = try #require(canvas.marks.first)
        #expect(edited.text == words && edited.lettering == original.lettering)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [original])
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == [edited])

        try gesture(canvas, from: CGPoint(x: edited.bounds.midX, y: edited.bounds.midY))
        try gesture(canvas, from: CGPoint(x: edited.bounds.maxX - 3, y: edited.bounds.midY),
                    to: CGPoint(x: edited.bounds.minX + 103, y: edited.bounds.midY))
        let wrapped = try #require(canvas.marks.first)
        #expect(wrapped.start == edited.start && abs(wrapped.bounds.width - 106) < 0.001)
        try #require(wrapped.bounds.height > edited.bounds.height * 2)
        #expect(wrapped.text == words && wrapped.lettering == original.lettering)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [edited])
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == [wrapped])

        canvas.onCopy?()
        if document { #expect(applied?.marks == [wrapped]) }
        let selection = try #require(canvas.selection)
        let crop = photo.pixelRect(selection)
        func hasBlueText(below top: CGFloat, in mark: CaptureMark) throws -> Bool {
            let image = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
            let bitmap = NSBitmapImageRep(cgImage: image)
            let rows = photo.pixelRect(CGRect(x: mark.bounds.minX + 5, y: mark.bounds.minY + 4,
                width: mark.bounds.width - 10, height: top - mark.bounds.minY - 4))
            return (Int(rows.minY)..<Int(rows.maxY)).contains { y in
                (Int(rows.minX)..<Int(rows.maxX)).contains { x in
                    guard let pixel = bitmap.colorAt(x: x - Int(crop.minX), y: y - Int(crop.minY))?.usingColorSpace(.sRGB)
                    else { return false }
                    return pixel.blueComponent > 0.9 && pixel.redComponent < 0.1
                }
            }
        }
        #expect(try hasBlueText(below: edited.bounds.minY, in: wrapped))

        let wrappedCenter = CGPoint(x: wrapped.bounds.midX, y: wrapped.bounds.midY)
        try gesture(canvas, from: wrappedCenter, clicks: 2)
        let narrowInput = try #require(panel.firstResponder as? AnnotationTextInput)
        #expect(narrowInput.frame.width == wrapped.bounds.width)
        narrowInput.string = "Ready"
        narrowInput.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let short = try #require(canvas.marks.first)
        #expect(short.text == "Ready" && short.bounds.width == wrapped.bounds.width)
        #expect(short.bounds.height < wrapped.bounds.height)
        toolbar.perform?(.tool(.text))
        try gesture(canvas, from: CGPoint(x: short.bounds.minX + 3, y: short.bounds.midY),
                    to: CGPoint(x: short.bounds.minX - 17, y: short.bounds.midY))
        let widened = try #require(canvas.marks.first)
        #expect(widened.bounds.maxX == short.bounds.maxX && abs(widened.bounds.width - short.bounds.width - 20) < 0.001)

        try gesture(canvas, from: CGPoint(x: widened.bounds.midX, y: widened.bounds.midY), clicks: 2)
        let multilineInput = try #require(panel.firstResponder as? AnnotationTextInput)
        func enter(_ key: CGKeyCode, modifiers: NSEvent.ModifierFlags = []) throws {
            let characters = key == KeyCode.keypadEnter ? "\u{3}" : "\r"
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 1, windowNumber: panel.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key))
            multilineInput.keyDown(with: event)
        }
        let singleLineHeight = multilineInput.frame.height
        try enter(KeyCode.returnKey, modifiers: .shift)
        #expect(multilineInput.string == "Ready\n" && multilineInput.frame.height > singleLineHeight)
        #expect(panel.firstResponder === multilineInput && canvas.marks == [widened])
        multilineInput.insertText("复核", replacementRange: NSRange(location: NSNotFound, length: 0))
        try enter(KeyCode.keypadEnter, modifiers: [.shift, .numericPad])
        #expect(multilineInput.string == "Ready\n复核\n" && canvas.marks == [widened])
        try enter(KeyCode.returnKey)
        let multiline = try #require(canvas.marks.first)
        #expect(!canvas.isEditingText && multiline.text == "Ready\n复核\n")
        #expect(multiline.bounds.width == widened.bounds.width)
        var withoutLastBreak = multiline
        withoutLastBreak.text.removeLast()
        #expect(multiline.bounds.height > withoutLastBreak.bounds.height)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [widened])
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == [multiline])
        canvas.onCopy?()
        if document { #expect(applied?.marks == [multiline]) }
        try #require(multiline.bounds.height > widened.bounds.height + 4)
        #expect(try hasBlueText(below: widened.bounds.minY, in: multiline))
    }

    @Test(arguments: [false, true])
    func textFormattingMatchesEditingAndExport(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: 0, y: 0, width: 330, height: 430)
        let panel = NSPanel(contentRect: frame.offsetBy(dx: -16000, dy: -16000), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(), frame: frame,
                                           position: 0, onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 200))
        }
        let toolbar = canvas.toolbar
        toolbar.perform?(.tool(.text))
        try chooseStyle(AnnotationColor.orange.title, in: toolbar)
        try gesture(canvas, from: CGPoint(x: 60, y: 610))
        let input = try #require(panel.firstResponder as? AnnotationTextInput)
        input.insertText("Alignment example\nB", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let left = try #require(canvas.marks.first)

        // 文字工具仍处于启用状态时，样式作用于已经选中的文字框。
        try chooseStyle(AnnotationTextFormat.Alignment.center.title, in: toolbar)
        let center = try #require(canvas.marks.first)
        #expect(center.textFormat.alignment == .center && center.bounds == left.bounds)
        try chooseStyle(AnnotationTextFormat.Alignment.center.title, in: toolbar)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [left])
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == [center])

        toolbar.perform?(.select)
        try gesture(canvas, from: CGPoint(x: center.bounds.midX, y: center.bounds.midY))
        try chooseStyle(AnnotationTextFormat.Alignment.right.title, in: toolbar)
        let right = try #require(canvas.marks.first)
        #expect(right.textFormat.alignment == .right && right.bounds == left.bounds)
        try chooseStyle(AnnotationTextFormat.Alignment.left.title, in: toolbar)
        #expect(canvas.marks.first?.textFormat.alignment == .left)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [right])

        let selection = try #require(canvas.selection)
        let crop = photo.pixelRect(selection)
        func rendered(_ mark: CaptureMark) throws -> NSBitmapImageRep {
            NSBitmapImageRep(cgImage: try #require(photo.render(selection, marks: [mark])))
        }
        func color(at x: Int, _ y: Int, in bitmap: NSBitmapImageRep) -> NSColor? {
            bitmap.colorAt(x: x - Int(crop.minX), y: y - Int(crop.minY))?.usingColorSpace(.sRGB)
        }
        func secondLineOrigin(_ mark: CaptureMark) throws -> Int {
            let bitmap = try rendered(mark)
            let rows = photo.pixelRect(CGRect(x: mark.bounds.minX, y: mark.bounds.minY + 3,
                                             width: mark.bounds.width, height: mark.bounds.height / 2 - 3))
            return try #require((Int(rows.minX)..<Int(rows.maxX)).first { x in
                (Int(rows.minY)..<Int(rows.maxY)).contains { y in
                    guard let pixel = color(at: x, y, in: bitmap) else { return false }
                    return pixel.redComponent > 0.95 && pixel.blueComponent < 0.15 && pixel.greenComponent > 0.45
                }
            })
        }
        let positions = try [left, center, right].map(secondLineOrigin)
        #expect(positions[0] + 40 < positions[1] && positions[1] + 40 < positions[2])

        try gesture(canvas, from: CGPoint(x: right.bounds.midX, y: right.bounds.midY))
        try chooseStyle(L("粗体"), in: toolbar)
        let bold = try #require(canvas.marks.first)
        #expect(bold.textFormat.bold && bold.textFormat.alignment == .right)
        try chooseStyle(L("文字底框"), in: toolbar, selected: false)
        let transparent = try #require(canvas.marks.first)
        #expect(!transparent.textFormat.showsBackground && transparent.textFormat.bold)
        let sample = try #require(photo.pixel(at: CGPoint(x: right.bounds.minX + 2, y: right.bounds.midY)))
        let opaqueColor = try #require(color(at: Int(sample.x), Int(sample.y), in: rendered(bold)))
        let transparentColor = try #require(color(at: Int(sample.x), Int(sample.y), in: rendered(transparent)))
        #expect(opaqueColor.redComponent < 0.05 && transparentColor.redComponent > 0.95)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [bold])
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks == [right])
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks == [transparent])

        try gesture(canvas, from: CGPoint(x: transparent.bounds.midX, y: transparent.bounds.midY), clicks: 2)
        let reopened = try #require(panel.firstResponder as? AnnotationTextInput)
        #expect(reopened.alignment == .right && !reopened.drawsBackground)
        #expect(reopened.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(reopened.frame.width == transparent.bounds.width)
        reopened.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(canvas.marks == [transparent])
        canvas.onCopy?()
        if document { #expect(applied?.marks == [transparent]) }
    }

    @Test(arguments: [false, true])
    func solidCoverExportsOpaqueColors(document: Bool) throws {
        let photo = CaptureImage(image: try page(), size: CGSize(width: 420, height: 700))
        let frame = CGRect(x: 0, y: 0, width: 300, height: 430)
        let panel = NSPanel(contentRect: frame.offsetBy(dx: -16000, dy: -16000), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let canvas: CaptureCanvas
        var applied: CaptureAnnotations?
        if document {
            let editor = LongCaptureEditor(photo: photo, annotations: CaptureAnnotations(), frame: frame,
                                           position: 0, onDone: { applied = $0 }, onBack: {})
            panel.contentView = editor
            editor.layoutSubtreeIfNeeded()
            canvas = editor.canvas
        } else {
            canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [])
            panel.setContentSize(photo.size)
            panel.contentView = canvas
            canvas.restoreRegion(CGRect(x: 25, y: 450, width: 350, height: 200))
        }
        let toolbar = canvas.toolbar
        let buttons = toolbar.subviews.compactMap { $0 as? NSButton }
        let cover = try #require(buttons.first { $0.accessibilityLabel() == CaptureMark.Kind.cover.title })
        let style = try #require(buttons.first { $0.accessibilityLabel() == L("标注样式") })
        cover.performClick(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(!style.isHidden && toolbar.bounds.contains(style.frame))
        let choices = toolbar.makeStyleMenu().items.filter { $0.action != nil }
        #expect(choices.map(\.title) == AnnotationColor.allCases.map(\.title))
        #expect(choices.first { $0.state == .on }?.title == AnnotationColor.black.title)
        try gesture(canvas, from: CGPoint(x: 45, y: 540), to: CGPoint(x: 120, y: 600))
        try chooseStyle(AnnotationColor.blue.title, in: toolbar)
        try gesture(canvas, from: CGPoint(x: 150, y: 540), to: CGPoint(x: 225, y: 600))
        #expect(canvas.marks.map(\.fillColor) == [.black, .blue])

        let selection = try #require(canvas.selection)
        let rectangle = try #require(canvas.marks.last)
        let edge = CGPoint(x: rectangle.bounds.maxX, y: rectangle.bounds.midY)
        try gesture(canvas, from: edge)
        try gesture(canvas, from: edge, clicks: 2)
        let converted = try #require(canvas.marks.last)
        #expect(canvas.marks.count == 2 && converted.kind == .cover && converted.fillColor == .blue)
        #expect(converted.polygon?.vertices.count == 5)
        let originalFill = try #require(photo.render(selection, marks: [rectangle])?.dataProvider?.data)
        let convertedFill = try #require(photo.render(selection, marks: [converted])?.dataProvider?.data)
        #expect(CFEqual(originalFill, convertedFill))
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks.last == rectangle)
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks.last == converted)

        let movedAnchor = CGPoint(x: 198, y: edge.y)
        try gesture(canvas, from: edge, to: movedAnchor)
        let reshaped = try #require(canvas.marks.last)
        #expect(reshaped.kind == .cover && reshaped.fillColor == .blue)
        #expect(reshaped.polygon?.contains(CGPoint(x: 218, y: edge.y)) == false)
        try gesture(canvas, from: CGPoint(x: 170, y: 560), to: CGPoint(x: 175, y: 560))
        let translated = try #require(canvas.marks.last)
        #expect(translated.kind == .cover && translated.fillColor == .blue)
        #expect(translated.polygon == reshaped.polygon?.offsetBy(dx: 5, dy: 0))
        try chooseStyle(AnnotationColor.orange.title, in: toolbar)
        toolbar.perform?(.undo)
        #expect(canvas.marks.last?.fillColor == .blue)
        toolbar.perform?(.redo)
        #expect(canvas.marks.map(\.fillColor) == [.black, .orange])

        let orangePolygon = try #require(canvas.marks.last)
        try gesture(canvas, from: movedAnchor.applying(.init(translationX: 5, y: 0)))
        try press(KeyCode.forwardDelete, on: canvas)
        let deletedAnchor = try #require(canvas.marks.last)
        #expect(deletedAnchor.polygon?.vertices.count == 4 && deletedAnchor.fillColor == .orange)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks.last == orangePolygon)
        try press(KeyCode.z, on: canvas, modifiers: [.command, .shift])
        #expect(canvas.marks.last == deletedAnchor)
        try press(KeyCode.z, on: canvas, modifiers: .command)
        #expect(canvas.marks.last == orangePolygon)

        canvas.onCopy?()
        if document { #expect(applied?.marks == canvas.marks) }
        let result = try #require(photo.render(selection, marks: applied?.marks ?? canvas.marks))
        let image = NSBitmapImageRep(cgImage: result)
        let crop = photo.pixelRect(selection)
        func sample(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
            let pixel = photo.pixelRect(CGRect(x: x, y: y, width: 0.5, height: 0.5)).origin
            return try #require(image.colorAt(x: Int(pixel.x - crop.minX), y: Int(pixel.y - crop.minY))?.usingColorSpace(.sRGB))
        }
        let black = try sample(75, 560)
        let orange = try sample(180, 560)
        #expect(black.alphaComponent == 1 && black.redComponent == 0 && black.greenComponent == 0 && black.blueComponent == 0)
        #expect(orange.alphaComponent == 1)
        #expect(orange.redComponent > 0.99)
        #expect((0.45...0.7).contains(orange.greenComponent))
        #expect(orange.blueComponent < 0.01)
        let outsidePolygon = try sample(225, edge.y)
        #expect(outsidePolygon.blueComponent > 0.95 && outsidePolygon.greenComponent > 0.95)
    }

    @Test func stitchedImageCanBeMarkedReeditedAndSearchedAfterCopy() async throws {
        let source = try page()
        #expect(ContentExtractor.recognizeText(in: source).lowercased().contains("orchid"))
        let first = try #require(source.cropping(to: CGRect(x: 0, y: 0, width: 840, height: 900)))
        let second = try #require(source.cropping(to: CGRect(x: 0, y: 350, width: 840, height: 900)))
        let area = CGRect(x: 120, y: 120, width: 420, height: 450)
        let region = ScrollCaptureRegion(display: 0, screen: area, photo: CaptureImage(image: first, size: area.size),
                                         selection: CGRect(origin: .zero, size: area.size))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var producer: ScrollCaptureSource.Frames.Continuation?
        var closed = false
        let clipboard = CaptureClipboard(pasteboard: board)
        let flow = ScrollingCapture(region: region, clipboard: clipboard) { closed = true }
        defer { flow.close() }
        flow.start { region, _ in
            let buffer = ScrollCaptureSource.buffer(width: region.width, height: region.height)
            producer = buffer.continuation
            buffer.continuation.yield(first)
            return ScrollCaptureSource(frames: buffer.stream, stop: { buffer.continuation.finish() })
        }
        try await wait { producer != nil }
        producer?.yield(second)
        producer?.finish()
        func resultWindow() -> NSWindow? {
            NSApp.windows.first { w in
                w.isVisible && (w.contentView as? NSHostingView<ScrollCapturePreview>)?.rootView.image.width == 840
            }
        }
        try await wait { resultWindow() != nil }
        let win = try #require(resultWindow())
        func preview() throws -> ScrollCapturePreview {
            try #require((win.contentView as? NSHostingView<ScrollCapturePreview>)?.rootView)
        }
        #expect(try preview().image.height == 1250)
        try preview().edit()
        let editor = try #require(win.contentView as? LongCaptureEditor)
        editor.layoutSubtreeIfNeeded()
        let canvas = editor.canvas
        // 在原图上添加步骤，选中第二个移动、删除，再分别撤销和重做。
        canvas.toolbar.perform?(.tool(.number))
        for x in [30, 80, 130] { try gesture(canvas, from: CGPoint(x: x, y: 515)) }
        #expect(canvas.marks.map(\.number) == [1, 2, 3])
        canvas.toolbar.perform?(.select)
        try gesture(canvas, from: CGPoint(x: 80, y: 515), to: CGPoint(x: 92, y: 509))
        #expect(hypot(canvas.marks[1].start.x - 92, canvas.marks[1].start.y - 509) < 0.001)
        let delete = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: win.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: KeyCode.backspace))
        #expect(canvas.handleKey(delete))
        #expect(canvas.marks.map(\.number) == [1, 2])
        canvas.toolbar.perform?(.undo)
        #expect(canvas.marks.map(\.number) == [1, 2, 3])
        canvas.toolbar.perform?(.redo)
        #expect(canvas.marks.map(\.number) == [1, 2])
        canvas.toolbar.perform?(.undo)
        // 第 1250 像素在原页上对应 150；原文在 750，此处坐标是 2x 显示的点。
        canvas.toolbar.perform?(.tool(.cover))
        try gesture(canvas, from: CGPoint(x: 22, y: 290), to: CGPoint(x: 260, y: 340))
        canvas.toolbar.perform?(.tool(.text))
        try gesture(canvas, from: CGPoint(x: 25, y: 440))
        let input = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextInput }.first)
        input.setMarkedText("que", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: win.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: KeyCode.returnKey))
        #expect(input.hasMarkedText() && !canvas.handleKey(enter) && !closed)
        input.insertText("确认步骤", replacementRange: NSRange(location: NSNotFound, length: 0))
        input.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(canvas.marks.last?.text == "确认步骤")
        // 双击修改旧字，只保留一个文字对象。
        try gesture(canvas, from: CGPoint(x: 40, y: 428), clicks: 2)
        let reopened = try #require(canvas.subviews.compactMap { $0 as? AnnotationTextInput }.first)
        reopened.string = "确认步骤 APPROVED"
        reopened.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(canvas.marks.count == 5)
        canvas.toolbar.perform?(.tool(.polygon))
        let vertices = [CGPoint(x: 275, y: 400), CGPoint(x: 342, y: 415), CGPoint(x: 314, y: 463)]
        for point in vertices { try gesture(canvas, from: point) }
        #expect(canvas.handleKey(enter))
        let polygon = try #require(canvas.marks.last?.polygon)
        #expect(canvas.marks.count == 6 && polygon.vertices.count == 3)
        canvas.onCopy?() // 与编辑窗口“完成标注”共用入口
        try await wait { resultWindow() != nil }
        try preview().edit()
        let again = try #require(win.contentView as? LongCaptureEditor)
        #expect(again.canvas.marks.first(where: { $0.kind == .text })?.text == "确认步骤 APPROVED")
        #expect(again.canvas.marks.last?.polygon == polygon)
        again.canvas.toolbar.perform?(.undo)
        again.canvas.onCancel?() // 丢弃这次修改，预览仍是上次确认的标注
        try preview().copy()
        #expect(closed)
        let capture = try #require(ClipboardWatcher.capture(from: board, recordImages: true))
        #expect(capture.imageSize == CGSize(width: 840, height: 1250))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardStore(directory: directory)
        store.setImageRecognition(enabled: true)
        store.add(capture, maxItems: 10)
        try await wait { store.items.first?.imageText != nil }
        #expect(store.search("APPROVED").count == 1 && store.search("确认").count == 1)
        #expect(store.search("ORCHID").isEmpty)
        let panel = ClipboardPanelModel(store: store)
        panel.copyImageText(try #require(store.items.first), to: board)
        try await wait { board.string(forType: .string) != nil }
        #expect(board.string(forType: .string)?.lowercased().contains("approved") == true && board.data(forType: .png) == nil)
    }
}
