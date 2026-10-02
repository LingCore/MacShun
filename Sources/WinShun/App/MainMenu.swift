// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// 主菜单。菜单栏程序不显示主菜单，但输入框里的 ⌘C/⌘V/⌘A/⌘Z 靠主菜单里的“编辑”项才能用
/// （剪贴板面板的搜索框、设置窗口里的输入框）。
/// 故意不放“退出 ⌘Q”，免得 Alt+F4（会换成 ⌘Q）在本程序窗口里把整个 Win顺 退出。
enum MainMenu {
    static func install() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window

        NSApp.mainMenu = main
    }
}
