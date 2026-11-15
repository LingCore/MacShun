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

    private func gesture(_ canvas: CaptureCanvas, from start: CGPoint, to end: CGPoint? = nil, clicks: Int = 1) throws {
        let win = try #require(canvas.window)
        let steps: [(NSEvent.EventType, CGPoint)] = [(.leftMouseDown, start), (.leftMouseDragged, end ?? start), (.leftMouseUp, end ?? start)]
        for (type, point) in steps {
            let event = try #require(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                modifierFlags: [], timestamp: 1, windowNumber: win.windowNumber, context: nil,
                eventNumber: 1, clickCount: clicks, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
    }

    private func chooseStyle(_ title: String, in toolbar: CaptureToolbar) throws {
        let item = try #require(toolbar.makeStyleMenu().items.first { $0.title == title && $0.action != nil })
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(toolbar.makeStyleMenu().items.first { $0.title == title && $0.action != nil }?.state == .on)
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
        func key(_ code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
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

        let movedVertex = first.applying(.init(translationX: 20, y: 15))
        let edited = [movedVertex] + vertices.dropFirst()
        try gesture(canvas, from: first, to: movedVertex)
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
                #expect(toolbar.frame.height <= 80)
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

        toolbar.perform?(.select)
        try gesture(canvas, from: CGPoint(x: 170, y: 560), to: CGPoint(x: 175, y: 560))
        try chooseStyle(AnnotationColor.orange.title, in: toolbar)
        toolbar.perform?(.undo)
        #expect(canvas.marks.last?.fillColor == .blue)
        toolbar.perform?(.redo)
        #expect(canvas.marks.map(\.fillColor) == [.black, .orange])

        let selection = try #require(canvas.selection)
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
        #expect(canvas.marks.map(\.number) == [1, 3])
        canvas.toolbar.perform?(.undo)
        canvas.toolbar.perform?(.redo)
        #expect(canvas.marks.map(\.number) == [1, 3])
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
