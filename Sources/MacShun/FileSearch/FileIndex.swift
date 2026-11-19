// SPDX-License-Identifier: MIT

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
struct FolderEntries: Equatable {
    struct Item: Equatable {
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
    /// 初扫时允许进入的真实文件夹；增量更新沿用同一决定。
    static let traversableFlag: UInt8 = 16

    private(set) var bytes: [UInt8] = []
    private(set) var items: [Item] = []
    /// 文件和文件夹的个数（不算显示名字）
    private(set) var count = 0

    private var namePairs: UInt64 = 0
    private var hasPronunciations = false
    /// 读取索引时的目录标记，只用于判断是否要再列一次，不参与名称结果比较。
    var directoryFingerprint = 0

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.count == rhs.count && lhs.items == rhs.items && lhs.bytes == rhs.bytes
    }

    /// 两个相邻字节散列为一位。缺位可确定排除，碰撞仍交由完整匹配核实。
    static func pairMask(_ bytes: [UInt8]) -> UInt64 {
        var mask: UInt64 = 0
        for i in bytes.indices.dropFirst() {
            let pair = UInt32(bytes[i - 1]) << 8 | UInt32(bytes[i])
            mask |= 1 << ((pair &* 2_654_435_761) >> 26)
        }
        return mask
    }

    func mightMatch(_ term: FileMatcher.Term) -> Bool {
        if !hasPronunciations && !term.isASCII { return false }
        if hasPronunciations && (term.isASCII || term.pronunciation != nil) { return true }
        return namePairs & term.namePairs == term.namePairs
    }

    init() {}

    init(_ entries: [FileEntry]) {
        entries.forEach { append($0) }
    }

    mutating func reserveCapacity(_ count: Int) {
        items.reserveCapacity(count)
    }

