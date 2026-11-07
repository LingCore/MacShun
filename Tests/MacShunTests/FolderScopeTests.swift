// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@Suite("在文件夹及子文件夹中搜索")
struct FolderScopeTests {
    private struct Fixture {
        let base: URL
        let project: URL
        let sibling: URL
        let sub: URL
        let note: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            project = base.appendingPathComponent("Project")
            sibling = base.appendingPathComponent("Project-old")
            sub = project.appendingPathComponent("Specs")
            note = sub.appendingPathComponent("客户/报价.md")
            let fm = FileManager.default
            for dir in [note.deletingLastPathComponent(), sibling, project.appendingPathComponent("Demo.app"),
                        project.appendingPathComponent(".git")] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            for relative in ["Project/Specs/客户/报价.md", "Project/Specs/客户/报价草稿.md", "Project-old/报价.md",
                             "Project/.git/报价.md", "Project/Demo.app/报价.md", "Project/top.txt"] {
                try Data("quietneedle".utf8).write(to: base.appendingPathComponent(relative))
            }
            try fm.createSymbolicLink(at: project.appendingPathComponent("Alias"), withDestinationURL: sibling)
        }

        func cleanup() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func temporaryTreeUsesTheSameBoundariesAsTheIndexAndPicksUpRenames() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let area = FileSearchFolder(path: fixture.project.path)
        func search(_ q: String, in snapshot: [String: FolderEntries] = [:]) throws -> FileNameSearch.Page {
            try #require(FileNameSearch(query: .init(q), limit: 60, boosts: [:], preferredFolder: nil, within: area)
                .run(in: snapshot, isCancelled: { false }))
        }

        let children = try search("").results
        #expect(try search(fixture.project.path).results == children)
        if (try fixture.sub.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames == false {
            #expect(try search(fixture.project.path.lowercased() + "/sPeCs/客户/报").results.count == 2)
        }
        #expect(children.contains { $0.name == "Specs" && $0.canSearchInside })
        #expect(!children.contains { $0.name == "报价.md" })
        #expect(children.filter { ["Alias", "Demo.app", ".git"].contains($0.name) }.allSatisfy { !$0.canSearchInside })
        let query = "客户 报价 *.md !草稿"
        #expect(try search(query).results.map(\.path) == [fixture.note.path])
        #expect(try search(fixture.project.path + "/Specs/客户/报").results.count == 2)
        #expect(try search(fixture.sibling.path + "/报价.md").directory == .outsideFolder)
        #expect(try search(fixture.project.path + "/Alias/报价.md").results.isEmpty)
        #expect(try search(fixture.project.path + "/.git/报价.md").results.isEmpty)
        #expect(try search(fixture.project.path + "/Demo.app/").results.isEmpty)
        #expect(try search("Project-old 报价").results.isEmpty)

        var indexed: [String: FolderEntries] = [:]
        for dir in [fixture.project, fixture.sub, fixture.note.deletingLastPathComponent(), fixture.sibling] {
            indexed[dir.path] = try #require(FileSearchDirectory.read(dir.path)).entries
        }
        #expect(try search(query, in: indexed).results.map(\.path) == [fixture.note.path])
        try FileManager.default.moveItem(at: fixture.note, to: fixture.note.deletingLastPathComponent().appendingPathComponent("合同.md"))
        #expect(try search(query).results.isEmpty)
        #expect(try search("合同").results.count == 1)
        try FileManager.default.removeItem(at: fixture.project)
        #expect(try search("合同", in: indexed).directory == .unavailable)
    }

    @Test func fullTextRestrictsThePathBeforeTakingTheBestHits() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let index = ContentIndex(directory: fixture.base.appendingPathComponent("db"))
        let siblingNote = fixture.sibling.appendingPathComponent("报价.md")
        try Data(("quietneedle " + String(repeating: "more ", count: 100)).utf8).write(to: fixture.note)
        index.start()
        defer { index.stop(deleteData: true); index.waitUntilIdle() }
        index.sync(files: [siblingNote.path, fixture.note.path, fixture.project.appendingPathComponent("top.txt").path],
                   scopes: [.init(folder: fixture.base.path, recursive: true)])
        index.waitUntilIdle()
        #expect(index.searchNow("quietneedle *.md", limit: 1, within: fixture.project.path).map(\.path) == [fixture.note.path])
        #expect(index.searchNow("quietneedle", within: fixture.sub.path).map(\.path) == [fixture.note.path])
        #expect(index.searchNow("quietneedle *.md !报价", within: fixture.project.path).isEmpty)
        #expect(index.searchNow(fixture.sibling.path + "/quietneedle *.md", within: fixture.project.path).isEmpty)
    }

    @MainActor
    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test @MainActor func menuKeyboardAndEscapeRestoreEachVisitAndDiscardOldResults() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let content = ContentIndex(directory: fixture.base.appendingPathComponent("db"))
        content.start()
        defer { content.stop(deleteData: true); content.waitUntilIdle() }
        content.sync(files: [fixture.note.path, fixture.sibling.appendingPathComponent("报价.md").path],
                     scopes: [.init(folder: fixture.base.path, recursive: true)])
        content.waitUntilIdle()
        let model = FileSearchModel(index: FileIndex(mainRoots: []), contentIndex: content)
        model.searchesContent = true
        model.isShown = true
        model.scope = .all
        try FileManager.default.createDirectory(at: fixture.base.appendingPathComponent("Pro"), withIntermediateDirectories: true)
        let original = fixture.base.path + "/Pro"
        model.query = original
        try await waitFor { model.results.contains { $0.path == fixture.project.path } }
        let result = try #require(model.results.first { $0.path == fixture.project.path })
        #expect(model.results.first?.name == "Pro")
        let menu = try #require(model.contextMenu(for: result))
        let action = menu.indexOfItem(withTitle: L("在此文件夹中搜索"))
        try #require(action >= 0)
        menu.performActionForItem(at: action)
        try await waitFor { model.folder?.path == fixture.project.path && model.results.contains { $0.name == "Specs" } }
        #expect(model.query.isEmpty && !model.availableScopes.contains(.system))
        model.query = "蓝牙"
        #expect(model.rows.allSatisfy { $0.file != nil })
        model.scope = .contents
        model.query = "quietneedle"
        try await waitFor { model.results.map(\.path) == [fixture.note.path] && model.results.first?.snippet != nil }
        model.scope = .files
        model.query = "Specs"
        try await waitFor { model.selectedResult?.path == fixture.sub.path }
        let commandF = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: KeyCode.f))
        #expect(model.handleFolderKey(commandF))
        try await waitFor { model.folder?.path == fixture.sub.path && model.results.contains { $0.name == "客户" } }
        model.query = "报价 *.md !草稿"
        try await waitFor { model.results.map(\.path) == [fixture.note.path] }
        model.toggleQuickLook()
        try #require(model.isPreviewing)
        model.cancelSearch()
        #expect(!model.isPreviewing && model.folder?.path == fixture.sub.path)
        model.cancelSearch()
        try await waitFor { model.selectedResult?.path == fixture.sub.path && model.query == "Specs" }
        #expect(model.folder?.path == fixture.project.path)
        model.cancelSearch()
        try await waitFor { model.selectedResult?.path == fixture.project.path && model.query == original }
        #expect(model.folder == nil && model.scope == .all)

        model.searchInside(result)
        model.query = "quietneedle"
        model.scope = .contents
        model.isShown = false
        model.prepareForShow()
        #expect(model.folder == nil && model.query.isEmpty && model.rows.isEmpty)
    }
}
