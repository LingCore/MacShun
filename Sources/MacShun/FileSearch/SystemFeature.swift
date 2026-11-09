// SPDX-License-Identifier: MIT

import AppKit

struct SystemFeature: Identifiable {
    enum Destination: Hashable {
        case pane(String), utility(String), settingsApp

        // Only catalog constants reach Launch Services. A query is never a URL, path or command to execute.
        var url: URL {
            switch self {
            case .pane(let pane): return URL(string: "x-apple.systempreferences:" + pane)!
            case .utility(let app): return URL(fileURLWithPath: "/System/Applications/Utilities/\(app).app")
            case .settingsApp: return URL(fileURLWithPath: "/System/Applications/System Settings.app")
            }
        }
    }

    let title: String
    let destination: Destination
    let symbol: String
    var id: Destination { destination }
    var localizedTitle: String { L(title) }
    var category: String {
        if case .utility = destination { return L("系统工具") }
        return L("系统设置")
    }

    private let foldedTitle: String
    private let aliases, subjects, needs: [String]
    private let pinyin: PinyinIndex

    init(title: String, destination: Destination, symbol: String, keywords: String, subjects: String = "", needs: String = "") {
        self.title = title
        self.destination = destination
        self.symbol = symbol
        foldedTitle = SystemFeatureQuery.fold(title)
        func words(_ list: String) -> [String] {
            list.split(separator: "|").map { SystemFeatureQuery.fold(String($0)) }.filter { !$0.isEmpty }
        }
        let phonetic = PinyinIndex(text: title)
        self.aliases = words(keywords) + [phonetic.syllables.compactMap(\.first).map(String.init).joined(),
                                          phonetic.syllables.map { String($0) }.joined()]
        self.subjects = words(subjects)
        self.needs = words(needs)
        pinyin = phonetic
    }

    /// “全部”只插入明确命中的功能；“系统”也接受局部名称，并允许浏览。
    static func search(_ text: String, browse: Bool) -> [Self] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return browse ? catalog : [] }
        guard let q = SystemFeatureQuery(text) else { return [] }
        let matches = catalog.enumerated().compactMap { offset, entry -> (Int, Int, Self)? in
            let score = q.score(title: entry.foldedTitle, aliases: entry.aliases, subjects: entry.subjects,
                                needs: entry.needs, pinyin: entry.pinyin, broad: browse)
            return score == 0 ? nil : (score, offset, entry)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
        return matches.prefix(browse ? matches.count : 3).map(\.2)
    }
}

/// 搜索结果和首页的固定项目使用不同的操作与选中标识。
enum LauncherRow: Identifiable {
    case file(FileSearchResult), feature(SystemFeature), project(PinnedSearchFolder)
    enum ID: Hashable { case file(String), feature(SystemFeature.Destination), project(String) }
    var id: ID {
        switch self {
        case .file(let file): .file(file.path)
        case .feature(let feature): .feature(feature.id)
        case .project(let folder): .project(folder.path)
        }
    }
    var file: FileSearchResult? {
        if case .file(let f) = self { return f }
        return nil
    }
}
