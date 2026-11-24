// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// 跨平台路径校验与文件名清洗，防止目录穿越与非法字符。
enum SyncPathSanitizer {
    private static let illegalChars = CharacterSet(charactersIn: "\\:*?\"<>|\0")
        .union(.controlCharacters)

    /// 校验并将协议中的 POSIX 相对路径解析为目标根目录下的安全本地路径。
    /// 拒绝空路径、前导 `/`、`..`、`.`、驱动器前缀（如 `C:`）和逃逸根目录的路径。
    static func resolveSafeURL(relativePath: String, under root: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("\\"),
              !relativePath.contains("\0")
        else { return nil }

        let rawComponents = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }

        var cleaned: [String] = []
        cleaned.reserveCapacity(rawComponents.count)

        for (idx, sub) in rawComponents.enumerated() {
            let segment = String(sub)
            if segment.isEmpty || segment == "." || segment == ".." {
                return nil
            }
            // 拦截 Windows 盘符前缀（如 C:）或含反斜杠的伪装穿越（..\a）
            if segment.contains("\\") { return nil }
            if idx == 0, segment.count >= 2,
               segment.first?.isASCII == true,
               segment.first?.isLetter == true,
               segment[segment.index(after: segment.startIndex)] == ":" {
                return nil
            }
            let safe = sanitizeSegment(segment)
            guard !safe.isEmpty, safe != ".", safe != ".." else { return nil }
            cleaned.append(safe)
        }

        let canonicalRoot = root.standardizedFileURL
        var target = canonicalRoot
        for part in cleaned {
            target.appendPathComponent(part, isDirectory: false)
        }
        let resolved = target.standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else { return nil }
        return resolved
    }

    static func sanitizeSegment(_ segment: String) -> String {
        let scalars = segment.unicodeScalars.map { illegalChars.contains($0) ? UnicodeScalar("_") : $0 }
        var out = String(String.UnicodeScalarView(scalars))
        // 去掉首尾空白与 Windows 不允许的末尾点，保留有效文件名。
        while out.hasSuffix(".") || out.hasSuffix(" ") {
            out.removeLast()
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    /// 格式化字节大小供界面展示。
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

/// 导出给对端拉取的一批本地文件/文件夹快照。
struct SharedFileBatch: Sendable {
    let transferID: UUID
    let entries: [SharedFileEntry]
    let totalBytes: Int64
    let indexToURL: [Int: URL]
    let createdAt: Date

    var topLevelNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let head = entry.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? entry.relativePath
            if !head.isEmpty && seen.insert(head).inserted {
                result.append(head)
            }
        }
        return result
    }
}

/// 本地共享文件注册表（LRU 保留最近 32 批），供对端按 transferID + fileIndex 流式拉取。
final class SyncFileRegistry: @unchecked Sendable {
    static let maxBatches = 32
    static let maxEntriesPerBatch = 10_000
    /// 单次分享默认总上限 20 GB，避免误选整盘触发超长扫描。
    static let maxTotalBytesPerBatch: Int64 = 20 * 1024 * 1024 * 1024

    private struct State {
        var order: [UUID] = []
        var batches: [UUID: SharedFileBatch] = [:]
    }

    private let state = Locked(State())

    enum ExportError: Error, Equatable {
        case emptySelection
        case tooManyEntries
        case totalSizeExceeded
    }

