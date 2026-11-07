// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import MacShun

@Suite("macOS 系统功能搜索")
struct SystemFeatureTests {
    @Test(arguments: [
        ("请问我的蓝牙耳机突然连不上了怎么办？", "蓝牙"), ("怎么把耳机连上？", "蓝牙"),
        ("耳机没声音了", "声音输出"), ("请问电脑连不上网了怎么办", "无线局域网"),
        ("我想调节屏幕亮度", "显示器"), ("帮我把桌面背景换一张", "墙纸"),
        ("怎么让字体变大一点", "显示器"), ("请问我的硬盘空间不够了怎么办", "储存空间"),
        ("我想知道谁在占内存", "活动监视器"), ("任务管理器", "活动监视器"), ("控制面板", "系统设置"),
        ("在哪儿改系统语言", "语言与地区"), ("摄像头用不了", "摄像头权限"), ("请帮我打开录屏权限", "屏幕录制权限"),
        ("lanya", "蓝牙"), ("hdjsq", "活动监视器"), ("Ｗｉ－Ｆｉ", "无线局域网"),
        ("How do I pair headphones?", "蓝牙"), ("How can I free up space?", "储存空间"),
    ])
    func firstHit(_ phrase: (String, String)) {
        #expect(SystemFeature.search(phrase.0, browse: false).first?.title == phrase.1)
    }

    @Test(arguments: ["", "请帮我", "打开", "项目 蓝牙 采购清单", "蓝牙耳机连不上说明书",
                      "wifi.pdf", "/tmp/蓝牙", #"D:\网络\wifi"#, "ext:pdf 蓝牙", "meeting notes"])
    func doesNotDisplaceFiles(_ phrase: String) {
        #expect(SystemFeature.search(phrase, browse: false).isEmpty)
    }

    @Test func browseFindsPartialNamesAndDestinationsAreUnique() {
        let entries = SystemFeature.search("", browse: true)
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(SystemFeature.search("监视", browse: true).contains { $0.title == "活动监视器" })
        #expect(SystemFeature.search("任务管理器", browse: false).first?.destination == .utility("Activity Monitor"))
    }

    @Test @MainActor func systemRowsOpenDirectlyAndNeverRunFileActions() {
        let model = FileSearchModel(index: FileIndex(mainRoots: []), contentIndex: ContentIndex(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var opened: [SystemFeature.Destination] = []
        model.onFeature = { opened.append($0.destination) }
        model.onAction = { _, _ in Issue.record("System entry dispatched a file action") }
        model.isShown = true
        model.query = "连不上网"
        model.query = "耳机连不上"
        model.toggleQuickLook()
        model.openSelected(reveal: true)
        #expect(!model.isPreviewing && opened.isEmpty)
        model.openSelected(reveal: false)
        #expect(opened == [.pane("com.apple.BluetoothSettings")])
        model.searchesContent = true
        model.scope = .all
        #expect(model.selectedRow?.id == .feature(.pane("com.apple.BluetoothSettings")))
        model.scope = .contents
        #expect(model.rows.allSatisfy { $0.file != nil })
        model.scope = .system
        model.query = ""
        #expect(model.rows.count == SystemFeature.catalog.count)
        model.move(1)
        model.openSelected(reveal: false)
        #expect(opened.last == SystemFeature.catalog[1].destination)
        model.isShown = false
        model.openSelected(reveal: false)
        #expect(opened.count == 2)
    }
}
