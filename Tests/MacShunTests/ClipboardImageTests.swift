// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@MainActor
@Suite("剪贴板图片文字与贴图")
struct ClipboardImageTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pin-test-" + UUID().uuidString)
    }

    /// 在隔离的剪贴板中生成测试图，走 ClipboardWatcher 正常的记录入口。
    private func sample(_ text: String, on board: NSPasteboard) throws -> ClipboardCapture {
        _ = NSApplication.shared
        let ctx = try #require(CGContext(data: nil, width: 800, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 120))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (text as NSString).draw(at: CGPoint(x: 25, y: 31),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 42), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let image = try #require(ctx.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        board.clearContents()
        board.setData(png, forType: .png)
        return try #require(ClipboardWatcher.capture(from: board, recordImages: true))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(condition())
    }

    @Test func oldAndNewImagesUseLocalOCRAndSurviveReload() async throws {
        let dir = folder()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
        let first = try sample("项目进度  ENGINE 742", on: board)
        let old = ClipboardStore(directory: dir)
        old.add(first, maxItems: 20)
        old.saveNow()
        let store = ClipboardStore(directory: dir)
        let firstID = try #require(store.items.first?.id)
        #expect(store.items.first?.imageText == nil)
        let model = ClipboardPanelModel(store: store)
        model.query = "engine 742"
        #expect(model.results.isEmpty)
        store.setImageRecognition(enabled: true)
        try await waitUntil { model.results.first?.id == firstID }
        #expect(store.search("项目").first?.id == firstID)
        #expect(store.search("xmjd").first?.id == firstID)
        #expect(model.selectedItem?.kind == .image && model.selectedItem?.text == nil)
        let fresh = try sample("HARBOUR 519", on: board)
        store.add(fresh, maxItems: 20)
        try await waitUntil { store.search("harbour").count == 1 }
        store.add(first, maxItems: 20)
        #expect(store.items.count == 2)
        store.saveNow()
        let rereads = Locked(0)
        let reopened = ClipboardStore(directory: dir) { _ in rereads.update { $0 += 1 }; return "" }
        reopened.setImageRecognition(enabled: true)
        #expect(reopened.search("engine").first?.id == firstID)
        #expect(reopened.search("519").first?.kind == .image)
        #expect(rereads.get() == 0)
    }

    @Test func removalWhileRecognizingDoesNotReviveAResult() async throws {
        let dir = folder(), board = NSPasteboard.withUniqueName()
        let started = Locked(false), calls = Locked(0)
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); board.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir) { _ in
            if calls.update({ $0 += 1; return $0 }) == 1 {
                started.set(true)
                _ = gate.wait(timeout: .now() + 10)
                return "deleted text"
            }
            return ""
        }
        store.setImageRecognition(enabled: true)
        store.add(try sample("A", on: board), maxItems: 3)
        try await waitUntil { started.get() }
        store.clearUnpinned()
        let blank = try sample("", on: board)
        store.add(blank, maxItems: 3)
        gate.signal()
        try await waitUntil { store.items.first?.imageText == "" }
        store.add(blank, maxItems: 3)
        #expect(store.search("deleted").isEmpty && calls.get() == 2)
        #expect(store.items.count == 1)
    }

    @Test func copyTextSharesIndexingAndPreservesNewerClipboardContents() async throws {
        let dir = folder(), board = NSPasteboard.withUniqueName()
        let calls = Locked(0), gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); board.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir) { _ in
            calls.update { $0 += 1 }
            _ = gate.wait(timeout: .now() + 8)
            return "indexed"
        }
        store.setImageRecognition(enabled: true)
        store.add(try sample("indexed", on: board), maxItems: 3)
        try await waitUntil { calls.get() == 1 }
        let item = try #require(store.items.first)
        let model = ClipboardPanelModel(store: store)
        model.copyImageText(item, to: board)
        board.clearContents()
        board.setString("later copy", forType: .string)
        gate.signal()
        try await waitUntil { model.copyFeedback == L("剪贴板已更改，请重新取字") }
        #expect(board.string(forType: .string) == "later copy")
        model.copyImageText(item, to: board)
        try await waitUntil { board.string(forType: .string) == "indexed" }
        #expect(calls.get() == 1)
    }

    @Test func explicitlyCopyingAnEmptyImageKeepsTheClipboard() async throws {
        let dir = folder(), board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir) { _ in "" }
        store.add(try sample("", on: board), maxItems: 3)
        let item = try #require(store.items.first)
        let model = ClipboardPanelModel(store: store)
        let count = board.changeCount
        model.copyImageText(item, to: board)
        try await waitUntil { model.copyFeedback == L("图片里没有可复制的文字") }
        #expect(board.changeCount == count && board.data(forType: .png) != nil)
        #expect(store.items.first?.imageText == nil)
    }

    @Test func floatingCopiesFullImageRegardlessOfAppearance() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let capture = try sample("Reference", on: board)
        let picture = try #require(PinPicture.read(board))
        let manager = ScreenPins()
        defer { manager.closeAll() }
        let first = try #require(manager.show(picture, at: CGRect(x: 180, y: 200, width: 400, height: 60), pasteboard: board))
        let second = try #require(manager.show(picture, pasteboard: board))
        #expect(first.frame.size == CGSize(width: 400, height: 60))
        #expect(first.level == .floating && first.isVisible && second.isVisible)
        let anchor = CGPoint(x: first.frame.midX, y: first.frame.midY)
        first.scale(to: 1.5, around: anchor)
        #expect(first.frame.midX == anchor.x && first.frame.midY == anchor.y)
        #expect(first.frame.size == CGSize(width: 600, height: 90))
        first.adjustOpacity(-0.45)
        #expect(abs(first.alphaValue - 0.55) < 0.01)
        board.clearContents()
        board.setString("prior", forType: .string)
        #expect(PinPicture.read(board) == nil)
        first.copyPicture()
        #expect(board.data(forType: .png) == capture.png)
        #expect(PinPicture.read(board)?.pixels == CGSize(width: 800, height: 120))
        first.setContentSize(CGSize(width: 94, height: 64))
        let surface = try #require(first.contentView)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
            timestamp: 1, windowNumber: first.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        surface.mouseEntered(with: enter)
        first.adjustOpacity(0)
        surface.layoutSubtreeIfNeeded()
        let close = try #require(surface.subviews.compactMap { $0 as? NSButton }.first)
        let badge = try #require(surface.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(!close.isHidden && !badge.isHidden && !close.frame.intersects(badge.frame))
        #expect(surface.bounds.contains(close.frame) && surface.bounds.contains(badge.frame))
        let number = first.windowNumber
        close.performClick(nil)
        #expect(manager.windows.count == 1 && manager.windows.first === second && ScreenPins.frames.get()[number] == nil)
        manager.closeAll()
        #expect(manager.windows.isEmpty)
    }
}
