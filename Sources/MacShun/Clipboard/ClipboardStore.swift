// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation

/// 剪贴板历史里的一条。
struct ClipboardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
        case files
    }

    var id: UUID
    var kind: Kind
    /// 纯文字内容。图片条目为 nil。
    var text: String?
    /// nil 还没识别；空串表示成功识别但没有文字。旧版历史没有这一项。
    var imageText: String?
    /// 其他格式的数据文件（例如带格式的 RTF、HTML），键是剪贴板类型，值是文件名。
    var extraFiles: [String: String]
    /// 原始 PNG，或等待后台转存的 TIFF。
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    /// 本机文件引用。旧历史没有这一项。
    var fileURLs: [URL]?
    /// 内容的指纹，用来去重。
    var fingerprint: String
    /// TIFF 转为 PNG 后，仍可从原剪贴板数据直接去重。
    var tiffFingerprint: String?
    var created: Date
    var lastUsed: Date
    var pinned: Bool
    /// 从哪个应用复制的
    var sourceApp: String?
    var note: String?

    var fileNames: [String] {
        (fileURLs ?? []).map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
    }

    var isWebLink: Bool {
        guard kind == .text, let text else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: \.isWhitespace), let url = URL(string: value),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return url.host?.isEmpty == false
    }
}

enum ClipboardFilter: CaseIterable {
    case all, text, links, images, files, pinned

    var title: String {
        switch self {
        case .all: L("全部")
        case .text: L("文字")
        case .links: L("链接")
        case .images: L("图片")
        case .files: L("文件")
        case .pinned: L("已固定")
        }
    }

    func includes(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text && !item.isWebLink
        case .links: item.isWebLink
        case .images: item.kind == .image
        case .files: item.kind == .files
        case .pinned: item.pinned
        }
    }
}

/// 从剪贴板读出来、还没存盘的内容。
struct ClipboardCapture {
    var kind: ClipboardItem.Kind
    var text: String?
    /// 剪贴板类型 → 数据
    var extras: [String: Data] = [:]
    var png: Data?
    var tiff: Data?
    var imageSize: CGSize?
    var fileURLs: [URL]?
    var fingerprint: String
    var sourceApp: String?
}

