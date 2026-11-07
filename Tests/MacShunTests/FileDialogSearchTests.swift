// SPDX-License-Identifier: MIT

import AppKit
import Testing
@testable import MacShun

@Suite("打开和存储面板中前往文件夹")
@MainActor
struct FileDialogSearchTests {
    @Test func jumpsToTheDirectoryAndTreatsPackagesAsFiles() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("项目 资料", isDirectory: true)
        let file = folder.appendingPathComponent("报价.txt")
        let package = folder.appendingPathComponent("Sample.app", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data().write(to: file)
        #expect(FileDialogTarget.folder(for: folder)?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(FileDialogTarget.folder(for: file)?.standardizedFileURL.path == folder.standardizedFileURL.path)
        #expect(FileDialogTarget.folder(for: package)?.standardizedFileURL.path == folder.standardizedFileURL.path)
        try fm.removeItem(at: file)
        #expect(FileDialogTarget.folder(for: URL(fileURLWithPath: file.path)) == nil)
    }

    @Test func dialogModeLimitsScopesUntilTheNextOrdinarySearch() {
        let model = FileSearchModel(index: FileIndex(mainRoots: []), contentIndex: ContentIndex(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        model.searchesContent = true
        model.prepareForShow(inFileDialog: true)
        model.query = "蓝牙"
        #expect(model.availableScopes == [.all, .files, .contents])
        #expect(model.rows.allSatisfy { $0.file != nil })
        model.searchesContent = false
        #expect(model.availableScopes == [.files])
        model.prepareForShow()
        model.query = "蓝牙"
        #expect(model.availableScopes.contains(.system))
        #expect(model.rows.contains { $0.file == nil })
    }
}