    /// 扫描本地选中的文件或目录并登记为可共享批次。
    func register(urls: [URL], transferID: UUID = UUID()) throws -> SharedFileBatch {
        let fm = FileManager.default
        var entries: [SharedFileEntry] = []
        var indexToURL: [Int: URL] = [:]
        var totalBytes: Int64 = 0
        var usedTopNames = Set<String>()

        for rawURL in urls {
            let url = rawURL.standardizedFileURL
            guard url.isFileURL else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true
            else { continue }

            let baseName = uniqueTopName(for: url.lastPathComponent, used: &usedTopNames)
            guard !baseName.isEmpty else { continue }
            let mtimeMs = Int64(((values.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000).rounded())

            if values.isDirectory == true {
                let dirIndex = entries.count
                guard dirIndex < Self.maxEntriesPerBatch else { throw ExportError.tooManyEntries }
                entries.append(SharedFileEntry(
                    index: dirIndex,
                    relativePath: baseName,
                    isDirectory: true,
                    size: 0,
                    modifiedMs: mtimeMs
                ))
                indexToURL[dirIndex] = url

                guard let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsPackageDescendants]
                ) else { continue }

                let rootPath = url.path.hasSuffix("/") ? url.path : url.path + "/"
                while let child = enumerator.nextObject() as? URL {
                    let childStd = child.standardizedFileURL
                    guard childStd.path.hasPrefix(rootPath) else { continue }
                    guard let childValues = try? childStd.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                          childValues.isSymbolicLink != true
                    else { continue }

                    let relSuffix = String(childStd.path.dropFirst(rootPath.count))
                    guard !relSuffix.isEmpty else { continue }
                    let relPath = baseName + "/" + relSuffix
                    let idx = entries.count
                    guard idx < Self.maxEntriesPerBatch else { throw ExportError.tooManyEntries }

                    let isDir = childValues.isDirectory == true
                    let size = isDir ? 0 : Int64(childValues.fileSize ?? 0)
                    let childMtime = Int64(((childValues.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000).rounded())
                    if !isDir {
                        totalBytes += max(0, size)
                        guard totalBytes <= Self.maxTotalBytesPerBatch else { throw ExportError.totalSizeExceeded }
                    }
                    entries.append(SharedFileEntry(
                        index: idx,
                        relativePath: relPath,
                        isDirectory: isDir,
                        size: max(0, size),
                        modifiedMs: childMtime
                    ))
                    indexToURL[idx] = childStd
                }
            } else {
                let idx = entries.count
                guard idx < Self.maxEntriesPerBatch else { throw ExportError.tooManyEntries }
                let size = Int64(values.fileSize ?? 0)
                totalBytes += max(0, size)
                guard totalBytes <= Self.maxTotalBytesPerBatch else { throw ExportError.totalSizeExceeded }
                entries.append(SharedFileEntry(
                    index: idx,
                    relativePath: baseName,
                    isDirectory: false,
                    size: max(0, size),
                    modifiedMs: mtimeMs
                ))
                indexToURL[idx] = url
            }
        }

        guard !entries.isEmpty else { throw ExportError.emptySelection }
        let batch = SharedFileBatch(
            transferID: transferID,
            entries: entries,
            totalBytes: totalBytes,
            indexToURL: indexToURL,
            createdAt: Date()
        )
        state.update { s in
            if s.batches[transferID] == nil {
                s.order.append(transferID)
            }
            s.batches[transferID] = batch
            while s.order.count > Self.maxBatches {
                let evicted = s.order.removeFirst()
                s.batches.removeValue(forKey: evicted)
            }
        }
        return batch
    }

    func fileURL(transferID: UUID, fileIndex: Int) -> URL? {
        state.withLock { $0.batches[transferID]?.indexToURL[fileIndex] }
    }

    func batch(for transferID: UUID) -> SharedFileBatch? {
        state.withLock { $0.batches[transferID] }
    }

    func removeAll() {
        state.update { s in
            s.order.removeAll()
            s.batches.removeAll()
        }
    }

    private func uniqueTopName(for raw: String, used: inout Set<String>) -> String {
        let cleaned = SyncPathSanitizer.sanitizeSegment(raw)
        let base = cleaned.isEmpty ? "file" : cleaned
        if used.insert(base).inserted { return base }
        let ext = (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            if used.insert(candidate).inserted { return candidate }
            n += 1
        }
    }
}

/// 接收端文件缓存与清理管理。
final class SyncCacheManager: @unchecked Sendable {
    let rootDirectory: URL
    private var stagingDirectory: URL { rootDirectory.appendingPathComponent(".staging", isDirectory: true) }

    init(directory: URL? = nil) {
        if let directory {
            self.rootDirectory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectory = caches.appendingPathComponent("MacShun/SharedFiles", isDirectory: true)
        }
    }