/// 剪贴板历史的存储。内容只保存在本机（C5）：
/// ~/Library/Application Support/MacShun/Clipboard/ 下面一个 history.json 加若干数据文件。
/// 只在主线程上使用。
@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    let directory: URL
    private var indexes: [UUID: PinyinIndex] = [:]
    private var saveScheduled = false
    private var replacedFiles = Set<String>()
    private var recognizesImages = false
    private var recognizing = false
    private var failedImages: Set<UUID> = []
    private var pendingReads: [UUID: Task<String?, Never>] = [:]
    private let ocrQueue = DispatchQueue(label: "MacShun.ClipboardImageText", qos: .utility)
    private var maxUnpinnedItems: Int?
    private var archivingTIFF = false
    private var failedArchives = Set<UUID>()
    private let readImageText: @Sendable (URL) -> String?

    private var historyFile: URL { directory.appendingPathComponent("history.json") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    init(directory: URL? = nil, readImageText: @escaping @Sendable (URL) -> String? = { ContentExtractor.imageText(at: $0) }) {
        self.readImageText = readImageText
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("MacShun/Clipboard", isDirectory: true)
        }
        load()
        archiveNextTIFF()
    }

    // MARK: - 读取

    /// 排序：固定的在前，其余按最近使用时间。
    var sortedItems: [ClipboardItem] {
        let sorted = items.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.lastUsed > b.lastUsed
        }
        guard let limit = maxUnpinnedItems, sorted.count > limit else { return sorted }
        let pinnedCount = sorted.prefix(while: \.pinned).count
        return Array(sorted.prefix(pinnedCount + limit))
    }

    func search(_ query: String, filter: ClipboardFilter = .all) -> [ClipboardItem] {
        let sorted = sortedItems.filter(filter.includes)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sorted }
        let term = PinyinIndex.Query(q)
        return sorted.filter { item in
            let content = item.kind == .files ? item.fileNames.joined(separator: "\n") : item.imageText ?? item.text
            let searchable = item.note.map { note in content.map { note + "\n" + $0 } ?? note } ?? content
            guard let text = searchable, !text.isEmpty else { return false }
            if item.kind == .image && text.localizedCaseInsensitiveContains(q) { return true }
            if let cached = indexes[item.id] { return cached.matches(term) }
            if term.matchesText(text.lowercased()) { return true }
            guard let letters = term.letters else { return false }
            let index = PinyinIndex(text: text)
            indexes[item.id] = index
            return PinyinIndex.syllableMatch(letters, index.syllables)
        }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard var file = item.imageFile else { return nil }
        if file.hasSuffix(".tiff"), let current = items.first(where: { $0.id == item.id || $0.tiffFingerprint == item.fingerprint }),
           let currentFile = current.imageFile { file = currentFile }
        return blobDirectory.appendingPathComponent(file)
    }

    func extraData(for item: ClipboardItem) -> [String: Data] {
        var result: [String: Data] = [:]
        for (type, file) in item.extraFiles {
            if let data = try? Data(contentsOf: blobDirectory.appendingPathComponent(file)) {
                result[type] = data
            }
        }
        return result
    }

    // MARK: - 修改

    /// 记录一条新内容。和已有条目相同时，只把那一条移到最前面。
    func add(_ capture: ClipboardCapture, maxItems: Int, now: Date = Date()) {
        if maxUnpinnedItems != maxItems { trim(maxItems: maxItems) }
        if let i = items.firstIndex(where: { $0.fingerprint == capture.fingerprint || $0.tiffFingerprint == capture.fingerprint }) {
            if capture.kind == .text, !capture.extras.isEmpty || !items[i].extraFiles.isEmpty {
                do {
                    // 先写新附件，等清单原子替换后再移除旧文件，中途退出仍可读回原记录。
                    let files = try writeExtras(capture.extras, prefix: UUID())
                    replacedFiles.formUnion(items[i].extraFiles.values)
                    items[i].extraFiles = files
                } catch {
                    Log.clipboard.error("保存剪贴板格式失败：\(error.localizedDescription, privacy: .public)")
                    return
                }
            }
            items[i].sourceApp = capture.sourceApp
            items[i].lastUsed = now
            scheduleSave()
            return
        }

        let id = UUID()
        var item = ClipboardItem(
            id: id, kind: capture.kind, text: capture.text, extraFiles: [:],
            imageFile: nil, imageWidth: nil, imageHeight: nil, fileURLs: capture.fileURLs,
            fingerprint: capture.fingerprint, created: now, lastUsed: now,
            pinned: false, sourceApp: capture.sourceApp
        )
        do {
            if let data = capture.png ?? capture.tiff {
                try createPrivateDirectory(blobDirectory)
                let name = id.uuidString + (capture.png != nil ? ".png" : ".tiff")
                try data.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                item.imageFile = name
                item.imageWidth = capture.imageSize.map { Int($0.width) }
                item.imageHeight = capture.imageSize.map { Int($0.height) }
            }
            item.extraFiles = try writeExtras(capture.extras, prefix: id)
        } catch {
            Log.clipboard.error("保存剪贴板内容失败：\(error.localizedDescription, privacy: .public)")
            removeFiles(of: item)
            return
        }

        items.append(item)
        trim(maxItems: maxItems)
        scheduleSave()
        indexNextImage()
        if capture.tiff != nil { archiveNextTIFF() }
    }

    private func needsArchiving(_ item: ClipboardItem) -> Bool {
        item.imageFile?.hasSuffix(".tiff") == true && !failedArchives.contains(item.id)
    }

    /// 先让原始 TIFF 可用，串行无损转存 PNG，避免快速复制时同时展开多张大图。
    private func archiveNextTIFF() {
        guard !archivingTIFF,
              let item = items.first(where: needsArchiving),
              let raw = imageURL(for: item) else { return }
        archivingTIFF = true
        let png = raw.deletingPathExtension().appendingPathExtension("png")
        Task {
            let fingerprint = await Task.detached(priority: .utility) { () -> String? in
                guard let data = try? Data(contentsOf: raw, options: .mappedIfSafe),
                      let encoded = ClipboardImage.png(fromTIFF: data) else { return nil }
                do {
                    try encoded.write(to: png, options: .atomic)
                    return Self.fingerprint([Data("image".utf8), encoded])
                } catch { return nil }
            }.value
            defer {
                archivingTIFF = false
                if let limit = maxUnpinnedItems { trim(maxItems: limit) }
                archiveNextTIFF()
                indexNextImage()
            }
            guard let i = items.firstIndex(where: { $0.id == item.id }) else {
                try? FileManager.default.removeItem(at: png)
                return
            }
            guard let fingerprint else {
                failedArchives.insert(item.id)
                return  // 原文件继续支持预览、粘贴；下次启动再尝试。
            }
            let current = items[i]
            // 先提交新清单，再删除旧文件；退出后可从任一已提交的清单恢复。
            replacedFiles.insert(raw.lastPathComponent)
            if let j = items.firstIndex(where: { $0.id != current.id && $0.fingerprint == fingerprint }) {
                var existing = items[j]
                if current.lastUsed > existing.lastUsed {
                    existing.lastUsed = current.lastUsed
                    existing.sourceApp = current.sourceApp
                }
                existing.tiffFingerprint = current.fingerprint
                existing.pinned = existing.pinned || current.pinned
                if let note = current.note, note != existing.note {
                    existing.note = [existing.note, note].compactMap { $0 }.joined(separator: " / ")
                    indexes[existing.id] = nil
                }
                items[j] = existing
                items.remove(at: i)
                indexes[current.id] = nil
                try? FileManager.default.removeItem(at: png)
            } else {
                var archived = current
                archived.imageFile = png.lastPathComponent
                archived.tiffFingerprint = current.fingerprint
                archived.fingerprint = fingerprint
                items[i] = archived
            }
            scheduleSave()
        }
    }

    private func writeExtras(_ extras: [String: Data], prefix: UUID) throws -> [String: String] {
        guard !extras.isEmpty else { return [:] }
        try createPrivateDirectory(blobDirectory)
        var files: [String: String] = [:]
        do {
            for (offset, pair) in extras.enumerated() {
                let name = "\(prefix.uuidString)-\(offset).dat"
                try pair.value.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                files[pair.key] = name
            }
            return files
        } catch {
            for name in files.values { try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name)) }
            throw error
        }
    }

    func setImageRecognition(enabled: Bool) {
        guard recognizesImages != enabled else { return }
        recognizesImages = enabled
        failedImages.removeAll()
        indexNextImage()
    }

    /// 一次只解码一张。每次从当前历史选取，排队期间被清除、去重或淘汰的图片不会再被添加。
    private func indexNextImage() {
        guard recognizesImages, !recognizing,
              let item = items.last(where: {
                  $0.kind == .image && $0.imageText == nil && $0.imageFile != nil && !failedImages.contains($0.id)
                      && !needsArchiving($0)
              }) else { return }
        recognizing = true
        Task { [weak self] in
            guard let self else { return }
            _ = await recognizedText(for: item.id)
            recognizing = false
            indexNextImage()
        }
    }

    /// 显式取字与后台索引共用一个串行解码队列；同一条图片只读一次。
    func recognizedText(for id: UUID) async -> String? {
        guard let item = items.first(where: { $0.id == id && $0.kind == .image }) else { return nil }
        if let text = item.imageText { return text }
        if let task = pendingReads[id] { return await task.value }
        guard let url = imageURL(for: item) else { return nil }
        let task = Task { [readImageText, ocrQueue] () -> String? in
            let text: String? = await withCheckedContinuation { continuation in
                ocrQueue.async { continuation.resume(returning: readImageText(url)) }
            }
            pendingReads[id] = nil
            if replacedFiles.contains(url.lastPathComponent) { scheduleSave() }
            guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
            if recognizesImages {
                if let text {
                    indexes[id] = nil
                    items[i].imageText = text
                    scheduleSave()
                } else { failedImages.insert(id) }
            }
            return text
        }
        pendingReads[id] = task
        return await task.value
    }

    func markUsed(_ id: UUID, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastUsed = now
        scheduleSave()
    }

    func setNote(_ text: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let note = line.isEmpty ? nil : line
        guard items[index].note != note else { return }
        indexes[id] = nil
        items[index].note = note
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: i)
        indexes[item.id] = nil
        removeFiles(of: item)
        scheduleSave()
    }

    /// 清空历史，固定的条目保留。
    func clearUnpinned() {
        for item in items where !item.pinned { removeFiles(of: item) }
        items.removeAll { !$0.pinned }
        indexes = indexes.filter { id, _ in items.contains { $0.id == id } }
        scheduleSave()
    }

    /// 超出数量时删掉最久没用的（固定的不删）。
    func trim(maxItems: Int) {
        maxUnpinnedItems = maxItems
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        guard unpinned.count > maxItems else { return }
        // TIFF 完成转码后可能与旧 PNG 合并。先隐藏超限的旧条目，确认去重后再释放文件。
        let recent = unpinned.prefix(maxItems)
        var keeping = Set(recent.map(\.id))
        if recent.contains(where: needsArchiving) {
            keeping.formUnion(unpinned.lazy.filter { !self.needsArchiving($0) }.prefix(maxItems).map(\.id))
        }
        let removing = Set(unpinned.lazy.map(\.id)).subtracting(keeping)
        guard !removing.isEmpty else { return }
        for item in items where removing.contains(item.id) {
            removeFiles(of: item)
            indexes[item.id] = nil
        }
        items.removeAll { removing.contains($0.id) }
        scheduleSave()
    }

    private func removeFiles(of item: ClipboardItem) {
        failedArchives.remove(item.id)
        failedImages.remove(item.id)
        var files = Array(item.extraFiles.values)
        if let image = item.imageFile { files.append(image) }
        for file in files {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file))
        }
    }

    // MARK: - 存盘

    private func load() {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([ClipboardItem].self, from: data)
            removeUnreferencedFiles()
        } catch {
            // 读不了的历史文件改名留着，不要被下次保存覆盖；数据文件也先不删。
            Log.clipboard.error("读取剪贴板历史失败：\(error.localizedDescription, privacy: .public)")
            let stamp = UUID().uuidString
            let aside = directory.appendingPathComponent("history-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: historyFile, to: aside)
        }
    }

    /// 删掉历史记录里没有引用的数据文件（例如上次保存历史之前程序退出了）。
    private func removeUnreferencedFiles() {
        // 旧清单无法解析时，不知道哪些附件仍被它引用。兼容已经留存的 unreadable 清单。
        guard let manifests = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              !manifests.contains(where: { $0.hasPrefix("history-unreadable-") && $0.hasSuffix(".json") }),
              let files = try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path) else { return }
        var referenced = Set<String>()
        for item in items {
            referenced.formUnion(item.extraFiles.values)
            if let image = item.imageFile { referenced.insert(image) }
        }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file))
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try createPrivateDirectory(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // ISO 8601 清单保留到秒。同秒复制或再次使用的条目按实际先后落盘。
            let data = try encoder.encode(items.sorted { $0.lastUsed > $1.lastUsed })
            try data.write(to: historyFile, options: .atomic)
            let readingTIFFs = Set(pendingReads.keys.map { $0.uuidString + ".tiff" })
            for name in replacedFiles.subtracting(readingTIFFs) {
                try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(name))
                replacedFiles.remove(name)
            }
        } catch {
            Log.clipboard.error("保存剪贴板历史失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 目录只允许当前用户读写。
    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    nonisolated static func fingerprint(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
