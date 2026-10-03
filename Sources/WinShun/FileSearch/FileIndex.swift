// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import CoreServices

/// 用来匹配的一个名字。
struct MatchText {
    /// 小写后的 UTF-8 字节，按字节查找比 String.contains 快得多
    let lower: [UInt8]
    /// 去掉扩展名后的长度（字节）。没有扩展名时等于全长
    let stemLength: Int
    /// 名字里有汉字时，每个字的拼音，用来按拼音、首字母搜
    let syllables: [[Character]]?

    init(_ text: String) {
        lower = Array(text.lowercased().utf8)
        if let dot = lower.lastIndex(of: 0x2E), dot > 0 { stemLength = dot } else { stemLength = lower.count }
        let chars = Array(text.prefix(PinyinIndex.maxIndexedCharacters))
        if chars.contains(where: { !$0.isASCII }) {
            syllables = Pinyin.syllables(of: chars.filter { !$0.isWhitespace }).map { Array($0) }
        } else {
            syllables = nil
        }
    }
}

/// 索引里的一个文件或文件夹。
struct FileEntry {
    let name: String
    let isDirectory: Bool
    /// 应用程序（.app）等“包”：在访达里看起来是一个文件，不索引里面的内容
    let isPackage: Bool
    /// 访达里显示的名字和文件名不一样时（应用程序的中文名，例如 Notes.app 显示成“备忘录”）
    let displayName: String?
    let text: MatchText
    let displayText: MatchText?

    init(name: String, isDirectory: Bool, isPackage: Bool, displayName: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.displayName = displayName
        text = MatchText(name)
        displayText = displayName.map(MatchText.init)
    }

    var isApp: Bool { isPackage && name.hasSuffix(".app") }
}

/// 一条搜索结果。
struct FileSearchResult: Identifiable, Equatable {
    let path: String
    /// 显示的名字（应用程序用访达里的名字）
    let name: String
    let isDirectory: Bool
    let score: Double

    var id: String { path }
}

/// 打分和排序。纯函数，方便测试。
enum FileMatcher {
    /// 一个搜索词和文件名的匹配程度，0 表示不匹配。
    /// 全名一样 > 去掉扩展名后一样 > 开头一样 > 某个词的开头 > 名字里包含 > 拼音或首字母。
    static func score(term: [UInt8], termCharacters: [Character], isASCII: Bool, text: MatchText) -> Double {
        let name = text.lower
        if name == term { return 100 }
        if let position = find(term, in: name) {
            if position == 0 { return term.count == text.stemLength ? 95 : 80 }
            return isWordStart(name, at: position) ? 60 : 40
        }
        if isASCII, let syllables = text.syllables, PinyinIndex.syllableMatch(termCharacters, syllables) {
            return 30
        }
        return 0
    }

    /// 文件名和显示的名字，取匹配得好的那个。
    static func score(term: [UInt8], termCharacters: [Character], isASCII: Bool, entry: FileEntry) -> Double {
        let byName = score(term: term, termCharacters: termCharacters, isASCII: isASCII, text: entry.text)
        guard let display = entry.displayText else { return byName }
        return max(byName, score(term: term, termCharacters: termCharacters, isASCII: isASCII, text: display))
    }

    /// 整个查询（空格分开的几个词都要匹配）的得分，再加上类型、长度、深度的微调。0 表示不匹配。
    static func score(query terms: [Term], entry: FileEntry, depth: Int) -> Double {
        var total = 0.0
        for term in terms {
            let s = score(term: term.bytes, termCharacters: term.characters, isASCII: term.isASCII, entry: entry)
            if s == 0 { return 0 }
            total += s
        }
        if entry.isApp { total += 8 }
        else if entry.isDirectory { total += 2 }
        total -= Double(min(entry.name.count, 80)) * 0.05
        total -= Double(min(depth, 12)) * 0.4
        return total
    }

    struct Term {
        let bytes: [UInt8]
        let characters: [Character]
        let isASCII: Bool

        init(_ text: String) {
            let lower = text.lowercased()
            bytes = Array(lower.utf8)
            characters = Array(lower)
            isASCII = lower.allSatisfy(\.isASCII)
        }
    }

    static func terms(of query: String) -> [Term] {
        query.split(whereSeparator: { $0.isWhitespace }).map { Term(String($0)) }
    }

