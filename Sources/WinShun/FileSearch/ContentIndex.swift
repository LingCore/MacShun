// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import SQLite3

/// 文件内容索引（F2）：把 txt、csv、json、Word、Excel、PowerPoint、PDF 里的文字存进 SQLite 的全文索引（FTS5），
/// 在搜索框里按内容搜。索引放在 ~/Library/Application Support/WinShun/ContentIndex/，只在这台电脑上，不联网。
///
/// - 要读哪些文件由文件名索引（FileIndex）告诉它：扫描完一遍、FSEvents 报告有变化时，把文件列表和范围交过来；
///   这里按修改时间和大小判断哪些要重新读，读完的不再重复读。
/// - 中文没有空格分词。存进去之前把每个汉字前后加上空格，变成一个个单字，搜“合同”时按短语找连在一起的“合 同”。
///   这样一两个字也能搜，不需要词典。
/// - 原文压缩后另存一份，搜到以后从里面截一段显示在结果里，不用再去读文件。
///
/// 写数据库在 workQueue 上，搜索在 searchQueue 上用另一个连接（WAL 模式下读写互不阻塞）。状态在主线程上发布。
final class ContentIndex: ObservableObject {
    static let shared = ContentIndex(directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WinShun/ContentIndex", isDirectory: true))

    /// 收录了内容的文件数
    @Published private(set) var documentCount = 0
    /// 还没读的文件数。大于 0 时表示正在建立索引
    @Published private(set) var pendingCount = 0
    /// 索引占的磁盘空间（字节）
    @Published private(set) var diskSize: Int64 = 0

    /// 一个范围：某个文件夹下面（recursive 为 false 时只算直接在这个文件夹里的文件）
    struct Scope {
        let folder: String
        let recursive: Bool
        private let prefix: String

        init(folder: String, recursive: Bool) {
            self.folder = folder
            self.recursive = recursive
            prefix = folder == "/" ? "/" : folder + "/"
        }

        func contains(_ path: String) -> Bool {
            guard path.hasPrefix(prefix) else { return false }
            return recursive || !path[path.index(path.startIndex, offsetBy: prefix.count)...].contains("/")
        }
    }

    struct Hit: Equatable {
        let path: String
        /// 匹配处附近的一段文字，一行
        let snippet: String
    }

    private let directory: URL
    private var databasePath: String { directory.appendingPathComponent("content.sqlite").path }
    /// 正在读的文件。读的时候程序崩了（文件损坏），下次启动跳过它，免得一启动就崩
    private var readingMarker: URL { directory.appendingPathComponent("reading") }
    /// 改了存储格式或分词方式就加一，旧索引会删掉重建
    private static let schemaVersion: Int32 = 1

    private let workQueue = DispatchQueue(label: "WinShun.ContentIndex", qos: .utility, autoreleaseFrequency: .workItem)
    private let searchQueue = DispatchQueue(label: "WinShun.ContentIndex.search", qos: .userInitiated)

    private struct Document {
        let id: Int64
        let mtime: Double
        let size: Int
        let hasText: Bool
    }

    /// 以下只在 workQueue 上读写
    private var database: SQLiteDatabase?
    private var known: [String: Document] = [:]
    /// 要读的文件。buckets 按种类分开排队，取的时候核对一下 todo，已经不用读的跳过
    private var todo: [String: ContentExtractor.Kind] = [:]
    private var buckets: [[String]] = []
    private var textCount = 0
    private var working = false
    private var lastPublish = Date.distantPast

    /// 以下只在 searchQueue 上读写
    private var reader: SQLiteDatabase?

    /// 搜索结果只要这些位置下面的（拔掉或者不再包括的外接硬盘上的文件，索引里还有，但不显示）
    private let searchRoots = Locked<[String]>([])

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: - 开始、停止

    /// 打开（没有就新建）索引。只在主线程上调用，重复调用没关系。
    func start() {
        workQueue.async {
            guard self.database == nil else { return }
            self.open()
            self.publish(force: true)
        }
    }

    /// 停止读文件。deleteData 为 true 时把索引文件也删掉。
    func stop(deleteData: Bool) {
        workQueue.async {
            guard self.database != nil || deleteData else { return }
            self.database = nil
            self.known = [:]
            self.todo = [:]
            self.buckets = []
            self.textCount = 0
            if deleteData, FileManager.default.fileExists(atPath: self.directory.path) {
                try? FileManager.default.removeItem(at: self.directory)
                Log.app.notice("内容索引：已删除")
            }
            self.searchQueue.async { self.reader = nil }
            self.publish(force: true)
        }
    }

    func setSearchRoots(_ roots: [String]) {
        searchRoots.set(roots)
    }

    private func open() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard var db = SQLiteDatabase(path: databasePath) else { return }
        if db.int("PRAGMA user_version") != Self.schemaVersion && db.int("SELECT count(*) FROM sqlite_master") != 0 {
            // 旧格式：整个删掉重建
            Log.app.notice("内容索引：格式变了，重新建立")
            searchQueue.sync { reader = nil }
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
            guard let fresh = SQLiteDatabase(path: databasePath) else { return }
            db = fresh
        }
        let ok = db.execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS docs (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                mtime REAL NOT NULL,
                size INTEGER NOT NULL,
                text BLOB
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS docs_fts USING fts5(
                body, content = '', tokenize = 'unicode61 remove_diacritics 2'
            );
            PRAGMA user_version = \(Self.schemaVersion);
            """)
        guard ok, let statement = db.prepare("SELECT id, path, mtime, size, text IS NOT NULL FROM docs") else { return }
        var loaded: [String: Document] = [:]
        var texts = 0
        while statement.step() {
            let hasText = statement.int(4) != 0
            loaded[statement.string(1)] = Document(id: statement.int(0), mtime: statement.double(2),
                                                   size: Int(statement.int(3)), hasText: hasText)
            if hasText { texts += 1 }
        }
        database = db
        known = loaded
        textCount = texts
        // 上次读这一批文件时程序崩了：都记成“没有内容”，文件改过之后才会再读
        let crashed = ((try? String(contentsOf: readingMarker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        if !crashed.isEmpty {
            Log.app.error("内容索引：上次读这些文件时退出了，跳过：\(crashed.joined(separator: ", "), privacy: .public)")
            transaction {
                for path in crashed {
                    guard let info = Self.fileInfo(path) else { continue }
                    upsert(path, mtime: info.mtime, size: info.size, compressed: nil, body: nil)
                }
            }
        }
        try? FileManager.default.removeItem(at: readingMarker)
    }

    // MARK: - 跟着文件变化更新

    /// 文件名索引扫描完或者有变化时调用（哪个线程都可以）：scopes 范围里现在有的文件就是 files。
    /// 新的、改过的排队去读；范围里索引有、files 里没有的（删掉、改名、移走了）从索引里去掉。
    func sync(files: [String], scopes: [Scope]) {
        workQueue.async {
            guard self.database != nil else { return }
            var present = Set<String>()
            present.reserveCapacity(files.count)
            // 外接硬盘上查一个文件的大小和修改时间要零点几毫秒，几个线程一起查
            let candidates = files.compactMap { path in
                ContentExtractor.kind(ofFileNamed: (path as NSString).lastPathComponent).map { (path, $0) }
            }
            let infos = Self.fileInfos(candidates.map(\.0))
            present.formUnion(files)
            for ((path, kind), info) in zip(candidates, infos) {
                guard let info else { continue }
                // iCloud 里还没下载到这台电脑的文件，读一下就会开始下载，不读
                if info.isDataless { continue }
                if info.size == 0 || info.size > kind.maxFileSize {
                    self.todo[path] = nil
                    if self.known[path] != nil { self.transaction { self.remove(path) } }
                    continue
                }
                if let doc = self.known[path], doc.mtime == info.mtime, doc.size == info.size {
                    self.todo[path] = nil
                } else {
                    self.enqueue(path, kind: kind)
                }
            }
            var gone: [String] = []
            for scope in scopes {
                for path in self.known.keys where !present.contains(path) && scope.contains(path) { gone.append(path) }
                for path in self.todo.keys where !present.contains(path) && scope.contains(path) { self.todo[path] = nil }
            }
            if !gone.isEmpty { self.transaction { gone.forEach(self.remove) } }
            self.publish(force: !gone.isEmpty)
            self.scheduleWork()
        }
    }

    /// 去掉 scopes 范围里、不在 present 里的文件（全部扫完以后调用，前面分批 sync 时只增不删）。
    func removeMissing(present: Set<String>, scopes: [Scope]) {
        workQueue.async {
            guard self.database != nil else { return }
            var gone: [String] = []
            for scope in scopes {
                for path in self.known.keys where !present.contains(path) && scope.contains(path) { gone.append(path) }
                for path in self.todo.keys where !present.contains(path) && scope.contains(path) { self.todo[path] = nil }
            }
            guard !gone.isEmpty else { return }
            self.transaction { gone.forEach(self.remove) }
            self.publish(force: true)
        }
    }

    /// 去掉不在这些位置下面的文件（例如关掉了“包括外接硬盘”）。
    func prune(keeping roots: [String]) {
        let scopes = roots.map { Scope(folder: $0, recursive: true) }
        workQueue.async {
            guard self.database != nil else { return }
            let outside = self.known.keys.filter { path in !scopes.contains { $0.contains(path) } }
            for path in self.todo.keys where !scopes.contains(where: { $0.contains(path) }) { self.todo[path] = nil }
            guard !outside.isEmpty else { return }
            self.transaction { outside.forEach(self.remove) }
            Log.app.notice("内容索引：去掉范围外的 \(outside.count, privacy: .public) 个文件")
            self.publish(force: true)
        }
    }

    private func enqueue(_ path: String, kind: ContentExtractor.Kind) {
        guard todo[path] != kind else { return }
        todo[path] = kind
        while buckets.count <= kind.rawValue { buckets.append([]) }
        buckets[kind.rawValue].append(path)
    }

    private func scheduleWork() {
        guard !working, !todo.isEmpty else { return }
        working = true
        workQueue.async { self.workBatch() }
    }

    /// 读一批文件：先读快的（文本，再 Word、PowerPoint、Excel，最后 PDF）。一批里的文件几个核同时读，
    /// 读完在一个事务里写进数据库；读满半秒就让出队列，让排在后面的文件变化先处理，搜索也能尽早搜到。
    private func workBatch() {
        working = false
        guard database != nil, !todo.isEmpty else { return }
        let begin = Date()
        while Date().timeIntervalSince(begin) < 0.5 {
            let tasks = nextTasks()
            guard !tasks.isEmpty else { break }
            tasks.forEach { todo[$0.path] = nil }
            try? Data(tasks.map(\.path).joined(separator: "\n").utf8).write(to: readingMarker)
            let results = Self.read(tasks)
            transaction {
                for (task, result) in zip(tasks, results) {
                    switch result {
                    case .missing: remove(task.path)
                    case .skipped: break
                    case let .read(info, compressed, body):
                        upsert(task.path, mtime: info.mtime, size: info.size, compressed: compressed, body: body)
                    }
                }
            }
        }
        try? FileManager.default.removeItem(at: readingMarker)
        publish(force: todo.isEmpty)
        if todo.isEmpty {
            Log.app.notice("内容索引：读完了，共 \(self.textCount, privacy: .public) 个文件有内容")
            // 并行读文件时用过的大块内存，系统分配器会留着备用，读完了就还给系统
            malloc_zone_pressure_relief(nil, 0)
        } else {
            scheduleWork()
        }
    }

    private struct Task {
        let path: String
        let kind: ContentExtractor.Kind
    }

    /// 下一批：同一种文件取十几个；PDF 在子进程里读，个别图片多的会占几百 MB 内存，一次只取四个
    private func nextTasks() -> [Task] {
        for rank in buckets.indices {
            let limit = rank == ContentExtractor.Kind.pdf.rawValue ? 4 : 16
            var tasks: [Task] = []
            var seen = Set<String>()
            while tasks.count < limit, let path = buckets[rank].popLast() {
                if let kind = todo[path], kind.rawValue == rank, seen.insert(path).inserted {
                    tasks.append(Task(path: path, kind: kind))
                }
            }
            if !tasks.isEmpty { return tasks }
        }
        return []
    }

    private enum ReadResult {
        /// 文件没了
        case missing
        /// iCloud 里还没下载的，先不读
        case skipped
        /// 读完了：压缩好的原文和交给全文索引的文字（没有文字时都是 nil）
        case read(FileInfo, Data?, String?)
    }

    /// 几个核同时读一批文件（哪个线程都可以）。解析、压缩、分词都在这里做，写数据库的线程只管写。
    private static func read(_ tasks: [Task]) -> [ReadResult] {
        var results = [ReadResult](repeating: .skipped, count: tasks.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: tasks.count) { index in
            // 每个文件读完就释放临时对象，不然 Data、XML 解析器会堆在一起
            let result: ReadResult = autoreleasepool {
                let task = tasks[index]
                guard let info = fileInfo(task.path) else { return .missing }
                guard !info.isDataless else { return .skipped }
                guard let text = ContentExtractor.extract(path: task.path, kind: task.kind) else { return .read(info, nil, nil) }
                let compressed = try? (Data(text.utf8) as NSData).compressed(using: .zlib) as Data
                return .read(info, compressed, compressed == nil ? nil : ftsText(text))
            }
            lock.lock()
            results[index] = result
            lock.unlock()
        }
        return results
    }

    // MARK: - 数据库读写（workQueue 上）

    private func transaction(_ body: () -> Void) {
        guard let database else { return }
        database.execute("BEGIN")
        body()
        database.execute("COMMIT")
    }

    private func upsert(_ path: String, mtime: Double, size: Int, compressed: Data?, body: String?) {
        guard let database else { return }
        let id: Int64
        if let old = known[path] {
            deleteFromFTS(old)
            guard let statement = database.prepare("UPDATE docs SET mtime = ?, size = ?, text = ? WHERE id = ?") else { return }
            statement.bind(1, mtime)
            statement.bind(2, Int64(size))
            statement.bind(3, compressed)
            statement.bind(4, old.id)
            _ = statement.step()
            id = old.id
            if old.hasText { textCount -= 1 }
        } else {
            guard let statement = database.prepare("INSERT INTO docs (path, mtime, size, text) VALUES (?, ?, ?, ?)") else { return }
            statement.bind(1, path)
            statement.bind(2, mtime)
            statement.bind(3, Int64(size))
            statement.bind(4, compressed)
            _ = statement.step()
            id = database.lastInsertID
        }
        let hasText = compressed != nil && body != nil
        if hasText, let body, let statement = database.prepare("INSERT INTO docs_fts (rowid, body) VALUES (?, ?)") {
            statement.bind(1, id)
            statement.bind(2, body)
            _ = statement.step()
            textCount += 1
        }
        known[path] = Document(id: id, mtime: mtime, size: size, hasText: hasText)
    }

    private func remove(_ path: String) {
        guard let database, let doc = known[path] else { return }
        deleteFromFTS(doc)
        if doc.hasText { textCount -= 1 }
        if let statement = database.prepare("DELETE FROM docs WHERE id = ?") {
            statement.bind(1, doc.id)
            _ = statement.step()
        }
        known[path] = nil
    }

    /// 没有存原文的全文索引（contentless），删除时要交回当初存进去的同样的文字，所以从原文重新算一遍。
    private func deleteFromFTS(_ doc: Document) {
        guard doc.hasText, let database,
              let select = database.prepare("SELECT text FROM docs WHERE id = ?") else { return }
        select.bind(1, doc.id)
        guard select.step(), let text = Self.decompress(select.data(0)),
              let delete = database.prepare("INSERT INTO docs_fts (docs_fts, rowid, body) VALUES ('delete', ?, ?)")
        else { return }
        delete.bind(1, doc.id)
        delete.bind(2, Self.ftsText(text))
        _ = delete.step()
    }

    private func publish(force: Bool) {
        guard force || Date().timeIntervalSince(lastPublish) > 0.5 else { return }
        lastPublish = Date()
        let documents = textCount, pending = todo.count
        let size = ["", "-wal"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        DispatchQueue.main.async {
            if self.documentCount != documents { self.documentCount = documents }
            if self.pendingCount != pending { self.pendingCount = pending }
            if self.diskSize != size { self.diskSize = size }
        }
    }

    private struct FileInfo {
        let mtime: Double
        let size: Int
        let isDataless: Bool
    }

    private static func fileInfos(_ paths: [String]) -> [FileInfo?] {
        var infos = [FileInfo?](repeating: nil, count: paths.count)
        let chunks = 8
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
            let range = stride(from: chunk, to: paths.count, by: chunks)
            let local = range.map { (index: $0, info: fileInfo(paths[$0])) }
            lock.lock()
            for item in local { infos[item.index] = item.info }
            lock.unlock()
        }
        return infos
    }

    /// 只要普通文件（不跟着替身走，免得同一个文件收录两遍）
    private static func fileInfo(_ path: String) -> FileInfo? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return FileInfo(mtime: mtime, size: Int(info.st_size),
                        isDataless: info.st_flags & 0x4000_0000 != 0)   // SF_DATALESS
    }

    private static func decompress(_ data: Data?) -> String? {
        guard let data, let raw = try? (data as NSData).decompressed(using: .zlib) else { return nil }
        return String(decoding: raw as Data, as: UTF8.self)
    }

    // MARK: - 搜索

    /// 按内容搜，结果在主线程上回调。查询太短（一个汉字、两个字母）时直接返回空，免得一个“的”字搜出整个硬盘。
    func search(_ query: String, limit: Int = 30, completion: @escaping ([Hit]) -> Void) {
        guard let match = Self.matchExpression(for: query) else {
            completion([])
            return
        }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let roots = searchRoots.get().map { Scope(folder: $0, recursive: true) }
        searchQueue.async {
            let hits = self.runSearch(match, terms: terms, roots: roots, limit: limit)
            DispatchQueue.main.async { completion(hits) }
        }
    }

    /// 测试用：同步搜索
    func searchNow(_ query: String, limit: Int = 30) -> [Hit] {
        guard let match = Self.matchExpression(for: query) else { return [] }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let roots = searchRoots.get().map { Scope(folder: $0, recursive: true) }
        return searchQueue.sync { runSearch(match, terms: terms, roots: roots, limit: limit) }
    }

    /// 测试用：等到排队的文件都读完
    func waitUntilIdle() {
        while workQueue.sync(execute: { !todo.isEmpty || working }) { usleep(5_000) }
    }

    /// 测试用：收录了内容的文件数（不经过主线程）
    var documentCountNow: Int { workQueue.sync { textCount } }

    private func runSearch(_ match: String, terms: [String], roots: [Scope], limit: Int) -> [Hit] {
        if reader == nil {
            guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
            reader = SQLiteDatabase(path: databasePath, create: false)
        }
        guard let reader, let statement = reader.prepare("""
            SELECT d.path, d.text FROM
                (SELECT rowid, rank FROM docs_fts WHERE docs_fts MATCH ? ORDER BY rank LIMIT ?) AS f
            JOIN docs AS d ON d.id = f.rowid
            ORDER BY f.rank
            """)
        else {
            self.reader = nil   // 可能索引还没建好，下次再试
            return []
        }
        // 多取一些，去掉已经不存在、不在搜索范围里的
        statement.bind(1, match)
        statement.bind(2, Int64(limit * 2))
        var hits: [Hit] = []
        while hits.count < limit && statement.step() {
            let path = statement.string(0)
            guard roots.isEmpty || roots.contains(where: { $0.contains(path) }),
                  FileManager.default.fileExists(atPath: path),
                  let text = Self.decompress(statement.data(1))
            else { continue }
            hits.append(Hit(path: path, snippet: Self.snippet(in: text, terms: terms)))
        }
        return hits
    }

    // MARK: - 分词和摘要（纯函数，方便测试）

    /// 中日韩文字：每个字单独成词
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3134F: true
        default: false
        }
    }

    /// 交给 FTS5 的文字：每个汉字前后加空格，英文、数字不变。
    static func ftsText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                out.append(" ")
                out.append(scalar)
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// 查询够不够长：汉字算 2，字母数字算 1，至少 3（两个汉字、三个字母、一个汉字加一个字母）。
    static func qualifies(_ query: String) -> Bool {
        var weight = 0
        for scalar in query.unicodeScalars {
            if isCJK(scalar) { weight += 2 } else if CharacterSet.alphanumerics.contains(scalar) { weight += 1 }
            if weight >= 3 { return true }
        }
        return false
    }

    /// 把搜索框里的字变成 FTS5 查询：空格分开的每个词都要出现，一个词里的字要连在一起（短语），
    /// 最后是字母或数字时按前缀找（打 “inv” 能找到 “invoice”）。
    static func matchExpression(for query: String) -> String? {
        guard qualifies(query) else { return nil }
        var phrases: [String] = []
        for term in query.split(whereSeparator: { $0.isWhitespace }) {
            let scalars = term.unicodeScalars
            guard scalars.contains(where: { isCJK($0) || CharacterSet.alphanumerics.contains($0) }) else { continue }
            let escaped = ftsText(String(term)).replacingOccurrences(of: "\"", with: "\"\"")
            var phrase = "\"" + escaped + "\""
            if let last = scalars.last(where: { isCJK($0) || CharacterSet.alphanumerics.contains($0) }), !isCJK(last),
               CharacterSet.alphanumerics.contains(scalars.last!) {
                phrase += " *"
            }
            phrases.append(phrase)
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: " AND ")
    }

    /// 从原文里截出第一次匹配附近的一段，压成一行：匹配处前面留十几个字，后面留到够显示一行。
    static func snippet(in text: String, terms: [String], before: Int = 14, after: Int = 90) -> String {
        let haystack = asciiLowercased(Array(text.utf8))
        var position: Int?
        for term in terms {
            if let found = FileMatcher.find(asciiLowercased(Array(term.utf8)), in: haystack), found < position ?? .max {
                position = found
            }
        }
        let utf8 = text.utf8
        var start = utf8.index(utf8.startIndex, offsetBy: position ?? 0)
        while start > utf8.startIndex && UTF8.isContinuation(utf8[start]) { start = utf8.index(before: start) }
        let match = start
        // 往前退几个字，碰到换行就停
        var steps = 0
        while start > text.startIndex && steps < before {
            let previous = text.index(before: start)
            if text[previous].isNewline { break }
            start = previous
            steps += 1
        }
        let end = text.index(match, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        var line = ""
        var lastWasSpace = false
        for character in text[start ..< end] {
            if character.isWhitespace {
                if !lastWasSpace && !line.isEmpty { line.append(" ") }
                lastWasSpace = true
            } else {
                line.append(character)
                lastWasSpace = false
            }
        }
        let cut = start > text.startIndex && !text[text.index(before: start)].isNewline
        return (cut ? "…" : "") + line.trimmingCharacters(in: .whitespaces)
    }

    private static func asciiLowercased(_ bytes: [UInt8]) -> [UInt8] {
        bytes.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }
}

// MARK: - SQLite

/// SQLite 连接的小包装。一个连接只在一个队列上用。
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init?(path: String, create: Bool = true) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            Log.app.error("内容索引：打不开数据库 \(path, privacy: .public)")
            sqlite3_close_v2(db)
            return nil
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    @discardableResult
    func execute(_ sql: String) -> Bool {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? ""
            Log.app.error("内容索引：\(message, privacy: .public)")
            sqlite3_free(error)
            return false
        }
        return true
    }

    func prepare(_ sql: String) -> SQLiteStatement? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            Log.app.error("内容索引：\(String(cString: sqlite3_errmsg(self.handle)), privacy: .public)")
            return nil
        }
        return SQLiteStatement(statement)
    }

    func int(_ sql: String) -> Int32 {
        guard let statement = prepare(sql), statement.step() else { return 0 }
        return Int32(statement.int(0))
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
}

final class SQLiteStatement {
    private let handle: OpaquePointer
    /// 让 SQLite 自己复制一份绑定的数据
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_finalize(handle) }

    func bind(_ index: Int32, _ value: String) { sqlite3_bind_text(handle, index, value, -1, Self.transient) }
    func bind(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(handle, index, value) }
    func bind(_ index: Int32, _ value: Double) { sqlite3_bind_double(handle, index, value) }
    func bind(_ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(handle, index)
            return
        }
        _ = value.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), Self.transient) }
    }

    /// 还有下一行时返回 true
    func step() -> Bool { sqlite3_step(handle) == SQLITE_ROW }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func string(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }
    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
