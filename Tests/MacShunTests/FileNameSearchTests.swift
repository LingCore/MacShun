// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("文件名与目录搜索")
struct FileNameSearchTests {
    private func entries(_ names: [String]) -> FolderEntries {
        FolderEntries(names.map { FileEntry(name: $0, isDirectory: false, isPackage: false) })
    }

    private func search(_ text: String, in folders: [String: FolderEntries] = [:], limit: Int = 60,
                        boosts: [String: Double] = [:], finder: String? = nil) throws -> FileNameSearch.Page {
        try #require(FileNameSearch(query: .init(text), limit: limit, boosts: boosts, preferredFolder: finder)
            .run(in: folders, isCancelled: { false }))
    }

    @Test func mixesWordsFromTheNameAndItsAncestorsInEitherOrder() throws {
        let folders = ["/Documents/春季项目/客户": entries(["报价单.xlsx", "说明.txt"]),
                       "/Documents/秋季项目": entries(["报价单.xlsx"]),
                       "/archive": entries(["春季报价说明.pdf"])]
        let spring = "/Documents/春季项目/客户/报价单.xlsx"
        #expect(try search("春季 报价单", in: folders).results.map(\.path) == [spring])
        #expect(try search("报价单 春季", in: folders).results.map(\.path) == [spring])
        #expect(try search("文稿 春季 bjd", in: folders).results.map(\.path) == [spring])
        #expect(try search("报价单", in: folders).results.count == 2)
        #expect(try search("春季 客户", in: folders).results.isEmpty)
        #expect(try search("春季", in: folders).results.map(\.name) == ["春季报价说明.pdf"])
    }

    @Test func exactNamesPrecedeBoostedPrefixesAndPreferTheFinderFolder() throws {
        let folders = ["/A": entries(["Release Note.md", "Release Note.md.backup", ".config-old", ".config"]),
                       "/B": entries(["Release Note.md"])]
        let boosts = ["/A/Release Note.md": 24.0, "/A/Release Note.md.backup": 24.0, "/A/.config-old": 24.0]
        let hits = try search("release note.MD", in: folders, boosts: boosts, finder: "/B").results
        #expect(hits.map(\.path) == ["/B/Release Note.md", "/A/Release Note.md", "/A/Release Note.md.backup"])
        #expect(try search(".config", in: folders, limit: 1, boosts: boosts).results.first?.name == ".config")
        #expect(try search("release note.md", in: folders, limit: 1, boosts: boosts).results.first?.path == "/A/Release Note.md")
    }

    @Test func finderVisibleAppNamesAndRealApostrophesAreExact() throws {
        let entries = FolderEntries([
            FileEntry(name: "Notes.app", isDirectory: true, isPackage: true),
            FileEntry(name: "Notes", isDirectory: true, isPackage: false),
            FileEntry(name: "James'", isDirectory: false, isPackage: false),
            FileEntry(name: "James", isDirectory: false, isPackage: false),
        ])
        #expect(try search("Notes", in: ["/a": entries]).results.first?.name == "Notes.app")
        #expect(try search("James'", in: ["/a": entries]).results.first?.name == "James'")
    }

    @Test @MainActor func immediateReturnUsesTheNewQueryAndClosingCancelsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["first.txt", "second.txt"] { try Data().write(to: root.appendingPathComponent(name)) }

        let index = FileIndex(mainRoots: [])
        let content = ContentIndex(directory: root.appendingPathComponent("unused"))
        let model = FileSearchModel(index: index, contentIndex: content)
        var opened: [String] = []
        model.onAction = { result, _ in opened.append(result.name) }
        model.isShown = true
        func waitForName(_ name: String) async throws {
            let deadline = ContinuousClock.now + .seconds(4)
            while model.results.first?.name != name, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(model.results.first?.name == name)
        }
        model.query = root.path + "/first"
        try await waitForName("first.txt")
        model.query = root.path + "/second"
        model.openSelected(reveal: false)
        try await waitForName("second.txt")
        #expect(opened == ["second.txt"])
        model.query = root.path + "/first"
        model.openSelected(reveal: false)
        model.isShown = false
        try await waitForName("first.txt")
        #expect(opened == ["second.txt"])
    }

    @Test func topResultsEqualFullSortAfterDeduplication() {
        let candidates = (0..<239).map { n in
            FileSearchResult(path: "/\(n % 101)", name: "a", isDirectory: false, score: Double(n * 11 % 17))
        }
        let unique = Dictionary(grouping: candidates, by: \.path).values.compactMap { $0.max { $0.score < $1.score } }
        let sorted = unique.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
        for limit in [0, 1, 2, 60, 300] {
            var best = BestFileResults(limit: limit)
            for row in candidates { best.add(row) }
            #expect(best.sorted() == Array(sorted.prefix(limit)))
        }
    }

    @Test @MainActor func returnInAllWaitsForCurrentContentInsteadOfOpeningAnOldHit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.txt"), second = root.appendingPathComponent("two.txt")
        try Data("orange fruit".utf8).write(to: first)
        try Data("banana fruit".utf8).write(to: second)
        let content = ContentIndex(directory: root.appendingPathComponent("db"))
        content.start()
        content.sync(files: [first.path, second.path], scopes: [.init(folder: root.path, recursive: true)])
        content.waitUntilIdle()
        defer { content.stop(deleteData: true); content.waitUntilIdle() }
        let model = FileSearchModel(index: FileIndex(mainRoots: []), contentIndex: content)
        model.isShown = true
        model.searchesContent = true
        model.scope = .all
        var opened: [String] = []
        model.onAction = { result, _ in opened.append(result.name) }
        model.query = "orange"
        let deadline = ContinuousClock.now + .seconds(5)
        while model.results.first?.path != first.path, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(model.results.first?.path == first.path)
        model.query = "banana"
        model.openSelected(reveal: false)
        while opened.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(opened == ["two.txt"])
    }

    @Test func browsesOnlyImmediateChildrenIncludingOutsideTheIndex() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("My Files")
        try fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root.deletingLastPathComponent()) }
        for name in ["note10.txt", "note2.txt", ".profile", "Folder/note3.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let elsewhere = ["/elsewhere": entries(["note-other.txt"])]
        let children = try search(root.path + "/", in: elsewhere)
        #expect(children.directory == .listing)
        #expect(children.results.first?.name == "Folder")
        #expect(children.results.map(\.name).filter { $0.hasPrefix("note") } == ["note2.txt", "note10.txt"])
        #expect(children.results.contains { $0.name == ".profile" })
        let partial = try search(root.path + "/note", in: elsewhere)
        #expect(Set(partial.results.map(\.name)) == ["note2.txt", "note10.txt"])
        #expect(try search(root.absoluteString + "/", in: elsewhere).results == children.results)
        #expect(try search(root.path + "/note2.txt", in: elsewhere).results.first?.path == root.path + "/note2.txt")
        #expect(try search(root.path + "/absent", in: elsewhere).directory == .listing)
        #expect(try search(root.path + "/missing/", in: elsewhere).directory == .unavailable)
    }

    @Test func homeSlashAndRootDescribeDirectoryContents() {
        #expect(FileMatcher.Query("~/").directoryInput?.folder == NSHomeDirectory())
        #expect(FileMatcher.Query("/").directoryInput?.listsChildren == true)
        #expect(FileMatcher.Query("~/Library/con").directoryInput?.folder == NSHomeDirectory() + "/Library")
        #expect(FileMatcher.Query(#"D:\资料\报价"#).directoryInput == nil)
        #expect(FileMatcher.Query("art/gpt/").directoryInput == nil)
    }

    @Test func relativePathsAndFinderSlashKeepTheirFallbacks() throws {
        let folders = ["/Workspace/Art": entries(["Report.pdf", "AC:DC.mp3"]), "/Other": entries(["Report.pdf"])]
        #expect(try search("art/report", in: folders).results.map(\.path) == ["/Workspace/Art/Report.pdf", "/Other/Report.pdf"])
        #expect(try search("AC/DC", in: folders).results.map(\.name) == ["AC:DC.mp3"])
        #expect(try search(#"D:\Art\Report.pdf"#, in: folders).results.first?.path == "/Workspace/Art/Report.pdf")
    }
}
