// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
@testable import MacShun

@Suite("纵向长截图")
struct ScrollStitcherTests {
    /// 有留白的文本行、不能随文档移动的多行表头和底栏，颜色可用全页坐标再次生成。
    private func image(top: Int, height: Int, header: Int = 0, footer: Int = 0, repeatEvery: Int? = nil) throws -> CGImage {
        let width = 220
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let px = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                var pageY = y + top
                if y < header { pageY = y + 100_000 }
                else if y >= height - footer { pageY = y - height + 200_000 }
                if let repeatEvery { pageY %= repeatEvery }
                for x in 0..<width {
                    let n = (pageY &* 7771 ^ (x / 5 &* 1129)) &* 2617
                    let value: UInt8 = pageY % 19 < 6 ? 248 : UInt8(truncatingIfNeeded: n >> (x % 3 + 3))
                    let i = (y * width + x) * 4
                    px[i] = value; px[i + 1] = value; px[i + 2] = value; px[i + 3] = 255
                }
            }
        }
        let provider = try #require(CGDataProvider(data: data as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @Test func severalOverlapsArePixelExactIncludingFixedChrome() throws {
        let h = 191
        func frame(_ top: Int) throws -> CGImage { try image(top: top, height: h, header: 22, footer: 17) }
        var stitch = try #require(ScrollStitcher(try frame(0)))
        for offset in [37, 86, 140, 147, 203] { #expect(try stitch.append(frame(offset)) == .appended) }
        #expect(try stitch.append(frame(203)) == .unchanged)
        let result = try #require(stitch.result())
        let expected = try image(top: 0, height: h + 203, header: 22, footer: 17)
        #expect(result.height == expected.height && result.width == expected.width)
        #expect(result.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
    }

    @Test func backingUpAndMissingOverlapKeepLastConfirmedImage() throws {
        var stitch = try #require(ScrollStitcher(try image(top: 0, height: 200)))
        #expect(try stitch.append(image(top: 50, height: 200)) == .appended)
        #expect(try stitch.append(image(top: 20, height: 200)) == .backtracked)
        #expect(try stitch.append(image(top: 650, height: 200)) == .noOverlap)
        #expect(stitch.height == 250)
        #expect(try stitch.append(image(top: 90, height: 200)) == .appended)
        let expected = try image(top: 0, height: 290)
        #expect(stitch.result()?.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
    }

    @Test func repeatPatternsAndSizeLimitNeverInventRows() throws {
        var repeated = try #require(ScrollStitcher(try image(top: 0, height: 200, repeatEvery: 22)))
        #expect(try repeated.append(image(top: 7, height: 200, repeatEvery: 22)) == .noOverlap)
        #expect(repeated.height == 200)
        var limited = try #require(ScrollStitcher(try image(top: 0, height: 200), maximumHeight: 235))
        #expect(try limited.append(image(top: 35, height: 200)) == .appended)
        #expect(try limited.append(image(top: 40, height: 200)) == .limit)
        #expect(limited.height == 235)
    }

    @MainActor @Test func fileListWithRepeatedNamesKeepsDistinctLineNumbers() throws {
        _ = NSApplication.shared
        let w = 1024, h = 1072
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for i in 0..<44 {
            let name = String(format: "Report - 2026 - revision %04d.txt", 1085 + i) as NSString
            name.draw(at: CGPoint(x: 20, y: h - 24 - 24 * i),
                      withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let source = try #require(context.makeImage())
        func part(_ y: Int, _ height: Int = 680) throws -> CGImage {
            try #require(source.cropping(to: CGRect(x: 0, y: y, width: w, height: height)))
        }
        var stitch = try #require(ScrollStitcher(try part(0)))
        for offset in [96, 131, 221] {
            let progress = try stitch.append(part(offset))
            #expect(progress == .appended, "offset \(offset)")
        }
        #expect(stitch.height == 901)
        let expected = try #require(ScrollStitcher(try part(0, 901))?.result())
        #expect(stitch.result()?.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
    }

    @MainActor
    private func sparseTextPage(repeated: Bool = false, retina: Bool = false) throws -> CGImage {
        let width = retina ? 1032 : 1000, height = 1500
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let labels = ["Maple", "Cedar", "Aspen", "Birch", "Spruce", "Willow"]
        let spacing = repeated ? 180 : 250
        let font = retina ? NSFont.systemFont(ofSize: 38, weight: .medium) : NSFont.systemFont(ofSize: 20)
        let left = retina ? 24 : 12
        let firstBaseline = retina ? 55 : 26
        for (index, label) in labels.enumerated() {
            let row = retina ? String(format: "ROW %03d", index + 1) : "Row \(index + 1)"
            let value = (index + 7) * 2419
            let text = repeated ? "Repeated row" : "\(row)  \(label)\(retina ? "  " : "   ")\(value)"
            (text as NSString).draw(at: CGPoint(x: left, y: height - firstBaseline - index * spacing),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        return try #require(context.makeImage())
    }

    @MainActor @Test(arguments: [[270], [330], [420], [270, 600, 850]])
    func sparseTextStitchesAcrossBlankSpace(offsets: [Int]) throws {
        let viewport = 630
        let source = try sparseTextPage()
        func crop(at y: Int, height: Int = viewport) throws -> CGImage {
            try #require(source.cropping(to: CGRect(x: 0, y: y, width: source.width, height: height)))
        }
        var stitch = try #require(ScrollStitcher(try crop(at: 0)))
        for offset in offsets {
            try #require(stitch.append(crop(at: offset)) == .appended)
            #expect(stitch.height == viewport + offset)
        }
        let lastOffset = try #require(offsets.last)
        let expected = try #require(ScrollStitcher(try crop(at: 0, height: viewport + lastOffset))?.result())
        #expect(stitch.result()?.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
    }

    @MainActor @Test func sparseRepeatedTextCannotBridgeMissingOverlap() throws {
        let source = try sparseTextPage(repeated: true)
        func crop(at y: Int) throws -> CGImage {
            try #require(source.cropping(to: CGRect(x: 0, y: y, width: source.width, height: 630)))
        }
        var stitch = try #require(ScrollStitcher(try crop(at: 0)))
        #expect(try stitch.append(crop(at: 750)) == .noOverlap)
        #expect(stitch.height == 630)
    }

    @MainActor @Test(arguments: [10, 45])
    func smallScrollStepsKeepTheSeamAcrossBlankSpace(step: Int) throws {
        let source = try sparseTextPage(retina: true)
        let viewport = 640, end = 800
        func crop(at offset: Int, height: Int = viewport) throws -> CGImage {
            try #require(source.cropping(to: CGRect(x: 0, y: offset, width: source.width, height: height)))
        }
        var stitch = try #require(ScrollStitcher(try crop(at: 0)))
        let offsets = Array(stride(from: step, to: end, by: step)) + [end]
        for offset in offsets {
            _ = try stitch.append(crop(at: offset))
        }
        #expect(stitch.height == viewport + end)
        let expected = try #require(ScrollStitcher(try crop(at: 0, height: viewport + end))?.result())
        #expect(stitch.result()?.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
    }

    @MainActor @Test func blinkingCaretAndScrollbarKeepTheFirstFrame() throws {
        let source = try sparseTextPage()
        let viewport = CGRect(x: 0, y: 0, width: source.width, height: 630)
        let first = try #require(source.cropping(to: viewport))
        let context = try #require(CGContext(data: nil, width: first.width, height: first.height, bitsPerComponent: 8,
                                             bytesPerRow: first.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setBlendMode(.copy)
        context.draw(first, in: viewport)
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 57, y: 517, width: 3, height: 24))
        context.fill(CGRect(x: 986, y: 289, width: 12, height: 200))

        let changed = try #require(context.makeImage())
        var stitch = try #require(ScrollStitcher(first))
        let baseline = try #require(stitch.result())
        #expect(stitch.append(changed) == .unchanged)
        #expect(stitch.result()?.dataProvider?.data as Data? == baseline.dataProvider?.data as Data?)

        let scrolled = try #require(source.cropping(to: viewport.offsetBy(dx: 0, dy: 270)))
        #expect(stitch.append(scrolled) == .appended)
        #expect(stitch.height == 900)
    }

    @Test func warnsAfterThreeMissesAndClearsWhenOverlapReturns() {
        var overlap = ScrollCaptureOverlap()
        overlap.recordFrame(.noOverlap)
        #expect(!overlap.needsBacktrack)
        overlap.recordFrame(.noOverlap)
        #expect(!overlap.needsBacktrack)
        overlap.recordFrame(.noOverlap)
        #expect(overlap.needsBacktrack)
        overlap.recordFrame(.appended)
        #expect(!overlap.needsBacktrack)
        overlap.recordFrame(.noOverlap)
        #expect(!overlap.needsBacktrack)
    }

    /// 从选区的快捷键进入、完成和取消，都使用独立剪贴板与合成画面。
    @MainActor @Test func captureEntryPreviewAndCancellation() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = try image(top: 0, height: 160)
        let middle = try image(top: 100, height: 160)
        let last = try image(top: 200, height: 160)
        var withoutMiddle = try #require(ScrollStitcher(first))
        #expect(withoutMiddle.append(last) == .noOverlap)
        let rect = CGRect(x: -18000, y: -17000, width: first.width, height: first.height)
        let photo = CaptureImage(image: first, size: rect.size)
        var producer: ScrollCaptureSource.Frames.Continuation?
        var stopped = 0
        let clipboard = CaptureClipboard(pasteboard: board)
        let controller = ScreenCaptureController(clipboard: clipboard, makeScrollSource: { region, _ in
            let buffer = ScrollCaptureSource.buffer(width: region.width, height: region.height)
            producer = buffer.continuation
            buffer.continuation.yield(first)
            return ScrollCaptureSource(frames: buffer.stream) {
                stopped += 1
                if stopped == 2 { buffer.continuation.yield(last) }
                buffer.continuation.finish()
            }
        }, freeze: { [FrozenScreen(frame: rect, photo: photo, windowRects: [photo.bounds])] })
        defer { controller.cancel() }

        func waitUntil(_ ready: () -> Bool) async throws {
            for _ in 0..<200 {
                if ready() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(ready())
        }
        func start() async throws {
            producer = nil
            controller.start(.image)
            func window() -> NSWindow? { NSApp.windows.first(where: { $0.isVisible && $0.frame == rect && $0.contentView is CaptureCanvas }) }
            try await waitUntil { window() != nil }
            let panel = try #require(window())
            let canvas = try #require(panel.contentView as? CaptureCanvas)
            let center = CGPoint(x: rect.width / 2, y: rect.height / 2)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let e = try #require(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: 1,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                panel.sendEvent(e)
            }
            let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 1, windowNumber: panel.windowNumber, context: nil, characters: "l", charactersIgnoringModifiers: "l",
                isARepeat: false, keyCode: KeyCode.l))
            #expect(canvas.handleKey(e))
            try await waitUntil { producer != nil }
        }
        board.setString("original", forType: .string)
        let count = board.changeCount
        try await start()
        controller.cancelScrolling()
        #expect(!FrontAppTracker.shared.scrollingCaptureActive.get() && board.changeCount == count)
        #expect(stopped == 1)
        try await start()
        producer?.yield(middle)
        // 模拟点击完成后最后一张画面才抵达，缓冲区应先排空再打开预览。
        try await waitUntil {
            controller.finishScrolling()
            return stopped == 2
        }
        func preview() -> ScrollCapturePreview? {
            NSApp.windows.compactMap { w in
                w.isVisible ? (w.contentView as? NSHostingView<ScrollCapturePreview>)?.rootView : nil
            }.first { $0.image.width == first.width }
        }
        try await waitUntil { preview() != nil }
        let result = try #require(preview())
        let expected = try image(top: 0, height: 360)
        #expect(result.image.height == 360 && result.message == nil && board.changeCount == count)
        #expect(result.image.dataProvider?.data as Data? == expected.dataProvider?.data as Data?)
        #expect(stopped == 2)
        result.copy()
        let data = try #require(board.data(forType: .png))
        #expect(NSBitmapImageRep(data: data)?.pixelsHigh == 360 && preview() == nil)
        #expect(clipboard.containsScreenshot)
    }

    @Test func regionUsesDisplayLocalPointsForScreenCaptureKit() throws {
        let cg = try image(top: 0, height: 180)
        let photo = CaptureImage(image: cg, size: CGSize(width: 110, height: 90))
        let frame = CGRect(x: -110, y: 170, width: 110, height: 90)
        let region = ScrollCaptureRegion(display: 2, screen: frame, photo: photo,
                                        selection: CGRect(x: 10.25, y: 20.25, width: 31.25, height: 45))
        #expect(region.source == CGRect(x: 10, y: 24.5, width: 31.5, height: 45.5))
        #expect(region.area == CGRect(x: -100, y: 190, width: 31.5, height: 45.5))
        #expect(region.width == 63 && region.height == 91)
    }

    @Test func takeResultResetsHeightAndReleasesBuffer() throws {
        let first = try image(top: 0, height: 160)
        let second = try image(top: 100, height: 160)
        var stitch = try #require(ScrollStitcher(first))
        #expect(stitch.append(second) == .appended)
        #expect(stitch.height == 260)
        let rawTaken = stitch.takeResult()
        let taken = try #require(rawTaken)
        #expect(taken.height == 260)
        #expect(stitch.height == 0)
        #expect(stitch.result() == nil)
    }
}
