// SPDX-License-Identifier: MIT

import Foundation

struct FileSearchMetadata: Equatable {
    let modified: Double
    let size: Int64?

    static func read(_ path: String) -> Self? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Self(modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                    size: info.st_mode & S_IFMT == S_IFREG ? info.st_size : nil)
    }
}

enum FileSearchOrder: String, CaseIterable, Codable {
    case relevance, nameAscending, nameDescending, folder, folderDescending, newest, oldest, largest, smallest

    var title: String {
        switch self {
        case .relevance: L("最匹配")
        case .nameAscending: L("名称升序")
        case .nameDescending: L("名称降序")
        case .folder: L("所在目录")
        case .folderDescending: L("所在目录降序")
        case .newest: L("修改时间：最新")
        case .oldest: L("修改时间：最早")
        case .largest: L("大小：从大到小")
        case .smallest: L("大小：从小到大")
        }
    }

    var needsMetadata: Bool {
        switch self {
        case .newest, .oldest, .largest, .smallest: true
        default: false
        }
    }

    func precedes(_ lhs: FileSearchResult, _ rhs: FileSearchResult) -> Bool {
        let order: ComparisonResult
        switch self {
        case .relevance:
            return BestFileResults.byRelevance(lhs, rhs)
        case .nameAscending:
            order = lhs.name.localizedStandardCompare(rhs.name)
        case .nameDescending:
            order = rhs.name.localizedStandardCompare(lhs.name)
        case .folder, .folderDescending:
            let a = (lhs.path as NSString).deletingLastPathComponent
            let b = (rhs.path as NSString).deletingLastPathComponent
            order = self == .folder ? a.localizedStandardCompare(b) : b.localizedStandardCompare(a)
        case .newest, .oldest:
            order = Self.compare(lhs.metadata?.modified, rhs.metadata?.modified, descending: self == .newest)
        case .largest, .smallest:
            order = Self.compare(lhs.metadata?.size, rhs.metadata?.size, descending: self == .largest)
        }
        return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, descending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedDescending
        case (_, nil): .orderedAscending
        case let (lhs?, rhs?):
            lhs == rhs ? .orderedSame : (descending ? lhs > rhs : lhs < rhs) ? .orderedAscending : .orderedDescending
        }
    }
}

enum FileSearchKind: String, CaseIterable, Codable {
    case any, folders, documents, pdf, images, video, audio, archives, code

    var title: String {
        switch self {
        case .any: L("所有类型")
        case .folders: L("文件夹")
        case .documents: L("文档")
        case .pdf: "PDF"
        case .images: L("图片文件")
        case .video: L("视频")
        case .audio: L("音频")
        case .archives: L("压缩包")
        case .code: L("代码与配置")
        }
    }

    var symbol: String {
        switch self {
        case .any: "square.grid.2x2"
        case .folders: "folder"
        case .documents: "doc.text"
        case .pdf: "doc.richtext"
        case .images: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .archives: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "wps", "odt", "rtf", "pages", "txt", "md", "markdown",
        "xls", "xlsx", "et", "ods", "numbers", "csv", "tsv", "ppt", "pptx", "dps", "odp", "key", "epub",
    ]
    private static let imageExtensions = ContentExtractor.imageExtensions.union(["gif", "svg", "ico", "psd", "avif", "dng", "raw"])
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "webm", "mkv", "avi", "wmv", "mpeg", "mpg", "mts", "m2ts"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "aac", "ogg", "opus", "caf", "wma"]
    private static let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg"]
    private static let codeExtensions = ContentExtractor.textExtensions.subtracting(documentExtensions)

