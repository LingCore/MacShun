// SPDX-License-Identifier: MIT

import Foundation

/// 一次文件夹搜索。界面只读 path，临时目录项只在 FileIndex 的搜索队列上访问。
/// 已收录的目录直接用索引快照。未收录的目录只缓存名称，退出范围即释放。
final class FileSearchFolder {
    let path: String
    private let prefix: String
    private let lock = NSLock()
    private var resolvedPhysicalRoot = false
    private var cachedPhysicalRoot: String?
    private struct Listing {
        let inode: ino_t
        let device: dev_t
        let changed: timespec
        let entries: FolderEntries
        var lastAccess: UInt64
    }
    private var listings: [String: Listing] = [:]
    private var accessCounter: UInt64 = 0
    private static let maxCachedListings = 512

    init(path: String) {
        self.path = path
        prefix = path == "/" ? "/" : path + "/"
    }

    private var physicalRoot: String? {
        lock.lock()
        if resolvedPhysicalRoot {
            let root = cachedPhysicalRoot
            lock.unlock()
            return root
        }
        lock.unlock()
        let root = Self.physicalPath(path)
        lock.lock()
        if !resolvedPhysicalRoot {
            cachedPhysicalRoot = root
            resolvedPhysicalRoot = true
        }
        let result = cachedPhysicalRoot
        lock.unlock()
        return result
    }

    func includes(_ directory: String) -> Bool { directory == path || directory.hasPrefix(prefix) }

    /// realpath 在大小写不敏感的卷上返回实际拼写；仅接受拼写差异，不把链接当作另一条入口。
    func canonicalSpelling(of directory: String) -> String {
        if directory == path { return path }
        guard directory.caseInsensitiveCompare(path) == .orderedSame ||
                directory.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil,
              let root = physicalRoot, let actual = Self.physicalPath(directory),
              actual == root || actual.hasPrefix(root == "/" ? "/" : root + "/") else { return directory }
        let spelling = path + actual.dropFirst(root.count)
        return directory.caseInsensitiveCompare(spelling) == .orderedSame ? spelling : directory
    }

    var rootIsAvailable: Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              access(path, R_OK | X_OK) == 0, let root = physicalRoot else { return false }
        return root == Self.physicalPath(path)
    }

    private static func physicalPath(_ directory: String) -> String? {
        guard let pointer = realpath(directory, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// 用户粘贴绝对路径时，和逐层进入目录一样核对每一级，避免从包或符号链接绕出范围。
    func canBrowse(_ directory: String, in snapshot: IndexedFolders, isCancelled: () -> Bool) -> Bool {
        guard includes(directory) else { return false }
        var parent = path
        for part in directory.dropFirst(path.count).split(separator: "/") {
            guard !isCancelled(), entries(in: parent, snapshot: snapshot, isCancelled: isCancelled)?.containsFolder(named: String(part)) == true
            else { return false }
            parent = parent == "/" ? "/" + part : parent + "/" + part
        }
        return true
    }

    func entries(in directory: String, snapshot: IndexedFolders, isCancelled: () -> Bool) -> FolderEntries? {
        if let entries = snapshot[directory] { return entries }
        // 快照可能刚好赶上父目录被换成链接。临时读盘前再确认实际位置。
        guard let root = physicalRoot, let actual = Self.physicalPath(directory),
              actual == root || actual.hasPrefix(root == "/" ? "/" : root + "/") else { return nil }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        lock.lock()
        var saved = listings[directory]
        if let existing = saved, existing.inode == info.st_ino, existing.device == info.st_dev,
           existing.changed.tv_sec == info.st_ctimespec.tv_sec, existing.changed.tv_nsec == info.st_ctimespec.tv_nsec {
            accessCounter &+= 1
            saved?.lastAccess = accessCounter
            listings[directory] = saved
            lock.unlock()
            return existing.entries
        }
        lock.unlock()
        guard let listing = autoreleasepool(invoking: { FileSearchDirectory.read(directory, isCancelled: isCancelled) }),
              !isCancelled() else { return nil }
        lock.lock()
        accessCounter &+= 1
        let fresh = Listing(inode: info.st_ino, device: info.st_dev, changed: info.st_ctimespec,
                            entries: listing.entries, lastAccess: accessCounter)
        if listings.count >= Self.maxCachedListings, listings[directory] == nil {
            // 淘汰最久未访问的四分之一，避免目录超过上限时每次按键都全清抖动。
            let evictCount = max(1, Self.maxCachedListings / 4)
            let oldest = listings.sorted { $0.value.lastAccess < $1.value.lastAccess }.prefix(evictCount).map(\.key)
            for key in oldest { listings.removeValue(forKey: key) }
        }
        listings[directory] = fresh
        lock.unlock()
        return listing.entries
    }
}
