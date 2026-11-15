// SPDX-License-Identifier: MIT

import AppKit

/// 只在系统剪贴板仍保留本次复制的截图时支持 Ctrl+V。
struct CaptureClipboard {
    static let general = CaptureClipboard(pasteboard: .general)

    let pasteboard: NSPasteboard
    private let copiedChangeCount = Locked<Int?>(nil)

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func copy(_ png: Data) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { return false }
        let changeCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        copiedChangeCount.set(changeCount)
        return true
    }

    var containsScreenshot: Bool {
        guard let copiedChangeCount = copiedChangeCount.get() else { return false }
        return pasteboard.changeCount == copiedChangeCount
    }
}
