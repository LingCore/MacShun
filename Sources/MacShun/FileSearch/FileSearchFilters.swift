// SPDX-License-Identifier: MIT

import Foundation

/// 文件名和全文共用的过滤条件，只在当前查询中生效。
struct FileSearchFilters {
    private(set) var suffixes: [[UInt8]] = []
    private(set) var excluded: [[UInt8]] = []
    private var sizes: [ClosedRange<Int64>] = []
    private var modifiedSince: Double?

    var needsMetadata: Bool { !sizes.isEmpty || modifiedSince != nil }
    var isEmpty: Bool { suffixes.isEmpty && excluded.isEmpty && !needsMetadata }

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
            if folded.hasPrefix("size:"), let size = sizeRange(folded.dropFirst(5)) {
                filters.sizes.append(size)
                continue
            }
            if folded.hasPrefix("dm:"), let since = modificationStart(folded.dropFirst(3)) {
                filters.modifiedSince = max(filters.modifiedSince ?? since, since)
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

    func accepts(_ metadata: FileSearchMetadata?) -> Bool {
        if let modifiedSince, metadata.map({ $0.modified >= modifiedSince }) != true { return false }
        return sizes.isEmpty || metadata?.size.map { size in sizes.allSatisfy { $0.contains(size) } } == true
    }

    private static func sizeRange(_ expression: Substring) -> ClosedRange<Int64>? {
        let comparisons = [">=", "<=", ">", "<", "="]
        let comparison = comparisons.first { expression.hasPrefix($0) } ?? "="
        let value = expression.dropFirst(expression.hasPrefix(comparison) ? comparison.count : 0)
        let units: [(String, Double)] = [("kb", 1_024), ("mb", 1_048_576), ("gb", 1_073_741_824), ("tb", 1_099_511_627_776), ("b", 1)]
        let unit = units.first { value.hasSuffix($0.0) }
        guard let quantity = Double(value.dropLast(unit?.0.count ?? 0)), quantity >= 0 else { return nil }
        let bytes = quantity * (unit?.1 ?? 1)
        guard bytes < Double(Int64.max), bytes.isFinite else { return nil }
        switch comparison {
        case ">=": return Int64(ceil(bytes)) ... Int64.max
        case ">": return Int64(floor(bytes)) + 1 ... Int64.max
        case "<=": return 0 ... Int64(floor(bytes))
        case "<": return bytes > 0 ? 0 ... Int64(ceil(bytes)) - 1 : -1 ... -1
        default: return bytes.rounded(.towardZero) == bytes ? Int64(bytes) ... Int64(bytes) : -1 ... -1
        }
    }

    private static func modificationStart(_ expression: Substring) -> Double? {
        let now = Date()
        switch expression {
        case "today": return FileSearchModified.today.since(now)
        case "thisyear": return FileSearchModified.year.since(now)
        default:
            guard expression.last == "d", let days = Int(expression.dropLast()), (1 ... 36_500).contains(days) else { return nil }
            return Calendar.current.date(byAdding: .day, value: -days, to: now)?.timeIntervalSince1970
        }
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
