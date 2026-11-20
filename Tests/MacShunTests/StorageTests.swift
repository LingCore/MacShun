// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing
@testable import MacShun

@Suite("C3 剪贴板存储")
@MainActor
struct ClipboardStoreTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacShunTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func text(_ s: String) -> ClipboardCapture {
        ClipboardCapture(kind: .text, text: s, fingerprint: ClipboardStore.fingerprint([Data(s.utf8)]))
    }

    @Test func addDeduplicatesAndOrders() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.add(text("一"), maxItems: 10, now: t0)
        store.add(text("二"), maxItems: 10, now: t0.addingTimeInterval(1))
        store.add(text("一"), maxItems: 10, now: t0.addingTimeInterval(2))
        #expect(store.items.count == 2)
        #expect(store.sortedItems.map(\.text) == ["一", "二"])
    }

    @Test func trimKeepsPinned() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        let t0 = Date(timeIntervalSince1970: 1000)
        store.add(text("固定"), maxItems: 3, now: t0)
        store.togglePin(store.items[0].id)
        for i in 1...5 {
            store.add(text("条目\(i)"), maxItems: 3, now: t0.addingTimeInterval(Double(i)))
        }
        #expect(store.items.count == 4)
        #expect(store.sortedItems.first?.text == "固定")
        #expect(store.sortedItems.dropFirst().map(\.text) == ["条目5", "条目4", "条目3"])
    }

    @Test func searchUsesPinyin() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("剪贴板历史"), maxItems: 10)
        store.add(text("银行卡号 6222"), maxItems: 10)
        #expect(store.search("jtb").map(\.text) == ["剪贴板历史"])
        #expect(store.search("yhk").map(\.text) == ["银行卡号 6222"])
        #expect(store.search("").count == 2)
    }

    @Test func notesAreLocalSearchableAndSurviveDuplicateCopies() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var fromEditor = text("Original 101")
        fromEditor.sourceApp = "com.apple.TextEdit"
        store.add(fromEditor, maxItems: 10)
        let item = try #require(store.items.first)
        store.setNote("  公司地址  ", for: item.id)
        #expect(store.search("gsdz").first?.id == item.id)
        #expect(store.search("Original").first?.note == "公司地址")

        fromEditor.sourceApp = "com.apple.Notes"
        store.add(fromEditor, maxItems: 10)
        store.saveNow()
        let reopened = ClipboardStore(directory: dir)
        #expect(reopened.search("地址", filter: .text, sourceApp: "com.apple.Notes").first?.id == item.id)
        #expect(reopened.search("gsdz", sourceApp: "com.apple.TextEdit").isEmpty)
        #expect(reopened.search("gsdz").first?.text == "Original 101")
        reopened.setNote(" ", for: item.id)
        #expect(reopened.search("gsdz").isEmpty)
        #expect(reopened.search("Original").first?.note == nil)
        reopened.saveNow()
    }

    @Test func resumingRecordingDoesNotBackfillPausedCopies() {
        let dir = tempDirectory()
        let board = NSPasteboard.withUniqueName()
        defer {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: dir)
        }
        let store = ClipboardStore(directory: dir)
        let watcher = ClipboardWatcher(store: store, pasteboard: board, config: ClipboardConfig.init)
        defer { watcher.stop(); store.saveNow() }

        watcher.start()
        board.clearContents()
        board.setString("before pause", forType: .string)
        watcher.recordPendingChange()
        watcher.stop()
        board.clearContents()
        board.setString("during pause", forType: .string)
        watcher.recordPendingChange()
        #expect(store.items.map(\.text) == ["before pause"])

        watcher.start()
        watcher.recordPendingChange()
        #expect(store.items.map(\.text) == ["before pause"])
        board.clearContents()
        board.setString("after resume", forType: .string)
        watcher.recordPendingChange()
        #expect(store.sortedItems.map(\.text) == ["after resume", "before pause"])
    }

    @Test func categoryFiltersComposeWithSearchAndKeepExplicitSelection() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        let link = "https://example.com/guide"
        store.add(text(link), maxItems: 10)
        store.togglePin(store.items[0].id)
        store.add(text("剪贴板使用说明"), maxItems: 10)
        store.add(text("请参阅 \(link)"), maxItems: 10)
        store.add(.init(kind: .image, fingerprint: "screenshot"), maxItems: 10)

        let model = ClipboardPanelModel(store: store)
        model.prepareForShow()
        model.filter = .links
        model.query = "guide"
        #expect(model.results.map(\.text) == [link])
        model.filter = .text
        #expect(model.results.map(\.text) == ["请参阅 \(link)"])
        model.query = "jtb"
        #expect(model.selectedItem?.text == "剪贴板使用说明")
        model.query = ""
        model.select(try #require(model.results.first(where: { $0.text == "剪贴板使用说明" })))
        let selectedID = model.selectedItem?.id
        store.add(text("新复制的条目"), maxItems: 10, now: Date().addingTimeInterval(1))
        model.refresh(keepingSelection: true)
        #expect(model.selectedItem?.id == selectedID)

        model.filter = .pinned
        #expect(model.results.map(\.text) == [link])
        #expect(!model.canClear)
        model.filter = .images
        #expect(model.results.map(\.kind) == [.image])
    }

    @Test func wordDeletionAndKeyRepeatKeepClipboardHistory() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("first note"), maxItems: 10)
        store.add(text("second note"), maxItems: 10)
        let model = ClipboardPanelModel(store: store)
        model.query = "note"
        for modifiers: NSEvent.ModifierFlags in [.option, .control, [.option, .shift], .shift, []] {
            let handled = model.handleDeleteShortcut(KeyCode.forwardDelete, modifiers: modifiers, isRepeat: false)
            #expect(!handled)
        }
        #expect(store.items.count == 2)
        let handled = model.handleDeleteShortcut(KeyCode.backspace, modifiers: .command, isRepeat: false)
        #expect(handled && store.items.count == 1)
        model.refresh()
        let repeatHandled = model.handleDeleteShortcut(KeyCode.backspace, modifiers: .command, isRepeat: true)
        #expect(repeatHandled && store.items.count == 1)
    }

    @Test func persistsToDisk() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = text("带格式")
        capture.extras = ["public.rtf": Data("{\\rtf1 x}".utf8)]
        store.add(capture, maxItems: 10)
        store.togglePin(store.items[0].id)
        store.saveNow()

        let reloaded = ClipboardStore(directory: dir)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].pinned)
        #expect(reloaded.extraData(for: reloaded.items[0])["public.rtf"] == Data("{\\rtf1 x}".utf8))
    }

    @Test func copyingIdenticalTextUsesTheLatestFormatsAfterReload() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = text("Same words")
        capture.extras = ["public.html": Data("<b>Same words</b>".utf8)]
        store.add(capture, maxItems: 10)
        let id = try #require(store.items.first?.id)
        store.togglePin(id)
        store.saveNow()
        capture.extras = ["public.rtf": Data("second format".utf8)]
        store.add(capture, maxItems: 10)
        store.saveNow()
        let reopened = ClipboardStore(directory: dir)
        let item = try #require(reopened.items.first)
        #expect(reopened.items.count == 1 && item.id == id && item.pinned)
        #expect(reopened.extraData(for: item) == capture.extras)
        capture.extras = [:]
        reopened.add(capture, maxItems: 10)
        reopened.saveNow()
        #expect(ClipboardStore(directory: dir).items.first?.extraFiles.isEmpty == true)
    }

    @Test func deleteRemovesFiles() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = ClipboardCapture(kind: .image, png: Data([0x89, 0x50, 0x4E, 0x47]), fingerprint: "img")
        capture.imageSize = CGSize(width: 1, height: 1)
        store.add(capture, maxItems: 10)
        let url = try #require(store.imageURL(for: store.items[0]))
        #expect(FileManager.default.fileExists(atPath: url.path))
        store.delete(store.items[0].id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(store.items.isEmpty)
    }
}

