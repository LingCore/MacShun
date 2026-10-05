// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import CoreServices

/// 一个文件或文件夹。扫描时先这样拿到，再存进 FolderEntries；测试打分时也用它。
struct FileEntry {
    let name: String
    let isDirectory: Bool
    /// 应用程序（.app）等“包”：在访达里看起来是一个文件，不索引里面的内容
    let isPackage: Bool
    /// 访达里显示的名字和文件名不一样时（应用程序的中文名，例如 Notes.app 显示成“备忘录”）
    let displayName: String?

    init(name: String, isDirectory: Bool, isPackage: Bool, displayName: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.displayName = displayName
    }
}

/// 一个文件夹里的文件名，紧凑存放：名字、小写后的名字、拼音都放在一块连续的字节里，每个文件只另占一个 24 字节的 Item。
/// 每个文件各用一个 String 和几个数组时，光对象头就要几百字节（实测 43 万个文件占了 150 MB）。
struct FolderEntries {
    struct Item {
        var nameStart: UInt32
        var lowerStart: UInt32
        var pinyinStart: UInt32
        var nameLength: UInt16
        var lowerLength: UInt16
        /// 去掉扩展名后的长度（字节）
        var stemLength: UInt16
        /// 逐字拼音的长度。名字全是 ASCII 时为 0，不按拼音搜
        var pinyinLength: UInt16
        var flags: UInt8
    }

    static let directoryFlag: UInt8 = 1
    static let packageFlag: UInt8 = 2
    /// 下一个 Item 是这个文件在访达里显示的名字
    static let hasDisplayNameFlag: UInt8 = 4
    /// 这个 Item 是上一个文件的显示名字，不单独算一个文件
    static let displayNameFlag: UInt8 = 8

    private(set) var bytes: [UInt8] = []
    private(set) var items: [Item] = []
    /// 文件和文件夹的个数（不算显示名字）
    private(set) var count = 0

    init() {}

    init(_ entries: [FileEntry]) {
        entries.forEach { append($0) }
    }

    mutating func reserveCapacity(_ count: Int) {
        items.reserveCapacity(count)
    }

    mutating func append(_ entry: FileEntry) {
        var flags: UInt8 = 0
        if entry.isDirectory { flags |= Self.directoryFlag }
        if entry.isPackage { flags |= Self.packageFlag }
        if entry.displayName != nil { flags |= Self.hasDisplayNameFlag }
        items.append(store(entry.name, flags: flags))
        count += 1
        if let display = entry.displayName { items.append(store(display, flags: Self.displayNameFlag)) }
    }

    /// 存完以后去掉多预留的空间（数组按两倍增长，最多会空一半）。
    /// Array(bytes) 和 Array(bytes[...]) 都会直接共用原来的存储，从指针复制才会建一个刚好大小的新数组
    mutating func compact() {
        if bytes.capacity > bytes.count + 64 { bytes = bytes.withUnsafeBufferPointer { Array($0) } }
        if items.capacity > items.count + 4 { items = items.withUnsafeBufferPointer { Array($0) } }
    }

    func name(at index: Int) -> String {
        let item = items[index]
        let start = Int(item.nameStart)
        return String(decoding: bytes[start ..< start + Int(item.nameLength)], as: UTF8.self)
    }

    func displayName(at index: Int) -> String? {
        items[index].flags & Self.hasDisplayNameFlag != 0 ? name(at: index + 1) : nil
    }

    func isDirectory(at index: Int) -> Bool { items[index].flags & Self.directoryFlag != 0 }

    func isPackage(at index: Int) -> Bool { items[index].flags & Self.packageFlag != 0 }

    /// 有没有这个名字的文件夹（不算“包”）
    func containsFolder(named name: String) -> Bool {
        let target = Array(name.utf8)
        var i = 0
        while i < items.count {
            let item = items[i]
            if item.flags & (Self.directoryFlag | Self.packageFlag) == Self.directoryFlag, Int(item.nameLength) == target.count {
                let start = Int(item.nameStart)
                if bytes[start ..< start + target.count].elementsEqual(target) { return true }
            }
            i += item.flags & Self.hasDisplayNameFlag != 0 ? 2 : 1
        }
        return false
    }

