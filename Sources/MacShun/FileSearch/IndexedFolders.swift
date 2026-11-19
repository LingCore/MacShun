// SPDX-License-Identifier: MIT

import Foundation

/// 发布给查询的值快照。更新一个目录只需复制它所在的分区，各分区也可以独立匹配。
struct IndexedFolders: Sequence {
    typealias Partition = [String: FolderEntries]
    // 分区数是 2 的幂，插入和查找使用同一个哈希掩码。
    private static let partitionCount = 16
    private(set) var partitions = Array(repeating: Partition(), count: partitionCount)
    let directorySetID = UUID()
    private(set) var pathRevisions = Array(repeating: UInt64(0), count: partitionCount)
    private(set) var fileCount = 0

    init(_ folders: Partition = [:]) { merge(folders) }

    subscript(path: String) -> FolderEntries? {
        get { partitions[path.hashValue & (partitions.count - 1)][path] }
        set {
            let part = path.hashValue & (partitions.count - 1)
            let old: FolderEntries?
            if let newValue { old = partitions[part].updateValue(newValue, forKey: path) }
            else { old = partitions[part].removeValue(forKey: path) }
            if (old == nil) != (newValue == nil) { pathRevisions[part] &+= 1 }
            fileCount += (newValue?.count ?? 0) - (old?.count ?? 0)
        }
    }

    mutating func merge(_ folders: Partition) {
        for (path, entries) in folders { self[path] = entries }
    }

    func makeIterator() -> FlattenSequence<[Partition]>.Iterator {
        partitions.joined().makeIterator()
    }
}
