// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("点号文件搜索")
struct HiddenFileSearchTests {
    private func makeRoot() throws -> URL {
        // FSEvents 使用物理路径；系统临时目录常写作 /var，实际位于 /private/var。
        let base = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(base) }
        let root = URL(fileURLWithPath: String(cString: base)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func bothScannersKeepDotNamesAndRespectTraversalBoundaries() throws {
        let fm = FileManager.default
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        for name in [".codex", ".git", ".Trashes", "HiddenByFinder", "Example.app"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var flagged = root.appendingPathComponent("HiddenByFinder")
        var attributes = URLResourceValues()
        attributes.isHidden = true
        try flagged.setResourceValues(attributes)
        for name in [".gitignore", ".DS_Store", "._report", ".localized"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent(".link"), withDestinationURL: root)

        for read in [FileSearchDirectory.read, FileSearchDirectory.readDrive] {
            let listing = try #require(read(root.path))
            let entries = listing.entries
            #expect(Set(entries.indices.map { entries.name(at: $0) }) == [".codex", ".git", ".gitignore", "Example.app", ".link"])
            #expect(listing.subfolders == [root.appendingPathComponent(".codex").path])
            #expect(entries.containsFolder(named: ".codex"))
            #expect(!entries.containsFolder(named: ".git"))
            #expect(!entries.containsFolder(named: ".link"))
        }
    }

    @MainActor
    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test @MainActor func searchPanelFindsHiddenNamesWithoutReadingTheirContents() async throws {
        let fm = FileManager.default
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        let config = files.appendingPathComponent(".codex")
        for directory in [config, files.appendingPathComponent(".codex-backup"), files.appendingPathComponent("work")] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let hiddenNote = config.appendingPathComponent("note.txt")
        let visibleNote = files.appendingPathComponent("work/note.txt")
        for file in [hiddenNote, visibleNote, files.appendingPathComponent(".private.txt")] {
            try "uniquetestmarker".write(to: file, atomically: true, encoding: .utf8)
        }
        let index = FileIndex(mainRoots: [files.path])
        index.includeExternalDrives = false
        let content = ContentIndex(directory: root.appendingPathComponent("index"))
        content.start()
        index.setContentIndex(content)
        index.start()
        defer {
            index.stop()
            content.stop(deleteData: true)
            content.waitUntilIdle()
        }

        let model = FileSearchModel(index: index, contentIndex: content)
        model.isShown = true
        model.query = ".codex"
        try await waitFor { model.results.first?.path == config.path }
        #expect(model.results.first?.isDirectory == true)
        #expect(model.results.first?.name == ".codex")
        #expect(model.results.count == 2)
        // 面板发起新查询时，独立调用方仍能收到自己那一次的结果。
        var directHit: String?
        index.search(".codex") { directHit = $0.first?.path }
        model.query = ".private.txt"
        try await waitFor { model.results.first?.name == ".private.txt" && directHit == config.path }
        model.query = "note.txt"
        try await waitFor { model.results.map(\.path) == [visibleNote.path, hiddenNote.path] }
        model.query = ".codex/note.txt"
        try await waitFor { model.results.first?.path == hiddenNote.path }
        model.query = "."
        try await waitFor { model.results.count == 3 && model.results.allSatisfy { $0.name.hasPrefix(".") } }

        content.waitUntilIdle()
        #expect(content.searchNow("uniquetestmarker").map(\.path) == [visibleNote.path])

        // 关键词不变、条目总数也不变。改名应刷新已打开的面板。
        model.query = ".private.txt"
        try await waitFor { model.results.first?.name == ".private.txt" }
        try fm.moveItem(at: files.appendingPathComponent(".private.txt"), to: files.appendingPathComponent(".renamed.txt"))
        try await waitFor { model.results.isEmpty }
        model.query = ".renamed.txt"
        try await waitFor { model.results.first?.name == ".renamed.txt" }
    }
}