    /// 每个文件（不含显示名字）的位置
    var indices: [Int] {
        var result: [Int] = []
        result.reserveCapacity(count)
        var i = 0
        while i < items.count {
            result.append(i)
            i += items[i].flags & Self.hasDisplayNameFlag != 0 ? 2 : 1
        }
        return result
    }

    /// 和查询匹配的文件，回调位置和得分。
    func forEachMatch(_ terms: [FileMatcher.Term], depth: Int, _ body: (Int, Double) -> Void) {
        bytes.withUnsafeBufferPointer { buffer in
            var i = 0
            while i < items.count {
                let hasDisplay = items[i].flags & Self.hasDisplayNameFlag != 0
                let score = FileMatcher.score(query: terms, item: items[i], display: hasDisplay ? items[i + 1] : nil,
                                              in: buffer, depth: depth)
                if score > 0 { body(i, score) }
                i += hasDisplay ? 2 : 1
            }
        }
    }

    private mutating func store(_ text: String, flags: UInt8) -> Item {
        let limit = Int(UInt16.max)
        let name = Array(text.utf8.prefix(limit))
        let nameStart = bytes.count
        bytes.append(contentsOf: name)
        // 小写、合成形式（NFC）：名字可能是分解形式存的（“デ” 存成 “テ” 加浊点），输入法打出来的是合成形式
        let lower = Array(Self.matchForm(text, isASCII: !name.contains(where: { $0 >= 0x80 })).utf8.prefix(limit))
        var lowerStart = nameStart
        if lower != name {
            lowerStart = bytes.count
            bytes.append(contentsOf: lower)
        }
        var stem = lower.count
        if let dot = lower.lastIndex(of: 0x2E), dot > 0 { stem = dot }
        var pinyinStart = 0, pinyinLength = 0
        if name.contains(where: { $0 >= 0x80 }) {
            let pinyin = Self.encodePinyin(text).prefix(limit)
            pinyinStart = bytes.count
            pinyinLength = pinyin.count
            bytes.append(contentsOf: pinyin)
        }
        return Item(nameStart: UInt32(nameStart), lowerStart: UInt32(lowerStart), pinyinStart: UInt32(pinyinStart),
                    nameLength: UInt16(name.count), lowerLength: UInt16(lower.count), stemLength: UInt16(stem),
                    pinyinLength: UInt16(pinyinLength), flags: flags)
    }

