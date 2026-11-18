// SPDX-License-Identifier: MIT

import Foundation

struct FileSearchLocation: Codable, Equatable, Identifiable {
    struct Share: Codable, Equatable {
        let server: String
        let name: String
        let subpath: String
    }

    let id: UUID
    let path: String
    let share: Share?

    init?(path: String, mounts: [SearchVolume] = SearchVolume.mounted()) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path != "/", path != "/Volumes" else { return nil }
        id = UUID()
        self.path = path
        if let volume = mounts.filter({ $0.contains(path) }).max(by: { $0.path.count < $1.path.count }), !volume.isLocal {
            guard let host = volume.server, let name = volume.share else { return nil }
            share = Share(server: host, name: name, subpath: String(path.dropFirst(volume.path.count)))
        } else {
            share = nil
        }
    }

    var name: String { (path as NSString).lastPathComponent }

    func matches(_ other: Self) -> Bool {
        if let share { return share == other.share }
        return other.share == nil && path == other.path
    }

    func mountedPath(in mounts: [SearchVolume]) -> String? {
        guard let share else { return path }
        let matches = mounts
            .filter { $0.server == share.server && $0.share == share.name }
            .compactMap { volume -> String? in
                let candidate = URL(fileURLWithPath: volume.path + share.subpath).standardizedFileURL.path
                return volume.contains(candidate) ? candidate : nil
            }.sorted()
        return matches.contains(path) ? path : matches.first
    }
}

enum FileSearchLocationStatus: Equatable {
    case indexing, ready, offline, unavailable

    var title: String {
        switch self {
        case .indexing: L("正在收录")
        case .ready: L("已收录")
        case .offline: L("共享已离线")
        case .unavailable: L("无法读取文件夹")
        }
    }
}

/// Uses the cached mount table so testing availability cannot block on a network share.
struct SearchVolume {
    let path: String
    let isLocal: Bool
    let server: String?
    let share: String?

    init(path: String, isLocal: Bool, smbSource: String? = nil) {
        self.path = path
        self.isLocal = isLocal
        let url = smbSource.flatMap { URLComponents(string: "smb:" + $0) }
        server = url?.host?.lowercased()
        share = url?.path.split(separator: "/").first?.lowercased()
    }

    func contains(_ file: String) -> Bool { Self.contains(file, under: path) }

    static func contains(_ file: String, under root: String) -> Bool {
        file == root || file.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func mounted() -> [Self] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        var buffer = Array(repeating: statfs(), count: Int(count) + 16)
        let read = buffer.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard read > 0 else { return [] }
        return buffer.prefix(Int(read)).map { mount in
            Self(path: decode(mount.f_mntonname), isLocal: mount.f_flags & UInt32(MNT_LOCAL) != 0,
                 smbSource: decode(mount.f_fstypename) == "smbfs" ? decode(mount.f_mntfromname) : nil)
        }
    }

    private static func decode<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

struct NetworkSearchSnapshot {
    let root: String
    let folders: [String: FolderEntries]
    let metadata: [String: FileSearchMetadata]

    static func read(_ root: String, cancelled: () -> Bool) -> Self? {
        var pending = [root]
        var folders: [String: FolderEntries] = [:]
        var metadata: [String: FileSearchMetadata] = [:]
        while let folder = pending.popLast() {
            guard !cancelled() else { return nil }
            guard let listing = autoreleasepool(invoking: { FileSearchDirectory.read(folder, isCancelled: cancelled) }) else {
                if folder == root { return nil }
                continue
            }
            folders[folder] = listing.entries
            pending.append(contentsOf: listing.subfolders)
            for index in listing.entries.indices {
                guard !cancelled() else { return nil }
                let path = folder + "/" + listing.entries.name(at: index)
                metadata[path] = FileSearchMetadata.read(path)
            }
        }
        return Self(root: root, folders: folders, metadata: metadata)
    }
}
