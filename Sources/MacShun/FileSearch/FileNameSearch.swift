// SPDX-License-Identifier: MIT

import Foundation

/// 在文件名快照上执行查询；显式选择的文件夹也可临时读取未收录的目录项。
struct FileNameSearch {
    enum DirectoryStatus { case listing, unavailable, partial, outsideFolder, offline, indexing }

    struct Page {
        let results: [FileSearchResult]
        var directory: DirectoryStatus? = nil
    }

    let query: FileMatcher.Query
    let limit: Int
    let boosts: [String: Double]
    let preferredFolder: String?
    var within: FileSearchFolder? = nil
    var options: FileSearchOptions = .init()
    var network: [NetworkSearchSnapshot] = []

    func run(in folders: IndexedFolders, isCancelled: () -> Bool) -> Page? {
        guard let exact = matchingPage(in: folders, isCancelled: isCancelled) else { return nil }
        guard exact.results.isEmpty, !isCancelled(), let spoken = query.withHomophones() else { return exact }
        let fallback = Self(query: spoken, limit: limit, boosts: boosts, preferredFolder: preferredFolder,
                            within: within, options: options, network: network)
        guard let page = fallback.matchingPage(in: folders, isCancelled: isCancelled) else { return nil }
        return Page(results: page.results.map { result in
            var result = result
            result.isHomophone = true
            return result
        }, directory: page.directory)
    }

