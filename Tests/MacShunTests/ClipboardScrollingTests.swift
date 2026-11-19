// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI
import Testing
@testable import MacShun

@Suite(.serialized)
@MainActor
struct ClipboardScrollingTests {
    @Test(arguments: [true, false])
    func longHistoryKeepsRowsVisibleAndNumberedWhileScrolling(_ opensAbove: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ClipboardStore(directory: directory)
        defer {
            store.saveNow()
            try? FileManager.default.removeItem(at: directory)
        }
        for n in 1...212 {
            let text = n.isMultiple(of: 3) ? String(repeating: "Wrapped content ", count: 10) + "\(n)" : "Row \(n)"
            store.add(.init(kind: .text, text: text, fingerprint: "\(n)"), maxItems: 212,
                      now: Date(timeIntervalSince1970: Double(n)))
        }
        for item in store.sortedItems.dropFirst(2).prefix(12) {
            store.togglePin(item.id)
        }

        let model = ClipboardPanelModel(store: store)
        model.prepareForShow(opensAbove: opensAbove)
        let panel = ClipboardPanel()
        let host = NSHostingView(rootView: ClipboardPanelView(model: model)
            .environment(\.sizeCategory, opensAbove ? .large : .accessibilityExtraExtraExtraLarge))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        let size = opensAbove ? ClipboardPanel.size : CGSize(width: 334, height: 240)
        panel.setFrame(NSRect(origin: CGPoint(x: -4000, y: 0), size: size), display: false)
        panel.appearance = NSAppearance(named: opensAbove ? .darkAqua : .aqua)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(70))
            host.layoutSubtreeIfNeeded()
            if let snapshot = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: snapshot)
            }
        }
        let first = try #require(model.results.first)
        let last = try #require(model.results.last)
        try await settle()
        try #require(model.rowState.visibleIDs.contains(first.id))
        let scroll = try #require(findScrollView(in: host))
        let clip = scroll.contentView
        let direction = opensAbove ? -1 : 1
        var panelChanges = 0
        let changes = model.objectWillChange.sink { panelChanges += 1 }
        defer { changes.cancel() }

        // Check both direct clip movement and wheel events delivered only to this window.
        let stepWheel = try wheelEvent(-direction * (opensAbove ? 203 : 106))
        for step in 1...28 {
            if step == 22 { model.showsQuickPasteNumbers = true }
            let before = clip.bounds.origin
            let previousIDs = model.rowState.visibleIDs
            let changesBeforeScroll = panelChanges
            if opensAbove {
                clip.scroll(to: CGPoint(x: before.x, y: before.y - 203))
                scroll.reflectScrolledClipView(clip)
            } else {
                scroll.scrollWheel(with: stepWheel)
            }
            try await settle()
            try #require(!model.rowState.visibleIDs.isEmpty, "Empty viewport at step \(step)")
            model.hoveredID = model.results.first { model.rowState.visibleIDs.contains($0.id) }?.id
            if abs(clip.bounds.minY - before.y) >= 100 {
                try #require(model.rowState.visibleIDs != previousIDs, "Stale viewport at step \(step)")
            }
            try #require(panelChanges == changesBeforeScroll, "Scrolling invalidated the entire panel at step \(step)")
        }
        #expect(!model.rowState.visibleIDs.contains(first.id))
        let firstVisible = try #require(model.results.first { model.rowState.visibleIDs.contains($0.id) })
        #expect(model.quickPasteNumber(for: firstVisible.id) == 1)
        var pastedID: UUID?
        model.onPaste = { pastedID = $0.id }
        model.pasteVisibleRow(1)
        #expect(pastedID == firstVisible.id)

        for destination in [last, first] {
            let wheel = try wheelEvent(destination.id == last.id ? -direction * 860 : direction * 860)
            for _ in 0..<26 {
                if model.rowState.visibleIDs.contains(destination.id) { break }
                scroll.scrollWheel(with: wheel)
                try await settle()
                try #require(!model.rowState.visibleIDs.isEmpty)
            }
            try #require(model.rowState.visibleIDs.contains(destination.id))
        }

        model.move(direction * (model.results.count - 1))
        try await settle()
        try #require(model.rowState.visibleIDs.contains(last.id))
        panel.orderOut(nil)
        model.prepareForShow(opensAbove: opensAbove)
        panel.orderFrontRegardless()
        try await settle()
        #expect(model.rowState.visibleIDs.contains(first.id))
        #expect(model.results.count == 212)
    }

    @Test func opensAboveMixedTextAndImagesReversalsHaveNoBottomGapOrSlowdown() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ClipboardStore(directory: directory)
        defer {
            store.saveNow()
            try? FileManager.default.removeItem(at: directory)
        }

        let pngs: [(Data, CGSize)] = [
            (try makePNG(width: 1440, height: 900, hue: 0.05), CGSize(width: 1440, height: 900)),
            (try makePNG(width: 1200, height: 400, hue: 0.35), CGSize(width: 1200, height: 400)),
            (try makePNG(width: 600, height: 600, hue: 0.60), CGSize(width: 600, height: 600)),
        ]
        // 213 条混合记录：底端偏向短文字，上方穿插大量图片与两行长文字，专门考验行高估算与底端锚点。
        for n in 1...213 {
            let now = Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 60)
            if n <= 185 && (n % 2 == 0 || (n >= 50 && n <= 120)) {
                let sample = pngs[n % pngs.count]
                store.add(.init(kind: .image, png: sample.0, imageSize: sample.1, fingerprint: "img-\(n)"),
                          maxItems: 250, now: now)
            } else if n % 3 == 0 {
                let text = "Item #\(n) — " + String(repeating: "这是一段包含中英文混合的剪贴板历史文字 ", count: 4)
                store.add(.init(kind: .text, text: text, fingerprint: "long-\(n)"), maxItems: 250, now: now)
            } else {
                store.add(.init(kind: .text, text: "Short #\(n)", fingerprint: "short-\(n)"), maxItems: 250, now: now)
            }
        }
        for (i, item) in store.sortedItems.prefix(12).enumerated() {
            if i == 1 || i == 5 { store.togglePin(item.id) }
            if i == 0 || i == 4 { store.setNote("备注 #\(i)", for: item.id) }
        }

        let model = ClipboardPanelModel(store: store)
        model.prepareForShow(opensAbove: true)
        #expect(model.results.count == 213)
        let first = try #require(model.results.first)

        let panel = ClipboardPanel()
        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setFrame(NSRect(origin: CGPoint(x: -4000, y: 0), size: ClipboardPanel.size), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        func settle(_ ms: Int = 16) async throws {
            try await Task.sleep(for: .milliseconds(ms))
            host.layoutSubtreeIfNeeded()
        }

        try await settle(150)
        let scroll = try #require(findScrollView(in: host))
        let clip = scroll.contentView
        let initialDocHeight = try #require(scroll.documentView?.frame.height)
        #expect(model.rowState.visibleIDs.contains(first.id))
        #expect(measureBottomBlankPoints(host: host, scroll: scroll) <= 25)

        var panelChanges = 0
        let changes = model.objectWillChange.sink { panelChanges += 1 }
        defer { changes.cancel() }

        // 1. 触控板快速向上再反复向下滑动（包含到达底部后的弹性越界）。
        for _ in 1...3 {
            scroll.scrollWheel(with: try trackpadEvent(deltaY: 0, phase: 1))
            try await settle(4)
            for _ in 1...12 {
                scroll.scrollWheel(with: try trackpadEvent(deltaY: 220, phase: 2))
                try await settle(8)
            }
            scroll.scrollWheel(with: try trackpadEvent(deltaY: 0, phase: 4))
            try await settle(30)
        }

        var maxDocDelta: CGFloat = 0
        for swipe in 1...5 {
            scroll.scrollWheel(with: try trackpadEvent(deltaY: 0, phase: 1))
            try await settle(4)
            for _ in 1...14 {
                let beforeH = scroll.documentView?.frame.height ?? 0
                scroll.scrollWheel(with: try trackpadEvent(deltaY: -220, phase: 2))
                try await settle(8)
                let afterH = scroll.documentView?.frame.height ?? 0
                maxDocDelta = max(maxDocDelta, abs(afterH - beforeH))
            }
            scroll.scrollWheel(with: try trackpadEvent(deltaY: 0, phase: 4))
            try await settle(350)
            let docH = scroll.documentView?.frame.height ?? 0
            let maxY = max(0, docH - clip.bounds.height)
            #expect(!model.rowState.visibleIDs.isEmpty)
            if swipe >= 4 {
                #expect(model.rowState.visibleIDs.contains(first.id))
                #expect(abs(maxY - clip.bounds.origin.y) <= 2)
                #expect(measureBottomBlankPoints(host: host, scroll: scroll) <= 25)
            }
        }

        // 2. 离散鼠标滚轮（按行单位）反复向上/向下换向，确认无异常空白且向下不降速。
        for cycle in 1...3 {
            let ticks = cycle * 24
            for _ in 0..<ticks {
                scroll.scrollWheel(with: try lineWheelEvent(lines: 6))
                try await settle(12)
            }
            try await settle(80)
            let afterUpMaxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            #expect(clip.bounds.origin.y < afterUpMaxY - 200)

            var movedDown: CGFloat = 0
            var measured = 0
            for _ in 0..<(ticks + 16) {
                let beforeY = clip.bounds.origin.y
                let beforeH = scroll.documentView?.frame.height ?? 0
                scroll.scrollWheel(with: try lineWheelEvent(lines: -6))
                try await settle(12)
                let afterY = clip.bounds.origin.y
                let afterH = scroll.documentView?.frame.height ?? 0
                maxDocDelta = max(maxDocDelta, abs(afterH - beforeH))
                let maxY = max(0, afterH - clip.bounds.height)
                if beforeY < maxY - 120 {
                    movedDown += (afterY - beforeY)
                    measured += 1
                }
            }
            try await settle(150)
            #expect(measured > 0)
            #expect(movedDown / CGFloat(max(measured, 1)) >= 45)
            let finalMaxY = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            #expect(abs(finalMaxY - clip.bounds.origin.y) <= 2)
            #expect(model.rowState.visibleIDs.contains(first.id))
            #expect(measureBottomBlankPoints(host: host, scroll: scroll) <= 25)
        }

        let finalDocHeight = try #require(scroll.documentView?.frame.height)
        #expect(abs(finalDocHeight - initialDocHeight) <= 32)
        #expect(maxDocDelta <= 25)
        #expect(panelChanges == 0)
    }

    @Test func shortListAlignsToSearchEdgeAndRestoresSelectionAfterPreviewToggle() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ClipboardStore(directory: directory)
        defer {
            store.saveNow()
            try? FileManager.default.removeItem(at: directory)
        }
        store.add(.init(kind: .text, text: "Older", fingerprint: "o"), maxItems: 50, now: Date(timeIntervalSince1970: 100))
        store.add(.init(kind: .text, text: "Newer", fingerprint: "n"), maxItems: 50, now: Date(timeIntervalSince1970: 200))

        let model = ClipboardPanelModel(store: store)
        model.prepareForShow(opensAbove: true)
        let panel = ClipboardPanel()
        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setFrame(NSRect(origin: CGPoint(x: -4000, y: 0), size: ClipboardPanel.size), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        func settle() async throws {
            try await Task.sleep(for: .milliseconds(70))
            host.layoutSubtreeIfNeeded()
        }

        try await settle()
        let scroll = try #require(findScrollView(in: host))
        // 向上展开且条目不足一屏时，内容靠底贴近分类栏。
        #expect(measureBottomBlankPoints(host: host, scroll: scroll) <= 25)

        // 窄屏下开关预览会卸载再重建列表，恢复后仍应定位到当前选中项。
        for n in 1...40 {
            store.add(.init(kind: .text, text: "Extra \(n)", fingerprint: "e-\(n)"), maxItems: 60,
                      now: Date(timeIntervalSince1970: 300 + Double(n)))
        }
        model.prepareForShow(opensAbove: true)
        panel.setFrame(NSRect(origin: CGPoint(x: -4000, y: 0), size: CGSize(width: 334, height: 240)), display: false)
        try await settle()
        model.move(-30)
        let target = try #require(model.selectedItem)
        try await settle()
        #expect(model.rowState.visibleIDs.contains(target.id))

        model.setPreviewOpen(true)
        try await settle()
        #expect(model.rowState.visibleIDs.isEmpty)

        model.setPreviewOpen(false)
        try await settle()
        #expect(model.rowState.visibleIDs.contains(target.id))
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap { findScrollView(in: $0) }.first
    }

    private func wheelEvent(_ delta: Int) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: Int32(delta), wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    private func lineWheelEvent(lines: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: lines, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: event))
    }

    private func trackpadEvent(deltaY: Double, phase: Int64, momentum: Int64 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: Int32(deltaY.rounded()), wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
        cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: cg))
    }

    private func makePNG(width: Int, height: Int, hue: CGFloat) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedHue: hue, saturation: 0.5, brightness: 0.75, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func measureBottomBlankPoints(host: NSView, scroll: NSScrollView) -> CGFloat {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scrollFrame = scroll.convert(scroll.bounds, to: host)
        let scale = CGFloat(rep.pixelsWide) / max(host.bounds.width, 1)
        let topY = host.isFlipped ? scrollFrame.minY : (host.bounds.height - scrollFrame.maxY)
        let botY = host.isFlipped ? scrollFrame.maxY : (host.bounds.height - scrollFrame.minY)
        let topPx = Int(round(topY * scale))
        let botPx = Int(round(botY * scale))
        let xStart = Int(round((scrollFrame.minX + 12) * scale))
        let xEnd = Int(round((scrollFrame.maxX - 12) * scale))
        guard botPx > topPx + 4, xEnd > xStart else { return -1 }
        guard let bg = rep.colorAt(x: xStart, y: max(topPx, botPx - 2))?.usingColorSpace(.deviceRGB) else { return -1 }
        func isBg(_ y: Int) -> Bool {
            var x = xStart
            while x < xEnd {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let diff = abs(c.redComponent - bg.redComponent)
                        + abs(c.greenComponent - bg.greenComponent)
                        + abs(c.blueComponent - bg.blueComponent)
                    if diff > 0.03 { return false }
                }
                x += 4
            }
            return true
        }
        var blankPx = 0
        var y = botPx - 1
        while y > topPx {
            if isBg(y) { blankPx += 1 } else { break }
            y -= 1
        }
        return CGFloat(blankPx) / scale
    }
}
