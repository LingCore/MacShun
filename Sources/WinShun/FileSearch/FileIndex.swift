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
    /// 按内容搜到的：匹配处附近的一段文字
    var snippet: String? = nil

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
/// 外接硬盘可能很大、读起来很慢（例如 macOS 只读挂载的 NTFS 盘），放在第二轮后台扫，不耽误搜索。
/// NTFS 驱动（FSKit）查每个文件的属性很慢，而且一次只处理一个，所以外接硬盘只读目录（readdir），
/// 只给文件夹查隐藏标记，几块盘一起用几个线程扫：实测 6 万个文件从 10 秒降到 0.5 秒。
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

    /// 文件内容索引（F2）。扫描完、文件有变化时，把要读内容的文件交给它。只在 queue 上读写，用 setContentIndex 设置
    private var contentIndex: ContentIndex?
    /// 这次要扫描的位置（包括还没扫到的外接硬盘），只在 queue 上读写
    private var plannedRoots: [String] = []

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
        let keepDrives = includeExternalDrives
        queue.async {
            self.activeGeneration = gen
            self.plannedRoots = mainRoots + drives
            self.contentIndex?.setSearchRoots(mainRoots + drives)
            // 关掉了“包括外接硬盘”时，内容索引里外接硬盘上的文件也去掉；只是拔掉了的留着，插回来不用重新读
            self.contentIndex?.prune(keeping: mainRoots + (keepDrives ? ["/Volumes"] : []))
        }
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
                self.sendContent(result, scopes: mainRoots.map { ContentIndex.Scope(folder: $0, recursive: true) })
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

    /// 第二轮：几块外接硬盘一起扫。边扫边并进索引、交给内容索引去读，不用等全部扫完。
    private func scanDrives(_ drives: [String], generation gen: Int) {
        let begin = Date()
        Self.scanTreesInParallel(drives, threads: 4) { batch in
            self.queue.async {
                guard gen == self.activeGeneration else { return }
                self.folders.merge(batch) { _, new in new }
                // 只增不删：还没扫到的文件不能当成删掉了
                self.sendContent(batch, scopes: [])
                self.publishCount()
            }
        }
        queue.async {
            guard gen == self.activeGeneration else { return }
            self.scannedRoots.append(contentsOf: drives)
            // 全部扫完，再把内容索引里已经不存在的文件去掉
            let scopes = drives.map { ContentIndex.Scope(folder: $0, recursive: true) }
            var files: [String] = []
            for (folder, entries) in self.folders where scopes.contains(where: { $0.folder == folder || $0.contains(folder) }) {
                Self.collectContentFiles(folder, entries, into: &files)
            }
            self.contentIndex?.removeMissing(present: Set(files), scopes: scopes)
            let count = self.folders.values.reduce(0) { $0 + $1.count }
            Log.app.notice("文件索引：外接硬盘扫完，共 \(count, privacy: .public) 个，用时 \(Date().timeIntervalSince(begin), format: .fixed(precision: 1), privacy: .public) 秒")
            malloc_zone_pressure_relief(nil, 0)
            self.publishCount { _ in self.isScanningDrives = false }
        }
    }

    /// 接上或断开内容索引。接上时把已经扫到的文件都交给它。哪个线程都可以调用。
    func setContentIndex(_ index: ContentIndex?) {
        queue.async {
            guard self.contentIndex !== index else { return }
            self.contentIndex = index
            guard let index else { return }
            index.setSearchRoots(self.plannedRoots)
            if !self.scannedRoots.isEmpty {
                self.sendContent(self.folders, scopes: self.scannedRoots.map { ContentIndex.Scope(folder: $0, recursive: true) })
            }
        }
    }

    /// 内容索引不读的文件夹：程序的依赖包，成千上万个 json、txt，都不是用户自己的文件
    private static let skippedForContent: Set<String> = [
        "node_modules", "site-packages", "dist-packages", "__pycache__", "bower_components", "Pods", "DerivedData",
    ]

    /// 把这些文件夹里要读内容的文件交给内容索引（在 queue 上）。
    private func sendContent(_ folders: [String: [FileEntry]], scopes: [ContentIndex.Scope]) {
        guard let contentIndex else { return }
        var files: [String] = []
        for (folder, entries) in folders { Self.collectContentFiles(folder, entries, into: &files) }
        contentIndex.sync(files: files, scopes: scopes)
    }

    private static func collectContentFiles(_ folder: String, _ entries: [FileEntry], into files: inout [String]) {
        guard !folder.split(separator: "/").contains(where: { skippedForContent.contains(String($0)) }) else { return }
        for entry in entries where !entry.isDirectory && ContentExtractor.kind(ofFileNamed: entry.name) != nil {
            files.append(folder == "/" ? "/" + entry.name : folder + "/" + entry.name)
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
        if folder.hasPrefix("/Volumes/") { return listDrive(folder) }
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

    /// Windows 的隐藏系统文件。外接硬盘上不查每个文件的隐藏标记（太慢），按名字跳过
    private static let windowsHiddenFiles: Set<String> = [
        "desktop.ini", "thumbs.db", "ehthumbs.db", "pagefile.sys", "hiberfil.sys", "swapfile.sys",
        "dumpstack.log", "dumpstack.log.tmp", "bootmgr", "bootnxt", "ntuser.ini", "ntuser.pol",
    ]

    /// 外接硬盘上列一个文件夹：只读目录项（名字和类型），不查文件属性；文件夹查一下隐藏标记，
    /// 隐藏的（ProgramData、Default 用户、目录联接）和 Windows 系统文件夹一样整个跳过。
    private static func listDrive(_ folder: String) -> (entries: [FileEntry], subfolders: [String])? {
        guard let dir = opendir(folder) else { return nil }
        defer { closedir(dir) }
        var entries: [FileEntry] = []
        var subfolders: [String] = []
        while let item = readdir(dir) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name.hasPrefix(".") || name.hasPrefix("$") { continue }
            let path = folder + "/" + name
            var type = item.pointee.d_type
            var info = stat()
            if type == DT_UNKNOWN {
                guard lstat(path, &info) == 0 else { continue }
                type = info.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
            }
            if type == DT_DIR {
                if windowsSystemFolders.contains(name) || excluded.contains(path) { continue }
                if lstat(path, &info) == 0 && info.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                // 只有带扩展名的文件夹可能是“包”（例如 .app），这种很少，单独问一下系统
                let isPackage = name.contains(".")
                    && (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                entries.append(FileEntry(name: name, isDirectory: true, isPackage: isPackage))
                if !isPackage { subfolders.append(path) }
            } else {
                if name.hasPrefix("~$") || windowsHiddenFiles.contains(name.lowercased())
                    || name.lowercased().hasPrefix("ntuser.dat") { continue }
                entries.append(FileEntry(name: name, isDirectory: false, isPackage: false))
            }
        }
        return (entries, subfolders)
    }

    /// 几个线程一起扫这些位置（外接硬盘）。每个线程攒够一批（或者过了一秒）就交给 onBatch，可能在不同线程上调用。
    private static func scanTreesInParallel(_ roots: [String], threads: Int,
                                            onBatch: @escaping ([String: [FileEntry]]) -> Void) {
        let lock = NSLock()
        var pending = roots
        var busy = 0
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var local: [String: [FileEntry]] = [:]
            var lastFlush = Date()
            while true {
                if !local.isEmpty && (local.count >= 2000 || Date().timeIntervalSince(lastFlush) > 1) {
                    onBatch(local)
                    local = [:]
                    lastFlush = Date()
                }
                lock.lock()
                guard let folder = pending.popLast() else {
                    let done = busy == 0
                    lock.unlock()
                    if done { break }
                    usleep(500)
                    continue
                }
                busy += 1
                lock.unlock()
                let listed = autoreleasepool { list(folder) }
                lock.lock()
                if let (entries, subfolders) = listed {
                    local[folder] = entries
                    pending.append(contentsOf: subfolders)
                }
                busy -= 1
                lock.unlock()
            }
            if !local.isEmpty { onBatch(local) }
        }
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
        // 交给内容索引的：这些范围里现在有的文件
        var contentFiles: [String] = []
        var contentScopes: [ContentIndex.Scope] = []
        for (rawPath, recursive) in changes {
            let folder = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard isIndexed(folder) else { continue }
            touched = true
            // 系统说要整个重新扫描时，先把这个文件夹下面的全部去掉
            if recursive { removeSubtree(folder) }
            guard let (entries, subfolders) = Self.list(folder) else {
                removeSubtree(folder)   // 文件夹被删了
                contentScopes.append(ContentIndex.Scope(folder: folder, recursive: true))
                continue
            }
            folders[folder] = entries
            Self.collectContentFiles(folder, entries, into: &contentFiles)
            contentScopes.append(ContentIndex.Scope(folder: folder, recursive: recursive))
            var denied: [String] = []
            for sub in subfolders where folders[sub] == nil {
                var scanned: [String: [FileEntry]] = [:]
                Self.scanTree(sub, into: &scanned, denied: &denied)
                folders.merge(scanned) { _, new in new }
                for (path, entries) in scanned { Self.collectContentFiles(path, entries, into: &contentFiles) }
                if !recursive { contentScopes.append(ContentIndex.Scope(folder: sub, recursive: true)) }
            }
            // 消失的子文件夹（被删除、改名或移走）
            let current = Set(subfolders)
            let prefix = folder + "/"
            var gone: Set<String> = []
            for key in folders.keys where key.hasPrefix(prefix) {
                let child = folder + "/" + key.dropFirst(prefix.count).split(separator: "/", maxSplits: 1)[0]
                if !current.contains(child) {
                    folders[key] = nil
                    gone.insert(child)
                }
            }
            if !recursive { contentScopes += gone.map { ContentIndex.Scope(folder: $0, recursive: true) } }
        }
        if touched { publishCount() }
        if !contentScopes.isEmpty { contentIndex?.sync(files: contentFiles, scopes: contentScopes) }
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
