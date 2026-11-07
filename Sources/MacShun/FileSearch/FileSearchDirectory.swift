// SPDX-License-Identifier: MIT

import Foundation

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

    /// 仓库内部数据和生成缓存只收目录名，避免一次扫描几十万个对象。
    private static let nameOnly: Set<String> = [".git", ".hg", ".svn", ".build", ".cache", ".venv"]
    private static let toolCacheParents = ["caches": ".gradle", "registry": ".cargo", "_cacache": ".npm", "toolchains": ".rustup"]

    private mutating func append(_ entry: FileEntry, in folder: String, isSymlink: Bool = false) {
        let name = entry.name
        let isToolCache = Self.toolCacheParents[name].map { folder.hasSuffix("/" + $0) } == true
        let mayDescend = entry.isDirectory && !entry.isPackage && !isSymlink
            && !Self.nameOnly.contains(name) && !(name == "Library" && folder == FileIndex.home)
            && !isToolCache
        entries.append(entry, mayDescend: mayDescend)
        if mayDescend { subfolders.append(folder == "/" ? "/" + name : folder + "/" + name) }
    }

    private static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey]

    static func read(_ folder: String) -> Self? {
        read(folder, isCancelled: { false })
    }

    static func read(_ folder: String, isCancelled: () -> Bool) -> Self? {
        if folder.hasPrefix("/Volumes/") { return readDrive(folder, isCancelled: isCancelled) }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))
        else { return nil }
        var listing = Self()
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

    /// 外接盘用 readdir 拿名字和类型，仅在类型未知或需判断文件夹的隐藏标记时查属性。
    static func readDrive(_ folder: String) -> Self? { readDrive(folder, isCancelled: { false }) }

    private static func readDrive(_ folder: String, isCancelled: () -> Bool) -> Self? {
        guard let dir = opendir(folder) else { return nil }
        defer { closedir(dir) }
        var listing = Self()
        let atRoot = (folder as NSString).deletingLastPathComponent == "/Volumes"
        var offset = 0
        while let item = readdir(dir) {
            if offset.isMultiple(of: 256), isCancelled() { return nil }
            offset += 1
            let name = withUnsafePointer(to: item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if skipsName(name) || (atRoot && name.hasPrefix("$")) { continue }
            let path = folder + "/" + name
            var type = item.pointee.d_type
            var info = stat()
            if type == DT_UNKNOWN {
                guard lstat(path, &info) == 0 else { continue }
                type = info.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
            }
            if type == DT_DIR {
                if atRoot ? windowsSystemFolders.contains(name) : name == "AppData" { continue }
                if !name.hasPrefix("."), lstat(path, &info) == 0, info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                let isPackage = name.contains(".")
                    && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                listing.append(FileEntry(name: name, isDirectory: true, isPackage: isPackage), in: folder)
            } else {
                let lower = name.lowercased()
                if name.hasPrefix("~$") || windowsHiddenFiles.contains(lower) || lower.hasPrefix("ntuser.dat") { continue }
                listing.entries.append(FileEntry(name: name, isDirectory: false, isPackage: false))
            }
        }
        listing.entries.compact()
        return listing
    }
}
