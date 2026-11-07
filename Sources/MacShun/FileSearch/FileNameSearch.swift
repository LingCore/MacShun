// SPDX-License-Identifier: MIT

import Foundation

/// 在文件名快照上执行查询；显式选择的文件夹也可临时读取未收录的目录项。
struct FileNameSearch {
    enum DirectoryStatus { case listing, unavailable, partial, outsideFolder }

    struct Page {
        let results: [FileSearchResult]
        var directory: DirectoryStatus? = nil
    }

    let query: FileMatcher.Query
    let limit: Int
    let boosts: [String: Double]
    let preferredFolder: String?
    var within: FileSearchFolder? = nil

    func run(in folders: [String: FolderEntries], isCancelled: () -> Bool) -> Page? {
        guard !isCancelled() else { return nil }
        if let within, !within.rootIsAvailable { return Page(results: [], directory: .unavailable) }
        let emptyQuery = query.terms.isEmpty && query.filters.isEmpty && query.directoryInput == nil
        var input = query.directoryInput
        if let within, emptyQuery || query.absolutePath.map({
            $0.caseInsensitiveCompare(within.path) == .orderedSame && within.canonicalSpelling(of: $0) == within.path
        }) == true {
            input = .init(folder: within.path, listsChildren: true)
        }
        if let input {
            let directory = within?.canonicalSpelling(of: input.folder) ?? input.folder
            let entries: FolderEntries?
            if let within {
                guard within.includes(directory) else { return Page(results: [], directory: .outsideFolder) }
                guard within.canBrowse(directory, in: folders, isCancelled: isCancelled) else { return Page(results: [], directory: .unavailable) }
                entries = within.entries(in: directory, snapshot: folders, isCancelled: isCancelled)
            } else {
                entries = folders[directory] ?? FileSearchDirectory.read(directory, isCancelled: isCancelled)?.entries
            }
            if let entries {
                var best = BestFileResults(limit: limit, byName: input.listsChildren || query.terms.isEmpty)
                if input.listsChildren {
                    for (offset, index) in entries.indices.enumerated() {
                        if offset.isMultiple(of: 512), isCancelled() { return nil }
                        let name = entries.name(at: index)
                        let hit = FileSearchResult(path: Self.child(name, in: directory),
                                                   name: entries.displayName(at: index) ?? name,
                                                   isDirectory: entries.isDirectory(at: index),
                                                   score: entries.isDirectory(at: index) ? 1 : 0,
                                                   canSearchInside: entries.isTraversable(at: index))
                        best.add(hit)
                    }
                } else {
                    match(entries, in: directory, using: &best, direct: true, isCancelled: isCancelled)
                }
                guard !isCancelled() else { return nil }
                return Page(results: finish(&best, preferPath: within == nil && !input.listsChildren), directory: .listing)
            }
            if within != nil { return Page(results: [], directory: .unavailable) }
            var isDirectory: ObjCBool = false
            if input.listsChildren || (FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue) {
                var hits: [FileSearchResult] = []
                if !input.listsChildren, let path = query.absolutePath, let hit = FileIndex.existingFile(path, among: &hits) {
                    return Page(results: [hit], directory: .unavailable)
                }
                return Page(results: [], directory: .unavailable)
            }
            // 复制的路径若包含已改名的上级，继续按原来的方式找同名文件。
        }
        var best = BestFileResults(limit: limit, byName: query.terms.isEmpty)
        if let within {
            var pending = [within.path]
            var partial = false
            while let folder = pending.popLast() {
                guard !isCancelled() else { return nil }
                guard let entries = within.entries(in: folder, snapshot: folders, isCancelled: isCancelled) else {
                    if isCancelled() { return nil }
                    if folder == within.path { return Page(results: [], directory: .unavailable) }
                    partial = true
                    continue
                }
                match(entries, in: folder, using: &best, direct: false, isCancelled: isCancelled)
                guard !isCancelled() else { return nil }
                for i in entries.indices where entries.isTraversable(at: i) {
                    pending.append(Self.child(entries.name(at: i), in: folder))
                }
            }
            return Page(results: best.sorted(), directory: partial ? .partial : nil)
        }
        for (offset, pair) in folders.enumerated() {
            if offset.isMultiple(of: 128), isCancelled() { return nil }
            match(pair.value, in: pair.key, using: &best, direct: false, isCancelled: isCancelled)
        }
        guard !isCancelled() else { return nil }
        return Page(results: finish(&best, preferPath: true))
    }

