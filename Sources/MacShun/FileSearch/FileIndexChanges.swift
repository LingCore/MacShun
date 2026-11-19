// SPDX-License-Identifier: MIT

import CoreServices
import Foundation

/// FSEvents 在一次回调里可能多次报告同一路径。目录重扫优先于普通目录核对。
struct FileIndexChanges {
    enum FileChange { case contents, checkName }

    private(set) var directories: [String: Bool] = [:]
    private(set) var files: [String: FileChange] = [:]

    var isEmpty: Bool { directories.isEmpty && files.isEmpty }

    mutating func merge(_ other: Self) {
        directories.merge(other.directories) { $0 || $1 }
        files.merge(other.files) { $0 == .checkName ? $0 : $1 }
    }

    mutating func record(_ rawPath: String, flags: FSEventStreamEventFlags) {
        guard !rawPath.isEmpty else { return }
        // 卷卸载由挂载通知单独处理，不能记成目录删除以免清掉外接盘已收录的正文索引。
        if flags & UInt32(kFSEventStreamEventFlagUnmount) != 0 { return }
        let path = rawPath.hasSuffix("/") && rawPath != "/" ? String(rawPath.dropLast()) : rawPath
        let file = UInt32(kFSEventStreamEventFlagItemIsFile)
        let directory = UInt32(kFSEventStreamEventFlagItemIsDir)
        let symlink = UInt32(kFSEventStreamEventFlagItemIsSymlink)
        let type = flags & (file | directory | symlink)
        let rescan = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        if flags & rescan != 0 {
            let folder = type == file || type == symlink ? (path as NSString).deletingLastPathComponent : path
            directories[folder] = true
            return
        }

        if type == file {
            let modified = file | UInt32(kFSEventStreamEventFlagItemModified)
            let dataFlags = modified | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
            if flags & modified == modified, flags & ~dataFlags == 0 {
                if files[path] == nil { files[path] = .contents }
            } else {
                files[path] = .checkName
            }
            return
        }

        // 无文件类型时按目录级事件处理；目录或链接的结构变化还需核对父目录。
        let structural = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                                | kFSEventStreamEventFlagItemRenamed)
        if type != 0 || flags & structural != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            if directories[parent] == nil { directories[parent] = false }
        }
        if type == 0 || type & directory != 0, directories[path] == nil { directories[path] = false }
    }
}