    /// 前一个字符是分隔符，这里算一个词的开头（“my-report” 里的 “report”）。
    private static func isWordStart(_ name: [UInt8], at position: Int) -> Bool {
        let previous = name[position - 1]
        return previous == 0x20 || previous == 0x2D || previous == 0x5F || previous == 0x2E
            || previous == 0x28 || previous == 0x5B || previous == 0xE3  // 空格 - _ . ( [，以及中文标点的开头字节
    }

    /// 子串第一次出现的位置。
    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        let n = needle.count, h = haystack.count
        guard n > 0, n <= h else { return n == 0 ? 0 : nil }
        let first = needle[0]
        var i = 0
        while i <= h - n {
            if haystack[i] == first {
                var j = 1
                while j < n && haystack[i + j] == needle[j] { j += 1 }
                if j == n { return i }
            }
            i += 1
        }
        return nil
    }
}

/// 文件名索引（F1）：第一次扫描一遍，之后用 FSEvents 跟着文件变化更新。只存在内存里，不联网。
///
/// 搜索范围：个人文件夹（不含“资源库”）、应用程序、系统自带的应用程序、共享文件夹，以及外接硬盘。
/// 不收录隐藏文件、应用程序包里的内容；外接硬盘上不收录 Windows 的系统文件夹。
/// 外接硬盘可能很大、读起来很慢（例如 macOS 只读挂载的 NTFS 盘），放在第二轮后台慢慢扫，不耽误搜索。
///
/// 索引数据只在 queue 上读写（搜索、合并扫描结果、处理 FSEvents）；扫描在别的队列上做；状态在主线程上发布给界面。
final class FileIndex: ObservableObject {
    static let shared = FileIndex()

    @Published private(set) var fileCount = 0
    /// 第一轮（个人文件夹、应用程序）还没扫完
    @Published private(set) var isIndexing = false
    /// 第二轮：正在扫描外接硬盘
    @Published private(set) var isScanningDrives = false
    @Published private(set) var lastIndexed: Date?
    /// 没有权限读的文件夹（例如用户在系统询问时点了“不允许”的“桌面”）
    @Published private(set) var deniedFolders: [String] = []

    /// 是否包括外接硬盘。改了之后要重新建立索引才生效。只在主线程上改。
    var includeExternalDrives = true

    private let queue = DispatchQueue(label: "WinShun.FileIndex", qos: .utility)
    private let scanQueue = DispatchQueue(label: "WinShun.FileIndex.scan", qos: .utility)
    private let driveQueue = DispatchQueue(label: "WinShun.FileIndex.drives", qos: .background)

    /// 以下只在 queue 上读写
    /// 文件夹路径 → 里面的文件
    private var folders: [String: [FileEntry]] = [:]
    /// 这次扫描的位置（判断 FSEvents 的变化在不在范围里时用）
    private var scannedRoots: [String] = []
    /// 第几次建立索引。重新建立后，上一次还没扫完的结果作废
    private var activeGeneration = 0

    /// 以下只在主线程上读写
    private var generation = 0
    private var stream: FSEventStreamRef?
    private var started = false
    private var volumeObservers: [NSObjectProtocol] = []

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// 第一轮扫描的位置。Safari 的真身在 Cryptexes 里，“应用程序”里只有一个带隐藏标记的替身
    private static let mainRoots = [
        home, "/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications", "/Users/Shared",
    ]

