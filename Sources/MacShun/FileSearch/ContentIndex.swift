// SPDX-License-Identifier: MIT

import Combine
import Foundation
import SQLite3

/// 文件内容索引（F2）：把 txt、csv、json、Word、Excel、PowerPoint、PDF 里的文字存进 SQLite 的全文索引（FTS5），
/// 在搜索框里按内容搜。索引放在 ~/Library/Application Support/MacShun/ContentIndex/，只在这台电脑上，不联网。
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
        .appendingPathComponent("MacShun/ContentIndex", isDirectory: true))

    /// 已提交的正文或搜索范围变化。改写同一份文件也会通知正在显示的查询。
    let resultsDidChange = PassthroughSubject<Void, Never>()

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
        fileprivate let prefix: String

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

    /// 一组范围。范围很多时（FSEvents 一次报告几千个文件夹）按文件夹查，每个路径只往上走一遍，不用和每个范围比
    struct ScopeSet {
        private let scopes: [Scope]
        private var direct = Set<String>()
        private var recursive = Set<String>()

        init(_ scopes: [Scope]) {
            self.scopes = scopes
            for scope in scopes {
                if scope.recursive { recursive.insert(scope.folder) } else { direct.insert(scope.folder) }
            }
        }

        func contains(_ path: String) -> Bool {
            if scopes.count <= 8 { return scopes.contains { $0.contains(path) } }
            var folder = (path as NSString).deletingLastPathComponent
            if direct.contains(folder) { return true }
            while true {
                if recursive.contains(folder) { return true }
                if folder == "/" || folder.isEmpty { return false }
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
    }

    struct Hit: Equatable {
        let path: String
        /// 匹配处附近的一段文字，一行
        let snippet: String
        var metadata: FileSearchMetadata? = nil
    }

    private let directory: URL
    private var databasePath: String { directory.appendingPathComponent("content.sqlite").path }
    /// 正在读的文件。读的时候程序崩了（文件损坏），下次启动跳过它，免得一启动就崩
    private var readingMarker: URL { directory.appendingPathComponent("reading") }
    /// 改了存储格式或分词方式就加一，旧索引会删掉重建
    private static let schemaVersion: Int32 = 4   // 3：两个汉字之间隔着标点时加分隔记号；4：JSON 也收 512 KB

    private let workQueue = DispatchQueue(label: "MacShun.ContentIndex", qos: .utility, autoreleaseFrequency: .workItem)
    private let searchQueue = DispatchQueue(label: "MacShun.ContentIndex.search", qos: .userInitiated)

    private struct Document {
        let id: Int64
        let mtime: Double
        let size: Int
        let hasText: Bool

        init(_ row: SQLiteStatement) {
            id = row.int(0)
            mtime = row.double(1)
            size = Int(row.int(2))
            hasText = row.int(3) != 0
        }
    }

    /// 以下只在 workQueue 上读写
    private var database: SQLiteDatabase?
    private var documentQuery: SQLiteStatement?
    private var updateDocStmt: SQLiteStatement?
    private var insertDocStmt: SQLiteStatement?
    private var insertAliasStmt: SQLiteStatement?
    private var insertFTSStmt: SQLiteStatement?
    private var deleteDocStmt: SQLiteStatement?
    private var selectTextStmt: SQLiteStatement?
    private var deleteFTSStmt: SQLiteStatement?
    /// 要读的文件。buckets 按种类分开排队，取的时候核对一下 todo，已经不用读的跳过
    private var todo: [String: ContentExtractor.Kind] = [:]
    private var buckets: [[String]] = []
    private var textCount = 0
    private var working = false
    private var lastPublish = Date.distantPast
    private var resultsChanged = false
    /// 上次和别的文件一起读时程序退出了的文件：这次一个一个单独读，再出事就知道是哪个
    private var suspects = Set<String>()

    /// 程序正在退出：不再开始读新的一批
    private let quitting = Locked(false)
    /// 启停代次：stop(deleteData:) 立即递增，阻止正在运行的 workBatch 在 terminateAllHelpers 之后拉起新一轮子进程。
    private let session = Locked(0)
    private let markerLock = Locked(())

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
            self.resultsChanged = true
            self.publish(force: true)
        }
    }

    private func closeWriter() {
        documentQuery = nil
        updateDocStmt = nil
        insertDocStmt = nil
        insertAliasStmt = nil
        insertFTSStmt = nil
        deleteDocStmt = nil
        selectTextStmt = nil
        deleteFTSStmt = nil
        database = nil
    }

    /// 停止读文件。deleteData 为 true 时把索引文件也删掉。
    func stop(deleteData: Bool) {
        session.update { $0 &+= 1 }
        ContentExtractor.terminateIndexingHelpers()
        workQueue.async {
            guard self.database != nil || deleteData else { return }
            self.closeWriter()
            self.todo = [:]
            self.buckets = []
            self.textCount = 0
            self.resultsChanged = true
            self.suspects = []
            // 关闭搜索连接与删除索引目录放在同一 searchQueue.sync 内，防止并发搜索在删目录前重新打开旧 inode。
            self.searchQueue.sync {
                self.reader = nil
                if deleteData, FileManager.default.fileExists(atPath: self.directory.path) {
                    try? FileManager.default.removeItem(at: self.directory)
                    Log.app.notice("内容索引：已删除")
                }
            }
            self.publish(force: true)
        }
    }

    func setSearchRoots(_ roots: [String]) {
        let changed = searchRoots.update { old in
            guard old != roots else { return false }
            old = roots
            return true
        }
        if changed { DispatchQueue.main.async { self.resultsDidChange.send() } }
    }

    /// 打开“认图片里的文字”时：之前没读出字的 PDF 可能是扫描件，忘掉，下次同步时重新读（认字）
    func forgetTextlessPDFs() {
        workQueue.async {
            guard let database = self.database else { return }
            // 没有正文的记录没有 FTS 行，也不计入 textCount。
            database.execute("DELETE FROM docs WHERE text IS NULL AND lower(substr(path, -4)) = '.pdf'")
        }
    }

    /// 程序正常退出时调用（主线程）：正在读的那批文件不算“读的时候崩了”，下次启动照常读。
    func prepareForQuit() {
        markerLock.withLock { _ in
            quitting.set(true)
            session.update { $0 &+= 1 }
            try? FileManager.default.removeItem(at: readingMarker)
        }
        ContentExtractor.terminateAllHelpers()
        // 尽量在短时限内刷盘并关闭数据库，避免异常残留大 WAL。
        let done = DispatchSemaphore(value: 0)
        workQueue.async {
            self.database?.execute("PRAGMA wal_checkpoint(PASSIVE);")
            self.closeWriter()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.35)
    }

    private func open() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !openAndPrepare() {
            // 数据库或表结构已损坏：先关掉所有读写句柄再删文件重建，避免删掉打开中的 WAL。
            Log.app.error("内容索引：数据库打不开或已损坏，重新建立")
            removeDatabaseFiles()
            guard openAndPrepare() else {
                Log.app.error("内容索引：无法读取文档元数据")
                return
            }
        }
        // 上次读这一批文件时程序退出了（崩溃或被强制结束）。只有一个文件时就是它：记成“没有内容”，
        // 文件改过之后才会再读；有好几个时不知道是哪个，这次一个一个单独读
        let marker = (try? String(contentsOf: readingMarker, encoding: .utf8)) ?? ""
        let crashed = marker.split(separator: marker.contains("\0") ? "\0" : "\n").map(String.init)
        if crashed.count == 1, let path = crashed.first {
            Log.app.error("内容索引：上次读这个文件时退出了，跳过：\(path, privacy: .public)")
            transaction {
                if let info = Self.fileInfo(path) { try upsert(path, mtime: info.mtime, size: info.size, compressed: nil, body: nil) }
            }
        } else if crashed.count > 1 {
            Log.app.notice("内容索引：上次读一批文件时退出了，这些文件改为单独读")
            suspects = Set(crashed)
        }
        try? FileManager.default.removeItem(at: readingMarker)
    }

    private func openAndPrepare() -> Bool {
        guard openDatabase(), let db = database, preparePathLookup(db),
              let count = db.prepare("SELECT count(*) FROM docs WHERE text IS NOT NULL"), count.step(),
              let query = db.prepare("""
                  SELECT id, mtime, size, text IS NOT NULL FROM docs
                  WHERE id = (SELECT id FROM doc_keys WHERE key = ? LIMIT 1)
                  """),
              let updateDoc = db.prepare("UPDATE docs SET mtime = ?, size = ?, text = ? WHERE id = ?"),
              let insertDoc = db.prepare("INSERT INTO docs (path, mtime, size, text) VALUES (?, ?, ?, ?)"),
              let insertAlias = db.prepare("INSERT INTO path_aliases (id, key) VALUES (?, ?)"),
              let insertFTS = db.prepare("INSERT INTO docs_fts (rowid, body) VALUES (?, ?)"),
              let deleteDoc = db.prepare("DELETE FROM docs WHERE id = ?"),
              let selectText = db.prepare("SELECT text FROM docs WHERE id = ?"),
              let deleteFTS = db.prepare("INSERT INTO docs_fts (docs_fts, rowid, body) VALUES ('delete', ?, ?)") else {
            closeWriter()
            return false
        }
        textCount = Int(count.int(0))
        documentQuery = query
        updateDocStmt = updateDoc
        insertDocStmt = insertDoc
        insertAliasStmt = insertAlias
        insertFTSStmt = insertFTS
        deleteDocStmt = deleteDoc
        selectTextStmt = selectText
        deleteFTSStmt = deleteFTS
        return true
    }

    /// 打开数据库，沿用已有的文档表和全文索引。
    private func openDatabase() -> Bool {
        var opened = SQLiteDatabase(path: databasePath)
        guard opened != nil else { return false }
        let (isEmpty, needsReset): (Bool, Bool) = {
            let db = opened!
            let empty = db.int("SELECT count(*) FROM sqlite_master") == 0
            return (empty, db.int("PRAGMA user_version") != Self.schemaVersion && !empty)
        }()
        if needsReset {
            // 旧格式：先释放已打开的读写连接，再删掉数据库和 WAL 文件重建。
            Log.app.notice("内容索引：格式变了，重新建立")
            opened = nil
            removeDatabaseFiles()
            opened = SQLiteDatabase(path: databasePath)
        }
        guard let db = opened else { return false }
        if isEmpty || needsReset {
            // 新库启用增量空间回收，删文件或裁剪外接盘后可以真正归还磁盘空间。
            db.execute("PRAGMA auto_vacuum = INCREMENTAL;")
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
        guard ok else { return false }
        // 总是重置只读连接，防止它残留指向旧库或已删除的 inode。
        searchQueue.sync { self.reader = nil }
        database = db
        return true
    }

    /// Swift 路径比较接受 Unicode 等价拼写。保留原始文件名，只把非 NFC 拼写的别名放进
    /// 写连接的临时 B 树；既有索引直接可用，绝大多数路径仍走 docs.path 原有的唯一索引。
    private func preparePathLookup(_ db: SQLiteDatabase) -> Bool {
        guard db.execute("""
            PRAGMA temp_store = FILE;
            CREATE TEMP TABLE path_aliases (id INTEGER PRIMARY KEY, key TEXT NOT NULL);
            CREATE INDEX temp.alias_keys ON path_aliases(key);
            CREATE TEMP VIEW doc_keys AS SELECT path AS key, id FROM docs UNION ALL SELECT key, id FROM path_aliases;
            CREATE TEMP TRIGGER discard_alias AFTER DELETE ON main.docs
            BEGIN DELETE FROM path_aliases WHERE id = OLD.id; END;
            """),
            // UTF-8 字节数等于字符数的路径是纯 ASCII，无需检查 NFC。
            let paths = db.prepare("SELECT id, path FROM docs WHERE length(CAST(path AS BLOB)) != length(path) ORDER BY path"),
            let insert = db.prepare("INSERT INTO path_aliases (id, key) VALUES (?, ?)")
        else { return false }
        do {
            while try paths.next() {
                try autoreleasepool {
                    let path = paths.string(1)
                    let key = path.precomposedStringWithCanonicalMapping
                    if !key.utf8.elementsEqual(path.utf8) {
                        insert.bind(1, paths.int(0))
                        insert.bind(2, key)
                        guard insert.run() else { throw SQLiteFailure() }
                        insert.reset()
                    }
                }
            }
            return true
        } catch { return false }
    }

    /// 重用写队列上的语句；reset 及时结束读事务，WAL 可以正常做 checkpoint。
    private func document(at path: String) throws -> Document? {
        guard let query = documentQuery else { throw SQLiteFailure() }
        query.bind(1, path.precomposedStringWithCanonicalMapping)
        defer { query.reset() }
        guard try query.next() else { return nil }
        return Document(query)
    }

    /// 扫描批次共用一次 SQLite 读事务，临时字典只覆盖本批文件。
    private func documents(for paths: [String]) throws -> [String: Document] {
        if paths.isEmpty { return [:] }
        if paths.count == 1 {
            guard let doc = try document(at: paths[0]) else { return [:] }
            return [paths[0]: doc]
        }
        let parameters = Array(repeating: "?", count: paths.count).joined(separator: ",")
        guard let rows = database?.prepare("""
            SELECT docs.id, mtime, size, text IS NOT NULL, key FROM doc_keys JOIN docs ON docs.id = doc_keys.id
            WHERE key IN (\(parameters))
            """) else { throw SQLiteFailure() }
        for (i, path) in paths.enumerated() { rows.bind(Int32(i + 1), path.precomposedStringWithCanonicalMapping) }
        var matches: [String: Document] = [:]
        while try rows.next() { matches[rows.string(4)] = Document(rows) }
        return matches
    }

    private func removeDatabaseFiles() {
        closeWriter()
        searchQueue.sync {
            reader = nil
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
        }
    }

    private func reclaimDiskSpace() {
        guard let database else { return }
        database.execute("PRAGMA incremental_vacuum(200);")
        database.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // MARK: - 跟着文件变化更新

    /// 文件名索引扫描完或者有变化时调用（哪个线程都可以）：scopes 范围里现在有的文件就是 files。
    /// 新的、改过的排队去读；范围里索引有、files 里没有的（删掉、改名、移走了）从索引里去掉。
    func sync(files: [String], scopes: [Scope]) {
        workQueue.async {
            guard self.database != nil else { return }
            // 外接硬盘上查一个文件的大小和修改时间要零点几毫秒，几个线程一起查
            do {
                for start in stride(from: 0, to: files.count, by: 512) {
                    try autoreleasepool {
                        let batch = files[start..<min(start + 512, files.count)]
                        let candidates = batch.compactMap { path in
                            ContentExtractor.kind(ofFileNamed: (path as NSString).lastPathComponent).map { (path, $0) }
                        }
                        try self.checkDocuments(candidates)
                    }
                }
            } catch {
                Log.app.error("内容索引：无法核对文件属性")
                self.scheduleWork()
                return
            }
            // 外接盘分批交来的文件只增不删，不必遍历整个已有索引。
            let removed = !scopes.isEmpty && self.removeMissingNow(present: Set(files), scopes: scopes)
            self.publish(force: removed)
            self.scheduleWork()
        }
    }

    /// 扫描队列传来紧凑的目录数据；到写队列实际处理时，才展开本批的完整路径。
    func sync<S: Sequence>(folders: S) where S.Element == (key: String, value: FolderEntries) {
        workQueue.async {
            guard self.database != nil else { return }
            var batch: [(String, ContentExtractor.Kind)] = []
            do {
                for (folder, entries) in folders {
                    try FileIndex.forEachContentName(in: folder, entries: entries) { name, kind in
                        batch.append((folder == "/" ? "/" + name : folder + "/" + name, kind))
                        if batch.count == 512 {
                            try autoreleasepool { try self.checkDocuments(batch) }
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                }
                if !batch.isEmpty { try self.checkDocuments(batch) }
            } catch { Log.app.error("内容索引：无法核对文件属性") }
            self.publish(force: false)
            self.scheduleWork()
        }
    }

    private func checkDocuments(_ candidates: [(String, ContentExtractor.Kind)]) throws {
        let paths = candidates.map(\.0)
        var docs = try self.documents(for: paths)
        let infos = Self.fileInfos(paths)
        for ((path, kind), info) in zip(candidates, infos) {
            guard let info, !info.isDataless else { continue }
            if info.size == 0 || info.size > kind.maxFileSize {
                self.todo[path] = nil
                if let doc = docs.removeValue(forKey: path) {
                    self.transaction { try self.remove(id: doc.id, hasText: doc.hasText) }
                }
            } else if let doc = docs[path], doc.mtime == info.mtime, doc.size == info.size {
                self.todo[path] = nil
            } else {
                self.enqueue(path, kind: kind)
            }
        }
    }

    /// 数据库按路径排序。逐目录展开名称，用完即释放，无需再造一份全盘的完整路径集合。
    func removeMissing(in folders: IndexedFolders, scopes: [Scope]) {
        workQueue.async {
            guard self.database != nil else { return }
            var lastFolder: String?
            var names = Set<String>()
            let removed = self.removeMissingNow(scopes: scopes, pending: self.todo.keys.sorted()) { path in
                let bytes = path.utf8
                guard let slash = bytes.lastIndex(of: 0x2F) else { return false }
                let folder = slash == bytes.startIndex ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
                if folder != lastFolder {
                    names.removeAll()
                    if let entries = folders[folder] {
                        FileIndex.forEachContentName(in: folder, entries: entries) { name, _ in names.insert(name) }
                    }
                    lastFolder = folder
                }
                return names.contains(String(decoding: bytes[bytes.index(after: slash)...], as: UTF8.self))
            }
            if removed { self.publish(force: true) }
        }
    }

    private func removeMissingNow(present: Set<String>, scopes: [Scope]) -> Bool {
        removeMissingNow(scopes: scopes, pending: todo.keys, isPresent: present.contains)
    }

    private func removeMissingNow(scopes: [Scope], pending: some Sequence<String>, isPresent: (String) -> Bool) -> Bool {
        guard let database else { return false }
        let covered = ScopeSet(scopes)
        for path in pending where covered.contains(path) && !isPresent(path) { todo[path] = nil }
        // path 上原有的唯一索引同时覆盖 rowid。先收集消失的行号，关闭游标后再改表。
        guard let paths = database.prepare("SELECT id, key FROM doc_keys WHERE key >= ? AND key < ? ORDER BY key")
        else { return false }
        var gone = Set<Int64>()
        do {
            for scope in scopes {
                var lower = scope.prefix.precomposedStringWithCanonicalMapping
                let prefixLength = lower.utf8.count
                let upper = String(lower.dropLast()) + "0"  // BINARY 排序中 "/" 的下一个字节
                while true {
                    paths.bind(1, lower)
                    paths.bind(2, upper)
                    var skipSubtree = false
                    while try paths.next() {
                        let path = paths.string(1)
                        if !scope.recursive, let slash = path.utf8.dropFirst(prefixLength).firstIndex(of: 0x2F) {
                            // 只核对直接子文件时，从索引跳过整个孙目录。下一条可能恰好等于新下界。
                            lower = String(decoding: path.utf8[..<slash], as: UTF8.self) + "0"
                            skipSubtree = true
                            break
                        }
                        if !isPresent(path) { gone.insert(paths.int(0)) }
                    }
                    paths.reset()
                    if !skipSubtree { break }
                }
            }
        } catch {
            Log.app.error("内容索引：无法核对目录")
            return false
        }
        return removeDocuments(gone)
    }

    /// 去掉 scopes 范围里、不在 present 里的文件（全部扫完以后调用，前面分批 sync 时只增不删）。
    func removeMissing(present: Set<String>, scopes: [Scope]) {
        workQueue.async {
            guard self.database != nil, self.removeMissingNow(present: present, scopes: scopes) else { return }
            self.publish(force: true)
        }
    }

    /// 去掉不在这些位置下面的文件（例如关掉了“包括外接硬盘”）。
    func prune(keeping roots: [String]) {
        let scopes = roots.map { Scope(folder: $0, recursive: true) }
        workQueue.async {
            guard let database = self.database, let rows = database.prepare("SELECT id, path FROM docs ORDER BY path") else { return }
            let keeping = ScopeSet(scopes)
            for path in self.todo.keys where !keeping.contains(path) { self.todo[path] = nil }
            var outside: [Int64] = []
            do {
                while try rows.next() {
                    if !keeping.contains(rows.string(1)) { outside.append(rows.int(0)) }
                }
            } catch { return }
            guard self.removeDocuments(outside) else { return }
            self.reclaimDiskSpace()
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
        let expectedSession = session.get()
        workQueue.async { self.workBatch(expectedSession: expectedSession) }
    }

    /// 读一批文件：先读快的（文本，再 Word、PowerPoint、Excel，最后 PDF）。一批里的文件几个核同时读，
    /// 读完在一个事务里写进数据库；读满半秒就让出队列，让排在后面的文件变化先处理，搜索也能尽早搜到。
    private func workBatch(expectedSession: Int) {
        working = false
        guard database != nil, session.get() == expectedSession else { return }
        guard !todo.isEmpty else { publish(force: true); return }
        let begin = Date()
        while Date().timeIntervalSince(begin) < 0.5 {
            guard !quitting.get(), session.get() == expectedSession else { return }
            let tasks = nextTasks()
            guard !tasks.isEmpty else { break }
            tasks.forEach { todo[$0.path] = nil }
            // 记下正在本进程里读的文件，读的时候崩了下次知道是谁（路径里可能有换行，用 0 分开）。
            // 与 prepareForQuit 共享 markerLock，避免退出清理后仍写入残留标记把健康文件拉黑。
            let inProcess = tasks.filter { $0.kind != .pdf && $0.kind != .image }.map(\.path)
            let canProceed = markerLock.withLock { _ -> Bool in
                guard !quitting.get(), session.get() == expectedSession else { return false }
                if inProcess.isEmpty {
                    try? FileManager.default.removeItem(at: readingMarker)
                } else {
                    try? Data(inProcess.joined(separator: "\0").utf8).write(to: readingMarker)
                }
                return true
            }
            guard canProceed else { return }
            let results = Self.read(tasks)
            guard !quitting.get(), session.get() == expectedSession else {
                try? FileManager.default.removeItem(at: readingMarker)
                return
            }
            transaction {
                for (task, result) in zip(tasks, results) {
                    switch result {
                    case .missing:
                        if let doc = try document(at: task.path) { try remove(id: doc.id, hasText: doc.hasText) }
                    case .skipped: break
                    case let .read(info, compressed, body):
                        try upsert(task.path, mtime: info.mtime, size: info.size, compressed: compressed, body: body)
                    }
                }
            }
        }
        try? FileManager.default.removeItem(at: readingMarker)
        guard session.get() == expectedSession else { return }
        if todo.isEmpty {
            reclaimDiskSpace()
            publish(force: true)
            Log.app.notice("内容索引：读完了，共 \(self.textCount, privacy: .public) 个文件有内容")
            // 并行读文件时用过的大块内存，系统分配器会留着备用，读完了就还给系统
            malloc_zone_pressure_relief(nil, 0)
        } else {
            publish(force: false)
            scheduleWork()
        }
    }

    private struct Task {
        let path: String
        let kind: ContentExtractor.Kind
    }

    /// 下一批：文本一次取 16 个；Office 文档解压 XML 内存较大，限制 4 并发；
    /// PDF 在子进程里读，一次取 4 个；图片文字最慢，一次 2 张。
    private func nextTasks() -> [Task] {
        for rank in buckets.indices {
            let limit = switch ContentExtractor.Kind(rawValue: rank) {
            case .docx, .pptx, .xlsx, .pdf: 4
            case .image: 2
            default: 16
            }
            var tasks: [Task] = []
            var seen = Set<String>()
            var later: [String] = []
            while tasks.count < limit, let path = buckets[rank].popLast() {
                guard let kind = todo[path], kind.rawValue == rank, seen.insert(path).inserted else { continue }
                if suspects.contains(path) {
                    // 单独一批
                    if tasks.isEmpty {
                        suspects.remove(path)
                        buckets[rank].append(contentsOf: later)
                        return [Task(path: path, kind: kind)]
                    }
                    later.append(path)
                    continue
                }
                tasks.append(Task(path: path, kind: kind))
            }
            buckets[rank].append(contentsOf: later)
            if !tasks.isEmpty { return tasks }
        }
        return []
    }

    private enum ReadResult {
        /// 文件没了
        case missing
        /// iCloud 里还没下载的、这次没读成要下次再读的，先不记
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
                let text: String
                switch ContentExtractor.read(path: task.path, kind: task.kind) {
                case .text(let read): text = read
                case .empty: return .read(info, nil, nil)
                case .retryLater: return .skipped
                }
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

    /// 数据库是元数据的唯一来源。回滚时只需恢复尚未发布的计数和通知状态。
    @discardableResult
    private func transaction(_ body: () throws -> Void) -> Bool {
        guard let database, database.execute("BEGIN") else { return false }
        let oldCount = textCount, oldChanged = resultsChanged
        do {
            try body()
            guard database.execute("COMMIT") else { throw SQLiteFailure() }
            return true
        } catch {
            database.execute("ROLLBACK")
            textCount = oldCount
            resultsChanged = oldChanged
            Log.app.error("内容索引：写入失败，已回滚")
            return false
        }
    }

    private func upsert(_ path: String, mtime: Double, size: Int, compressed: Data?, body: String?) throws {
        guard let database, let updateDocStmt, let insertDocStmt, let insertAliasStmt, let insertFTSStmt else {
            throw SQLiteFailure()
        }
        let old = try document(at: path)
        let id: Int64
        if let old {
            if old.hasText { try deleteFromFTS(old.id) }
            defer { updateDocStmt.reset() }
            updateDocStmt.bind(1, mtime)
            updateDocStmt.bind(2, Int64(size))
            updateDocStmt.bind(3, compressed)
            updateDocStmt.bind(4, old.id)
            guard updateDocStmt.run() else { throw SQLiteFailure() }
            id = old.id
            if old.hasText { textCount -= 1 }
        } else {
            do {
                defer { insertDocStmt.reset() }
                insertDocStmt.bind(1, path)
                insertDocStmt.bind(2, mtime)
                insertDocStmt.bind(3, Int64(size))
                insertDocStmt.bind(4, compressed)
                guard insertDocStmt.run() else { throw SQLiteFailure() }
            }
            id = database.lastInsertID
            let key = path.precomposedStringWithCanonicalMapping
            if !key.utf8.elementsEqual(path.utf8) {
                defer { insertAliasStmt.reset() }
                insertAliasStmt.bind(1, id)
                insertAliasStmt.bind(2, key)
                guard insertAliasStmt.run() else { throw SQLiteFailure() }
            }
        }
        if let body {
            defer { insertFTSStmt.reset() }
            insertFTSStmt.bind(1, id)
            insertFTSStmt.bind(2, body)
            guard insertFTSStmt.run() else { throw SQLiteFailure() }
            textCount += 1
        }
        if old?.hasText == true || body != nil { resultsChanged = true }
    }

    private func removeDocuments<C: Collection>(_ ids: C) -> Bool where C.Element == Int64 {
        guard !ids.isEmpty, let query = database?.prepare("SELECT text IS NOT NULL FROM docs WHERE id = ?") else { return false }
        let ok = transaction {
            for id in ids {
                query.bind(1, id)
                guard try query.next() else { throw SQLiteFailure() }
                let hasText = query.int(0) != 0
                query.reset()
                try autoreleasepool { try remove(id: id, hasText: hasText) }
            }
        }
        if ok && ids.count >= 16 { reclaimDiskSpace() }
        return ok
    }

    private func remove(id: Int64, hasText: Bool) throws {
        guard let deleteDocStmt else { throw SQLiteFailure() }
        if hasText {
            try deleteFromFTS(id)
            textCount -= 1
            resultsChanged = true
        }
        defer { deleteDocStmt.reset() }
        deleteDocStmt.bind(1, id)
        guard deleteDocStmt.run() else { throw SQLiteFailure() }
    }

    /// contentless FTS5 删除时需交回原分词；任一步失败都必须保留原记录和词条。
    private func deleteFromFTS(_ id: Int64) throws {
        guard let selectTextStmt, let deleteFTSStmt else { throw SQLiteFailure() }
        let text: String
        do {
            defer { selectTextStmt.reset() }
            selectTextStmt.bind(1, id)
            guard try selectTextStmt.next(), let decoded = Self.decompress(selectTextStmt.data(0)) else {
                throw SQLiteFailure()
            }
            text = decoded
        }
        defer { deleteFTSStmt.reset() }
        deleteFTSStmt.bind(1, id)
        deleteFTSStmt.bind(2, Self.ftsText(text))
        guard deleteFTSStmt.run() else { throw SQLiteFailure() }
    }

    private func publish(force: Bool) {
        // 初扫队列清空后，释放字典容量及已取消、尚未从 buckets 弹出的路径。
        if todo.isEmpty {
            todo = [:]
            buckets = []
        }
        guard force || (resultsChanged && todo.isEmpty) || Date().timeIntervalSince(lastPublish) > 0.5 else { return }
        lastPublish = Date()
        let documents = textCount, pending = todo.count
        let notifySearch = resultsChanged
        resultsChanged = false
        let size = ["", "-wal"].reduce(Int64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath + suffix)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        DispatchQueue.main.async {
            if self.documentCount != documents { self.documentCount = documents }
            if self.pendingCount != pending { self.pendingCount = pending }
            if self.diskSize != size { self.diskSize = size }
            if notifySearch { self.resultsDidChange.send() }
        }
    }

    private struct FileInfo {
        let mtime: Double
        let size: Int
        let isDataless: Bool
    }

    private static func fileInfos(_ paths: [String]) -> [FileInfo?] {
        guard !paths.isEmpty else { return [] }
        if paths.count <= 4 { return paths.map(fileInfo) }
        var infos = [FileInfo?](repeating: nil, count: paths.count)
        let chunks = min(8, paths.count)
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
    func search(_ query: String, limit: Int = 30, within folder: String? = nil, options: FileSearchOptions = .init(),
                cancelled: Locked<Bool> = Locked(false), completion: @escaping ([Hit]) -> Void) {
        let parsed = FileMatcher.Query(query)
        guard let match = Self.matchExpression(for: parsed.contentText), limit > 0 else {
            completion([])
            return
        }
        let roots = searchRoots.get().map { Scope(folder: $0, recursive: true) }
        searchQueue.async {
            let hits = self.runSearch(match, query: parsed, roots: roots, within: folder, limit: limit, options: options, cancelled: cancelled)
            DispatchQueue.main.async { if !cancelled.get() { completion(hits) } }
        }
    }

    /// 测试用：同步搜索
    func searchNow(_ query: String, limit: Int = 30, within folder: String? = nil, options: FileSearchOptions = .init()) -> [Hit] {
        let parsed = FileMatcher.Query(query)
        guard let match = Self.matchExpression(for: parsed.contentText), limit > 0 else { return [] }
        let roots = searchRoots.get().map { Scope(folder: $0, recursive: true) }
        return searchQueue.sync { runSearch(match, query: parsed, roots: roots, within: folder, limit: limit, options: options, cancelled: Locked(false)) }
    }

    /// 测试用：等到排队的文件都读完
    func waitUntilIdle() {
        while workQueue.sync(execute: { !todo.isEmpty || working }) { usleep(5_000) }
    }

    /// 测试用：收录了内容的文件数（不经过主线程）
    var documentCountNow: Int { workQueue.sync { textCount } }

    private func runSearch(_ match: String, query: FileMatcher.Query, roots: [Scope], within folder: String?,
                           limit: Int, options: FileSearchOptions, cancelled: Locked<Bool>) -> [Hit] {
        guard !cancelled.get(), !options.foldersOnly else { return [] }
        let terms = query.contentText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let selectedFolder = folder.map { Scope(folder: $0, recursive: true) }
        let directory = query.filters.isEmpty ? nil : query.directoryInput.map { Scope(folder: $0.folder, recursive: false) }
        let since = options.modified.since(Date())
        if reader == nil {
            guard FileManager.default.fileExists(atPath: databasePath) else { return [] }
            reader = SQLiteDatabase(path: databasePath, create: false)
        }
        // 排序只读主键、路径和属性。确定这一页后才按主键解压摘要需要的正文。
        let ranksByRelevance = options.order == .relevance
        guard let reader, let statement = reader.prepare("""
            SELECT docs.id, path, mtime, size FROM docs_fts JOIN docs ON docs.id = docs_fts.rowid
            WHERE docs_fts MATCH ? \(ranksByRelevance ? "ORDER BY rank" : "")
            """), let textStatement = reader.prepare("SELECT text FROM docs WHERE id = ?")
        else {
            self.reader = nil   // 可能索引还没建好，下次再试
            return []
        }
        // 按相关性顺次取路径，达到「通过筛选」的条数才停。已拔盘或大量同类文件不会挤掉后面的命中。
        reader.observeCancellation(cancelled)
        defer { withExtendedLifetime(cancelled) { reader.observeCancellation(nil) } }
        statement.bind(1, match)
        func makeHit(id: Int64, path: String, metadata: FileSearchMetadata?) -> Hit? {
            guard !cancelled.get() else { return nil }
            textStatement.reset()
            textStatement.bind(1, id)
            guard textStatement.step(), let text = Self.decompress(textStatement.data(0)) else { return nil }
            return Hit(path: path, snippet: Self.snippet(in: text, terms: terms), metadata: metadata)
        }
        var hits: [Hit] = []
        var best = BestFileResults(limit: limit, order: options.order)
        var idByPath: [String: Int64] = [:]
        while hits.count < limit && !cancelled.get() && statement.step() {
            let docID = statement.int(0)
            let path = statement.string(1)
            guard selectedFolder?.contains(path) != false, directory?.contains(path) != false, query.filters.accepts(fileAt: path),
                  roots.isEmpty || roots.contains(where: { $0.contains(path) }), options.acceptsKind(path, isFolder: false)
            else { continue }
            let metadata = FileSearchMetadata(modified: statement.double(2), size: statement.int(3))
            guard options.accepts(metadata, since: since), query.filters.accepts(metadata) else { continue }
            if ranksByRelevance {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                if let hit = makeHit(id: docID, path: path, metadata: options.showsMetadata ? metadata : nil) { hits.append(hit) }
            } else {
                // 先用堆截止阈值剪枝，仅对能进入前 limit 的候选检查文件存在性，避免死记录挤掉有效结果也避免万级刷盘。
                let candidate = FileSearchResult(path: path, name: (path as NSString).lastPathComponent, isDirectory: false,
                                                 score: 0, metadata: metadata)
                guard best.couldAccept(candidate), FileManager.default.fileExists(atPath: path) else { continue }
                idByPath[path] = docID
                best.add(candidate)
            }
        }
        if ranksByRelevance { return hits }
        return best.sorted().compactMap { row in
            guard let docID = idByPath[row.path] else { return nil }
            return makeHit(id: docID, path: row.path, metadata: row.metadata)
        }
    }

    // MARK: - 分词和摘要（纯函数，方便测试）

    /// 中日韩文字：每个字单独成词
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x3134F: true
        default: false
        }
    }

    /// 两个汉字之间隔着标点时放的分隔记号（私用区字符，分词器会把它当成一个词）：
    /// 搜“合同”时，“符合。同时”里隔着句号的两个字连不起来。
    /// 空格、换行不算（中文硬换行也可能把一个词断开）；英文本来按词分，隔着标点也没关系，不加（代码里标点很多，加了索引会大很多）。
    static let boundary: Unicode.Scalar = "\u{E000}"

    /// 交给 FTS5 的文字：每个汉字前后加空格，英文、数字不变，两个汉字之间隔着标点时加一个分隔记号。
    static func ftsText(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasCJK = false
        var punctuation = false
        for scalar in text.unicodeScalars {
            let cjk = isCJK(scalar)
            if cjk || isWordCharacter(scalar) {
                if cjk && lastWasCJK && punctuation {
                    out.append(" ")
                    out.append(boundary)
                    out.append(" ")
                }
                punctuation = false
                lastWasCJK = cjk
                if cjk {
                    out.append(" ")
                    out.append(scalar)
                    out.append(" ")
                } else {
                    out.append(scalar)
                }
            } else {
                if !scalar.properties.isWhitespace { punctuation = true }
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// 分词器当成词的一部分的字符：字母、数字、附加符号、私用区字符（和 unicode61 一样）
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark, .enclosingMark, .privateUse:
            return true
        default:
            return false
        }
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
        func isLetter(_ scalar: Unicode.Scalar) -> Bool { !isCJK(scalar) && CharacterSet.alphanumerics.contains(scalar) }
        for term in query.split(whereSeparator: { $0.isWhitespace }) {
            let scalars = Array(term.unicodeScalars)
            let hasCJK = scalars.contains(where: isCJK)
            // 只有一个字母或数字的词太宽（以它开头的词成千上万），搜起来慢，不参与内容搜索；继续打字就有了
            guard hasCJK || scalars.filter(isLetter).count >= 2 else { continue }
            let escaped = ftsText(String(term)).replacingOccurrences(of: "\"", with: "\"\"")
            var phrase = "\"" + escaped + "\""
            // 结尾至少两个字母或数字时按前缀找
            if scalars.count >= 2, isLetter(scalars[scalars.count - 1]), isLetter(scalars[scalars.count - 2]) {
                phrase += " *"
            }
            phrases.append(phrase)
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: " AND ")
    }

    /// 从原文里截出第一次匹配附近的一段，压成一行：匹配处前面留十几个字，后面留到够显示一行。
    /// 直接在 String 上做 Unicode 大小写/变音符号不敏感查找，零整文拷贝，并支持跨换行的中文短语。
    static func snippet(in text: String, terms: [String], before: Int = 14, after: Int = 90) -> String {
        var earliest: String.Index?
        for term in terms where !term.isEmpty {
            let found = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])?.lowerBound
                ?? findAcrossWhitespace(term, in: text)
            if let found, earliest == nil || found < earliest! {
                earliest = found
            }
        }
        var start = earliest ?? text.startIndex
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

    /// FTS5 中文短语允许中间夹硬换行或空格；直接 range(of:) 未命中时回退按去空白字序列查找。
    private static func findAcrossWhitespace(_ term: String, in text: String) -> String.Index? {
        let chars = term.filter { !$0.isWhitespace }
        guard chars.count >= 2, chars.unicodeScalars.contains(where: isCJK), let first = chars.first else { return nil }
        let tail = Array(chars.dropFirst())
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == first {
                var cursor = text.index(after: i)
                var matched = true
                for expected in tail {
                    while cursor < text.endIndex && text[cursor].isWhitespace { cursor = text.index(after: cursor) }
                    guard cursor < text.endIndex && text[cursor] == expected else { matched = false; break }
                    cursor = text.index(after: cursor)
                }
                if matched { return i }
            }
            i = text.index(after: i)
        }
        return nil
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

    /// 只在读取连接的串行队列上安装，调用方在移除回调前持有标记。
    func observeCancellation(_ flag: Locked<Bool>?) {
        guard let flag else { sqlite3_progress_handler(handle, 0, nil, nil); return }
        sqlite3_progress_handler(handle, 2048, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<Locked<Bool>>.fromOpaque(pointer).takeUnretainedValue().get() ? 1 : 0
        }, Unmanaged.passUnretained(flag).toOpaque())
    }

    func int(_ sql: String) -> Int32 {
        guard let statement = prepare(sql), statement.step() else { return 0 }
        return Int32(statement.int(0))
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }
}

private struct SQLiteFailure: Error {}

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
    /// 在写入和删除核对中区分正常结束与读取失败，避免提交不完整的事务。
    func next() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteFailure()
        }
    }
    /// 执行不返回结果的语句，成功时返回 true
    func run() -> Bool { sqlite3_step(handle) == SQLITE_DONE }
    /// 重新执行前调用
    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func string(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }
    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(handle, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }
}