extension ClipboardStoreTests {
    @Test func cleansUpOrphanedFiles() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        var capture = ClipboardCapture(kind: .image, png: Data([1, 2, 3]), fingerprint: "img")
        capture.imageSize = CGSize(width: 1, height: 1)
        store.add(capture, maxItems: 10)
        store.saveNow()
        let blobs = dir.appendingPathComponent("blobs")
        let orphan = blobs.appendingPathComponent("orphan.png")
        try Data([9]).write(to: orphan)

        let reloaded = ClipboardStore(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let image = try #require(reloaded.imageURL(for: reloaded.items[0]))
        #expect(FileManager.default.fileExists(atPath: image.path))
    }

    @Test func unreadableHistoryIsKept() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("history.json"))
        let blobs = dir.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let attachment = blobs.appendingPathComponent("old-image.png")
        try Data([1, 2, 3]).write(to: attachment)
        let store = ClipboardStore(directory: dir)
        #expect(store.items.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("history-unreadable-") })
        _ = ClipboardStore(directory: dir)
        store.saveNow()
        _ = ClipboardStore(directory: dir)
        #expect(FileManager.default.fileExists(atPath: attachment.path))

    }

    /// 面板上的“全部清除”：点两下才清，固定的保留；中间打了字就不算
    @Test func clearAllNeedsTwoClicks() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir)
        store.add(text("固定"), maxItems: 10)
        store.togglePin(store.items[0].id)
        store.add(text("一"), maxItems: 10)
        store.add(text("二"), maxItems: 10)
        let model = ClipboardPanelModel(store: store)
        #expect(model.canClear)

        model.clearTapped()
        #expect(model.confirmingClear && store.items.count == 3)
        model.query = "y"
        #expect(!model.confirmingClear && !model.canClear)
        model.query = ""
        model.clearTapped()
        #expect(store.items.count == 3)

        model.clearTapped()
        #expect(!model.confirmingClear)
        #expect(store.items.map(\.text) == ["固定"])
        #expect(!model.canClear)
    }

    @Test func captureFallsThroughBlankTextAndPartialFileURLsToImage() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        // 最小合法 1×1 PNG
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = try #require(rep.representation(using: .png, properties: [:]))

        // 空白字符串 + 图片：不应因为字符串为空白而丢掉后面的图片
        let blankAndImage = NSPasteboardItem()
        blankAndImage.setString("   \n\t ", forType: .string)
        blankAndImage.setData(png, forType: .png)
        board.clearContents()
        #expect(board.writeObjects([blankAndImage]))
        let first = try #require(ClipboardWatcher.capture(from: board, recordImages: true, sourceApp: "Preview"))
        #expect(first.kind == .image)
        #expect(first.sourceApp == "Preview")

        // 无效/混合文件 URL + 图片：文件列表解析失败时应继续回落到图片
        let brokenURLAndImage = NSPasteboardItem()
        brokenURLAndImage.setString("https://example.com/not-a-file", forType: .fileURL)
        brokenURLAndImage.setData(png, forType: .png)
        board.clearContents()
        #expect(board.writeObjects([brokenURLAndImage]))
        let second = try #require(ClipboardWatcher.capture(from: board, recordImages: true, sourceApp: "Safari"))
        #expect(second.kind == .image)
        #expect(second.sourceApp == "Safari")

        // 超过 2MB 上限的超大文本即便附带图片也不应降级误录成图片
        let oversizedTextAndImage = NSPasteboardItem()
        oversizedTextAndImage.setString(String(repeating: "A", count: ClipboardWatcher.maxTextBytes + 64), forType: .string)
        oversizedTextAndImage.setData(png, forType: .png)
        board.clearContents()
        #expect(board.writeObjects([oversizedTextAndImage]))
        #expect(ClipboardWatcher.capture(from: board, recordImages: true, sourceApp: "TextEdit") == nil)
    }

    @MainActor
    @Test func recognizedTextAndSortedCacheAndRemoveFilesCallback() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var removedURLs: [URL] = []
        let store = ClipboardStore(directory: dir, readImageText: { _ in "合同一号" })
        store.onRemoveFiles = { urls in removedURLs.append(contentsOf: urls) }

        var capture = ClipboardCapture(kind: .image, png: Data([0x89, 0x50, 0x4E, 0x47, 1]), fingerprint: "png-fp")
        capture.imageSize = CGSize(width: 20, height: 20)
        store.add(capture, maxItems: 10)
        let item = try #require(store.items.first)
        let recognized = await store.recognizedText(for: item.id, fingerprint: "png-fp")
        #expect(recognized == "合同一号")
        // 通过指纹也能命中同一条目的识别缓存
        let byFingerprint = await store.recognizedText(for: UUID(), fingerprint: "png-fp")
        #expect(byFingerprint == "合同一号")

        store.add(text("普通条目"), maxItems: 10)
        store.togglePin(item.id)
        #expect(store.sortedItems.first?.id == item.id)
        let imageURL = try #require(store.imageURL(for: item))
        store.delete(item.id)
        #expect(store.sortedItems.count == 1)
        #expect(removedURLs.contains(imageURL))
    }
}

