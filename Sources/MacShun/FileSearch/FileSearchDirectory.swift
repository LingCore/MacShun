// SPDX-License-Identifier: MIT

import Foundation

/// 标记目录的身份与名称列表的变化。仅在当前进程内用其哈希核对索引。
struct DirectoryStamp: Hashable {
    private let device: dev_t
    private let inode: ino_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    private init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        self.init(info)
    }

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }
}

/// 一次目录读取同时决定可搜索的名称和可进入的子目录。初扫和 FSEvents 共用。
struct FileSearchDirectory {
    private(set) var entries = FolderEntries()
    private(set) var subfolders: [String] = []

    private static let metadata: Set<String> = [
        ".", "..", ".DS_Store", ".localized", ".Trash", ".Trashes", ".Spotlight-V100",
        ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100", ".VolumeIcon.icns",
    ]

    private static func skipsName(_ name: String) -> Bool {
        name.hasPrefix(".") && (metadata.contains(name) || name.hasPrefix("._"))
    }

    /// 仓库内部数据、依赖包与生成缓存只收目录名，避免一次扫描几十万个构建/依赖对象。
    private static let nameOnly: Set<String> = [
        ".git", ".hg", ".svn", ".build", ".cache", ".venv",
        "node_modules", "Pods", "DerivedData", "site-packages", "dist-packages", "__pycache__",
        "bower_components", "venv", "Carthage",
    ]
    private static let toolCacheParents = ["caches": ".gradle", "registry": ".cargo", "_cacache": ".npm", "toolchains": ".rustup"]

    private static func mayDescend(_ entry: FileEntry, in folder: String, isSymlink: Bool = false) -> Bool {
        let name = entry.name
        let isToolCache = Self.toolCacheParents[name].map { folder.hasSuffix("/" + $0) } == true
        return entry.isDirectory && !entry.isPackage && !isSymlink
            && !Self.nameOnly.contains(name) && !(name == "Library" && folder == FileIndex.home)
            && !isToolCache
    }

    private mutating func append(_ entry: FileEntry, in folder: String, isSymlink: Bool = false) {
        let mayDescend = Self.mayDescend(entry, in: folder, isSymlink: isSymlink)
        entries.append(entry, mayDescend: mayDescend)
        if mayDescend { subfolders.append(folder == "/" ? "/" + entry.name : folder + "/" + entry.name) }
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey]

    /// 上级目录也刚刚创建时，沿访达给出的实际路径核对边界，不枚举祖先目录。
    static func mayReadNewFolder(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().path
        guard !skipsName(name), let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true,
              values.isHidden != true || name.hasPrefix(".") else { return false }
        if path.hasPrefix("/Volumes/"), skipsDriveDirectory(name, atRoot: (parent as NSString).deletingLastPathComponent == "/Volumes") {
            return false
        }
        let entry = FileEntry(name: name, isDirectory: true, isPackage: values.isPackage == true)
        return mayDescend(entry, in: parent, isSymlink: values.isSymbolicLink == true)
    }

    static func read(_ folder: String) -> Self? {
        read(folder, isCancelled: { false })
    }

    static func read(_ folder: String, recordStamp: Bool = false, isCancelled: () -> Bool) -> Self? {
        if folder.hasPrefix("/Volumes/") { return readDrive(folder, recordStamp: recordStamp, isCancelled: isCancelled) }
        let stamp = recordStamp ? DirectoryStamp(path: folder) : nil
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        else { return nil }
        var listing = Self()
        listing.entries.directoryFingerprint = stamp?.hashValue ?? 0
        listing.entries.reserveCapacity(children.count)
        for (offset, child) in children.enumerated() {
            if offset.isMultiple(of: 256), isCancelled() { return nil }
            let name = child.lastPathComponent
            guard !skipsName(name) else { continue }
            let values = try? child.resourceValues(forKeys: keys)
            // 点号名称可搜索；继续跳过 Finder 隐藏的系统替身（例如 /Applications/Safari.app）。
            if values?.isHidden == true && !name.hasPrefix(".") { continue }
            let isDirectory = values?.isDirectory == true
            let isPackage = values?.isPackage == true
            var displayName: String?
            if !name.hasPrefix("."), (isPackage && child.pathExtension == "app") || (isDirectory && folder == FileIndex.home) {
                let shown = FileManager.default.displayName(atPath: child.path)
                if shown != name && shown != child.deletingPathExtension().lastPathComponent { displayName = shown }
            }
            listing.append(FileEntry(name: name, isDirectory: isDirectory, isPackage: isPackage, displayName: displayName),
                           in: folder, isSymlink: values?.isSymbolicLink == true)
        }
        listing.entries.compact()
        return listing
    }

