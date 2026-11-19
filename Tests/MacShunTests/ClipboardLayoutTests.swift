// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

struct ClipboardLayoutTests {
    private let visible = CGRect(x: -1024, y: 42, width: 1024, height: 764)

    @Test func prefersBelowAndUsesAvailableHeightBeforeOverlappingTheAnchor() {
        let caret = CGRect(x: -600, y: 447, width: 0, height: 20)
        let placement = ClipboardPanelPlacement(anchor: caret, gap: 12, visibleFrame: visible)

        #expect(!placement.opensAbove)
        #expect(placement.frame.minX == caret.minX)
        #expect(placement.frame.maxY == caret.minY - 12)
        #expect(placement.frame.minY == visible.minY + 8)
        #expect(placement.frame.height < ClipboardPanel.size.height)
    }

    @Test func opensAboveNearTheDockAndClampsAtTheDisplayEdge() {
        let caret = CGRect(x: -60, y: 110, width: 0, height: 20)
        let placement = ClipboardPanelPlacement(anchor: caret, gap: 12, visibleFrame: visible)

        #expect(placement.opensAbove)
        #expect(placement.frame.minY == caret.maxY + 12)
        #expect(placement.frame.maxX == visible.maxX - 8)
        #expect(placement.frame.height == ClipboardPanel.size.height)
    }

    @Test func keepsTheWindowInsideACompactWorkArea() {
        let visible = CGRect(x: 0, y: -260, width: 350, height: 260)
        let searchBar = CGRect(x: 55, y: -158, width: 230, height: 56)
        let placement = ClipboardPanelPlacement(anchor: searchBar, gap: 4, visibleFrame: visible)

        #expect(visible.insetBy(dx: 8, dy: 8).contains(placement.frame))
        #expect(placement.frame.width == 334)
        #expect(placement.frame.height == 240)
    }

    @Test @MainActor func keyboardSelectionMovesInTheVisibleDirection() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ClipboardStore(directory: directory)
        defer {
            store.saveNow()
            try? FileManager.default.removeItem(at: directory)
        }
        store.add(.init(kind: .text, text: "Older", fingerprint: "older"), maxItems: 10)
        store.add(.init(kind: .text, text: "Newer", fingerprint: "newer"), maxItems: 10)
        let model = ClipboardPanelModel(store: store)

        model.prepareForShow(opensAbove: true)
        #expect(model.selectedItem?.text == "Newer")
        model.move(-1)
        #expect(model.selectedItem?.text == "Older")
        model.move(1)
        #expect(model.selectedItem?.text == "Newer")

        model.prepareForShow()
        model.move(1)
        #expect(model.selectedItem?.text == "Older")
    }

    @Test @MainActor func quickPasteTracksVisibleRowsFromTheSearchEdge() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ClipboardStore(directory: directory)
        defer {
            store.saveNow()
            try? FileManager.default.removeItem(at: directory)
        }
        for n in 1...12 {
            store.add(.init(kind: .text, text: "Row \(n)", fingerprint: "\(n)"), maxItems: 12,
                      now: Date(timeIntervalSince1970: Double(n)))
        }
        let model = ClipboardPanelModel(store: store)
        model.prepareForShow(opensAbove: true)
        model.showsQuickPasteNumbers = true
        let rows = model.results
        model.updateVisibleRows(Set(rows.dropFirst(2).map(\.id)))
        #expect(model.quickPasteNumber(for: rows[0].id) == nil)
        #expect(model.quickPasteNumber(for: rows[2].id) == 1)
        #expect(model.quickPasteNumber(for: rows.last!.id) == nil)

        var pasted: ClipboardItem?
        model.onPaste = { pasted = $0 }
        model.updateVisibleRows(Set(rows.dropFirst(3).map(\.id)))
        model.pasteVisibleRow(1)
        #expect(pasted == rows[3])
        model.pasteVisibleRow(10)
        #expect(pasted == rows[3])
    }
}
