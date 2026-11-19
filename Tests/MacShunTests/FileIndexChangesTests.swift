// SPDX-License-Identifier: MIT

import CoreServices
import Foundation
import Testing
@testable import MacShun

struct FileIndexChangesTests {
    @Test func mergedEventsKeepStructuralChangesAndRecursiveRescans() {
        let folder = "/Volumes/Example/Work"
        let path = folder + "/draft.txt"
        let write = UInt32(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified
                           | kFSEventStreamEventFlagItemInodeMetaMod)
        var writes = FileIndexChanges()
        writes.record(path, flags: write)
        writes.record(path, flags: write)
        #expect(writes.files == [path: .contents] && writes.directories.isEmpty)

        var replacement = FileIndexChanges()
        replacement.record(path, flags: write | UInt32(kFSEventStreamEventFlagItemRenamed))
        replacement.record(folder + "/", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        writes.record(folder, flags: 0)
        for (first, second) in [(writes, replacement), (replacement, writes)] {
            var batch = first
            batch.merge(second)
            #expect(batch.files == [path: .checkName])
            #expect(batch.directories == [folder: true])
        }
    }

    @Test func directoryMovesAndCoarseEventsReconcileTheReportedLocations() {
        let parent = "/Volumes/Example"
        let dir = parent + "/Reports"
        var batch = FileIndexChanges()
        batch.record(dir, flags: UInt32(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemRenamed))
        #expect(batch.directories == [dir: false, parent: false])
        batch.record(parent, flags: UInt32(kFSEventStreamEventFlagRootChanged))
        batch.record(parent, flags: 0)
        #expect(batch.directories[parent] == true)
        var coarse = FileIndexChanges()
        coarse.record(dir, flags: 0)
        #expect(coarse.directories == [dir: false] && coarse.files.isEmpty)
        coarse.record(dir + "/item", flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsFile))
        #expect(coarse.directories == [dir: true] && coarse.files.isEmpty)
    }

    @Test func driveRescanSharesUnchangedBuffersButRechecksSpellingTypesAndRemovals() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("Draft.txt")
        try Data().write(to: file)
        let child = root.appendingPathComponent("part")
        try fm.createDirectory(at: child, withIntermediateDirectories: false)
        let old = try #require(FileSearchDirectory.readDrive(root.path)?.entries)
        let same = try #require(FileSearchDirectory.readDrive(root.path, reusing: old, isCancelled: { false }))
        let shared = old.bytes.withUnsafeBufferPointer { original in
            same.entries.bytes.withUnsafeBufferPointer { $0.baseAddress == original.baseAddress }
        }
        #expect(shared && same.subfolders == [child.path])
        try fm.moveItem(at: file, to: root.appendingPathComponent("draft.txt"))
        try fm.removeItem(at: child)
        try Data().write(to: child)
        let changed = try #require(FileSearchDirectory.readDrive(root.path, reusing: old, isCancelled: { false }))
        #expect(changed.subfolders.isEmpty)
        #expect(changed.entries.index(ofName: "draft.txt") != nil && changed.entries.index(ofName: "Draft.txt") == nil)
        #expect(old.containsFolder(named: "part") && !changed.entries.containsFolder(named: "part"))
        try fm.removeItem(at: child)
        let short = try #require(FileSearchDirectory.readDrive(root.path, reusing: changed.entries, isCancelled: { false }))
        #expect(short.entries.count == 1 && short.entries.index(ofName: "part") == nil)
    }

    @Test @MainActor func rebuildingAnExternalRootReconcilesRemovedSubtreesAndKeepsExplicitLocations() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let old = root.appendingPathComponent("before"), new = root.appendingPathComponent("after")
        let explicit = root.appendingPathComponent(".git/explicit")
        for dir in [old, explicit] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("needle.txt"))
        }
        defer { try? fm.removeItem(at: root) }
        let index = FileIndex(mainRoots: [], externalRoots: { [root.path] })
        index.setIndexedLocations([try #require(FileSearchLocation(path: explicit.path, mounts: []))])
        index.start()
        defer { index.stop() }
        func complete() async throws {
            let deadline = ContinuousClock.now + .seconds(10)
            while index.isScanningDrives && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            try #require(!index.isScanningDrives)
        }
        func matches() async -> Set<String> {
            await withCheckedContinuation { continuation in
                index.search("needle") { continuation.resume(returning: Set($0.map(\.path))) }
            }
        }
        try await complete()
        let kept = explicit.appendingPathComponent("needle.txt").path
        #expect(await matches() == [kept, old.appendingPathComponent("needle.txt").path])
        try fm.moveItem(at: old, to: new)
        try Data().write(to: root.appendingPathComponent("newneedle.md"))
        index.rebuild()
        index.rebuild()  // 取消的那一代不能删掉新一代已经核过的目录。
        try await complete()
        #expect(await matches() == [kept, new.appendingPathComponent("needle.txt").path, root.appendingPathComponent("newneedle.md").path])
    }

    @Test func replacementProbeChecksActualSpellingTypeAndPresence() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let name = "Draft.txt"
        let file = folder.appendingPathComponent(name)
        try Data("original".utf8).write(to: file)
        let entries = try #require(FileSearchDirectory.readDrive(folder.path)?.entries)
        func unchanged(_ name: String) -> Bool {
            FileSearchDirectory.matchesDriveFile(at: folder.appendingPathComponent(name).path, name: name, in: entries)
        }
        try Data("replacement".utf8).write(to: file, options: .atomic)
        #expect(unchanged(name))
        #expect(unchanged("temporary.tmp"))
        try Data().write(to: folder.appendingPathComponent("new.txt"))
        #expect(!unchanged("new.txt"))
        try fm.moveItem(at: file, to: folder.appendingPathComponent("draft.txt"))
        #expect(!unchanged(name))
        #expect(!unchanged("draft.txt"))
        try fm.removeItem(at: folder.appendingPathComponent("draft.txt"))
        #expect(!unchanged(name))
        try fm.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!unchanged(name))
        try fm.removeItem(at: file)
        try fm.createSymbolicLink(at: file, withDestinationURL: folder.appendingPathComponent("new.txt"))
        #expect(!unchanged(name))
    }
}
