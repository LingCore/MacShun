// SPDX-License-Identifier: MIT

import Foundation

/// 文件名和全文共用的过滤条件，只在当前查询中生效。
struct FileSearchFilters {
    private(set) var suffixes: [[UInt8]] = []
    private(set) var excluded: [[UInt8]] = []

    var isEmpty: Bool { suffixes.isEmpty && excluded.isEmpty }

    /// 未识别或未写完整的条件保留为普通文字。没有条件时保留原来的空格，供全名精确匹配。
    static func parse(_ text: String, literal: Bool) -> (words: String, filters: Self) {
        var filters = Self()
        guard !literal, text.contains("!") || text.contains("*.") || text.contains(":") else { return (text, filters) }
        var words: [Substring] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let folded = String(token).precomposedStringWithCanonicalMapping.lowercased()
            if folded.hasPrefix("!"), folded.count > 1 {
                filters.excluded.append(Array(folded.dropFirst().utf8))
                continue
            }
            let extensions: [Substring]
            if folded.hasPrefix("*.") {
                extensions = [folded.dropFirst(2)]
            } else if folded.hasPrefix("ext:") {
                extensions = folded.dropFirst(4).split(separator: ",", omittingEmptySubsequences: false)
            } else {
                words.append(token)
                continue
            }
            guard !extensions.isEmpty, extensions.allSatisfy(validExtension) else { words.append(token); continue }
            for ext in extensions {
                let suffix = Array(("." + ext).utf8)
                if !filters.suffixes.contains(suffix) { filters.suffixes.append(suffix) }
            }
        }
        return (filters.isEmpty ? text : words.joined(separator: " "), filters)
    }

    private static func validExtension(_ ext: Substring) -> Bool {
        !ext.isEmpty && ext.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "_+-".contains($0) }
        }
    }

    func accepts(_ name: UnsafeBufferPointer<UInt8>, display: UnsafeBufferPointer<UInt8>? = nil, isDirectory: Bool) -> Bool {
        if !suffixes.isEmpty {
            guard !isDirectory, suffixes.contains(where: { name.count > $0.count && name.suffix($0.count).elementsEqual($0) })
            else { return false }
        }
        return !excluded.contains { word in
            FileMatcher.find(word, in: name) != nil || display.map { FileMatcher.find(word, in: $0) != nil } == true
        }
    }

    func accepts(fileAt path: String) -> Bool {
        guard !isEmpty else { return true }
        let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        return Array(name.utf8).withUnsafeBufferPointer { accepts($0, isDirectory: false) }
    }
}
