// SPDX-License-Identifier: MIT

import Foundation

/// Local search vocabulary. Keep a file path or filename out of intent matching, even if it contains a feature name.
struct SystemFeatureQuery {
    let text: String
    let request: String

    init?(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = q.last == "." ? String(q.dropLast()) : q
        guard (1...140).contains(q.count), !phrase.contains(where: { "/\\.:*".contains($0) }) else { return nil }
        text = Self.fold(q)
        guard !text.isEmpty else { return nil }
        var body = text
        while let prefix = Self.prefixes.first(where: { body.hasPrefix($0) }) { body.removeFirst(prefix.count) }
        while let suffix = Self.suffixes.first(where: { body.hasSuffix($0) }) { body.removeLast(suffix.count) }
        request = body
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // Strip conversational scaffolding only at the edges; do not match arbitrary text containing “wifi”.
    private static let prefixes = ["请问一下", "能不能帮我", "可不可以", "我想知道", "有没有办法", "怎么才能", "怎样才能",
        "帮我看看", "给我看看", "我想要", "我想", "想要", "我要", "我该", "我可以", "请帮我", "请问", "请", "帮我", "给我", "能不能", "可以",
        "为什么", "怎么样", "怎么", "怎样", "如何", "在哪儿", "在哪里", "打开", "找到", "看看", "设置一下", "设置", "调整", "调节", "调一下", "调高", "调低", "修改", "更改", "更换", "切换到", "换成", "改成", "换个", "换一下", "改一下", "查一下", "查看", "改", "调",
        "我的", "我这台", "can you please", "can you", "please", "how do i", "how can i", "how to", "where is", "where are", "where can i", "i want to",
        "show me", "take me to", "open", "change", "my"].map(fold).sorted { $0.count > $1.count }
    private static let suffixes = ["在哪里设置", "怎么设置", "在哪里", "在哪儿", "怎么办", "在哪", "怎么弄", "怎么调",
        "怎么改", "怎么开", "设置", "一下", "呢", "吗", "呀", "啊", "settings", "please"].map(fold).sorted { $0.count > $1.count }

    func score(title: String, aliases: [String], subjects: [String], needs: [String],
               pinyin: PinyinIndex, broad: Bool) -> Int {
        if title == text || title == request { return 100 }
        if aliases.contains(text) || (!request.isEmpty && aliases.contains(request)) { return 95 }
        if request.hasSuffix("了"), aliases.contains(String(request.dropLast())) { return 94 }
        // Both the object and the request must match, in either order. Residual words must be conversational glue.
        if !request.isEmpty {
            for subject in subjects {
                guard let s = request.range(of: subject) else { continue }
                let rest = request.replacingCharacters(in: s, with: " ")
                for need in needs {
                    guard let n = rest.range(of: need) else { continue }
                    var leftover = rest.replacingCharacters(in: n, with: "").replacingOccurrences(of: " ", with: "")
                    for filler in Self.glue where !leftover.isEmpty {
                        leftover = leftover.replacingOccurrences(of: filler, with: "")
                    }
                    if leftover.isEmpty { return 90 }
                }
            }
        }
        guard broad else { return 0 }
        if title.contains(text) || aliases.contains(where: { $0.hasPrefix(text) }) { return 60 }
        if text.utf8.allSatisfy({ (97...122).contains($0) }), text.count <= 32, pinyin.matches(text) {
            return 50
        }
        return 0
    }

    private static let glue = ["macbook", "macos", "mac", "电脑上", "电脑", "笔记本", "我这台", "我的", "现在", "最近",
        "突然", "老是", "总是", "一直", "不小心", "一下", "一点", "帮我", "我想", "我", "把", "让", "给", "的", "在", "要", "了",
        "on my mac", "on this mac", "to the", "the", "my", "is"].map(fold).sorted { $0.count > $1.count }
}
