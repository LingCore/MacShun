// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
@testable import MacShun

@Suite("搜索结果布局", .serialized)
@MainActor
struct FileSearchLayoutTests {
    @Test func draggedPositionKeepsThePanelReachableAndRestoresTheCompactAnchor() throws {
        let inUse = CGRect(x: -1024, y: 24, width: 1024, height: 704)
        let position = FileSearchWindowPosition(point: CGPoint(x: -390, y: 402))
        let reopened = try JSONDecoder().decode(FileSearchWindowPosition.self, from: JSONEncoder().encode(position))
        #expect(reopened.isOn(inUse))
        #expect(!reopened.isOn(CGRect(x: 0, y: 0, width: 1440, height: 900)))
        let expanded = reopened.frame(size: CGSize(width: 920, height: 600), in: inUse)
        #expect(inUse.contains(expanded))
        #expect(expanded.minY == inUse.minY)
        let compact = reopened.frame(size: CGSize(width: 640, height: 80), in: inUse)
        #expect(compact.midX == position.point.x && compact.maxY == position.point.y)
    }

    @Test func resizingKeepsTheTopLeftAnchorAndClampsToTheDisplay() throws {
        let workArea = CGRect(x: 0, y: 0, width: 1440, height: 860)
        let frame = CGRect(x: 250, y: 180, width: 920, height: 600)
        let larger = FileSearchExpandedGeometry.resizedFrame(frame, by: CGSize(width: 450, height: -400), in: workArea)
        #expect(larger == CGRect(x: 250, y: 0, width: 1190, height: 780))
        let smaller = FileSearchExpandedGeometry.resizedFrame(frame, by: CGSize(width: -850, height: 515), in: workArea)
        #expect(smaller == CGRect(x: 250, y: 470, width: 420, height: 310))
        let saved = FileSearchExpandedGeometry(position: .init(frame: smaller), size: smaller.size)
        let decoded = try JSONDecoder().decode(FileSearchExpandedGeometry.self, from: JSONEncoder().encode(saved))
        #expect(decoded.position.frame(size: decoded.size, in: workArea) == smaller)
    }