    mutating func append(_ entry: FileEntry, mayDescend: Bool = true) {
        var flags: UInt8 = 0
        if entry.isDirectory { flags |= Self.directoryFlag }
        if entry.isPackage { flags |= Self.packageFlag }
        if entry.isDirectory && !entry.isPackage && mayDescend { flags |= Self.traversableFlag }
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

    /// 直接比较扫描时存好的小写字节，包含访达显示名。
    func hasFullName(_ name: FileMatcher.Term, at index: Int) -> Bool {
        func equals(_ item: Item) -> Bool {
            guard Int(item.lowerLength) == name.bytes.count else { return false }
            let start = Int(item.lowerStart)
            return bytes[start ..< start + name.bytes.count].elementsEqual(name.bytes)
        }
        let item = items[index]
        if equals(item) || (item.flags & Self.hasDisplayNameFlag != 0 && equals(items[index + 1])) { return true }
        // 访达通常省略 .app；这个显示名没有重复存进索引。
        guard item.flags & Self.packageFlag != 0, Int(item.stemLength) == name.bytes.count,
              Int(item.lowerLength) == name.bytes.count + 4 else { return false }
        let start = Int(item.lowerStart), stemEnd = start + name.bytes.count
        return bytes[stemEnd ..< stemEnd + 4].elementsEqual(".app".utf8) && bytes[start ..< stemEnd].elementsEqual(name.bytes)
    }

    func isDirectory(at index: Int) -> Bool { items[index].flags & Self.directoryFlag != 0 }

    func isTraversable(at index: Int) -> Bool { items[index].flags & Self.traversableFlag != 0 }

    /// 外接盘没有单独的访达显示名。逐字节比较，大小写或 Unicode 拼写变化也要重新收录。
    func matchesDriveEntry(_ entry: FileEntry, at index: Int, mayDescend: Bool) -> Bool {
        guard index < items.count else { return false }
        let item = items[index]
        let flags = (entry.isDirectory ? Self.directoryFlag : 0) | (entry.isPackage ? Self.packageFlag : 0)
            | (mayDescend ? Self.traversableFlag : 0)
        let start = Int(item.nameStart)
        return item.flags == flags && bytes[start..<start + Int(item.nameLength)].elementsEqual(entry.name.utf8)
    }

    /// 这个名字是不是允许扫描的子文件夹
    func containsFolder(named name: String) -> Bool {
        index(ofName: name, requiring: Self.traversableFlag) != nil
    }

    /// 精确比较磁盘名字的原始字节，跳过仅用于搜索的访达显示名。
    func index(ofName name: String, requiring flags: UInt8 = 0) -> Int? {
        let target = Array(name.utf8)
        var i = 0
        while i < items.count {
            let item = items[i]
            if item.flags & flags == flags, Int(item.nameLength) == target.count {
                let start = Int(item.nameStart)
                if bytes[start ..< start + target.count].elementsEqual(target) { return i }
            }
            i += item.flags & Self.hasDisplayNameFlag != 0 ? 2 : 1
        }
        return nil
    }

    /// 每个文件（不含显示名字）的位置
    var indices: some Sequence<Int> {
        items.indices.lazy.filter { items[$0].flags & Self.displayNameFlag == 0 }
    }

    /// 和查询匹配的文件，回调位置和得分。
    func forEachMatch(_ terms: [FileMatcher.Term], depth: Int, folderTerms: [Bool] = [], filters: FileSearchFilters = .init(), allowEmpty: Bool = false,
                      isCancelled: () -> Bool = { false }, _ body: (Int, Double) -> Void) {
        // 单独输入点号时只列点号开头的名字，避免把所有带扩展名的文件都列出来。
        let dotNamesOnly = terms.count == 1 && terms[0].bytes == [0x2E]
        bytes.withUnsafeBufferPointer { buffer in
            var i = 0
            // 调用方在目录之间检查取消；大目录内仍按条目检查。
            var nextCheck = 512
            while i < items.count {
                if i >= nextCheck {
                    if isCancelled() { return }
                    nextCheck = i + 512
                }
                let hasDisplay = items[i].flags & Self.hasDisplayNameFlag != 0
                let index = i
                let item = items[index]
                let display = hasDisplay ? items[index + 1] : nil
                i += hasDisplay ? 2 : 1
                if dotNamesOnly && (item.nameLength == 0 || buffer[Int(item.nameStart)] != 0x2E) { continue }
                if !filters.isEmpty {
                    func lower(_ value: Item) -> UnsafeBufferPointer<UInt8> {
                        let start = Int(value.lowerStart)
                        return UnsafeBufferPointer(rebasing: buffer[start ..< start + Int(value.lowerLength)])
                    }
                    guard filters.accepts(lower(item), display: display.map(lower), isDirectory: isDirectory(at: index)) else { continue }
                }
                if terms.isEmpty && (allowEmpty || !filters.isEmpty) { body(index, 1); continue }
                let score = FileMatcher.score(query: terms, item: item, display: display, in: buffer, depth: depth,
                                              folderTerms: folderTerms, matchedExtension: !filters.suffixes.isEmpty)
                if score > 0 { body(index, score) }
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
        namePairs |= Self.pairMask(lower)
        var lowerStart = nameStart
        if lower != name {
            lowerStart = bytes.count
            bytes.append(contentsOf: lower)
        }
        var stem = lower.count
        if let dot = lower.lastIndex(of: 0x2E), dot > 0 { stem = dot }
        var pinyinStart = 0, pinyinLength = 0
        if name.contains(where: { $0 >= 0x80 }) {
            hasPronunciations = true
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
    enum NameRank: Int { case partial, exact, exactInFinder }

    let path: String
    /// 显示的名字（应用程序用访达里的名字）
    let name: String
    let isDirectory: Bool
    let score: Double
    /// 按内容搜到的：匹配处附近的一段文字
    var snippet: String? = nil

    var nameRank: NameRank = .partial
    var canSearchInside = false
    var metadata: FileSearchMetadata? = nil
    var isHomophone = false

    var id: String { path }
    var fileURL: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
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
        if let pronunciation = term.pronunciation, !pinyin.isEmpty {
            var offset = 0
            while offset <= pinyin.count - pronunciation.count {
                let end = offset + pronunciation.count
                if (end == pinyin.count || pinyin[end] == 0), pinyin[offset..<end].elementsEqual(pronunciation) { return 28 }
                repeat { offset += 1 } while offset < pinyin.count && pinyin[offset - 1] != 0
            }
        } else if term.isASCII, !pinyin.isEmpty, PinyinIndex.syllableMatch(term.bytes, encoded: pinyin) {
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
                      in buffer: UnsafeBufferPointer<UInt8>, depth: Int, folderTerms: [Bool], matchedExtension: Bool) -> Double {
        var total = 0.0
        var matchedName = matchedExtension
        for (i, term) in terms.enumerated() {
            let byName = score(term: term, item: item, display: display, in: buffer)
            if byName > 0 {
                matchedName = true
                total += byName
            } else if !folderTerms.isEmpty && folderTerms[i] {
                total += 15
            } else {
                return 0
            }
        }
        guard matchedName else { return 0 }
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
        let text: String
        private(set) var bytes: [UInt8]
        let isASCII: Bool
        let namePairs: UInt64
        private(set) var pronunciation: [UInt8]?

        init(_ text: String, pronunciation: [UInt8]? = nil) {
            self.text = FolderEntries.matchForm(text, isASCII: text.utf8.allSatisfy { $0 < 0x80 })
            bytes = Array(self.text.utf8)
            namePairs = FolderEntries.pairMask(bytes)
            isASCII = bytes.allSatisfy { $0 < 0x80 }
            self.pronunciation = pronunciation
        }

        func workerCopy() -> Self {
            var copy = self
            copy.bytes = bytes.withUnsafeBufferPointer { Array($0) }
            copy.pronunciation = pronunciation?.withUnsafeBufferPointer { Array($0) }
            return copy
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
        struct DirectoryInput {
            let folder: String
            /// 末尾的 / 明确要求列出子项。否则最后一段是本层的文件名。
            let listsChildren: Bool
        }

        let filters: FileSearchFilters
        let contentText: String
        let fullName: Term
        let isPlainName: Bool
        private let isLiteral: Bool
        let directoryInput: DirectoryInput?
        let terms: [Term]
        /// 路径里的文件夹，一段一段（比较用的形式），每段是能对上的写法（本来的、对应的真名）
        let folders: [Set<String>]
        /// 写的是完整路径（/ 开头）：存在的话直接放在最前面，没收录的位置（例如“资源库”里）也能打开
        let absolutePath: String?
        /// 带 / 但不像完整路径时，也可能是名字里的 /（访达把名字里的 : 显示成 /，例如“AC/DC”）：
        /// 整个查询再按名字搜一遍，取好的那个
        let nameTerms: [Term]?

        init(_ query: String) {
            var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var literal = false
            // 只移除成对的外层引号，保留文件名末尾真正的撇号。
            if let first = text.first, let last = text.last, text.count >= 2,
               ["\"": "\"", "'": "'", "“": "”", "‘": "’"][String(first)] == String(last) {
                text = String(text.dropFirst().dropLast())
                literal = true
            }
            isPlainName = !text.contains("/") && !text.contains("\\")
            isLiteral = literal
            if isPlainName {
                let parsed = FileSearchFilters.parse(text, literal: literal)
                filters = parsed.filters
                contentText = parsed.words
                fullName = Term(parsed.words)
                directoryInput = nil
                (terms, folders, absolutePath, nameTerms) = (FileMatcher.terms(of: parsed.words), [], nil, nil)
                return
            }
            var endsInSlash = text.hasSuffix("/")
            if text.hasPrefix("file://"), let url = URL(string: text), url.isFileURL {
                text = url.path
                literal = true
                endsInSlash = url.hasDirectoryPath
            }
            let nativePath = text.hasPrefix("/") || text.hasPrefix("~/")
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
            let parsed = FileSearchFilters.parse(parts.last ?? "", literal: literal || endsInSlash)
            filters = parsed.filters
            contentText = filters.isEmpty ? query : parsed.words
            absolutePath = filters.isEmpty ? absolute.flatMap { $0.count > 1 ? $0 : nil } : nil
            fullName = Term(parsed.words)
            if nativePath, let absolute {
                let folder = endsInSlash ? absolute : (absolute as NSString).deletingLastPathComponent
                directoryInput = DirectoryInput(folder: folder, listsChildren: endsInSlash)
            } else {
                directoryInput = nil
            }
            nameTerms = !filters.isEmpty || looksAbsolute || query.contains("\\") ? nil : FileMatcher.terms(of: text.replacingOccurrences(of: "/", with: ":"))
            terms = FileMatcher.terms(of: parsed.words)
            folders = parts.dropLast().map { part in
                let form = FolderEntries.matchForm(part, isASCII: part.utf8.allSatisfy { $0 < 0x80 })
                return Set([form] + (FileMatcher.folderAliases[form].map { [$0] } ?? []))
            }
        }

        func withHomophones() -> Self? {
            guard isPlainName, !isLiteral, terms.flatMap({ $0.text.filter(Pinyin.isHan) }).count >= 2 else { return nil }
            let spoken = terms.map { term -> Term in
                guard term.text.contains(where: Pinyin.isHan) else { return term }
                let encoded = FolderEntries.encodePinyin(term.text)
                guard !encoded.isEmpty, !encoded.contains(0xFF) else { return term }
                return Term(term.text, pronunciation: encoded)
            }
            guard spoken.contains(where: { $0.pronunciation != nil }) else { return nil }
            return Self(copying: self, terms: spoken)
        }

        /// 各个工作线程反复读取词的字节，独立存储避免在每条记录上争用同一引用计数。
        func workerCopy() -> Self {
            Self(copying: self, terms: terms.map { $0.workerCopy() })
        }

        private init(copying query: Self, terms: [Term]) {
            filters = query.filters
            contentText = query.contentText
            fullName = query.fullName
            isPlainName = query.isPlainName
            isLiteral = query.isLiteral
            directoryInput = query.directoryInput
            self.terms = terms
            folders = query.folders
            absolutePath = query.absolutePath
            nameTerms = query.nameTerms
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
/// 点号开头的用户文件也按名称收录；跳过系统杂项、应用包内部及工具缓存。
/// 外接硬盘可能很大、读起来很慢（例如 macOS 只读挂载的 NTFS 盘），放在第二轮后台扫，不耽误搜索。
/// NTFS 驱动（FSKit）查每个文件的属性很慢，而且一次只处理一个，所以外接硬盘只读目录（readdir），
/// 只给文件夹查隐藏标记，几块盘一起用几个线程扫：实测 6 万个文件从 10 秒降到 0.5 秒。
///
/// queue 合并扫描结果、处理 FSEvents。搜索在独立队列读取快照，状态在主线程发布。
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
    @Published private(set) var locationStatuses: [UUID: FileSearchLocationStatus] = [:]

    /// 是否包括外接硬盘。改了之后要重新建立索引才生效。只在主线程上改。
    var includeExternalDrives = true

    /// 文件内容索引（F2）。扫描完、文件有变化时，把要读内容的文件交给它。只在 queue 上读写，用 setContentIndex 设置
    private var contentIndex: ContentIndex?
    /// 这次要扫描的位置（包括还没扫到的外接硬盘），只在 queue 上读写
    private var plannedRoots: [String] = []

    private let queue: DispatchQueue
    private let scanQueue = DispatchQueue(label: "MacShun.FileIndex.scan", qos: .utility)
    private let watchQueue = DispatchQueue(label: "MacShun.FileIndex.watches", qos: .utility)
    private let driveQueue = DispatchQueue(label: "MacShun.FileIndex.drives", qos: .background)
    private let networkQueue = DispatchQueue(label: "MacShun.FileIndex.network", qos: .utility, attributes: .concurrent)
    private let temporaryNetworkSearchQueue = DispatchQueue(label: "MacShun.FileIndex.networkSearch", qos: .utility)

    /// 以下只在 queue 上读写
    /// 文件夹路径 → 里面的文件
    private var folders = IndexedFolders()
    /// 这次扫描的位置（判断 FSEvents 的变化在不在范围里时用）
    private var scannedRoots: [String] = []
    /// 第几次建立索引。重新建立后，上一次还没扫完的结果作废
    private var activeGeneration = 0
    /// 正在扫描、还没并进索引的位置。这期间这些位置下的变化先记下来，扫完再处理，免得漏掉或被扫描结果盖掉
    private var pendingRoots: [String] = []
    private var deferredChanges: [String: Bool] = [:]
    private var pendingDriveChanges = FileIndexChanges()
    /// 搜索只读一次快照，避免匹配和后台索引更新互相占住队列。
    private let searchQueue = DispatchQueue(label: "MacShun.FileIndex.search", qos: .userInitiated)
    /// 仅在 searchQueue 上缓存已读过的直系子项。事件发布新快照时也会重新核对。
    private var recentListings: [String: (stamp: DirectoryStamp, indexed: FolderEntries, listing: FolderEntries)] = [:]
    private var finderTitleMatches: (title: String, setID: UUID, revisions: [UInt64], paths: [[String]])?
    /// 查询先看到了索引之外的变化。文件事件到达后要核对已经显示的结果。
    private let pendingRecentFolders = Locked(Set<String>())

    /// 文件名查询读取最近发布的完整批次。文件系统事件可能花几秒读盘，不能占住查询入口。
    private struct SearchSnapshot {
        var generation = 0
        var localRoots: [String] = []
        var folders = IndexedFolders()
        var network: [UUID: NetworkSearchSnapshot] = [:]
        var routes: [(location: FileSearchLocation, mounted: String?)] = []
        var failedShares: Set<UUID> = []
    }
    private let searchable = Locked(SearchSnapshot())

    /// Stream 持有回调上下文。晚到的回调通过弱引用访问索引，关停后不会访问已释放的对象。
    private final class WatchContext {
        weak var index: FileIndex?
        init(_ index: FileIndex) { self.index = index }
    }

    /// 只在 watchQueue 上启动、冲刷及关闭，回调由索引队列处理。
    private var streams: [FSEventStreamRef] = []

    /// 以下只在主线程上读写
    private var generation = 0
    private var started = false
    private var volumeObservers: [NSObjectProtocol] = []
    /// 这次扫描的外接硬盘
    private var currentDrives: [String] = []
    private var indexedLocations: [FileSearchLocation] = []
    private var networkPaths: [UUID: String] = [:]
    private var networkJobs: [UUID: Locked<Bool>] = [:]
    private var networkPoll: Timer?

    private let mainRoots: [String]
    private let recentFolders: [String]
    private let externalRoots: () -> [String]
    private let mountedVolumes: () -> [SearchVolume]

    init(mainRoots: [String] = FileIndex.defaultRoots, mountedVolumes: @escaping () -> [SearchVolume] = SearchVolume.mounted,
         externalRoots: @escaping () -> [String] = FileIndex.driveRoots,
         recentFolders: [String] = FileIndex.defaultRecentFolders,
         indexQueue: DispatchQueue = DispatchQueue(label: "MacShun.FileIndex", qos: .utility)) {
        queue = indexQueue
        self.externalRoots = externalRoots
        self.mainRoots = mainRoots
        self.recentFolders = recentFolders
        self.mountedVolumes = mountedVolumes
    }

    deinit {
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        networkPoll?.invalidate()
        networkJobs.values.forEach { $0.set(true) }
        let existing = streams
        if !existing.isEmpty {
            watchQueue.async {
                for stream in existing {
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                }
            }
        }
    }

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let defaultRecentFolders = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }

    /// 第一轮扫描的位置。Safari 的真身在 Cryptexes 里，“应用程序”里只有一个带隐藏标记的替身
    private static let defaultRoots = [
        home, "/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications", "/Users/Shared",
    ]

    /// 外接硬盘（本地的、在访达里能看到的，不含系统盘）
    private static func driveRoots() -> [String] {
        let keys: [URLResourceKey] = [.volumeIsRootFileSystemKey, .volumeIsLocalKey, .volumeIsBrowsableKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        let local = Set(SearchVolume.mounted().lazy.filter(\.isLocal).map(\.path))
        return volumes.compactMap { volume in
            guard local.contains(volume.path), let values = try? volume.resourceValues(forKeys: Set(keys)),
                  values.volumeIsRootFileSystem != true, values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  volume.path.hasPrefix("/Volumes/")
            else { return nil }
            return volume.path
        }.sorted()
    }

    func setIndexedLocations(_ locations: [FileSearchLocation]) {
        guard indexedLocations != locations else { return }
        let localsChanged = indexedLocations.filter { $0.share == nil } != locations.filter { $0.share == nil }
        indexedLocations = locations
        guard started else { return }
        if localsChanged { rebuild() }
        pollNetworkLocations()
    }

    func makeLocation(for path: String) -> FileSearchLocation? {
        FileSearchLocation(path: path, mounts: mountedVolumes())
    }

    /// 开始建立索引并跟踪变化。已经开始过就不再重复。只在主线程上调用。
    func start() {
        guard !started else { return }
        started = true
        rebuild()
        pollNetworkLocations()
        // 接上或拔掉外接硬盘后，扫描位置变了，重新来一遍
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 只有外接硬盘真的变了才重新扫描（例如系统挂载了不显示的卷时不用）
                guard let self, self.started else { return }
                self.pollNetworkLocations()
                if self.includeExternalDrives, self.externalRoots() != self.currentDrives { self.rebuild() }
            })
        }
    }

    /// 停止并清空，释放内存。
    func stop() {
        guard started else { return }
        started = false
        generation += 1
        let gen = generation
        searchable.set(SearchSnapshot(generation: gen))
        searchQueue.async {
            self.recentListings.removeAll()
            self.finderTitleMatches = nil
            self.pendingRecentFolders.set([])
        }
        watchQueue.async { self.stopWatching() }
        volumeObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        volumeObservers = []
        networkPoll?.invalidate()
        networkPoll = nil
        networkJobs.values.forEach { $0.set(true) }
        networkPaths = [:]
        locationStatuses = [:]
        queue.async {
            self.activeGeneration = gen
            self.folders = IndexedFolders()
            self.scannedRoots = []
            self.pendingRoots = []
            self.deferredChanges = [:]
            self.pendingDriveChanges = FileIndexChanges()
            self.plannedRoots = []
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
        let locals = indexedLocations.filter { $0.share == nil }
        let configured = Self.uniquePaths(self.mainRoots + locals.map(\.path))
        let volumes = includeExternalDrives ? externalRoots() : []
        searchable.update {
            $0.generation = gen
            $0.localRoots = configured + volumes
        }
        currentDrives = volumes
        func onDrive(_ path: String) -> Bool {
            path.hasPrefix("/Volumes/") || volumes.contains { SearchVolume.contains(path, under: $0) }
        }
        let mainRoots = configured.filter { !onDrive($0) }
        let drives = Self.uniquePaths(volumes + configured.filter(onDrive))
        let mainLocations = locals.filter { !onDrive($0.path) }
        let driveLocations = locals.filter { onDrive($0.path) }
        updateLocalStatuses(locals, available: nil)
        let isFirstScan = lastIndexed == nil
        isIndexing = true
        isScanningDrives = !drives.isEmpty
        let keepDrives = includeExternalDrives
        queue.async {
            self.activeGeneration = gen
            let roots = mainRoots + drives
            let retired = self.plannedRoots.filter { old in !roots.contains { SearchVolume.contains(old, under: $0) } }
            self.plannedRoots = roots
            self.pendingRoots = roots
            self.deferredChanges = [:]
            self.pendingDriveChanges = FileIndexChanges()
            self.contentIndex?.setSearchRoots(roots)
            if !retired.isEmpty {
                for (folder, _) in self.folders where !roots.contains(where: { SearchVolume.contains(folder, under: $0) }) {
                    self.folders[folder] = nil
                }
                self.publishCount()
            }
            // 关掉了“包括外接硬盘”时，内容索引里外接硬盘上的文件也去掉；只是拔掉了的留着，插回来不用重新读
            self.contentIndex?.prune(keeping: configured + (keepDrives ? ["/Volumes"] : []))
        }
        scanQueue.async {
            self.watchQueue.sync {
                if self.isCurrentScan(gen) { self.restartWatching(mainRoots + drives) }
            }
            let begin = Date()
            var result: [String: FolderEntries] = [:]
            var denied: [String] = []
            let cancelled = { !self.isCurrentScan(gen) }
            Self.scanLocalRoots(mainRoots, denied: &denied, isCancelled: cancelled) { batch in
                result.merge(batch) { _, new in new }
                // 冷启动还没有上一轮快照。已经读完的目录先供查询，正文仍在主盘扫描结束后统一核对。
                if isFirstScan {
                    self.queue.sync {
                        guard self.isCurrentScan(gen) else { return }
                        self.folders.merge(batch)
                        self.publishCount()
                    }
                }
            }
            guard !cancelled() else { return }
            Log.app.notice("文件索引：第一轮 \(result.values.reduce(0) { $0 + $1.count }, privacy: .public) 个，用时 \(Date().timeIntervalSince(begin), format: .fixed(precision: 2), privacy: .public) 秒")
            self.queue.async {
                guard self.isCurrentScan(gen) else { return }
                var unvisited = Set<String>()
                if !isFirstScan && drives.isEmpty {
                    self.folders = IndexedFolders(result)
                } else {
                    // 主盘扫描结束时，外接盘的旧目录仍可搜索。扫描批次会逐项核销。
                    for (path, _) in self.folders where result[path] == nil {
                        if drives.contains(where: { SearchVolume.contains(path, under: $0) }) { unvisited.insert(path) }
                        else { self.folders[path] = nil }
                    }
                    if !isFirstScan { self.folders.merge(result) }
                }
                self.scannedRoots = mainRoots
                let available = Set(mainLocations.lazy.map(\.path).filter { result[$0] != nil })
                self.publishCount { _ in
                    self.isIndexing = false
                    self.lastIndexed = Date()
                    self.deniedFolders = denied
                    self.updateLocalStatuses(mainLocations, available: available)
                }
                self.sendContent(result, scopes: mainRoots.map { ContentIndex.Scope(folder: $0, recursive: true) })
                self.finishedScanning(mainRoots)
                malloc_zone_pressure_relief(nil, 0)
                guard !drives.isEmpty else { return }
                self.driveQueue.async { self.scanDrives(drives, unvisited: unvisited, locations: driveLocations, generation: gen) }
            }
        }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func updateLocalStatuses(_ locals: [FileSearchLocation], available: Set<String>?) {
        var statuses = locationStatuses.filter { id, _ in indexedLocations.contains { $0.id == id } }
        for location in locals {
            statuses[location.id] = available.map { $0.contains(location.path) ? .ready : .unavailable } ?? .indexing
        }
        if locationStatuses != statuses { locationStatuses = statuses }
    }

    /// SMB changes are reconciled off the local scan queue. A stalled share keeps at most one scan in flight.
    func pollNetworkLocations() {
        guard started else { return }
        let locations = indexedLocations.filter { $0.share != nil }
        if locations.isEmpty {
            networkPoll?.invalidate()
            networkPoll = nil
        } else if networkPoll == nil {
            networkPoll = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                self?.pollNetworkLocations()
            }
        }
        let mounts = locations.isEmpty ? [] : mountedVolumes()
        let routes = locations.map { (location: $0, mounted: $0.mountedPath(in: mounts)) }
        let paths = Dictionary(routes.compactMap { route in route.mounted.map { (route.location.id, $0) } },
                               uniquingKeysWith: { first, _ in first })
        for id in networkJobs.keys where networkPaths[id] != paths[id] { networkJobs[id]?.set(true) }
        var statuses = locationStatuses.filter { id, _ in indexedLocations.contains { $0.id == id } }
        for location in locations {
            let id = location.id
            if paths[id] == nil { statuses[id] = .offline }
            else if paths[id] != networkPaths[id] { statuses[id] = .indexing }
        }
        networkPaths = paths
        if statuses != locationStatuses { locationStatuses = statuses }
        let removed = searchable.update { state in
            state.routes = routes
            let stale = state.network.keys.filter { state.network[$0]?.root != paths[$0] }
            for id in stale { state.network[id] = nil }
            state.failedShares.formIntersection(Set(paths.keys))
            return !stale.isEmpty
        }
        if removed { queue.async { self.publishCount() } }
        for route in routes {
            guard let path = route.mounted, networkJobs[route.location.id] == nil else { continue }
            startNetworkScan(id: route.location.id, path: path)
        }
    }

    private func startNetworkScan(id: UUID, path: String) {
        let cancelled = Locked(false)
        networkJobs[id] = cancelled
        if locationStatuses[id] != .ready { locationStatuses[id] = .indexing }
        networkQueue.async {
            let snapshot = NetworkSearchSnapshot.read(path, cancelled: cancelled.get)
            DispatchQueue.main.async {
                self.networkJobs[id] = nil
                guard self.started else { return }
                guard !cancelled.get(), self.networkPaths[id] == path else {
                    if let replacement = self.networkPaths[id] { self.startNetworkScan(id: id, path: replacement) }
                    return
                }
                self.locationStatuses[id] = snapshot == nil ? .offline : .ready
                self.searchable.update { state in
                    state.network[id] = snapshot
                    if snapshot == nil { state.failedShares.insert(id) }
                    else { state.failedShares.remove(id) }
                }
                self.queue.async { self.publishCount() }
            }
        }
    }

    func isFolderIndexed(_ path: String, completion: @escaping (Bool) -> Void) {
        let snapshot = searchable.get()
        let indexed = snapshot.folders[path] != nil || snapshot.network.values.contains { $0.folders[path] != nil }
            || snapshot.routes.contains { route in
                SearchVolume.contains(path, under: route.location.path)
                    || route.mounted.map { SearchVolume.contains(path, under: $0) } == true
            }
        DispatchQueue.main.async { completion(indexed) }
    }

    func activePath(for location: FileSearchLocation) -> String {
        networkPaths[location.id] ?? location.path
    }

    func resolvedLocationPath(_ path: String) -> String {
        guard let location = indexedLocations.filter({ networkPaths[$0.id] != nil && SearchVolume.contains(path, under: $0.path) })
            .max(by: { $0.path.count < $1.path.count }) else { return path }
        return activePath(for: location) + path.dropFirst(location.path.count)
    }

    private func isCurrentScan(_ gen: Int) -> Bool {
        searchable.update { $0.generation == gen }
    }

    /// 第二轮：几块外接硬盘一起扫。边扫边并进索引、交给内容索引去读，不用等全部扫完。
    private func scanDrives(_ drives: [String], unvisited: Set<String>, locations: [FileSearchLocation], generation gen: Int) {
        let begin = Date()
        var remaining = unvisited
        Self.scanTreesInParallel(drives, threads: 4, previous: { path in
            self.searchable.update { $0.folders[path] }
        }, isCancelled: { !self.isCurrentScan(gen) }) { batch in
            // 等这一批并入后才继续读盘，限制排队的批次，同时保留独立的查询队列。
            self.queue.sync {
                guard self.isCurrentScan(gen) else { return }
                self.mergeDriveBatch(batch, remaining: &remaining)
            }
        }
        // 等待扫描期间已发生的文件事件送达索引队列，再合并其最终状态。
        watchQueue.sync { flushWatchedChanges(gen) }
        queue.async {
            guard self.isCurrentScan(gen) else { return }
            self.scannedRoots.append(contentsOf: drives)
            self.applyPendingDriveChanges()
            self.finishDriveScan(drives, remaining: remaining)
            self.finishedScanning(drives)
            let count = self.folders.fileCount
            Log.app.notice("文件索引：外接硬盘扫完，共 \(count, privacy: .public) 个，用时 \(Date().timeIntervalSince(begin), format: .fixed(precision: 1), privacy: .public) 秒")
            malloc_zone_pressure_relief(nil, 0)
            let available = Set(locations.lazy.map(\.path).filter { self.folders[$0] != nil })
            self.publishCount { _ in
                self.isScanningDrives = false
                self.updateLocalStatuses(locations, available: available)
            }
        }
    }

    private func mergeDriveBatch(_ batch: [String: FolderEntries], remaining: inout Set<String>) {
        var changed = false
        for (path, entries) in batch {
            remaining.remove(path)
            if folders[path] != entries {
                folders[path] = entries
                changed = true
            }
        }
        if changed { publishCount() }
        contentIndex?.sync(folders: batch)
    }

    private func finishDriveScan(_ roots: [String], remaining: Set<String>) {
        for path in remaining { folders[path] = nil }
        if !remaining.isEmpty { publishCount() }
        contentIndex?.removeMissing(in: folders, scopes: roots.map { .init(folder: $0, recursive: true) })
    }

    /// MustScanSubDirs 已在索引队列上执行。单个遍历器分批更新，查询始终使用最近发布的快照。
    private func rescanDriveSubtree(_ root: String, isCancelled: () -> Bool) {
        var remaining = Set(folders.lazy.map(\.key).filter { SearchVolume.contains($0, under: root) })
        // 显式收录的位置可能位于这个卷的包或不自动进入的目录中。
        let roots = [root] + scannedRoots.filter { $0 != root && SearchVolume.contains($0, under: root) }
        Self.scanTreesInParallel(roots, threads: 1, previous: { self.folders[$0] }, isCancelled: isCancelled) { batch in
            self.mergeDriveBatch(batch, remaining: &remaining)
        }
        guard !isCancelled() else { return }
        finishDriveScan([root], remaining: remaining)
        let gen = activeGeneration
        watchQueue.async {
            self.flushWatchedChanges(gen)
            self.queue.async { if self.isCurrentScan(gen) { self.applyPendingDriveChanges() } }
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
    private func sendContent<S: Sequence>(_ folders: S, scopes: [ContentIndex.Scope]) where S.Element == (key: String, value: FolderEntries) {
        guard let contentIndex else { return }
        contentIndex.sync(folders: folders)
        if !scopes.isEmpty { contentIndex.removeMissing(in: self.folders, scopes: scopes) }
    }

    static func indexesContents(in folder: String) -> Bool {
        guard !systemContentRoots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else { return false }
        return !folder.split(separator: "/").contains { part in
            part.hasPrefix(".") || skippedForContent.contains(String(part)) || part.lowercased().contains("cache")
        }
    }

    private static func collectContentFiles(_ folder: String, _ entries: FolderEntries, into files: inout [String]) {
        forEachContentName(in: folder, entries: entries) { name, _ in
            files.append(folder == "/" ? "/" + name : folder + "/" + name)
        }
    }

    static func forEachContentName(in folder: String, entries: FolderEntries, _ body: (String, ContentExtractor.Kind) throws -> Void) rethrows {
        guard indexesContents(in: folder) else { return }
        for index in entries.indices where !entries.isDirectory(at: index) {
            let name = entries.name(at: index)
            if !name.hasPrefix("."), let kind = ContentExtractor.kind(ofFileNamed: name) { try body(name, kind) }
        }
    }

    private func publishSearchSnapshot() {
        searchable.update { state in
            if state.generation == activeGeneration { state.folders = folders }
        }
    }

    /// 在 queue 上数一下总数，回到主线程更新界面。
    private func publishCount(then: @escaping (Int) -> Void = { _ in }) {
        var networkFolders = Set<String>()
        let networkCount = searchable.get().network.values.reduce(0) { total, snapshot in
            total + snapshot.folders.reduce(0) { $0 + (networkFolders.insert($1.key).inserted ? $1.value.count : 0) }
        }
        let count = folders.fileCount + networkCount
        publishSearchSnapshot()
        let gen = activeGeneration
        DispatchQueue.main.async {
            guard self.generation == gen else { return }
            self.fileCount = count
            then(count)
        }
    }

    /// 空访达窗口有时只有标题。保留所有同名目录；有歧义时不指定排序优先位置。
    private func foldersWithFinderTitle(_ title: String, in snapshot: SearchSnapshot,
                                        isCancelled: () -> Bool) -> [String] {
        let folders = snapshot.folders
        let previous = finderTitleMatches.flatMap { $0.title == title && $0.setID == folders.directorySetID ? $0 : nil }
        var paths = previous?.paths ?? Array(repeating: [], count: folders.partitions.count)
        let suffix = "/" + title
        // 文件内容变化不改变目录位置；目录被增删时也只核对相应分区。
        for i in folders.partitions.indices where previous?.revisions[i] != folders.pathRevisions[i] {
            var matches: [String] = []
            for (offset, path) in folders.partitions[i].keys.enumerated() {
                if offset.isMultiple(of: 256), isCancelled() { return [] }
                if path.hasSuffix(suffix) { matches.append(path) }
            }
            paths[i] = matches
        }
        finderTitleMatches = (title, folders.directorySetID, folders.pathRevisions, paths)
        return paths.flatMap { $0 }
    }

    /// 受关注的访达目录可能比快照更新，甚至初扫还没发布。只在配置范围内沿可进入的目录查找。
    private func canReadFinderFolder(_ path: String, in snapshot: SearchSnapshot, isCancelled: () -> Bool) -> Bool {
        guard let root = snapshot.localRoots.filter({ SearchVolume.contains(path, under: $0) }).max(by: { $0.count < $1.count })
        else { return false }
        var folder = path
        while folder != root && snapshot.folders[folder] == nil {
            guard !isCancelled(), FileSearchDirectory.mayReadNewFolder(folder) else { return false }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return true
    }

    /// 常用目录和呼出面板时的访达目录都只核对直接子项。只读取收录范围内的本地目录，
    /// 并将改动用于本次查询；主索引和全文更新继续由文件事件维护。
    private func withRecentListings(_ snapshot: SearchSnapshot, finderPaths: [String], within requested: String?,
                                    isCancelled: () -> Bool) -> IndexedFolders {
        var paths = Set(recentFolders.filter { snapshot.folders[$0] != nil })
        if !finderPaths.isEmpty {
            let mounts = mountedVolumes()
            let remote = mounts.filter { !$0.isLocal }
            for finder in finderPaths {
                if isCancelled() { return snapshot.folders }
                if let requested, requested != finder { continue }
                if remote.contains(where: { $0.contains(finder) }) { continue }
                guard canReadFinderFolder(finder, in: snapshot, isCancelled: isCancelled) else { continue }
                paths.insert(finder)
            }
            pendingRecentFolders.update { $0.formIntersection(paths) }
        }
        // 切换搜索上下文时释放旧列表。待核对标记独立于缓存，索引事件仍能刷新结果。
        for old in recentListings.keys where !paths.contains(old) {
            recentListings.removeValue(forKey: old)
        }
        var current = snapshot.folders
        for path in paths {
            if isCancelled() { break }
            if let requested, requested != path { continue }
            guard let stamp = DirectoryStamp(path: path) else {
                recentListings[path] = nil
                continue
            }
            let indexed = snapshot.folders[path] ?? FolderEntries()
            if finderPaths.count > 1 && !recentFolders.contains(path),
               indexed.directoryFingerprint != 0 && indexed.directoryFingerprint == stamp.hashValue {
                recentListings[path] = nil
                continue
            }
            let listing: FolderEntries
            if let cached = recentListings[path], cached.stamp == stamp, cached.indexed == indexed {
                listing = cached.listing
            } else {
                guard let entries = autoreleasepool(invoking: { FileSearchDirectory.read(path, isCancelled: isCancelled)?.entries }),
                      !isCancelled(), DirectoryStamp(path: path) == stamp else { continue }
                listing = entries == indexed ? indexed : entries
                // 变化再多也逐个核对；只留少量访达目录的完整列表供连续输入复用。
                if recentFolders.contains(path) || recentListings[path] != nil || recentListings.count < recentFolders.count + 4 {
                    recentListings[path] = (stamp, indexed, listing)
                }
            }
            // 在记录待核对目录的同时确认它仍然是刚读过的状态，避免错过并行发布的文件事件。
            if listing != indexed, pendingRecentFolders.update({ pending in
                guard DirectoryStamp(path: path) == stamp else { return false }
                pending.insert(path)
                return true
            }) {
                current[path] = listing
            }
        }
        return current
    }

    /// 搜索，结果在主线程上回调。boosts：常打开的文件加的分（见 OpenHistory）
    func search(_ query: String, limit: Int = 60, boosts: [String: Double] = [:],
                isCancelled: @escaping () -> Bool = { false }, completion: @escaping ([FileSearchResult]) -> Void) {
        searchPage(FileMatcher.Query(query), limit: limit, boosts: boosts, isCancelled: isCancelled) {
            completion($0.results)
        }
    }

    func searchPage(_ query: FileMatcher.Query, limit: Int = 60, boosts: [String: Double] = [:],
                    preferredFolder: String? = nil, finderTitle: String? = nil, within: FileSearchFolder? = nil, options: FileSearchOptions = .init(),
                    isCancelled: @escaping () -> Bool = { false },
                    completion: @escaping (FileNameSearch.Page) -> Void) {
        guard limit > 0, !query.terms.isEmpty || !query.filters.isEmpty || query.directoryInput != nil || within != nil || options.hasFilters else {
            completion(.init(results: []))
            return
        }
        let snapshot = searchable.get()
        let requested = within?.path ?? query.directoryInput?.folder
        let route = requested.flatMap { path in
            snapshot.routes.filter { route in
                SearchVolume.contains(path, under: route.location.path) ||
                    route.mounted.map { SearchVolume.contains(path, under: $0) } == true
            }.max { $0.location.path.count < $1.location.path.count }
        }
        var effectiveFolder = within
        if let route {
            guard let mounted = route.mounted, snapshot.network[route.location.id] != nil else {
                let status: FileNameSearch.DirectoryStatus = route.mounted == nil || snapshot.failedShares.contains(route.location.id)
                    ? .offline : .indexing
                DispatchQueue.main.async { if !isCancelled() { completion(.init(results: [], directory: status)) } }
                return
            }
            if let within, mounted != route.location.path, SearchVolume.contains(within.path, under: route.location.path) {
                effectiveFolder = FileSearchFolder(path: mounted + within.path.dropFirst(route.location.path.count))
            }
        }
        let folder = effectiveFolder
        let isTemporaryNetworkSearch = route == nil && requested.map { path in
            mountedVolumes().contains { !$0.isLocal && $0.contains(path) }
        } == true
        let worker = isTemporaryNetworkSearch ? temporaryNetworkSearchQueue : searchQueue
        worker.async {
            guard !isCancelled() else { return }
            var finderPaths = preferredFolder.map { [$0] } ?? []
            var folders = snapshot.folders
            if route == nil && !isTemporaryNetworkSearch {
                if preferredFolder == nil, let finderTitle, requested == nil {
                    finderPaths = self.foldersWithFinderTitle(finderTitle, in: snapshot, isCancelled: isCancelled)
                }
                folders = self.withRecentListings(snapshot, finderPaths: finderPaths, within: requested, isCancelled: isCancelled)
            }
            let preferred = finderPaths.count == 1 ? finderPaths.first : nil
            let search = FileNameSearch(query: query, limit: limit, boosts: boosts, preferredFolder: preferred,
                                        within: folder, options: options, network: Array(snapshot.network.values))
            guard let page = search.run(in: folders, isCancelled: isCancelled) else { return }
            DispatchQueue.main.async { if !isCancelled() { completion(page) } }
        }
    }

    /// 写的是完整路径而且存在：放在最前面。索引里已经搜到的（大小写可能和写的不一样）拿出来，用索引里的写法。
    static func existingFile(_ path: String, among matches: inout [FileSearchResult]) -> FileSearchResult? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        var foundIndex = matches.firstIndex { $0.path == path }
        if foundIndex == nil, !matches.isEmpty,
           (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false {
            let key = FolderEntries.matchForm(path, isASCII: false)
            foundIndex = matches.firstIndex { FolderEntries.matchForm($0.path, isASCII: false) == key }
        }
        if let i = foundIndex {
            let found = matches.remove(at: i)
            return FileSearchResult(path: found.path, name: found.name, isDirectory: found.isDirectory, score: 1000, canSearchInside: found.canSearchInside)
        }
        return FileSearchResult(path: path, name: (path as NSString).lastPathComponent,
                                isDirectory: isDirectory.boolValue, score: 1000)
    }

    // MARK: - 扫描（不碰索引数据，哪个队列都可以）

    /// 几个线程一起扫这些位置（外接硬盘）。每个线程攒够一批（或达到时间上限）就交给 onBatch，可能在不同线程上调用。
    static func scanTreesInParallel(_ roots: [String], threads: Int,
                                    previous: (String) -> FolderEntries? = { _ in nil }, isCancelled: () -> Bool,
                                    onBatch: @escaping ([String: FolderEntries]) -> Void) {
        let condition = NSCondition()
        let explicitRoots = Set(roots)
        var pending = roots
        var busy = 0
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            var local: [String: FolderEntries] = [:]
            var entryCount = 0
            var lastFlush = Date()
            while !isCancelled() {
                if !local.isEmpty && (local.count >= 256 || entryCount >= 8192 || Date().timeIntervalSince(lastFlush) > 0.5) {
                    onBatch(local)
                    local = [:]
                    entryCount = 0
                    lastFlush = Date()
                }
                condition.lock()
                while pending.isEmpty && busy > 0 && !isCancelled() {
                    condition.wait(until: Date().addingTimeInterval(0.05))
                }
                guard !isCancelled(), let folder = pending.popLast() else {
                    condition.broadcast()
                    condition.unlock()
                    break
                }
                busy += 1
                condition.unlock()
                let listed = autoreleasepool {
                    FileSearchDirectory.readDrive(folder, reusing: previous(folder), recordStamp: true, isCancelled: isCancelled)
                }
                if let listed {
                    local[folder] = listed.entries
                    entryCount += listed.entries.count
                }
                condition.lock()
                if let listed {
                    // 单独收录的子根已在初始队列中，包括不从父根自动进入的目录。
                    if explicitRoots.count == 1 { pending.append(contentsOf: listed.subfolders) }
                    else { pending.append(contentsOf: listed.subfolders.lazy.filter { !explicitRoots.contains($0) }) }
                }
                busy -= 1
                if !pending.isEmpty || busy == 0 { condition.broadcast() }
                condition.unlock()
            }
            if !isCancelled(), !local.isEmpty { onBatch(local) }
        }
    }

    static func scanTree(_ root: String, into result: inout [String: FolderEntries], denied: inout [String], isCancelled: () -> Bool) {
        var stack = [root]
        while !isCancelled(), let folder = stack.popLast() {
            guard let listing = readLocalFolder(folder, denied: &denied, isCancelled: isCancelled) else { continue }
            result[folder] = listing.entries
            stack.append(contentsOf: listing.subfolders)
        }
    }

    private static func readLocalFolder(_ folder: String, denied: inout [String], isCancelled: () -> Bool) -> FileSearchDirectory? {
        // 每个目录读完就释放 FileManager 的临时对象。
        let listing = autoreleasepool { FileSearchDirectory.read(folder, recordStamp: true, isCancelled: isCancelled) }
        if listing == nil, !isCancelled(), (folder as NSString).deletingLastPathComponent == home {
            denied.append(FileManager.default.displayName(atPath: folder))
        }
        return listing
    }

    /// 逐层扫描常用目录，再扫描隐藏目录和依赖。首层可立即搜索，后续限频发布。
    private static func scanLocalRoots(_ roots: [String], denied: inout [String], isCancelled: () -> Bool,
                                       onBatch: ([String: FolderEntries]) -> Void) {
        let explicitRoots = Set(roots)
        var level = uniquePaths(roots)
        var deferred: [String] = []
        var batch: [String: FolderEntries] = [:]
        var firstLevel = true
        var lastPublish = ContinuousClock.now
        func publish() {
            guard !batch.isEmpty, !isCancelled() else { return }
            onBatch(batch)
            batch.removeAll(keepingCapacity: true)
            lastPublish = .now
        }

        while !level.isEmpty {
            var next: [String] = []
            for folder in level {
                guard !isCancelled() else { return }
                guard let listed = readLocalFolder(folder, denied: &denied, isCancelled: isCancelled) else { continue }
                batch[folder] = listed.entries
                for child in listed.subfolders where !explicitRoots.contains(child) {
                    let name = (child as NSString).lastPathComponent
                    if name.hasPrefix(".") || skippedForContent.contains(name) { deferred.append(child) }
                    else { next.append(child) }
                }
                if lastPublish.duration(to: .now) >= .milliseconds(150) { publish() }
            }
            if firstLevel { publish(); firstLevel = false }
            if next.isEmpty { swap(&next, &deferred) }
            level = next
        }
        publish()
    }

    // MARK: - 跟踪变化

    private func flushWatchedChanges(_ gen: Int) {
        guard isCurrentScan(gen) else { return }
        for stream in streams { FSEventStreamFlushSync(stream) }
    }

    private func stopWatching() {
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
    }

    private func restartWatching(_ roots: [String]) {
        stopWatching()
        let external = roots.filter { $0.hasPrefix("/Volumes/") }
        // 主盘仍按目录合并通知。缩短这条流的等待，让已经打开的面板更快刷新。
        let directories = roots.filter { !$0.hasPrefix("/Volumes/") }
        if !external.isEmpty, !startWatching(external, fileEvents: true, latency: 1),
           !startWatching(external, fileEvents: false, latency: 1) {
            Log.app.error("文件索引：无法跟踪外接盘变化")
        }
        if !directories.isEmpty, !startWatching(directories, fileEvents: false, latency: 0.25) {
            Log.app.error("文件索引：无法跟踪文件变化")
        }
    }

    private func startWatching(_ roots: [String], fileEvents: Bool, latency: TimeInterval) -> Bool {
        let owner = WatchContext(self)
        defer { withExtendedLifetime(owner) {} }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(owner).toOpaque(),
            retain: { info in
                if let info { _ = Unmanaged<WatchContext>.fromOpaque(info).retain() }
                return info
            },
            release: { info in
                if let info { Unmanaged<WatchContext>.fromOpaque(info).release() }
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, let index = Unmanaged<WatchContext>.fromOpaque(info).takeUnretainedValue().index else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            var changes = FileIndexChanges()
            for i in 0..<min(count, list.count) { changes.record(list[i], flags: flags[i]) }
            if !changes.files.isEmpty || list.first?.hasPrefix("/Volumes/") == true {
                index.enqueueDriveChanges(changes)
            } else {
                index.apply(changes.directories)
            }
        }
        var flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        if fileEvents { flags |= UInt32(kFSEventStreamCreateFlagFileEvents) }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags)
        ) else { return false }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        streams.append(stream)
        return true
    }

    /// 本程序自己动了这个文件夹里的文件（右键“移到废纸篓”）：马上重新列出来，不等 FSEvents。
    func refresh(folder: String) {
        queue.async { self.apply([folder: false]) }
    }

    /// 使用从第一条通知算起的固定窗口；连续写入也不会一直推迟搜索结果更新。
    private func enqueueDriveChanges(_ batch: FileIndexChanges) {
        let schedule = pendingDriveChanges.isEmpty
        pendingDriveChanges.merge(batch)
        guard schedule, !pendingDriveChanges.isEmpty else { return }
        let gen = activeGeneration
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            guard self.activeGeneration == gen else { return }
            self.applyPendingDriveChanges()
        }
    }

    private func applyPendingDriveChanges() {
        let changes = pendingDriveChanges
        pendingDriveChanges = FileIndexChanges()
        if !changes.isEmpty { applyDriveChanges(changes) }
    }

    private func applyDriveChanges(_ batch: FileIndexChanges) {
        let gen = activeGeneration
        var modifiedContent: [String] = []
        var changes = batch.directories
        var probes: [String: Int] = [:]
        for (path, change) in batch.files {
            guard isCurrentScan(gen) else { return }
            let folder = (path as NSString).deletingLastPathComponent
            guard changes[folder] == nil else { continue }
            if pendingRoots.contains(where: { SearchVolume.contains(folder, under: $0) }) {
                // 初扫结果可能尚未发布。扫完后按该目录的最终状态核对。
                if deferredChanges[folder] == nil { deferredChanges[folder] = false }
                continue
            }
            guard let entries = folders[folder] else {
                if isIndexed(folder) { changes[folder] = false }
                continue
            }
            let name = (path as NSString).lastPathComponent
            if change == .checkName {
                // 原子保存也会产生改名事件。少量路径直接核实；批量变动只列一次父目录。
                probes[folder, default: 0] += 1
                if probes[folder, default: 0] > 8 || !FileSearchDirectory.matchesDriveFile(at: path, name: name, in: entries) {
                    changes[folder] = false
                    continue
                }
            }
            if contentIndex != nil, !name.hasPrefix("."), ContentExtractor.kind(ofFileNamed: name) != nil,
               Self.indexesContents(in: folder), FileSearchDirectory.includesDriveFile(name, in: folder) {
                modifiedContent.append(path)
            }
        }

        // 单文件通知不描述目录的完整内容。随后目录核对的 present 只能包含实际列到的文件。
        if !modifiedContent.isEmpty { contentIndex?.sync(files: modifiedContent, scopes: []) }
        if !changes.isEmpty { apply(changes) }
    }

    private func apply(_ changes: [String: Bool]) {
        let gen = activeGeneration
        let cancelled = { !self.isCurrentScan(gen) }
        var touched = false
        var contentFiles: [String] = []
        var contentScopes: [ContentIndex.Scope] = []
        for (folder, recursive) in changes {
            guard !cancelled() else { return }
            if pendingRoots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
                deferredChanges[folder] = (deferredChanges[folder] ?? false) || recursive
                continue
            }
            guard isIndexed(folder) else { continue }
            // 在目录事件上核销查询提前显示的变化。创建和删除可能被合并，最终快照数量不变。
            if pendingRecentFolders.update({ $0.remove(folder) }) != nil { touched = true }
            if recursive, folder.hasPrefix("/Volumes/") {
                // 外接盘卸载时仅清内存目录，不触发内容索引删库，重新接回时保留正文索引。
                if !mountedVolumes().contains(where: { $0.contains(folder) }) {
                    if folders[folder] != nil { touched = true }
                    removeSubtree(folder)
                } else {
                    rescanDriveSubtree(folder, isCancelled: cancelled)
                }
                continue
            }
            // 主盘沿用整树替换
            let nestedRoots = recursive ? scannedRoots.filter { $0 != folder && SearchVolume.contains($0, under: folder) } : []
            if recursive {
                touched = true
                removeSubtree(folder)
                for nested in nestedRoots { removeSubtree(nested) }
            }
            guard let listed = autoreleasepool(invoking: { FileSearchDirectory.read(folder, recordStamp: true, isCancelled: cancelled) }) else {
                if cancelled() { return }
                if folders[folder] != nil { touched = true }
                removeSubtree(folder)   // 文件夹被删了，或外接卷已弹出
                if !folder.hasPrefix("/Volumes/") || mountedVolumes().contains(where: { $0.contains(folder) }) {
                    contentScopes.append(ContentIndex.Scope(folder: folder, recursive: true))
                }
                continue
            }
            // 消失的子文件夹（被删除、改名或移走）：和原来列着的子文件夹比
            let current = Set(listed.subfolders)
            var gone: [String] = []
            if let old = folders[folder] {
                for index in old.indices where old.isTraversable(at: index) {
                    let name = old.name(at: index)
                    let child = folder == "/" ? "/" + name : folder + "/" + name
                    if !current.contains(child) && folders[child] != nil {
                        removeSubtree(child)
                        gone.append(child)
                    }
                }
            }
            // 只改正文时仍同步内容；通常不必刷新文件名。
            if folders[folder] != listed.entries {
                touched = true
                folders[folder] = listed.entries
            }
            if contentIndex != nil { Self.collectContentFiles(folder, listed.entries, into: &contentFiles) }
            contentScopes.append(ContentIndex.Scope(folder: folder, recursive: recursive))
            var denied: [String] = []
            for sub in listed.subfolders + nestedRoots where folders[sub] == nil {
                var scanned: [String: FolderEntries] = [:]
                Self.scanTree(sub, into: &scanned, denied: &denied, isCancelled: cancelled)
                guard !cancelled() else { return }
                if !scanned.isEmpty { touched = true }
                folders.merge(scanned)
                if contentIndex != nil {
                    for (path, entries) in scanned { Self.collectContentFiles(path, entries, into: &contentFiles) }
                }
                if !recursive { contentScopes.append(ContentIndex.Scope(folder: sub, recursive: true)) }
            }
            if !recursive { contentScopes += gone.map { ContentIndex.Scope(folder: $0, recursive: true) } }
        }
        if touched { publishCount() }
        // 只收名称的位置经常有日志和缓存写入，不能因此让全文索引逐条检查已有文档。
        let scopes = contentScopes.filter { Self.indexesContents(in: $0.folder) }
        if !scopes.isEmpty { contentIndex?.sync(files: contentFiles, scopes: scopes) }
    }

    /// 这个文件夹在索引范围里吗：是扫描根目录，或者上一级扫描时明确允许进入。
    /// 上一级也是新的时不用管：处理上一级时会把它整个扫一遍。
    private func isIndexed(_ folder: String) -> Bool {
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
        apply(changes)
    }

    /// 去掉这个文件夹和它下面所有的文件夹（按列着的子文件夹往下找，不用把所有文件夹比一遍）。
    private func removeSubtree(_ folder: String) {
        guard let entries = folders[folder] else { return }
        folders[folder] = nil
        for index in entries.indices where entries.isTraversable(at: index) {
            let name = entries.name(at: index)
            removeSubtree(folder == "/" ? "/" + name : folder + "/" + name)
        }
    }
}
