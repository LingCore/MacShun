// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("文件名和全文筛选")
struct FileFilterTests {
    private let sample = [
        "/春季报价": FolderEntries(["定稿.PDF", "草稿.pdf", "说明.docx", ".pdf", "归档.tar.gz", "归档.gz"].map {
            FileEntry(name: $0, isDirectory: false, isPackage: false)
        } + [FileEntry(name: "客户.pdf", isDirectory: true, isPackage: false)]),
        "/Other": FolderEntries(["报价.PDF.bak", "报价.docx", "!重要", "ext:pdf,"].map {
            FileEntry(name: $0, isDirectory: false, isPackage: false)
        }),
    ]

    private func names(_ query: String) throws -> Set<String> {
        let search = FileNameSearch(query: .init(query), limit: 60, boosts: [:], preferredFolder: nil)
        let page = try #require(search.run(in: sample, isCancelled: { false }))
        return Set(page.results.map(\.name))
    }

    @Test func extensionQualifiesTheLeafAndExclusionsApplyToNames() throws {
        #expect(try names("报价 *.pdf !草稿") == ["定稿.PDF"])
        #expect(try names("报价 EXT:pdf,docx !草稿") == ["定稿.PDF", "说明.docx", "报价.docx"])
        #expect(try names("*.pdf") == ["草稿.pdf", "定稿.PDF"])
        #expect(try names("*.tar.gz") == ["归档.tar.gz"])
        #expect(try names("!报价 *.docx") == ["说明.docx"])
        #expect(try names("/春季报价/*.pdf !草稿") == ["定稿.PDF"])
        #expect(try names("!重要").contains("!重要") == false)
    }

    @Test func quotesAndCopiedFileURLsPreserveLiteralNames() throws {
        #expect(try names("\"!重要\"") == ["!重要"])
        #expect(try names("ext:pdf,") == ["ext:pdf,"])
        #expect(FileMatcher.Query("file:///some/folder/!important").filters.isEmpty)
        #expect(FileMatcher.Query("/some/!folder/").filters.isEmpty)
        #expect(FileMatcher.Query("/some/!folder/file.txt").terms.map(\.text) == ["file.txt"])
        #expect(FileMatcher.Query(".codex").filters.isEmpty)
        #expect(FileMatcher.Query("*.").terms.map(\.text) == ["*."])
    }

    @Test func filteredContentCanBeFoundBeyondTheFirstThousandHits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ContentIndex(directory: root.appendingPathComponent("index"))
        var paths: [String] = []
        for i in 0..<1005 {
            let file = root.appendingPathComponent("\(i).txt")
            try Data("needle".utf8).write(to: file)
            paths.append(file.path)
        }
        let target = root.appendingPathComponent("报价.md")
        for file in [root.appendingPathComponent("草稿.md"), target] {
            try Data(("needle " + String(repeating: "notes ", count: 30)).utf8).write(to: file)
            paths.append(file.path)
        }
        index.start()
        defer { index.stop(deleteData: true); index.waitUntilIdle() }
        index.sync(files: paths, scopes: [.init(folder: root.path, recursive: true)])
        index.waitUntilIdle()
        #expect(index.documentCountNow == paths.count)
        #expect(index.searchNow("needle *.md !草稿", limit: 1).map(\.path) == [target.path])
        #expect(index.searchNow("*.md").isEmpty)
        #expect(index.searchNow(root.path + "/needle *.md !草稿").map(\.path) == [target.path])
        #expect(index.searchNow(root.appendingPathComponent("other").path + "/needle *.md").isEmpty)
        #expect(index.searchNow("needle ext:md !报价", limit: 1).first?.path.hasSuffix("/草稿.md") == true)
    }
}
