// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Testing
@testable import MacShun

@Suite("搜索结果布局", .serialized)
@MainActor
struct FileSearchLayoutTests {
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
        window.setContentSize(NSSize(width: width, height: FileSearchView.height(resultCount: results.count, hasSectionHeader: false, showsStatus: false)))
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
        #expect(top >= FileSearchView.margin + FileSearchView.capsuleHeight + FileSearchView.gap, "\(phase)")
    }
}