    @Test func dragMovesTheNativePanelAndCommitsItsPositionOnceAtMouseUp() throws {
        _ = NSApplication.shared
        let panel = FileSearchPanel()
        let initial = panel.frame.origin
        var moves: [Bool] = []
        var releases = 0
        panel.onHandleDragEnded = { moves.append($0) }
        let start = NSPoint(x: 200, y: 30)
        panel.beginHandleDrag(at: panel.convertPoint(toScreen: start)) { releases += 1 }
        func mouseEvent(_ type: NSEvent.EventType, location: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        panel.sendEvent(try mouseEvent(.leftMouseDragged, location: NSPoint(x: 280, y: 65)))
        #expect(panel.isDraggingFromHandle)
        #expect(panel.frame.origin == NSPoint(x: initial.x + 80, y: initial.y + 35))
        #expect(moves.isEmpty)
        #expect(releases == 0)
        panel.sendEvent(try mouseEvent(.leftMouseUp, location: start))
        panel.endHandleDrag()
        #expect(!panel.isDraggingFromHandle)
        #expect(moves == [true])
        #expect(releases == 1)
    }

    @Test(arguments: [CGFloat(640), CGFloat(420)], [false, true])
    func firstResultStaysBelowSearchWhenPanelExpands(_ width: CGFloat, _ dark: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = FileSearchModel(index: FileIndex.shared, contentIndex: ContentIndex(directory: directory), pinDefaults: nil)
        let view = FileSearchView(model: model, index: FileIndex.shared, contentIndex: ContentIndex.shared)
            .environment(\.sizeCategory, width < 500 ? .accessibilityExtraExtraExtraLarge : .large)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: 80),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()
        let results = (0..<20).map { FileSearchResult(path: "/tmp/sample-\($0).txt", name: "sample-\($0).txt", isDirectory: false, score: 1) }
        try await Task.sleep(for: .milliseconds(100))
        model.showPreview(query: "sample", results: results)
        // Results arrive while the native window still has its collapsed height.
        try await Task.sleep(for: .milliseconds(100))
        let fullHeight = FileSearchView.height(resultCount: results.count, hasSectionHeader: false,
                                               showsStatus: false, typeAreaHeight: model.compactLayout.visible.fileTypes)
        window.setContentSize(NSSize(width: width, height: fullHeight))
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        try await Task.sleep(for: .milliseconds(100))
        try checkFirstRow(model, phase: "expanded")
        model.selection = results.count - 1
        try await Task.sleep(for: .milliseconds(100))
        model.selection = 0
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try checkFirstRow(model, phase: "returned to first")
        window.setContentSize(NSSize(width: width, height: 260))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) { host.cacheDisplay(in: host.bounds, to: rep) }
        try await Task.sleep(for: .milliseconds(150))
        try checkFirstRow(model, phase: "compact height")
    }

    private func checkFirstRow(_ model: FileSearchModel, phase: String) throws {
        let button = try #require(model.buttonFrames[.init(path: "/tmp/sample-0.txt", button: .copy)])
        // The 22pt button is centered in a 46pt row; check the entire row.
        let top = button.minY - (FileSearchView.rowHeight - button.height) / 2
        let header = FileSearchView.compactHeaderHeight(inFolder: model.folder != nil, typeAreaHeight: model.compactLayout.visible.fileTypes)
        #expect(top >= FileSearchView.margin + header + FileSearchView.gap, "\(phase)")
    }

    @Test(arguments: [CGFloat(920), CGFloat(420)], [false, true])
    func selectedResultRemainsVisibleAfterCollapsingTheSearchPanel(_ width: CGFloat, _ dark: Bool) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for number in 1...67 {
            try Data(count: number * 1500).write(to: directory.appendingPathComponent("report-\(number).pdf"))
        }
        let index = FileIndex(mainRoots: [])
        let contentIndex = ContentIndex(directory: directory.appendingPathComponent("db"))
        let model = FileSearchModel(index: index, contentIndex: contentIndex)
        model.isShown = true
        model.toggleExpanded()
        model.setFilterFolder(directory.path)
        model.panelOptions = FileSearchOptions(kind: .pdf, modified: .week, size: .underMB, order: .largest)
        #expect(model.saveFilters(named: "本周的项目 PDF"))
        model.query = "report"
        let view = FileSearchView(model: model, index: index, contentIndex: contentIndex)
            .environment(\.sizeCategory, width < 500 ? .accessibilityExtraExtraExtraLarge : .large)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        let deadline = ContinuousClock.now + .seconds(4)
        while model.results.count != 60, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.results.count == 60)
        #expect(model.results.first?.name == "report-67.pdf")
        #expect(model.hasMoreResults)
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()

        // The native triggers must fill the custom rows, including in the narrow top strip.
        let labels = Set([L("修改时间"), L("大小"), L("目录")])
        func menuButtons(in view: NSView) -> [NSButton] {
            if let button = view as? NSButton, labels.contains(button.accessibilityLabel() ?? "") { return [button] }
            return view.subviews.flatMap { menuButtons(in: $0) }
        }
        let buttons = menuButtons(in: host)
        #expect(buttons.count == labels.count)
        let minimumHeight: CGFloat = width < 500 ? 25 : 28
        #expect(buttons.allSatisfy { $0.bounds.height >= minimumHeight })

        model.selection = model.results.count - 1
        let selectedPath = try #require(model.selectedResult?.path)
        let loaded = ContinuousClock.now + .seconds(3)
        while model.results.count != 67, ContinuousClock.now < loaded { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.results.count == 67)
        #expect(model.selectedResult?.path == selectedPath)
        let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "\u{05}", charactersIgnoringModifiers: "e",
                                                      isARepeat: false, keyCode: KeyCode.e))
        #expect(model.handlePanelKey(shortcut))
        #expect(!model.isExpanded)
        window.setContentSize(NSSize(width: min(width, 640), height: 370))
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        let button = try #require(model.buttonFrames[.init(path: selectedPath, button: .copy)])
        #expect(model.selectedResult?.path == selectedPath)
        #expect(model.query == "report")
        #expect(button.minY > FileSearchView.capsuleHeight + FileSearchView.margin + FileSearchView.gap)
        #expect(button.maxY < host.bounds.height - 36)

    }
}
