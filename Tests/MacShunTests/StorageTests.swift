// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacShun

@Suite("C3 剪贴板存储")
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
        let store = ClipboardStore(directory: dir)
        #expect(store.items.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("history-unreadable-") })
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
}

@Suite("配置")
struct ConfigTests {
    @Test func missingKeysUseDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config == AppConfig())
    }

    @Test func partialConfig() throws {
        let json = #"{"keyboard":{"layout":"mac","excludedApps":["a.b.c"]},"mouse":{"defaults":{"scrollLines":99}}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.keyboard.layout == .mac)
        #expect(config.keyboard.excludedApps == ["a.b.c"])
        #expect(config.keyboard.ctrlAsCommand)
        #expect(config.mouse.defaults.scrollLines == 20)
        #expect(config.clipboard == ClipboardConfig())
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
    }
}
