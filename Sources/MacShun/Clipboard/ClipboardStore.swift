// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation

/// 剪贴板历史里的一条。
struct ClipboardItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    var id: UUID
    var kind: Kind
    /// 纯文字内容。图片条目为 nil。
    var text: String?
    /// 其他格式的数据文件（例如带格式的 RTF、HTML），键是剪贴板类型，值是文件名。
    var extraFiles: [String: String]
    /// 图片文件名（PNG）。
    var imageFile: String?
    var imageWidth: Int?
    var imageHeight: Int?
    /// 内容的指纹，用来去重。
    var fingerprint: String
    var created: Date
    var lastUsed: Date
    var pinned: Bool
    /// 从哪个应用复制的
    var sourceApp: String?
}

/// 从剪贴板读出来、还没存盘的内容。
struct ClipboardCapture {
    var kind: ClipboardItem.Kind
    var text: String?
    /// 剪贴板类型 → 数据
    var extras: [String: Data] = [:]
    var png: Data?
    var imageSize: CGSize?
    var fingerprint: String
    var sourceApp: String?
}

/// 剪贴板历史的存储。内容只保存在本机（C5）：
/// ~/Library/Application Support/MacShun/Clipboard/ 下面一个 history.json 加若干数据文件。
/// 只在主线程上使用。
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    let directory: URL
    private var indexes: [UUID: PinyinIndex] = [:]
    private var saveScheduled = false

    private var historyFile: URL { directory.appendingPathComponent("history.json") }
    private var blobDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("MacShun/Clipboard", isDirectory: true)
        }
        load()
    }

    // MARK: - 读取

    /// 排序：固定的在前，其余按最近使用时间。
    var sortedItems: [ClipboardItem] {
        items.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.lastUsed > b.lastUsed
        }
    }

    func search(_ query: String) -> [ClipboardItem] {
        let sorted = sortedItems
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { item in
            guard item.kind == .text else { return false }
            return index(for: item).matches(q)
        }
    }

    private func index(for item: ClipboardItem) -> PinyinIndex {
        if let cached = indexes[item.id] { return cached }
        let index = PinyinIndex(text: item.text ?? "")
        indexes[item.id] = index
        return index
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.imageFile.map { blobDirectory.appendingPathComponent($0) }
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
        if let i = items.firstIndex(where: { $0.fingerprint == capture.fingerprint }) {
            items[i].lastUsed = now
            scheduleSave()
            return
        }

        let id = UUID()
        var item = ClipboardItem(
            id: id, kind: capture.kind, text: capture.text, extraFiles: [:],
            imageFile: nil, imageWidth: nil, imageHeight: nil,
            fingerprint: capture.fingerprint, created: now, lastUsed: now,
            pinned: false, sourceApp: capture.sourceApp
        )
        do {
            try createPrivateDirectory(blobDirectory)
            if let png = capture.png {
                let name = "\(id.uuidString).png"
                try png.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                item.imageFile = name
                item.imageWidth = capture.imageSize.map { Int($0.width) }
                item.imageHeight = capture.imageSize.map { Int($0.height) }
            }
            for (n, (type, data)) in capture.extras.enumerated() {
                let name = "\(id.uuidString)-\(n).dat"
                try data.write(to: blobDirectory.appendingPathComponent(name), options: .atomic)
                item.extraFiles[type] = name
            }
        } catch {
            Log.clipboard.error("保存剪贴板内容失败：\(error.localizedDescription, privacy: .public)")
            removeFiles(of: item)
            return
        }

        items.append(item)
        trim(maxItems: maxItems)
        scheduleSave()
    }

    func markUsed(_ id: UUID, now: Date = Date()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastUsed = now
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
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastUsed > $1.lastUsed }
        guard unpinned.count > maxItems else { return }
        let removing = Set(unpinned[maxItems...].map(\.id))
        for item in items where removing.contains(item.id) {
            removeFiles(of: item)
            indexes[item.id] = nil
        }
        items.removeAll { removing.contains($0.id) }
    }

    private func removeFiles(of item: ClipboardItem) {
        var files = Array(item.extraFiles.values)
        if let image = item.imageFile { files.append(image) }
        for file in files {
            try? FileManager.default.removeItem(at: blobDirectory.appendingPathComponent(file))
        }
    }

    // MARK: - 存盘

    private func load() {
        guard let data = try? Data(contentsOf: historyFile) else {
            removeUnreferencedFiles()
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([ClipboardItem].self, from: data)
            removeUnreferencedFiles()
        } catch {
            // 读不了的历史文件改名留着，不要被下次保存覆盖；数据文件也先不删。
            Log.clipboard.error("读取剪贴板历史失败：\(error.localizedDescription, privacy: .public)")
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = directory.appendingPathComponent("history-unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: historyFile, to: aside)
        }
    }

    /// 删掉历史记录里没有引用的数据文件（例如上次保存历史之前程序退出了）。
    private func removeUnreferencedFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: blobDirectory.path) else { return }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try createPrivateDirectory(directory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: historyFile, options: .atomic)
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

    static func fingerprint(_ parts: [Data]) -> String {
        var hasher = SHA256()
        for part in parts { hasher.update(data: part) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
