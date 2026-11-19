// SPDX-License-Identifier: MIT

import Combine
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

    @Test func cancelledDirectoryWalksDiscardIncompleteListingsAndBatches() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child"), withIntermediateDirectories: true)

        // 允许取出第一个目录，在读取目录项时取消。
        let checks = Locked(0)
        func cancelled() -> Bool { checks.update { $0 += 1; return $0 > 1 } }
        var listings: [String: FolderEntries] = [:], denied: [String] = []
        FileIndex.scanTree(root.path, into: &listings, denied: &denied, isCancelled: cancelled)
        #expect(listings.isEmpty && denied.isEmpty)
        checks.set(0)
        let published = Locked(false)
        FileIndex.scanTreesInParallel([root.path], threads: 1, isCancelled: cancelled) { _ in published.set(true) }
        #expect(!published.get())
    }

    @MainActor
    private func waitFor(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    @Test @MainActor func typingUsesPublishedNamesWhileIndexUpdatesAreBlocked() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("年度文档.txt")
        try Data().write(to: file)
        let writer = DispatchQueue(label: "FileSearchTests.index")
        let index = FileIndex(mainRoots: [root.path], indexQueue: writer)
        index.includeExternalDrives = false
        index.start()
        defer { index.stop() }
        try await waitFor { !index.isIndexing && index.fileCount == 1 }

        writer.suspend()
        defer { writer.resume() }
        let model = FileSearchModel(index: index, contentIndex: ContentIndex(directory: root.appendingPathComponent("unused")))
        model.isShown = true
        model.query = "年度"
        model.query = "ndwd"
        try await waitFor { !model.isLoadingResults && model.results.first?.path == file.path }
        model.query = "没有匹配文件"
        try await waitFor { !model.isLoadingResults && model.results.isEmpty }

        index.stop()
        model.query = "年度"
        try await waitFor { !model.isLoadingResults && model.results.isEmpty }
    }

    @Test @MainActor func firstQueryUpdatesAsLocalFoldersAreDiscovered() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("项目")
        let archived = project.appendingPathComponent("交付/春季归档校样")
        let hidden = root.appendingPathComponent(".往期/冬季归档校样")
        for url in [archived, hidden] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // 显式收录的子目录也是个人目录的后代，扫描与计数都只应发生一次。
        let index = FileIndex(mainRoots: [root.path, project.path], recentFolders: [])
        index.includeExternalDrives = false
        let model = FileSearchModel(index: index, contentIndex: ContentIndex(directory: root.appendingPathComponent("unused")))
        model.isShown = true
        model.query = "归档校样"
        var counts: [Int] = []
        let updates = index.$fileCount.sink { counts.append($0) }
        defer { updates.cancel(); index.stop() }
        index.start()
        try await waitFor { !index.isIndexing && Set(model.results.map(\.path)) == [archived.path, hidden.path] }
        #expect(counts.contains(3))
        #expect(index.fileCount == 5)
    }

    @Test @MainActor func newlyCreatedAndRenamedDesktopItemsAppearBeforeTheIndexQueueRuns() async throws {
        let fm = FileManager.default
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let desktop = root.appendingPathComponent("Desktop")
        let archive = root.appendingPathComponent("Archive")
        let name = "新建示例资料"
        let existing = archive.appendingPathComponent(name)
        for path in [desktop, existing] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }

        let writer = DispatchQueue(label: "FileSearchTests.freshDesktop")
        let index = FileIndex(mainRoots: [root.path], recentFolders: [desktop.path], indexQueue: writer)
        index.includeExternalDrives = false
        index.start()
        defer { index.stop() }
        try await waitFor { !index.isIndexing && index.fileCount == 3 }

        func results(_ query: String) async -> [FileSearchResult] {
            await withCheckedContinuation { continuation in
                index.search(query) { continuation.resume(returning: $0) }
            }
        }

        let content = ContentIndex(directory: root.appendingPathComponent("unused"))
        let model = FileSearchModel(index: index, contentIndex: content)
        model.isShown = true
        // 模拟刚建完就搜，索引还没收到或处理文件事件。别处已经有同名文件夹。
        do {
            writer.suspend()
            defer { writer.resume() }
            let fresh = desktop.appendingPathComponent(name)
            try fm.createDirectory(at: fresh, withIntermediateDirectories: false)
            let first = await results(name)
            #expect(Set(first.map(\.path)) == [existing.path, fresh.path])
            #expect(first.filter { !$0.isDirectory }.isEmpty)
            #expect(index.fileCount == 3)

            let renamed = desktop.appendingPathComponent("改名后的独立目录")
            try fm.moveItem(at: fresh, to: renamed)
            #expect(await results(name).map(\.path) == [existing.path])
            #expect(await results(renamed.lastPathComponent).map(\.path) == [renamed.path])
            model.query = renamed.lastPathComponent
            try await waitFor { model.results.first?.path == renamed.path }
            try fm.removeItem(at: renamed)
            #expect(await results(renamed.lastPathComponent).isEmpty)
        }

        // 创建和删除都发生在事件合并窗口内，索引数量没变，面板也应清除已消失的结果。
        try await waitFor { model.results.isEmpty }
        #expect(index.fileCount == 3)

        // 搜索词已输入时，系统通知也应使空结果自动更新。
        let arrivesLater = desktop.appendingPathComponent("查询期间新建", isDirectory: true)
        model.query = arrivesLater.lastPathComponent
        try await waitFor { !model.isLoadingResults && model.results.isEmpty }
        try fm.createDirectory(at: arrivesLater, withIntermediateDirectories: false)
        try await waitFor { model.results.first?.path == arrivesLater.path }
    }

    @Test @MainActor func finderFolderSuppliesFreshChildrenAlongsideGlobalMatches() async throws {
        let fm = FileManager.default
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let project = root.appendingPathComponent("项目/制作/交付")
        let archive = root.appendingPathComponent("归档")
        let name = "校样资料"
        let newName = "签收记录"
        let oldCopy = archive.appendingPathComponent(name)
        let newCopy = archive.appendingPathComponent(newName)
        let previouslyIndexed = project.appendingPathComponent("装订原稿")
        let left = project.appendingPathComponent("样品")
        let right = archive.appendingPathComponent("样品")
        for folder in [previouslyIndexed, oldCopy, newCopy, left, right] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let writer = DispatchQueue(label: "FileSearchTests.finderFolder")
        let index = FileIndex(mainRoots: [root.path], recentFolders: [], indexQueue: writer)
        index.includeExternalDrives = false
        index.start()
        defer { index.stop() }
        try await waitFor { !index.isIndexing && index.fileCount == 9 }

        func paths(_ query: String, finder: URL? = nil, title: String? = nil) async -> [String] {
            await withCheckedContinuation { continuation in
                index.searchPage(.init(query), preferredFolder: finder?.path, finderTitle: title) {
                    continuation.resume(returning: $0.results.map(\.path))
                }
            }
        }
        writer.suspend()
        defer { writer.resume() }
        let fresh = project.appendingPathComponent(name)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: false)
        #expect(await paths(name, finder: project) == [fresh.path, oldCopy.path])
        #expect(await paths(name, title: project.lastPathComponent) == [fresh.path, oldCopy.path])

        let renamed = project.appendingPathComponent(newName)
        try fm.moveItem(at: fresh, to: renamed)
        #expect(await paths(newName, finder: project) == [renamed.path, newCopy.path])
        #expect(await paths(name, finder: project) == [oldCopy.path])

        let final = project.appendingPathComponent("最终印样")
        try fm.moveItem(at: previouslyIndexed, to: final)
        #expect(await paths(previouslyIndexed.lastPathComponent, finder: project).isEmpty)
        #expect(await paths(final.lastPathComponent, finder: project) == [final.path])

        // 切到另一个访达窗口，直接读取的位置也随之切换。
        let other = archive.appendingPathComponent("窗口切换后新增")
        try fm.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(await paths(other.lastPathComponent, finder: archive) == [other.path])

        // 两个窗口标题相同时，两处的变化都能看到；访达给出了确切路径时，优先该窗口。
        for parent in [left, right] {
            try fm.createDirectory(at: parent.appendingPathComponent("色卡"), withIntermediateDirectories: false)
        }
        let colors = await paths("色卡", title: "样品")
        #expect(Set(colors) == [left.path + "/色卡", right.path + "/色卡"])
        #expect(await paths("色卡", finder: left, title: "样品") == [left.path + "/色卡"])

        // 父项目也是新建的。访达提供实际路径时，只核对这层，仍遵守索引的包、链接和缓存边界。
        let newParent = project.appendingPathComponent("新项目/二期")
        let newChild = newParent.appendingPathComponent("封存清单")
        try fm.createDirectory(at: newChild, withIntermediateDirectories: true)
        #expect(await paths(newChild.lastPathComponent, finder: newParent) == [newChild.path])
        let hiddenCache = project.appendingPathComponent(".git/objects")
        try fm.createDirectory(at: hiddenCache.appendingPathComponent("仓库内部文件"), withIntermediateDirectories: true)
        #expect(await paths("仓库内部文件", finder: hiddenCache).isEmpty)
        let link = project.appendingPathComponent("替身目录")
        try fm.createSymbolicLink(at: link, withDestinationURL: newParent)
        #expect(await paths(newChild.lastPathComponent, finder: link).isEmpty)
    }

    @Test @MainActor func ambiguousFinderTitleReflectsChangesBeforeIndexNotifications() async throws {
        let fm = FileManager.default
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let folders = (0..<12).map { root.appendingPathComponent("项目\($0)/交付") }
        let archive = root.appendingPathComponent("归档/封面初稿")
        for dir in folders + [archive] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let old = folders[9].appendingPathComponent("装订样本")
        try fm.createDirectory(at: old, withIntermediateDirectories: false)
        let writer = DispatchQueue(label: "FileSearchTests.ambiguousFinder")
        let index = FileIndex(mainRoots: [root.path], recentFolders: [], indexQueue: writer)
        index.includeExternalDrives = false
        index.start()
        defer { index.stop() }
        try await waitFor { !index.isIndexing && index.fileCount == 27 }
        func paths(_ query: String) async -> Set<String> {
            await withCheckedContinuation { done in
                index.searchPage(.init(query), finderTitle: "交付") { done.resume(returning: Set($0.results.map(\.path))) }
            }
        }
        let fresh = folders[2].appendingPathComponent(archive.lastPathComponent)
        do {
            writer.suspend()
            defer { writer.resume() }
            try fm.createDirectory(at: fresh, withIntermediateDirectories: false)
            #expect(await paths("封面") == [archive.path, fresh.path])
            let renamed = old.deletingLastPathComponent().appendingPathComponent("装订定稿")
            try fm.moveItem(at: old, to: renamed)
            #expect(await paths("装订样本").isEmpty)
            #expect(await paths("装订定稿") == [renamed.path])
            try fm.removeItem(at: fresh)
            #expect(await paths("封面初稿") == [archive.path])
        }

        // 目录集合变化后，同一个标题的下一次查询也必须核对新加入的目录。
        let extra = root.appendingPathComponent("追加项目/交付")
        try fm.createDirectory(at: extra, withIntermediateDirectories: true)
        index.refresh(folder: root.path)
        writer.sync {}
        writer.suspend()
        defer { writer.resume() }
        let final = extra.appendingPathComponent("定版确认")
        try fm.createDirectory(at: final, withIntermediateDirectories: false)
        #expect(await paths("定版确认") == [final.path])
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