    private func match(_ entries: FolderEntries, in folder: String, using best: inout BestFileResults, direct: Bool,
                       isCancelled: () -> Bool) {
        let mixed = query.isPlainName && !query.terms.isEmpty && (query.terms.count > 1 || !query.filters.suffixes.isEmpty)
        // 搜索范围以上的祖先目录不参与混合词匹配或相对路径加分。
        lazy var folderWords = within.map { ($0.path as NSString).lastPathComponent + folder.dropFirst($0.path.count) } ?? folder
        let folderTerms = mixed ? wordsInFolder(folderWords) : []
        let depth = folder.utf8.reduce(0) { $1 == 0x2F ? $0 + 1 : $0 }
        lazy var folderBonus = direct || query.folders.isEmpty ? 0 : query.folderBonus(folderWords)
        lazy var insideDotFolder = folder.contains("/.")
        lazy var asksForDotName = query.terms.contains { $0.bytes.first == 0x2E }
            || query.folders.contains { forms in forms.contains { $0.hasPrefix(".") } }

        func add(_ i: Int, score: Double) {
            let name = entries.name(at: i)
            let path = Self.child(name, in: folder)
            let penalty = !asksForDotName && (insideDotFolder || name.hasPrefix(".")) ? 8.0 : 0
            let exact = (query.isPlainName || direct) && entries.hasFullName(query.fullName, at: i)
            var hit = FileSearchResult(path: path, name: entries.displayName(at: i) ?? name, isDirectory: entries.isDirectory(at: i),
                                       score: score - penalty + (boosts[path] ?? 0), canSearchInside: entries.isTraversable(at: i))
            if exact { hit.nameRank = folder == preferredFolder ? .exactInFinder : .exact }
            best.add(hit)
        }
        entries.forEachMatch(query.terms, depth: depth, folderTerms: folderTerms, filters: query.filters, isCancelled: isCancelled) { add($0, score: $1 + folderBonus) }
        // 访达用 / 显示名字里的 : 。相对路径两种写法都搜，合并时同一路径留较高分。
        if let alternate = query.nameTerms {
            entries.forEachMatch(alternate, depth: depth, isCancelled: isCancelled) { add($0, score: $1) }
        }
    }

    private func wordsInFolder(_ folder: String) -> [Bool] {
        let folded = FolderEntries.matchForm(folder, isASCII: folder.utf8.allSatisfy { $0 < 0x80 })
        return query.terms.map { term in
            if folded.contains(term.text) { return true }
            guard let alias = FileMatcher.folderAliases[term.text] else { return false }
            return folded.split(separator: "/").contains { $0 == alias }
        }
    }

    private func finish(_ best: inout BestFileResults, preferPath: Bool) -> [FileSearchResult] {
        var rows = best.sorted()
        if preferPath, let path = query.absolutePath, let hit = FileIndex.existingFile(path, among: &rows) {
            rows.insert(hit, at: 0)
            if rows.count > limit { rows.removeLast() }
        }
        return rows
    }

    private static func child(_ name: String, in folder: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }
}

/// 最多暂存两倍显示条数的候选。每积满一批就按最终顺序去重截断，之后分数低的直接丢弃。
struct BestFileResults {
    let limit: Int
    let byName: Bool
    private var rows: [FileSearchResult] = []
    private var cutoff: FileSearchResult?

    init(limit: Int, byName: Bool = false) {
        self.limit = max(0, limit)
        self.byName = byName
    }

    mutating func add(_ hit: FileSearchResult) {
        guard limit > 0 else { return }
        if let cutoff, !precedes(hit, cutoff) { return }
        rows.append(hit)
        if rows.count - limit >= limit { trim() }
    }

    mutating func sorted() -> [FileSearchResult] {
        trim()
        return rows
    }

    private mutating func trim() {
        let order = precedes
        rows.sort(by: order)
        var paths = Set<String>()
        var kept: [FileSearchResult] = []
        kept.reserveCapacity(min(limit, rows.count))
        for row in rows where paths.insert(row.path).inserted {
            kept.append(row)
            if kept.count == limit { break }
        }
        rows = kept
        if rows.count == limit { cutoff = rows.last }
    }

    private func precedes(_ lhs: FileSearchResult, _ rhs: FileSearchResult) -> Bool {
        if lhs.nameRank != rhs.nameRank { return lhs.nameRank.rawValue > rhs.nameRank.rawValue }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if byName {
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.path < rhs.path
    }
}
