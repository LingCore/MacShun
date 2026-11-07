// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@Suite("文件搜索快速查看")
@MainActor
struct FileQuickLookTests {
    private func key(_ code: CGKeyCode, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    @Test func previewsCurrentQueryAndReturnsToTheSameFile() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data("preview".utf8).write(to: root.appendingPathComponent(name)) }
        let model = FileSearchModel(index: FileIndex(mainRoots: []), contentIndex: ContentIndex(directory: root.appendingPathComponent("unused")))
        model.isShown = true
        model.query = root.path + "/*.txt"
        let original = model.query
        #expect(try model.handleQuickLookKey(key(KeyCode.y, "y", .command)))
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.isPreviewing, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.isPreviewing && model.selectedResult?.name == "a.txt")
        #expect(model.adjacentPreviewIndex(-1) == nil)
        #expect(try !model.handleQuickLookKey(key(KeyCode.space, " ")))
        #expect(try model.handleQuickLookKey(key(KeyCode.downArrow, "\u{F701}")))
        #expect(model.selectedResult?.name == "b.txt")
        #expect(model.adjacentPreviewIndex(1) == nil)
        #expect(try model.handleQuickLookKey(key(KeyCode.escape, "\u{1b}")))
        #expect(!model.isPreviewing && model.selectedResult?.name == "b.txt" && model.query == original)
        model.toggleQuickLook()
        model.remove(root.appendingPathComponent("b.txt").path)
        #expect(!model.isPreviewing)
        model.toggleQuickLook()
        #expect(model.isPreviewing)
        model.query = "new query"
        #expect(!model.isPreviewing)
        model.isShown = false
    }
}
