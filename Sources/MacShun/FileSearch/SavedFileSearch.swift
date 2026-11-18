// SPDX-License-Identifier: MIT

import Foundation

struct SavedFileSearch: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let folder: String?
    let options: FileSearchOptions
}

struct SavedFileSearches {
    private static let key = "fileSearch.savedFilters"
    private let defaults: UserDefaults?
    private(set) var items: [SavedFileSearch]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        items = defaults?.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([SavedFileSearch].self, from: $0) } ?? []
    }

    @discardableResult
    mutating func add(name: String, folder: String?, options: FileSearchOptions) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !items.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return false }
        items.append(SavedFileSearch(id: UUID(), name: name, folder: folder, options: options))
        save()
        return true
    }

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults?.set(data, forKey: Self.key) }
    }
}