@Suite("配置")
struct ConfigTests {
    @Test func missingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config == AppConfig())
    }

    @Test func partialConfig() throws {
        let json = #"{"keyboard":{"layout":"mac","excludedApps":["a.b.c"],"systemShortcuts":false,"finderShortcuts":false,"ctrlAsCommand":true,"textNavigation":true,"chatScreenshot":true},"mouse":{"defaults":{"scrollLines":99}}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.keyboard.layout == .mac)
        #expect(config.keyboard.excludedApps == ["a.b.c"])
        #expect(!config.keyboard.systemShortcuts)
        #expect(!config.keyboard.finderShortcuts)
        #expect(config.mouse.defaults.scrollLines == 20)
        #expect(config.clipboard == ClipboardConfig())
    }

    @Test func windowsEditingDefaultsSurviveMissingOrInvalidSettings() throws {
        for json in [#"{"keyboard":{}}"#, #"{"keyboard":{"ctrlAsCommand":"on","textNavigation":null}}"#] {
            let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
            #expect(config.keyboard.ctrlAsCommand)
            #expect(config.keyboard.textNavigation)
        }
    }

    @Test func explicitEditingPreferencesArePreserved() throws {
        let json = #"{"keyboard":{"ctrlAsCommand":false,"textNavigation":false}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(!config.keyboard.ctrlAsCommand)
        #expect(!config.keyboard.textNavigation)
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func roundTrip() throws {
        var config = AppConfig()
        config.mouse.devices["1:2:鼠标"] = MouseDeviceSettings()
        config.mouse.devices["1:2:鼠标"]?.scrollLines = 5
        config.mouse.devices["1:2:鼠标"]?.pointerSpeed = 2.5
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(AppConfig.self, from: data) == config)
    }

    /// 没调过指针速度时跟系统走；存下来的值超出范围时收回到最近的一头。
    @Test func pointerSpeedDecoding() throws {
        #expect(AppConfig().mouse.defaults.pointerSpeed == nil)
        let json = #"{"mouse":{"defaults":{"pointerSpeed":50},"devices":{"a":{"pointerSpeed":0.01},"b":{"pointerSpeed":"快"}}}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.mouse.defaults.pointerSpeed == 8)
        #expect(config.mouse.devices["a"]?.pointerSpeed == 0.25)
        #expect(config.mouse.devices["b"]?.pointerSpeed == nil)
        #expect(config.mouse.devices["b"]?.linearPointer == true)
    }

    @Test func pointerSpeedSteps() {
        #expect(PointerSpeed.steps == PointerSpeed.steps.sorted())
        #expect(PointerSpeed.steps.contains(1) && PointerSpeed.steps.contains(3))
        #expect(PointerSpeed.steps[PointerSpeed.nearestStep(to: 0.875)] == 0.875)
        #expect(PointerSpeed.steps[PointerSpeed.nearestStep(to: 0.6875)] == 0.625 || PointerSpeed.steps[PointerSpeed.nearestStep(to: 0.6875)] == 0.75)
        #expect(PointerSpeed.steps[PointerSpeed.nearestStep(to: 100)] == 8)
        #expect(PointerSpeed.describe(1) == "1 倍")
        #expect(PointerSpeed.describe(1.5) == "1.5 倍")
        #expect(PointerSpeed.describe(0.875) == "0.875 倍")
        #expect(PointerSpeed.describe(2.25) == "2.25 倍")
    }

    @Test func symbolicHotKeyParsing() {
        let entry: [String: Any] = ["enabled": true, "value": ["parameters": [65535, 103, 8_388_608], "type": "standard"]]
        #expect(SymbolicHotKeys.parse(entry) == KeyStroke(103, []))
        let spotlight: [String: Any] = ["enabled": 1, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]]
        #expect(SymbolicHotKeys.parse(spotlight) == KeyStroke(KeyCode.space, .maskCommand))
        let disabled: [String: Any] = ["enabled": false, "value": ["parameters": [32, 49, 1_048_576]]]
        #expect(SymbolicHotKeys.parse(disabled) == nil)
        // 未分配的 65535 哨兵值、负数键码、超大键码均不能触发整数溢出崩溃
        let sentinel: [String: Any] = ["enabled": true, "value": ["parameters": [65535, 65535, 1_048_576]]]
        #expect(SymbolicHotKeys.parse(sentinel) == nil)
        let negative: [String: Any] = ["enabled": true, "value": ["parameters": [0, -1, 1_048_576]]]
        #expect(SymbolicHotKeys.parse(negative) == nil)
        let overflow: [String: Any] = ["enabled": true, "value": ["parameters": [0, 100_000, -1]]]
        #expect(SymbolicHotKeys.parse(overflow) == nil)
    }

    @Test func cursorScaleClampedOnDecode() throws {
        let high = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mouse":{"cursorScale":99}}"#.utf8))
        #expect(high.mouse.cursorScale == CursorSizeController.range.upperBound)
        let low = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mouse":{"cursorScale":0.1}}"#.utf8))
        #expect(low.mouse.cursorScale == CursorSizeController.range.lowerBound)
        let valid = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"mouse":{"cursorScale":2.5}}"#.utf8))
        #expect(valid.mouse.cursorScale == 2.5)
    }
}