    func accepts(_ path: String, isFolder: Bool) -> Bool {
        if self == .any { return true }
        if isFolder { return self == .folders }
        let ext = (path as NSString).pathExtension.lowercased()
        switch self {
        case .any, .folders: return false
        case .documents: return Self.documentExtensions.contains(ext)
        case .pdf: return ext == "pdf"
        case .images: return Self.imageExtensions.contains(ext)
        case .video: return Self.videoExtensions.contains(ext)
        case .audio: return Self.audioExtensions.contains(ext)
        case .archives: return Self.archiveExtensions.contains(ext)
        case .code: return Self.codeExtensions.contains(ext)
        }
    }
}

enum FileSearchModified: String, CaseIterable, Codable {
    case any, today, week, month, year, custom

    var title: String {
        switch self {
        case .any: L("不限时间")
        case .today: L("今天")
        case .week: L("最近 7 天")
        case .month: L("最近 30 天")
        case .year: L("今年")
        case .custom: L("自定义范围")
        }
    }

    func since(_ now: Date, calendar: Calendar = .current) -> Double? {
        let date: Date?
        switch self {
        case .any, .custom: date = nil
        case .today: date = calendar.startOfDay(for: now)
        case .week: date = calendar.date(byAdding: .day, value: -7, to: now)
        case .month: date = calendar.date(byAdding: .day, value: -30, to: now)
        case .year: date = calendar.dateInterval(of: .year, for: now)?.start
        }
        return date?.timeIntervalSince1970
    }
}

enum FileSearchSize: String, CaseIterable, Codable {
    case any, underMB, medium, large, overGB, custom

    var title: String {
        switch self {
        case .any: L("不限")
        case .underMB: "< 1 MB"
        case .medium: "1–100 MB"
        case .large: "100 MB–1 GB"
        case .overGB: "≥ 1 GB"
        case .custom: L("自定义范围")
        }
    }

    var range: Range<Int64>? {
        switch self {
        case .any, .custom: nil
        case .underMB: 0 ..< 1_048_576
        case .medium: 1_048_576 ..< 104_857_600
        case .large: 104_857_600 ..< 1_073_741_824
        case .overGB: 1_073_741_824 ..< Int64.max
        }
    }
}

struct FileSearchBounds: Equatable, Codable {
    let lower: Double?
    let upper: Double?

    func contains(_ value: Double) -> Bool {
        lower.map { value >= $0 } != false && upper.map { value <= $0 } != false
    }
}

enum FileSearchRangeKind {
    case date, size

    var title: String { self == .date ? L("自定义修改时间") : L("自定义大小") }
    var lowerPlaceholder: String { self == .date ? L("起始日期 YYYY-MM-DD") : L("最小大小（MB）") }
    var upperPlaceholder: String { self == .date ? L("结束日期 YYYY-MM-DD") : L("最大大小（MB）") }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    func parse(lower: String, upper: String) -> FileSearchBounds? {
        let lower = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = upper.trimmingCharacters(in: .whitespacesAndNewlines)
        let minimum = parse(lower, endOfDay: false)
        let maximum = parse(upper, endOfDay: true)
        guard lower.isEmpty || minimum != nil, upper.isEmpty || maximum != nil,
              minimum != nil || maximum != nil,
              minimum.map({ $0 <= (maximum ?? .infinity) }) != false else { return nil }
        return FileSearchBounds(lower: minimum, upper: maximum)
    }

    private func parse(_ text: String, endOfDay: Bool) -> Double? {
        if self == .size {
            guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number >= 0,
                  number * 1_048_576 < Double(Int64.max) else { return nil }
            return number * 1_048_576
        }
        let formatter = dateFormatter
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        if !endOfDay { return date.timeIntervalSince1970 }
        return Calendar.current.date(byAdding: .day, value: 1, to: date)?.timeIntervalSince1970.nextDown
    }

    func label(_ value: Double?) -> String {
        guard let value else { return "" }
        // 上界存为次日 00:00 的 nextDown，向下取整到整秒避免 ICU DateFormatter 毫秒舍入回次日导致每次重开弹窗 +1 天。
        return self == .date ? dateFormatter.string(from: Date(timeIntervalSince1970: floor(value)))
            : String(format: "%.10g", value / 1_048_576)
    }
}