    private static let windowsSystemFolders: Set<String> = [
        "Windows", "Program Files", "Program Files (x86)", "ProgramData", "AppData", "$Recycle.Bin", "$RECYCLE.BIN",
        "System Volume Information", "Recovery", "$WinREAgent", "$SysReset", "PerfLogs", "Config.Msi", "MSOCache",
        "$Windows.~BT", "$Windows.~WS", "Windows.old", "OneDriveTemp",
    ]

    private static let windowsHiddenFiles: Set<String> = [
        "desktop.ini", "thumbs.db", "ehthumbs.db", "pagefile.sys", "hiberfil.sys", "swapfile.sys",
        "dumpstack.log", "dumpstack.log.tmp", "bootmgr", "bootnxt", "ntuser.ini", "ntuser.pol",
    ]

    private static func skipsDriveDirectory(_ name: String, atRoot: Bool) -> Bool {
        atRoot ? name.hasPrefix("$") || windowsSystemFolders.contains(name) : name == "AppData"
    }

    static func includesDriveFile(_ name: String, in folder: String) -> Bool {
        if name.hasPrefix("$"), (folder as NSString).deletingLastPathComponent == "/Volumes" { return false }
        let lower = name.lowercased()
        return !name.hasPrefix("~$") && !windowsHiddenFiles.contains(lower) && !lower.hasPrefix("ntuser.dat")
    }

    /// 原子替换常用“临时文件改名覆盖”。只有实际名字和类型仍与快照相符时才跳过重新列目录。
    static func matchesDriveFile(at path: String, name: String, in entries: FolderEntries) -> Bool {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        do {
            let values = try url.resourceValues(forKeys: [.nameKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                  let actual = values.name, actual.utf8.elementsEqual(name.utf8),
                  let index = entries.index(ofName: name) else { return false }
            return !entries.isDirectory(at: index)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return entries.index(ofName: name) == nil
        } catch {
            return false
        }
    }

    /// 外接盘用 readdir 拿名字和类型，仅在类型未知或需判断文件夹的隐藏标记时查属性。
    static func readDrive(_ folder: String) -> Self? { readDrive(folder, isCancelled: { false }) }

    static func readDrive(_ folder: String, reusing previous: FolderEntries? = nil, recordStamp: Bool = false,
                          isCancelled: () -> Bool) -> Self? {
        guard let dir = opendir(folder) else { return nil }
        defer { closedir(dir) }
        let atRoot = (folder as NSString).deletingLastPathComponent == "/Volumes"
        let stamp = recordStamp ? DirectoryStamp(descriptor: dirfd(dir)) : nil

        // 仍然读完磁盘上的名字和类型。完全相同时直接共享已发布的字节和拼音；
        // 碰到第一处差异才回到目录开头，为这个目录建立新条目。
        func list(matching old: FolderEntries?) -> Self? {
            var listing = Self()
            var matched = 0, offset = 0
            while let item = readdir(dir) {
                if offset.isMultiple(of: 256), isCancelled() { return nil }
                offset += 1
                let name = withUnsafePointer(to: item.pointee.d_name) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                if skipsName(name) || (atRoot && name.hasPrefix("$")) { continue }
                var type = item.pointee.d_type
                var info = stat()
                if type == DT_UNKNOWN {
                    guard lstat(folder + "/" + name, &info) == 0 else { continue }
                    type = info.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
                }
                let isDirectory = type == DT_DIR
                var isPackage = false
                if isDirectory {
                    if skipsDriveDirectory(name, atRoot: atRoot) { continue }
                    let path = folder + "/" + name
                    if !name.hasPrefix("."), lstat(path, &info) == 0, info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                    isPackage = name.contains(".")
                        && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                } else if !includesDriveFile(name, in: folder) { continue }

                let entry = FileEntry(name: name, isDirectory: isDirectory, isPackage: isPackage)
                let descend = isDirectory && Self.mayDescend(entry, in: folder)
                if let old {
                    guard old.matchesDriveEntry(entry, at: matched, mayDescend: descend) else { return nil }
                    matched += 1
                } else {
                    listing.entries.append(entry, mayDescend: descend)
                }
                if descend { listing.subfolders.append(folder + "/" + name) }
            }
            if let old {
                guard matched == old.items.count else { return nil }
                listing.entries = old
            } else { listing.entries.compact() }
            listing.entries.directoryFingerprint = stamp?.hashValue ?? 0
            return listing
        }

        if let previous {
            if let unchanged = list(matching: previous) { return unchanged }
            guard !isCancelled() else { return nil }
            rewinddir(dir)
        }
        return list(matching: nil)
    }
}
