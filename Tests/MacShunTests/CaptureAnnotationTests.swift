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

    private func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<250 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(ready())
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
        let reads = Locked(0)
        var closed = false
        let flow = ScrollingCapture(region: region, pasteboard: board) { closed = true }
        defer { flow.close() }
        flow.start { _, _ in { reads.update { $0 += 1; return $0 == 1 ? first : second } } }
        try await wait { reads.get() >= 2 }
        flow.requestFinish()
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
        canvas.onCopy?() // 与编辑窗口“完成标注”共用入口
        try await wait { resultWindow() != nil }
        try preview().edit()
        let again = try #require(win.contentView as? LongCaptureEditor)
        #expect(again.canvas.marks.last?.text == "确认步骤 APPROVED")
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