struct FileSearchOptions: Equatable, Codable {
    private enum CodingKeys: String, CodingKey { case kind, kinds, modified, size, order, dateBounds, sizeBounds }
    private(set) var kinds: Set<FileSearchKind> = []
    var modified: FileSearchModified = .any {
        didSet { if modified != .custom { dateBounds = nil } }
    }
    var size: FileSearchSize = .any {
        didSet { if size != .custom { sizeBounds = nil } }
    }
    var order: FileSearchOrder = .relevance
    var dateBounds: FileSearchBounds?
    var sizeBounds: FileSearchBounds?
    var showsMetadata = false
    var recursive = false

    init(kind: FileSearchKind = .any, modified: FileSearchModified = .any, size: FileSearchSize = .any,
         order: FileSearchOrder = .relevance, showsMetadata: Bool = false, recursive: Bool = false) {
        kinds = kind == .any ? [] : [kind]
        self.modified = modified
        self.size = size
        self.order = order
        self.showsMetadata = showsMetadata
        self.recursive = recursive
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try values.decodeIfPresent(FileSearchKind.self, forKey: .kind) ?? .any
        kinds = try values.decodeIfPresent(Set<FileSearchKind>.self, forKey: .kinds) ?? (legacy == .any ? [] : [legacy])
        kinds.remove(.any)
        if kinds.contains(.folders) { kinds = [.folders] }
        modified = try values.decodeIfPresent(FileSearchModified.self, forKey: .modified) ?? .any
        size = try values.decodeIfPresent(FileSearchSize.self, forKey: .size) ?? .any
        order = try values.decodeIfPresent(FileSearchOrder.self, forKey: .order) ?? .relevance
        dateBounds = modified == .custom ? try values.decodeIfPresent(FileSearchBounds.self, forKey: .dateBounds) : nil
        sizeBounds = size == .custom ? try values.decodeIfPresent(FileSearchBounds.self, forKey: .sizeBounds) : nil
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kinds.sorted { $0.rawValue < $1.rawValue }, forKey: .kinds)
        try values.encode(modified, forKey: .modified)
        try values.encode(size, forKey: .size)
        try values.encode(order, forKey: .order)
        if modified == .custom { try values.encodeIfPresent(dateBounds, forKey: .dateBounds) }
        if size == .custom { try values.encodeIfPresent(sizeBounds, forKey: .sizeBounds) }
    }

    var foldersOnly: Bool { kinds.contains(.folders) }
    var hasFilters: Bool { !kinds.isEmpty || modified != .any || size != .any }
    var needsMetadata: Bool { modified != .any || size != .any || order.needsMetadata }

    func selects(_ kind: FileSearchKind) -> Bool { kind == .any ? kinds.isEmpty : kinds.contains(kind) }

    mutating func toggle(_ kind: FileSearchKind) {
        switch kind {
        case .any: kinds.removeAll()
        case .folders: kinds = foldersOnly ? [] : [.folders]
        default:
            kinds.remove(.folders)
            if kinds.remove(kind) == nil { kinds.insert(kind) }
        }
    }

    func acceptsKind(_ path: String, isFolder: Bool) -> Bool {
        kinds.isEmpty || kinds.contains { $0.accepts(path, isFolder: isFolder) }
    }

    func accepts(_ metadata: FileSearchMetadata?, since: Double?) -> Bool {
        if let since, metadata.map({ $0.modified >= since }) != true { return false }
        if modified == .custom, let dateBounds, metadata.map({ dateBounds.contains($0.modified) }) != true { return false }
        if let range = size.range, metadata?.size.map(range.contains) != true { return false }
        if size == .custom, let sizeBounds, metadata?.size.map({ sizeBounds.contains(Double($0)) }) != true { return false }
        return true
    }
}
