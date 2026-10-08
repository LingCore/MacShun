// SPDX-License-Identifier: MIT

import Foundation

/// 从搜索框打开过哪些文件：常打开的、最近打开的排在前面，越用越顺手。只存在这台电脑上，关掉文件搜索时清空。
/// 只在主线程上用。
final class OpenHistory {
    private struct Entry: Codable {
        var count: Int
        var last: Date
    }

    private let defaults: UserDefaults
    private let key = "fileSearch.openHistory"
    private var entries: [String: Entry]
    /// 最多记这么多个文件，多了去掉最久没打开的
    static let capacity = 300

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (defaults.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    func record(_ path: String, at date: Date = Date()) {
        var entry = entries[path] ?? Entry(count: 0, last: date)
        entry.count += 1
        entry.last = date
        entries[path] = entry
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.last < $1.value.last })?.key {
            entries[oldest] = nil
        }
        save()
    }

    func clear() {
        entries = [:]
        defaults.removeObject(forKey: key)
    }

    /// 给搜索结果加的分：打开的次数（最多算 6 次），一周内打开过再加一点。
    /// 加满 24 分：常用的“开头一样”能排到没用过的“全名一样”前面，但“包含”排不过“开头一样”。
    func boosts(now: Date = Date()) -> [String: Double] {
        entries.mapValues { entry in
            Double(min(entry.count, 6)) * 3 + (now.timeIntervalSince(entry.last) < 7 * 86400 ? 6 : 0)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}