    /// 比较用的形式：小写，非 ASCII 的再转成合成形式（NFC）
    static func matchForm(_ text: String, isASCII: Bool) -> String {
        isASCII ? text.lowercased() : text.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// 逐字的拼音，字之间用 0 隔开：汉字是拼音，ASCII 字符是它自己（小写），其他字符记成 0xFF（对不上任何 ASCII 查询）。
    static func encodePinyin(_ text: String) -> [UInt8] {
        let chars = Array(text.prefix(PinyinIndex.maxIndexedCharacters)).filter { !$0.isWhitespace }
        var out: [UInt8] = []
        for (position, syllable) in Pinyin.syllables(of: chars).enumerated() {
            if position > 0 { out.append(0) }
            if syllable.utf8.allSatisfy({ $0 < 0x80 }) {
                out.append(contentsOf: syllable.utf8)
            } else {
                out.append(0xFF)
            }
        }
        return out
    }
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
    /// 一个搜索词和一个名字的匹配程度，0 表示不匹配。
    /// 全名一样 > 去掉扩展名后一样 > 开头一样 > 某个词的开头 > 名字里包含 > 拼音或首字母。
    static func score(term: Term, lower: UnsafeBufferPointer<UInt8>, stemLength: Int,
                      pinyin: UnsafeBufferPointer<UInt8>) -> Double {
        if lower.count == term.bytes.count && lower.elementsEqual(term.bytes) { return 100 }
        if let position = find(term.bytes, in: lower) {
            if position == 0 { return term.bytes.count == stemLength ? 95 : 80 }
            return isWordStart(lower, at: position) ? 60 : 40
        }
        if term.isASCII, !pinyin.isEmpty, PinyinIndex.syllableMatch(term.bytes, encoded: pinyin) {
            return 30
        }
        return 0
    }

    /// 文件名和显示的名字，取匹配得好的那个。
    private static func score(term: Term, item: FolderEntries.Item, display: FolderEntries.Item?,
                              in buffer: UnsafeBufferPointer<UInt8>) -> Double {
        func one(_ item: FolderEntries.Item) -> Double {
            let lower = UnsafeBufferPointer(rebasing: buffer[Int(item.lowerStart) ..< Int(item.lowerStart) + Int(item.lowerLength)])
            let pinyin = UnsafeBufferPointer(rebasing: buffer[Int(item.pinyinStart) ..< Int(item.pinyinStart) + Int(item.pinyinLength)])
            return score(term: term, lower: lower, stemLength: Int(item.stemLength), pinyin: pinyin)
        }
        let byName = one(item)
        guard let display else { return byName }
        return max(byName, one(display))
    }

    /// 整个查询（空格分开的几个词都要匹配）的得分，再加上类型、长度、深度的微调。0 表示不匹配。
    static func score(query terms: [Term], item: FolderEntries.Item, display: FolderEntries.Item?,
                      in buffer: UnsafeBufferPointer<UInt8>, depth: Int) -> Double {
        var total = 0.0
        for term in terms {
            let s = score(term: term, item: item, display: display, in: buffer)
            if s == 0 { return 0 }
            total += s
        }
        let lower = UnsafeBufferPointer(rebasing: buffer[Int(item.lowerStart) ..< Int(item.lowerStart) + Int(item.lowerLength)])
        if item.flags & FolderEntries.packageFlag != 0 && lower.count > 4 && lower.suffix(4).elementsEqual(".app".utf8) {
            total += 8
        } else if item.flags & FolderEntries.directoryFlag != 0 {
            total += 2
        }
        // 名字的字数：数一下不是 UTF-8 后续字节的字节
        let characters = lower.reduce(0) { $1 & 0xC0 == 0x80 ? $0 : $0 + 1 }
        total -= Double(min(characters, 80)) * 0.05
        total -= Double(min(depth, 12)) * 0.4
        return total
    }

    /// 测试用：给一个文件打分
    static func score(query terms: [Term], entry: FileEntry, depth: Int) -> Double {
        let folder = FolderEntries([entry])
        var result = 0.0
        folder.forEachMatch(terms, depth: depth) { _, score in result = score }
        return result
    }

    struct Term {
        let bytes: [UInt8]
        let isASCII: Bool

        init(_ text: String) {
            bytes = Array(FolderEntries.matchForm(text, isASCII: text.utf8.allSatisfy { $0 < 0x80 }).utf8)
            isASCII = bytes.allSatisfy { $0 < 0x80 }
        }
    }

    static func terms(of query: String) -> [Term] {
        query.split(whereSeparator: { $0.isWhitespace }).map { Term(String($0)) }
    }

    /// 一次搜索。查询里带 /（或 Windows 的 \）就当成路径，例如 “art/gpt/style_reference.png”：
    /// 最后一段按名字搜，前面的文件夹对上得越多排得越前，对不上也照样列出名字对上的文件。
    /// 文件夹可以写访达里显示的名字（“桌面/…”）或 Windows 的叫法（“文档”“视频”）；“~/” 是个人文件夹；
    /// Windows 的盘符（“D:\”）去掉，旧硬盘上的路径照样找得到；两边的引号（Windows“复制为路径”会带上）和 file:// 去掉。
    struct Query {
        let terms: [Term]
        /// 路径里的文件夹，一段一段（比较用的形式），每段是能对上的写法（本来的、对应的真名）
        let folders: [Set<String>]
        /// 写的是完整路径（/ 开头）：存在的话直接放在最前面，没收录的位置（例如“资源库”里）也能打开
        let absolutePath: String?
        /// 带 / 但不像完整路径时，也可能是名字里的 /（访达把名字里的 : 显示成 /，例如“AC/DC”）：
        /// 整个查询再按名字搜一遍，取好的那个
        let nameTerms: [Term]?

        init(_ query: String) {
            let quotes = CharacterSet(charactersIn: "\"'“”‘’")
            // 两边的空格、换行（从别处复制常带着）和引号
            var text = query.trimmingCharacters(in: .whitespacesAndNewlines.union(quotes))
            guard text.contains("/") || text.contains("\\") else {
                (terms, folders, absolutePath, nameTerms) = (FileMatcher.terms(of: query), [], nil, nil)
                return
            }
            if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL { text = url.path }
            if text.contains("/") {
                // Mac 的路径：\ 是终端里的转义（“My\ Project”）
                text = text.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
            } else {
                // Windows 的路径；\\服务器\共享 是网络上的共享文件夹，接上以后在 /Volumes/共享 里
                text = text.replacingOccurrences(of: "\\", with: "/")
                if text.hasPrefix("//") {
                    let parts = text.split(separator: "/", omittingEmptySubsequences: true)
                    text = parts.count >= 2 ? "/Volumes/" + parts.dropFirst().joined(separator: "/") : text
                }
            }
            let looksAbsolute = text.hasPrefix("/") || text.hasPrefix("~")
            if text == "~" || text.hasPrefix("~/") { text = NSHomeDirectory() + text.dropFirst() }
            let chars = Array(text.prefix(3))
            if chars.count >= 2, chars[0].isASCII, chars[0].isLetter, chars[1] == ":", chars.count == 2 || chars[2] == "/" {
                text.removeFirst(2)
            }
            // 一段一段，去掉每段两边的空格（“桌面 / 塔防游戏”）和 “.”，“..” 回到上一层
            var parts: [String] = []
            for raw in text.split(separator: "/") {
                let part = raw.trimmingCharacters(in: .whitespaces)
                if part == ".." { _ = parts.popLast() } else if !part.isEmpty && part != "." { parts.append(part) }
            }
            let absolute = text.hasPrefix("/") ? "/" + parts.joined(separator: "/") : nil
            absolutePath = absolute.flatMap { $0.count > 1 ? $0 : nil }
            nameTerms = looksAbsolute || query.contains("\\") ? nil : FileMatcher.terms(of: text.replacingOccurrences(of: "/", with: ":"))
            terms = FileMatcher.terms(of: parts.last ?? "")
            folders = parts.dropLast().map { part in
                let form = FolderEntries.matchForm(part, isASCII: part.utf8.allSatisfy { $0 < 0x80 })
                return Set([form] + (FileMatcher.folderAliases[form].map { [$0] } ?? []))
            }
        }

        /// 按文件所在的文件夹加的分：写的那几段连着对上，正好是这个文件夹 40、在它下面更深的地方 30；
        /// 没有连着对上时，对上几段给几分（最多 20）。没写文件夹时 0。
        func folderBonus(_ folder: String) -> Double {
            guard !folders.isEmpty else { return 0 }
            let parts = FolderEntries.matchForm(folder, isASCII: folder.utf8.allSatisfy { $0 < 0x80 })
                .split(separator: "/").map(String.init)
            let n = folders.count
            if parts.count >= n {
                for end in stride(from: parts.count, through: n, by: -1)
                where (0 ..< n).allSatisfy({ folders[$0].contains(parts[end - n + $0]) }) {
                    return end == parts.count ? 40 : 30
                }
            }
            let matched = folders.filter { forms in parts.contains { forms.contains($0) } }.count
            return 20 * Double(matched) / Double(n)
        }
    }

    /// 前一个字符是分隔符，这里算一个词的开头（“my-report” 里的 “report”）。
    private static func isWordStart(_ name: UnsafeBufferPointer<UInt8>, at position: Int) -> Bool {
        let previous = name[position - 1]
        if previous == 0x20 || previous == 0x2D || previous == 0x5F || previous == 0x2E || previous == 0x28 || previous == 0x5B {
            return true   // 空格 - _ . ( [
        }
        // 中文标点：U+3000–303F（、。「」【】《》）是 E3 80 xx，全角的 ！（）＿－ 等是 EF BC 81–8F
        guard position >= 3 else { return false }
        let lead = (name[position - 3], name[position - 2])
        return lead == (0xE3, 0x80) || (lead == (0xEF, 0xBC) && (0x81...0x8F).contains(previous))
    }

    /// 子串第一次出现的位置。
    static func find(_ needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>) -> Int? {
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

    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        haystack.withUnsafeBufferPointer { find(needle, in: $0) }
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
    private var folders: [String: FolderEntries] = [:]
    /// 这次扫描的位置（判断 FSEvents 的变化在不在范围里时用）
    private var scannedRoots: [String] = []
    /// 第几次建立索引。重新建立后，上一次还没扫完的结果作废
    private var activeGeneration = 0
    /// 正在扫描、还没并进索引的位置。这期间这些位置下的变化先记下来，扫完再处理，免得漏掉或被扫描结果盖掉
    private var pendingRoots: [String] = []
    private var deferredChanges: [String: Bool] = [:]
    /// 最近一次搜索的编号：打字很快时，排在后面还没开始的旧搜索直接跳过
    private let latestSearch = Locked(0)

    /// 以下只在主线程上读写
    private var generation = 0
    private var stream: FSEventStreamRef?
    private var started = false
    private var volumeObservers: [NSObjectProtocol] = []
    /// 这次扫描的外接硬盘
    private var currentDrives: [String] = []

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
                // 只有外接硬盘真的变了才重新扫描（例如系统挂载了不显示的卷时不用）
                guard let self, self.started, self.includeExternalDrives, Self.driveRoots() != self.currentDrives else { return }
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
            self.pendingRoots = []
            self.deferredChanges = [:]
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
        currentDrives = drives
        isIndexing = true
        isScanningDrives = !drives.isEmpty
        let keepDrives = includeExternalDrives
        queue.async {
            self.activeGeneration = gen
            self.plannedRoots = mainRoots + drives
            self.pendingRoots = mainRoots + drives
            self.deferredChanges = [:]
            self.contentIndex?.setSearchRoots(mainRoots + drives)
            // 关掉了“包括外接硬盘”时，内容索引里外接硬盘上的文件也去掉；只是拔掉了的留着，插回来不用重新读
            self.contentIndex?.prune(keeping: mainRoots + (keepDrives ? ["/Volumes"] : []))
        }
        restartWatching(mainRoots + drives)

        scanQueue.async {
            let begin = Date()
            var result: [String: FolderEntries] = [:]
            var denied: [String] = []
            for root in mainRoots { Self.scanTree(root, into: &result, denied: &denied) }
            Log.app.notice("文件索引：第一轮 \(result.values.reduce(0) { $0 + $1.count }, privacy: .public) 个，用时 \(Date().timeIntervalSince(begin), format: .fixed(precision: 2), privacy: .public) 秒")
            self.queue.async {
                guard gen == self.activeGeneration else { return }
                self.folders = result
                self.scannedRoots = mainRoots
                self.sendContent(result, scopes: mainRoots.map { ContentIndex.Scope(folder: $0, recursive: true) })
                self.finishedScanning(mainRoots)
                malloc_zone_pressure_relief(nil, 0)
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
            self.finishedScanning(drives)
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
        // 编译、打包、测试覆盖率生成的文件，和第三方依赖
        "dist", "build", "coverage", "vendor", "venv", "target", "Carthage",
        // 装在个人文件夹里的 Python 发行版、第三方源码
        "anaconda3", "miniconda3", "miniforge3", "third_party",
    ]

    /// 这些位置只按名字搜，不读内容
    private static let systemContentRoots = ["/Applications", "/System"]

    /// 把这些文件夹里要读内容的文件交给内容索引（在 queue 上）。
    private func sendContent(_ folders: [String: FolderEntries], scopes: [ContentIndex.Scope]) {
        guard let contentIndex else { return }
        var files: [String] = []
        for (folder, entries) in folders { Self.collectContentFiles(folder, entries, into: &files) }
        contentIndex.sync(files: files, scopes: scopes)
    }

    private static func collectContentFiles(_ folder: String, _ entries: FolderEntries, into files: inout [String]) {
        // 只读用户自己的文件：“应用程序”和系统文件夹里不是 .app 的文件夹（素材库、自带文档）不读内容
        guard !systemContentRoots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else { return }
        // 缓存文件夹里是程序生成的东西（例如成千上万张缩略图），不读
        guard !folder.split(separator: "/").contains(where: { skippedForContent.contains(String($0)) || $0.lowercased().contains("cache") })
        else { return }
        for index in entries.indices where !entries.isDirectory(at: index) {
            let name = entries.name(at: index)
            guard ContentExtractor.kind(ofFileNamed: name) != nil else { continue }
            files.append(folder == "/" ? "/" + name : folder + "/" + name)
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

    /// 搜索，结果在主线程上回调。boosts：常打开的文件加的分（见 OpenHistory）
    func search(_ query: String, limit: Int = 60, boosts: [String: Double] = [:],
                completion: @escaping ([FileSearchResult]) -> Void) {
        let parsed = FileMatcher.Query(query)
        let terms = parsed.terms
        guard !terms.isEmpty || parsed.absolutePath != nil else {
            completion([])
            return
        }
        let token = latestSearch.update { value -> Int in
            value += 1
            return value
        }
        queue.async {
            // 已经有更新的搜索了：这次的结果反正用不上
            guard self.latestSearch.get() == token else { return }
            var matches: [FileSearchResult] = []
            for (folder, entries) in self.folders where !terms.isEmpty {
                let depth = folder.utf8.reduce(0) { $1 == 0x2F ? $0 + 1 : $0 }
                var folderBonus: Double?
                func add(_ index: Int, _ score: Double) {
                    let name = entries.name(at: index)
                    let path = folder == "/" ? "/" + name : folder + "/" + name
                    matches.append(FileSearchResult(path: path, name: entries.displayName(at: index) ?? name,
                                                    isDirectory: entries.isDirectory(at: index), score: score + (boosts[path] ?? 0)))
                }
                entries.forEachMatch(terms, depth: depth) { index, score in
                    if folderBonus == nil { folderBonus = parsed.folderBonus(folder) }
                    add(index, score + (folderBonus ?? 0))
                }
                if let nameTerms = parsed.nameTerms { entries.forEachMatch(nameTerms, depth: depth, add) }
            }
            if parsed.nameTerms != nil {
                // 两种搜法都搜到的，留分高的那个
                var best: [String: FileSearchResult] = [:]
                for match in matches where match.score > best[match.path]?.score ?? -.infinity { best[match.path] = match }
                matches = Array(best.values)
            }
            if let path = parsed.absolutePath, let hit = Self.existingFile(path, among: &matches) {
                matches.append(hit)
            }
            matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            let top = Array(matches.prefix(limit))
            DispatchQueue.main.async { completion(top) }
        }
    }

    /// 写的是完整路径而且存在：放在最前面。索引里已经搜到的（大小写可能和写的不一样）拿出来，用索引里的写法。
    static func existingFile(_ path: String, among matches: inout [FileSearchResult]) -> FileSearchResult? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let key = FolderEntries.matchForm(path, isASCII: false)
        if let i = matches.firstIndex(where: { FolderEntries.matchForm($0.path, isASCII: false) == key }) {
            let found = matches.remove(at: i)
            return FileSearchResult(path: found.path, name: found.name, isDirectory: found.isDirectory, score: 1000)
        }
        return FileSearchResult(path: path, name: (path as NSString).lastPathComponent,
                                isDirectory: isDirectory.boolValue, score: 1000)
    }

    // MARK: - 扫描（不碰索引数据，哪个队列都可以）

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]

    /// 列出一个文件夹，返回里面的文件和要继续往下扫描的子文件夹。读不了时返回 nil。
    private static func list(_ folder: String) -> (entries: FolderEntries, subfolders: [String])? {
        if folder.hasPrefix("/Volumes/") { return listDrive(folder) }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }
        let onDrive = folder.hasPrefix("/Volumes/")
        var entries = FolderEntries()
        var subfolders: [String] = []
        entries.reserveCapacity(urls.count)
        for child in urls {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            let isPackage = values?.isPackage == true
            let path = folder == "/" ? "/" + name : folder + "/" + name
            if onDrive && isDirectory && windowsSystemFolders.contains(name) { continue }
            // 应用程序和个人文件夹里的“桌面”“下载”这些再记一个访达里显示的名字（系统语言下的名字，例如“备忘录”）
            var displayName: String?
            if (isPackage && child.pathExtension == "app") || (isDirectory && folder == home) {
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
        entries.compact()
        return (entries, subfolders)
    }

    /// Windows 的隐藏系统文件。外接硬盘上不查每个文件的隐藏标记（太慢），按名字跳过
    private static let windowsHiddenFiles: Set<String> = [
        "desktop.ini", "thumbs.db", "ehthumbs.db", "pagefile.sys", "hiberfil.sys", "swapfile.sys",
        "dumpstack.log", "dumpstack.log.tmp", "bootmgr", "bootnxt", "ntuser.ini", "ntuser.pol",
    ]

    /// 外接硬盘上列一个文件夹：只读目录项（名字和类型），不查文件属性；文件夹查一下隐藏标记，
    /// 隐藏的（ProgramData、Default 用户、目录联接）和 Windows 系统文件夹一样整个跳过。
    private static func listDrive(_ folder: String) -> (entries: FolderEntries, subfolders: [String])? {
        guard let dir = opendir(folder) else { return nil }
        defer { closedir(dir) }
        var entries = FolderEntries()
        var subfolders: [String] = []
        // Windows 的系统文件夹、$ 开头的系统文件都在盘的最上一层；AppData 在每个用户的文件夹里
        let atRoot = (folder as NSString).deletingLastPathComponent == "/Volumes"
        while let item = readdir(dir) {
            let name = withUnsafePointer(to: item.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name.hasPrefix(".") || (atRoot && name.hasPrefix("$")) { continue }
            let path = folder + "/" + name
            var type = item.pointee.d_type
            var info = stat()
            if type == DT_UNKNOWN {
                guard lstat(path, &info) == 0 else { continue }
                type = info.st_mode & S_IFMT == S_IFDIR ? UInt8(DT_DIR) : UInt8(DT_REG)
            }
            if type == DT_DIR {
                if (atRoot ? windowsSystemFolders.contains(name) : name == "AppData") || excluded.contains(path) { continue }
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
        entries.compact()
        return (entries, subfolders)
    }

    /// 几个线程一起扫这些位置（外接硬盘）。每个线程攒够一批（或者过了一秒）就交给 onBatch，可能在不同线程上调用。
    private static func scanTreesInParallel(_ roots: [String], threads: Int,
                                            onBatch: @escaping ([String: FolderEntries]) -> Void) {
        let lock = NSLock()
        var pending = roots
        var busy = 0
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var local: [String: FolderEntries] = [:]
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

    private static func scanTree(_ root: String, into result: inout [String: FolderEntries], denied: inout [String]) {
        var stack = [root]
        while let folder = stack.popLast() {
            // 每个文件夹读完就释放 FileManager 产生的临时对象，不然要等整个扫描结束，峰值高、留下很多内存碎片
            guard let (entries, subfolders) = autoreleasepool(invoking: { list(folder) }) else {
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
            if pendingRoots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
                deferredChanges[folder] = (deferredChanges[folder] ?? false) || recursive
                continue
            }
            guard isIndexed(folder) else { continue }
            touched = true
            // 系统说要整个重新扫描时，先把这个文件夹下面的全部去掉
            if recursive { removeSubtree(folder) }
            guard let (entries, subfolders) = autoreleasepool(invoking: { Self.list(folder) }) else {
                removeSubtree(folder)   // 文件夹被删了
                contentScopes.append(ContentIndex.Scope(folder: folder, recursive: true))
                continue
            }
            // 消失的子文件夹（被删除、改名或移走）：和原来列着的子文件夹比
            let current = Set(subfolders)
            var gone: [String] = []
            if let old = folders[folder] {
                for index in old.indices where old.isDirectory(at: index) && !old.isPackage(at: index) {
                    let name = old.name(at: index)
                    let child = folder == "/" ? "/" + name : folder + "/" + name
                    if !current.contains(child) && folders[child] != nil {
                        removeSubtree(child)
                        gone.append(child)
                    }
                }
            }
            folders[folder] = entries
            Self.collectContentFiles(folder, entries, into: &contentFiles)
            contentScopes.append(ContentIndex.Scope(folder: folder, recursive: recursive))
            var denied: [String] = []
            for sub in subfolders where folders[sub] == nil {
                var scanned: [String: FolderEntries] = [:]
                Self.scanTree(sub, into: &scanned, denied: &denied)
                folders.merge(scanned) { _, new in new }
                for (path, entries) in scanned { Self.collectContentFiles(path, entries, into: &contentFiles) }
                if !recursive { contentScopes.append(ContentIndex.Scope(folder: sub, recursive: true)) }
            }
            if !recursive { contentScopes += gone.map { ContentIndex.Scope(folder: $0, recursive: true) } }
        }
        if touched { publishCount() }
        if !contentScopes.isEmpty { contentIndex?.sync(files: contentFiles, scopes: contentScopes) }
    }

    /// 这个文件夹在索引范围里吗：是扫过的位置本身，或者上一级文件夹里列着它、而且它不是“包”。
    /// 包（.app、照片图库）、隐藏文件夹、外接硬盘上的 Windows 系统文件夹扫描时都没收，里面有变化也不收。
    /// 上一级也是新的时不用管：处理上一级时会把它整个扫一遍。
    private func isIndexed(_ folder: String) -> Bool {
        if Self.excluded.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) { return false }
        if scannedRoots.contains(folder) { return true }
        guard scannedRoots.contains(where: { folder.hasPrefix($0 + "/") }) else { return false }
        let parent = (folder as NSString).deletingLastPathComponent
        return folders[parent]?.containsFolder(named: (folder as NSString).lastPathComponent) == true
    }

    /// 这些位置扫完、并进索引了：处理扫描期间记下来的变化。
    private func finishedScanning(_ roots: [String]) {
        pendingRoots.removeAll { roots.contains($0) }
        let changes = deferredChanges.filter { change in roots.contains { change.key == $0 || change.key.hasPrefix($0 + "/") } }
        guard !changes.isEmpty else { return }
        changes.keys.forEach { deferredChanges[$0] = nil }
        apply(changes.map { ($0.key, $0.value) })
    }

    /// 去掉这个文件夹和它下面所有的文件夹（按列着的子文件夹往下找，不用把所有文件夹比一遍）。
    private func removeSubtree(_ folder: String) {
        guard let entries = folders.removeValue(forKey: folder) else { return }
        for index in entries.indices where entries.isDirectory(at: index) && !entries.isPackage(at: index) {
            let name = entries.name(at: index)
            removeSubtree(folder == "/" ? "/" + name : folder + "/" + name)
        }
    }
}