    /// 外接硬盘（本地的、在访达里能看到的，不含系统盘）
    private static func driveRoots() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  volume.path.hasPrefix("/Volumes/")
            else { return nil }
            return volume.path
        }
    }

    /// 不扫描的文件夹（里面的东西对用户没用，或者太多）
    private static let excluded: Set<String> = [home + "/Library", home + "/.Trash"]

    /// 外接硬盘上不扫描的文件夹：Windows 的系统文件、程序和缓存，几十万个文件，对找自己的文件没有用
    private static let windowsSystemFolders: Set<String> = [
        "Windows", "Program Files", "Program Files (x86)", "ProgramData", "AppData", "$Recycle.Bin", "$RECYCLE.BIN",
        "System Volume Information", "Recovery", "$WinREAgent", "$SysReset", "PerfLogs", "Config.Msi", "MSOCache",
        "$Windows.~BT", "$Windows.~WS", "Windows.old", "OneDriveTemp",
    ]

    /// 开始建立索引并跟踪变化。已经开始过就不再重复。只在主线程上调用。
    func start() {
        guard !started else { return }
        started = true
        rebuild()
        // 接上或拔掉外接硬盘后，扫描位置变了，重新来一遍
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.started, self.includeExternalDrives else { return }
                self.rebuild()
            })
        }
    }

    /// 停止并清空，释放内存。
    func stop() {
        guard started else { return }
        started = false
        generation += 1
        let gen = generation
        stopWatching()
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        volumeObservers = []
        queue.async {
            self.activeGeneration = gen
            self.folders = [:]
            self.scannedRoots = []
        }
        fileCount = 0
        isIndexing = false
        isScanningDrives = false
        lastIndexed = nil
        deniedFolders = []
    }

    /// 重新扫描一遍：先扫个人文件夹和应用程序，扫完就能搜；再在后台扫外接硬盘。只在主线程上调用。
    func rebuild() {
        generation += 1
        let gen = generation
        let mainRoots = Self.mainRoots
        let drives = includeExternalDrives ? Self.driveRoots() : []
        isIndexing = true
        isScanningDrives = !drives.isEmpty
        queue.async { self.activeGeneration = gen }
        restartWatching(mainRoots + drives)

        scanQueue.async {
            let begin = Date()
            var result: [String: [FileEntry]] = [:]
            var denied: [String] = []
            for root in mainRoots { Self.scanTree(root, into: &result, denied: &denied) }
            Log.app.notice("文件索引：第一轮 \(result.values.reduce(0) { $0 + $1.count }, privacy: .public) 个，用时 \(Date().timeIntervalSince(begin), format: .fixed(precision: 2), privacy: .public) 秒")
            self.queue.async {
                guard gen == self.activeGeneration else { return }
                self.folders = result
                self.scannedRoots = mainRoots
                self.publishCount { count in
                    self.isIndexing = false
                    self.lastIndexed = Date()
                    self.deniedFolders = denied
                    _ = count
                }
                guard !drives.isEmpty else { return }
                self.driveQueue.async { self.scanDrives(drives, generation: gen) }
            }
        }
    }

    /// 第二轮：一块一块扫外接硬盘，每扫完一块就并进索引。
    private func scanDrives(_ drives: [String], generation gen: Int) {
        for (position, drive) in drives.enumerated() {
            let begin = Date()
            var result: [String: [FileEntry]] = [:]
            var denied: [String] = []
            Self.scanTree(drive, into: &result, denied: &denied)
            Log.app.notice("文件索引：\(drive, privacy: .public) \(result.values.reduce(0) { $0 + $1.count }, privacy: .public) 个，用时 \(Date().timeIntervalSince(begin), format: .fixed(precision: 1), privacy: .public) 秒")
            let last = position == drives.count - 1
            queue.async {
                guard gen == self.activeGeneration else { return }
                self.folders.merge(result) { _, new in new }
                self.scannedRoots.append(drive)
                self.publishCount { _ in
                    if last { self.isScanningDrives = false }
                }
            }
        }
    }

    /// 在 queue 上数一下总数，回到主线程更新界面。
    private func publishCount(then: @escaping (Int) -> Void = { _ in }) {
        let count = folders.values.reduce(0) { $0 + $1.count }
        DispatchQueue.main.async {
            self.fileCount = count
            then(count)
        }
    }

    /// 搜索，结果在主线程上回调。
    func search(_ query: String, limit: Int = 60, completion: @escaping ([FileSearchResult]) -> Void) {
        let terms = FileMatcher.terms(of: query)
        guard !terms.isEmpty else {
            completion([])
            return
        }
        queue.async {
            var matches: [FileSearchResult] = []
            for (folder, entries) in self.folders {
                let depth = folder.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
                for entry in entries {
                    let score = FileMatcher.score(query: terms, entry: entry, depth: depth)
                    guard score > 0 else { continue }
                    let path = folder == "/" ? "/" + entry.name : folder + "/" + entry.name
                    matches.append(FileSearchResult(path: path, name: entry.displayName ?? entry.name,
                                                    isDirectory: entry.isDirectory, score: score))
                }
            }
            matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            let top = Array(matches.prefix(limit))
            DispatchQueue.main.async { completion(top) }
        }
    }

    // MARK: - 扫描（不碰索引数据，哪个队列都可以）

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]

    /// 列出一个文件夹，返回里面的文件和要继续往下扫描的子文件夹。读不了时返回 nil。
    private static func list(_ folder: String) -> (entries: [FileEntry], subfolders: [String])? {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        let onDrive = folder.hasPrefix("/Volumes/")
        var entries: [FileEntry] = []
        var subfolders: [String] = []
        entries.reserveCapacity(urls.count)
        for child in urls {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            let isPackage = values?.isPackage == true
            let path = folder == "/" ? "/" + name : folder + "/" + name
            if onDrive && isDirectory && windowsSystemFolders.contains(name) { continue }
            // 应用程序再记一个访达里显示的名字（系统语言下的名字，例如“备忘录”）
            var displayName: String?
            if isPackage && child.pathExtension == "app" {
                let shown = FileManager.default.displayName(atPath: path)
                if shown != name && shown != child.deletingPathExtension().lastPathComponent {
                    displayName = shown
                }
            }
            entries.append(FileEntry(name: name, isDirectory: isDirectory, isPackage: isPackage, displayName: displayName))
            if isDirectory && !isPackage && values?.isSymbolicLink != true && !excluded.contains(path) {
                subfolders.append(path)
            }
        }
        return (entries, subfolders)
    }

    private static func scanTree(_ root: String, into result: inout [String: [FileEntry]], denied: inout [String]) {
        var stack = [root]
        while let folder = stack.popLast() {
            guard let (entries, subfolders) = list(folder) else {
                // 个人文件夹下第一层读不了，多半是没给权限（桌面、文稿、下载）
                if (folder as NSString).deletingLastPathComponent == home {
                    denied.append(FileManager.default.displayName(atPath: folder))
                }
                continue
            }
            result[folder] = entries
            stack.append(contentsOf: subfolders)
        }
    }

    // MARK: - 跟踪变化

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func restartWatching(_ roots: [String]) {
        stopWatching()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let index = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changes: [(String, Bool)] = []
            for i in 0..<min(count, list.count) {
                let mustScan = flags[i] & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                changes.append((list[i], mustScan))
            }
            index.apply(changes)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, FSEventStreamCreateFlags(flags)
        ) else {
            Log.app.error("文件索引：无法跟踪文件变化")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// FSEvents 告诉我们哪些文件夹里有变化（在 queue 上）。重新列出这些文件夹，新出现的子文件夹整个扫描，消失的整个删掉。
    private func apply(_ changes: [(path: String, mustScanSubfolders: Bool)]) {
        var touched = false
        for (rawPath, recursive) in changes {
            let folder = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard isIndexed(folder) else { continue }
            touched = true
            // 系统说要整个重新扫描时，先把这个文件夹下面的全部去掉
            if recursive { removeSubtree(folder) }
            guard let (entries, subfolders) = Self.list(folder) else {
                removeSubtree(folder)   // 文件夹被删了
                continue
            }
            folders[folder] = entries
            var denied: [String] = []
            for sub in subfolders where folders[sub] == nil {
                Self.scanTree(sub, into: &folders, denied: &denied)
            }
            // 消失的子文件夹（被删除、改名或移走）
            let current = Set(subfolders)
            let prefix = folder + "/"
            for key in folders.keys where key.hasPrefix(prefix) {
                let child = folder + "/" + key.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)[0]
                if !current.contains(child) { folders[key] = nil }
            }
        }
        if touched { publishCount() }
    }

    /// 这个文件夹在索引范围里吗：在已经扫过的位置下面，不在排除的文件夹里，路径上也没有隐藏文件夹、Windows 系统文件夹。
    private func isIndexed(_ folder: String) -> Bool {
        guard scannedRoots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else { return false }
        if Self.excluded.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { return false }
        let parts = folder.split(separator: "/")
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if folder.hasPrefix("/Volumes/"), parts.contains(where: { Self.windowsSystemFolders.contains(String($0)) }) { return false }
        return true
    }

    /// 去掉这个文件夹和它下面所有的文件夹。
    private func removeSubtree(_ folder: String) {
        let prefix = folder + "/"
        for key in folders.keys where key.hasPrefix(prefix) { folders[key] = nil }
        folders[folder] = nil
    }
}