    func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func stagingFolder(for transferID: UUID) throws -> URL {
        try ensureRootDirectory()
        let dir = stagingDirectory.appendingPathComponent(transferID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    func finalFolder(for transferID: UUID) -> URL {
        rootDirectory.appendingPathComponent(transferID.uuidString, isDirectory: true)
    }

    /// 校验全部条目落盘后，将 `.staging/<id>` 原子提交为 `<root>/<id>`，返回顶层文件/文件夹本地 URL。
    func commitTransfer(transferID: UUID, entries: [SharedFileEntry]) throws -> [URL] {
        let fm = FileManager.default
        let staging = stagingDirectory.appendingPathComponent(transferID.uuidString, isDirectory: true)
        let finalDir = finalFolder(for: transferID)
        if fm.fileExists(atPath: finalDir.path) {
            try fm.removeItem(at: finalDir)
        }
        try fm.moveItem(at: staging, to: finalDir)

        var seen = Set<String>()
        var topURLs: [URL] = []
        for entry in entries {
            let head = entry.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? entry.relativePath
            guard !head.isEmpty, seen.insert(head).inserted,
                  let resolved = SyncPathSanitizer.resolveSafeURL(relativePath: head, under: finalDir),
                  fm.fileExists(atPath: resolved.path)
            else { continue }
            topURLs.append(resolved)
        }
        return topURLs
    }

    func removeStaging(for transferID: UUID) {
        let staging = stagingDirectory.appendingPathComponent(transferID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
    }

    func currentCacheBytes() -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path),
              let enumerator = fm.enumerator(
                at: rootDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
              )
        else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func clearAll() {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else { return }
        for child in children {
            try? fm.removeItem(at: child)
        }
    }

    /// 将已接收的文件/文件夹复制到指定目标目录（默认 ~/Downloads），重名时自动追加序号不覆盖原文件。
    static func copyToDownloads(_ urls: [URL], destinationFolder: URL? = nil) throws -> [URL] {
        let fm = FileManager.default
        let destRoot = destinationFolder
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        var saved: [URL] = []
        for src in urls {
            let name = src.lastPathComponent
            let target = uniqueDestination(named: name, in: destRoot)
            try fm.copyItem(at: src, to: target)
            saved.append(target)
        }
        return saved
    }

    private static func uniqueDestination(named rawName: String, in folder: URL) -> URL {
        let fm = FileManager.default
        let first = folder.appendingPathComponent(rawName)
        if !fm.fileExists(atPath: first.path) { return first }
        let ext = (rawName as NSString).pathExtension
        let stem = ext.isEmpty ? rawName : (rawName as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidate = folder.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// 按过期时间和容量配额清理历史接收缓存（LRU）。
    func prune(maxBytes: Int64, maxAgeDays: Int = 7, now: Date = Date()) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootDirectory.path) else { return }

        // 清理超过 24 小时的孤立暂存目录。
        if let stagingItems = try? fm.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let stagingCutoff = now.addingTimeInterval(-24 * 3600)
            for item in stagingItems {
                let mtime = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if mtime < stagingCutoff {
                    try? fm.removeItem(at: item)
                }
            }
        }

        guard let folders = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, maxAgeDays)) * 24 * 3600)
        var surviving: [(url: URL, mtime: Date, bytes: Int64)] = []
        var totalBytes: Int64 = 0

        for folder in folders where folder.lastPathComponent != ".staging" {
            let mtime = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if mtime < cutoff {
                try? fm.removeItem(at: folder)
                continue
            }
            let size = directorySize(folder)
            surviving.append((folder, mtime, size))
            totalBytes += size
        }

        guard maxBytes >= 0, totalBytes > maxBytes else { return }
        // 按最后修改时间从旧到新淘汰。
        surviving.sort { $0.mtime < $1.mtime }
        for entry in surviving where totalBytes > maxBytes {
            try? fm.removeItem(at: entry.url)
            totalBytes -= entry.bytes
        }
    }

    private func directorySize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}

struct SyncTransferProgress: Equatable, Sendable {
    var transferID: UUID
    var originDeviceName: String
    var bytesReceived: Int64
    var totalBytes: Int64
    var completedFiles: Int
    var totalFiles: Int

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
    }

    var percent: Int { Int((fraction * 100).rounded()) }
}