    private func matchingPage(in folders: IndexedFolders, isCancelled: () -> Bool) -> Page? {
        guard !isCancelled() else { return nil }
        let scopedNetwork = within.flatMap { networkSnapshot(for: $0.path) }
        if let within, scopedNetwork == nil, !within.rootIsAvailable { return Page(results: [], directory: .unavailable) }
        let since = options.modified.since(Date())
        let emptyQuery = query.terms.isEmpty && query.filters.isEmpty && query.directoryInput == nil
            && !options.hasFilters && !options.recursive
        var input = query.directoryInput
        if let within, emptyQuery || query.absolutePath.map({
            $0 == within.path || (scopedNetwork == nil && $0.caseInsensitiveCompare(within.path) == .orderedSame
                && within.canonicalSpelling(of: $0) == within.path)
        }) == true {
            input = .init(folder: within.path, listsChildren: true)
        }
        if let input {
            let directory = scopedNetwork == nil ? (within?.canonicalSpelling(of: input.folder) ?? input.folder) : input.folder
            let entries: FolderEntries?
            let snapshot = networkSnapshot(for: directory)
            if let snapshot {
                if let within, !within.includes(directory) { return Page(results: [], directory: .outsideFolder) }
                entries = snapshot.folders[directory]
            } else if let within {
                guard within.includes(directory) else { return Page(results: [], directory: .outsideFolder) }
                guard within.canBrowse(directory, in: folders, isCancelled: isCancelled) else { return Page(results: [], directory: .unavailable) }
                entries = within.entries(in: directory, snapshot: folders, isCancelled: isCancelled)
            } else {
                entries = folders[directory] ?? FileSearchDirectory.read(directory, isCancelled: isCancelled)?.entries
            }
            if let entries {
                var best = BestFileResults(limit: limit, byName: input.listsChildren || query.terms.isEmpty, order: options.order)
                if input.listsChildren {
                    for (offset, index) in entries.indices.enumerated() {
                        if offset.isMultiple(of: 512), isCancelled() { return nil }
                        let name = entries.name(at: index)
                        let hit = FileSearchResult(path: Self.child(name, in: directory),
                                                   name: entries.displayName(at: index) ?? name,
                                                   isDirectory: entries.isDirectory(at: index),
                                                   score: entries.isDirectory(at: index) ? 1 : 0,
                                                   canSearchInside: entries.isTraversable(at: index))
                        if let hit = accepted(hit, since: since) { best.add(hit) }
                    }
                } else {
                    match(entries, in: directory, using: &best, direct: true, since: since, isCancelled: isCancelled)
                }
                guard !isCancelled() else { return nil }
                return Page(results: finish(&best, preferPath: snapshot == nil && within == nil && !input.listsChildren,
                                            since: since), directory: .listing)
            }
            if snapshot != nil { return Page(results: [], directory: .unavailable) }
            if within != nil { return Page(results: [], directory: .unavailable) }
            var isDirectory: ObjCBool = false
            if input.listsChildren || (FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue) {
                var hits: [FileSearchResult] = []
                if !input.listsChildren, let path = query.absolutePath,
                   let hit = FileIndex.existingFile(path, among: &hits).flatMap({ accepted($0, since: since) }) {
                    return Page(results: [hit], directory: .unavailable)
                }
                return Page(results: [], directory: .unavailable)
            }
            // 复制的路径若包含已改名的上级，继续按原来的方式找同名文件。
        }
        var best = BestFileResults(limit: limit, byName: query.terms.isEmpty, order: options.order)
        if let within {
            var pending = [within.path]
            var partial = false
            while let folder = pending.popLast() {
                guard !isCancelled() else { return nil }
                let entries = scopedNetwork == nil ? within.entries(in: folder, snapshot: folders, isCancelled: isCancelled)
                    : scopedNetwork?.folders[folder]
                guard let entries else {
                    if isCancelled() { return nil }
                    if folder == within.path { return Page(results: [], directory: .unavailable) }
                    partial = true
                    continue
                }
                match(entries, in: folder, using: &best, direct: false, since: since, isCancelled: isCancelled)
                guard !isCancelled() else { return nil }
                for i in entries.indices where entries.isTraversable(at: i) {
                    pending.append(Self.child(entries.name(at: i), in: folder))
                }
            }
            return Page(results: finish(&best, preferPath: false, since: since), directory: partial ? .partial : nil)
        }
        let sources = [folders] + network.map(\.folders)
        // 对大索引分区取各自的前 limit 项，再按同一排序合并，精确匹配、历史加分和分页顺序一致。
        let workers = sources.contains { $0.fileCount >= 16_384 }
            ? min(8, ProcessInfo.processInfo.activeProcessorCount) : 1
        let partials = Locked([[FileSearchResult]]())
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            let matcher = Self(query: workers > 1 ? query.workerCopy() : query, limit: limit, boosts: boosts,
                               preferredFolder: preferredFolder, within: within, options: options, network: network)
            var local = BestFileResults(limit: limit, byName: query.terms.isEmpty, order: options.order)
            for source in sources {
                for part in stride(from: worker, to: source.partitions.count, by: workers) {
                    for (offset, pair) in source.partitions[part].enumerated() {
                        if offset.isMultiple(of: 64), isCancelled() { return }
                        matcher.match(pair.value, in: pair.key, using: &local, direct: false, since: since, isCancelled: isCancelled)
                    }
                }
            }
            let rows = local.sorted()
            partials.update { $0.append(rows) }
        }
        guard !isCancelled() else { return nil }
        for rows in partials.get() {
            for hit in rows { best.add(hit) }
        }
        return Page(results: finish(&best, preferPath: true, since: since))
    }

    private func match(_ entries: FolderEntries, in folder: String, using best: inout BestFileResults, direct: Bool,
                       since: Double?, isCancelled: () -> Bool) {
        let mixed = query.isPlainName && !query.terms.isEmpty && (query.terms.count > 1 || !query.filters.suffixes.isEmpty)
        if !mixed, query.nameTerms == nil, query.terms.count == 1, !entries.mightMatch(query.terms[0]) { return }
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
            if let hit = accepted(hit, since: since) { best.add(hit) }
        }
        entries.forEachMatch(query.terms, depth: depth, folderTerms: folderTerms, filters: query.filters,
                             allowEmpty: options.hasFilters || options.recursive, isCancelled: isCancelled) { add($0, score: $1 + folderBonus) }
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

    private func accepted(_ result: FileSearchResult, since: Double?) -> FileSearchResult? {
        guard options.acceptsKind(result.path, isFolder: result.isDirectory && !result.path.hasSuffix(".app")) else { return nil }
        if !options.needsMetadata && !query.filters.needsMetadata { return result }
        var result = result
        result.metadata = metadata(for: result.path)
        guard options.accepts(result.metadata, since: since), query.filters.accepts(result.metadata) else { return nil }
        return result
    }

    private func finish(_ best: inout BestFileResults, preferPath: Bool, since: Double?) -> [FileSearchResult] {
        var rows = best.sorted()
        if preferPath, let path = query.absolutePath {
            var matches = rows
            if let hit = FileIndex.existingFile(path, among: &matches).flatMap({ accepted($0, since: since) }) {
                matches.insert(hit, at: 0)
                if options.order != .relevance { matches.sort(by: options.order.precedes) }
                rows = Array(matches.prefix(limit))
            }
        }
        if options.showsMetadata && !options.needsMetadata && !query.filters.needsMetadata {
            for index in rows.indices { rows[index].metadata = metadata(for: rows[index].path) }
        }
        return rows
    }

    private func networkSnapshot(for path: String) -> NetworkSearchSnapshot? {
        network.filter { SearchVolume.contains(path, under: $0.root) }.max { $0.root.count < $1.root.count }
    }

    private func metadata(for path: String) -> FileSearchMetadata? {
        if let snapshot = networkSnapshot(for: path) { return snapshot.metadata[path] }
        return FileSearchMetadata.read(path)
    }

    private static func child(_ name: String, in folder: String) -> String {
        folder == "/" ? "/" + name : folder + "/" + name
    }
}

/// 最多暂存两倍显示条数的候选。每积满一批就按最终顺序去重截断，之后分数低的直接丢弃。
struct BestFileResults {
    let limit: Int
    let byName: Bool
    let order: FileSearchOrder
    private var rows: [FileSearchResult] = []
    private var cutoff: FileSearchResult?

    init(limit: Int, byName: Bool = false, order: FileSearchOrder = .relevance) {
        self.limit = max(0, limit)
        self.byName = byName
        self.order = order
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
        if order != .relevance { return order.precedes(lhs, rhs) }
        return Self.byRelevance(lhs, rhs, byName: byName)
    }

    static func byRelevance(_ lhs: FileSearchResult, _ rhs: FileSearchResult, byName: Bool = false) -> Bool {
        if lhs.nameRank != rhs.nameRank { return lhs.nameRank.rawValue > rhs.nameRank.rawValue }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        if byName {
            let order = lhs.name.localizedStandardCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return lhs.path < rhs.path
    }
}
