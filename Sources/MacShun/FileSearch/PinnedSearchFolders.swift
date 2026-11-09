// SPDX-License-Identifier: MIT

import Foundation

struct PinnedSearchFolder: Codable, Equatable {
    let path: String
    let name: String
}

/// 用户主动固定的目录，与自动记录的打开历史分开保存。
struct PinnedSearchFolders {
    private static let key = "fileSearch.pinnedFolders"
    private let defaults: UserDefaults?
    private(set) var folders: [PinnedSearchFolder]

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        folders = defaults?.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([PinnedSearchFolder].self, from: $0) } ?? []
    }

    func contains(_ path: String) -> Bool { folders.contains { $0.path == path } }

    mutating func pin(_ folder: PinnedSearchFolder) {
        guard !contains(folder.path) else { return }
        folders.append(folder)
        save()
    }

    mutating func unpin(_ path: String) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        folders.remove(at: index)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(folders) { defaults?.set(data, forKey: Self.key) }
    }
}
