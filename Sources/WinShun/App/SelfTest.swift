// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices

/// 真机自测：模拟真实的按键、滚轮和鼠标按键，让它们经过本程序的事件拦截，再检查最终效果
/// （测试窗口收到的按键、光标位置、剪贴板内容、Finder 里的文件）。
///
/// 用 scripts/selftest.sh 运行。会弹出测试窗口、打开 Finder 窗口和聚焦搜索，并切换一次程序；
/// 运行期间不要操作键盘鼠标。不测 Win+L（会锁屏）；Win+D 只能看屏幕确认，也不测。
@MainActor
final class SelfTest {
    nonisolated static var isRequested: Bool { CommandLine.arguments.contains("--self-test") || onlyWindow || onlySearch }
    /// 只测分屏：scripts/selftest.sh window
    nonisolated static var onlyWindow: Bool { CommandLine.arguments.contains("--self-test-window") }
    /// 只测文件搜索：scripts/selftest.sh search
    nonisolated static var onlySearch: Bool { CommandLine.arguments.contains("--self-test-search") }

    private enum Mod { case ctrl, alt, win, shift }

    private let config: AppConfig
    private let clipboard: ClipboardController
    private let openSettings: () -> Void
    /// 临时改设置（测鼠标侧键的几种设置），测完改回去
    private let updateConfig: ((inout AppConfig) -> Void) -> Void
    private let windowSnapper: WindowSnapper?
    private let fileSearch: FileSearchController?
    private let mapper: KeyMapper
    private let source = CGEventSource(stateID: .hidSystemState)
    private let ownBundleID = Bundle.main.bundleIdentifier

    private var window: NSWindow!
    private var textView: NSTextView!
    private var monitor: Any?
    private var keyLog: [(code: UInt16, mods: NSEvent.ModifierFlags)] = []
    private var buttonLog: [Int] = []
    private var scrollLog: [(dy: CGFloat, precise: Bool)] = []
    private var passed = 0
    private var failed = 0

    /// - Parameter layout: 事件拦截对当前键盘使用的布局，模拟按键要按同样的布局发出修饰键。
    init(config: AppConfig, layout: KeyboardLayoutKind, clipboard: ClipboardController, windowSnapper: WindowSnapper? = nil,
         fileSearch: FileSearchController? = nil, updateConfig: @escaping ((inout AppConfig) -> Void) -> Void = { _ in },
         openSettings: @escaping () -> Void) {
        var config = config
        config.keyboard.layout = layout
        self.config = config
        self.clipboard = clipboard
        self.windowSnapper = windowSnapper
        self.fileSearch = fileSearch
        self.openSettings = openSettings
        self.updateConfig = updateConfig
        mapper = KeyMapper(config: config.keyboard)
    }

    // MARK: - 流程

    func run() async {
        say("Win顺 自测开始。键盘类型：\(config.keyboard.layout == .windows ? "Windows 键盘" : "Mac 键盘")")
        guard Permissions.accessibility else {
            fail("权限", "没有辅助功能权限")
            return finish()
        }
        if Self.onlyWindow {
            setUpWindow()
            await windowTests()
            if let monitor { NSEvent.removeMonitor(monitor) }
            window.orderOut(nil)
            return finish()
        }
        if Self.onlySearch {
            let savedClipboard = NSPasteboard.general.string(forType: .string)
            await fileSearchTest()
            if let savedClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(savedClipboard, forType: .string)
            }
            try? FileManager.default.removeItem(at: clipboard.store.directory)
            return finish()
        }
        let savedClipboard = NSPasteboard.general.string(forType: .string)
        setUpWindow()
        if await ensureFocus() {
            await textTests()
            await clipboardPanelTest()
            await fileSearchTest()
            _ = await ensureFocus()
            await mouseTests()
            await pointerSpeedTest()
            await altF4Test()
            await winSpaceTest()
            await altTabTest()
            await winETest()
            await finderTests()
            await spotlightTest()
            await settingsWindowTest()
            await windowTests()
        } else {
            fail("测试窗口", "无法把测试窗口切到前台，没有继续，以免按键打到别的程序里")
        }
        say("Win+D（显示桌面）：程序坞接口\(DockNotification.isAvailable ? "可用" : "不可用，会改用系统快捷键")，需要看屏幕确认")
        say("Win+L（锁屏）：锁屏接口\(LoginFramework.isAvailable ? "可用" : "不可用，会改用 ⌃⌘Q")，没有自动测试")

        if let monitor { NSEvent.removeMonitor(monitor) }
        window.orderOut(nil)
        if let savedClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(savedClipboard, forType: .string)
        }
        try? FileManager.default.removeItem(at: clipboard.store.directory)
        finish()
    }

    private func finish() {
        say("自测结束：通过 \(passed) 项，失败 \(failed) 项")
    }

    // MARK: - K1、K2：文字编辑

    private func textTests() async {
        say("— 键盘：文字编辑（K1、K2）")
        let text = "hello world foo\nsecond line here"

        await setText(text, caret: 3)
        await press(KeyCode.a, [.ctrl])
        expectKey("Ctrl+A → ⌘A", KeyCode.a, .command)
        check("Ctrl+A 全选", textView.selectedRange() == NSRange(location: 0, length: (text as NSString).length))

        NSPasteboard.general.clearContents()
        await press(KeyCode.c, [.ctrl])
        expectKey("Ctrl+C → ⌘C", KeyCode.c, .command)
        check("Ctrl+C 复制", NSPasteboard.general.string(forType: .string) == text,
              "剪贴板：\(NSPasteboard.general.string(forType: .string) ?? "空")")

        await setText(text, caret: 7)
        await press(KeyCode.end)
        expectKey("End → ⌘→", KeyCode.rightArrow, .command)
        check("End 到行尾", caret == 15, "光标在 \(caret)")

        await press(KeyCode.home)
        expectKey("Home → ⌘←", KeyCode.leftArrow, .command)
        check("Home 到行首", caret == 0, "光标在 \(caret)")

        await setText(text, caret: 7)
        await press(KeyCode.end, [.shift])
        check("Shift+End 选到行尾", textView.selectedRange() == NSRange(location: 7, length: 8),
              "选区 \(textView.selectedRange())")

        await setText(text, caret: 7)
        await press(KeyCode.end, [.ctrl])
        expectKey("Ctrl+End → ⌘↓", KeyCode.downArrow, .command)
        check("Ctrl+End 到文末", caret == (text as NSString).length, "光标在 \(caret)")
        await press(KeyCode.home, [.ctrl])
        check("Ctrl+Home 到文首", caret == 0, "光标在 \(caret)")

        await setText(text, caret: 0)
        await press(KeyCode.rightArrow, [.ctrl])
        expectKey("Ctrl+→ → ⌥→", KeyCode.rightArrow, .option)
        check("Ctrl+→ 按词移动", caret == 5, "光标在 \(caret)")

        await setText(text, caret: 11)
        await press(KeyCode.backspace, [.ctrl])
        expectKey("Ctrl+Backspace → ⌥⌫", KeyCode.backspace, .option)
        let afterDelete = "hello  foo\nsecond line here"
        check("Ctrl+Backspace 删除一个词", textView.string == afterDelete, "内容：\(textView.string.debugDescription)")

        await press(KeyCode.z, [.ctrl])
        expectKey("Ctrl+Z → ⌘Z", KeyCode.z, .command)
        check("Ctrl+Z 撤销", textView.string == text, "内容：\(textView.string.debugDescription)")

        await press(KeyCode.y, [.ctrl])
        expectKey("Ctrl+Y → ⌘⇧Z", KeyCode.z, [.command, .shift])
        check("Ctrl+Y 重做", textView.string == afterDelete, "内容：\(textView.string.debugDescription)")

        await setText("abc", caret: 3)
        await press(KeyCode.h, [.ctrl])
        expectKey("Ctrl+H 保持原样", KeyCode.h, .control)
    }

    // MARK: - C1、C2：剪贴板历史

    private func clipboardPanelTest() async {
        say("— 剪贴板历史（C1、C2）")
        guard config.clipboard.enabled else { return say("跳过：剪贴板历史已关闭") }
        let store = clipboard.store
        for s in ["剪贴板历史记录", "银行卡号 6222 0000"] {
            store.add(ClipboardCapture(kind: .text, text: s, fingerprint: ClipboardStore.fingerprint([Data(s.utf8)])),
                      maxItems: 50)
        }
        await setText("", caret: 0)
        await press(KeyCode.v, [.win], settle: 600)
        check("Win+V 打开面板", clipboard.isVisible)
        guard clipboard.isVisible else { return }

        for key in [KeyCode.y, KeyCode.h, KeyCode.k] {
            await press(key, settle: 120)
        }
        await pause(300)
        let top = clipboard.visibleResults.first?.text ?? "无"
        check("拼音首字母 yhk 搜到“银行卡号”", top.hasPrefix("银行卡号"),
              "第一条：\(top)；当前输入法：\(FrontAppTracker.shared.inputSourceID.get() ?? "未知")")

        await press(KeyCode.returnKey, settle: 300)
        let pasted = await waitUntil(timeout: 2) { self.textView.string.contains("银行卡号") }
        check("Enter 粘贴到原来的窗口", pasted && !clipboard.isVisible, "测试窗口内容：\(textView.string.debugDescription)")

        // 不管键盘处于哪种模式，⌥V 都是 Win+V（键盘刚切换了模式时也能用）。
        _ = await ensureFocus()
        let option: Mod = mapper.altFlag == .maskAlternate ? .alt : .win
        await press(KeyCode.v, [option], settle: 600)
        check("⌥V 也能打开剪贴板历史", clipboard.isVisible)

        // “全部清除”只点一下（不真的清，免得清掉自己的历史）：等着确认；搜索框还在接收按键，一打字就取消
        let count = store.items.count
        postClick(at: clipboard.clearButtonPoint)
        let confirming = await waitUntil(timeout: 1) { self.clipboard.confirmingClear }
        await press(KeyCode.y, settle: 300)
        check("点一下“全部清除”等着确认，搜索框照样能打字，一打字就取消", confirming && clipboard.query == "y"
                && !clipboard.confirmingClear && store.items.count == count && clipboard.isVisible,
              "等确认：\(confirming)，搜索框里：\(clipboard.query.debugDescription)，还在等确认：\(clipboard.confirmingClear)，"
                + "条数 \(count) → \(store.items.count)，面板开着：\(clipboard.isVisible)")
        await press(KeyCode.escape, settle: 300)
        check("然后 Esc 照样关掉面板", !clipboard.isVisible)
        clipboard.hide()
    }

    // MARK: - F1：文件搜索

    /// 连按两下 Ctrl 打开；开着时再连按、按一下 Ctrl 接着 Ctrl+V 都不会关掉；粘贴“桌面/…”这样的路径能搜到；
    /// Ctrl+Enter 在访达中显示。测试文件放在桌面上（个人文件夹里会收录的位置），测完删掉。
    private func fileSearchTest() async {
        say("— 文件搜索（F1）")
        guard let fileSearch, config.fileSearch.enabled else { return say("跳过：文件搜索已关闭") }
        let fm = FileManager.default
        let rootName = "Win顺自测-\(Int(Date().timeIntervalSince1970))"
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").appendingPathComponent(rootName)
        let file = root.appendingPathComponent("art/gpt/style_reference.png")
        // 右键菜单测试用：一个同名文件夹（左键点它打开），一个要移到废纸篓的文件；还有一个用结果右边的“删除”删
        let folder = root.appendingPathComponent("art/gpt/style_reference")
        let junk = root.appendingPathComponent("art/gpt/style_reference \(rootName).txt")
        let junk2 = root.appendingPathComponent("art/gpt/style_reference \(rootName) 2.txt")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: file)
            try Data().write(to: junk)
            try Data().write(to: junk2)
        } catch {
            return fail("文件搜索测试准备", error.localizedDescription)
        }
        var menus = 0
        /// 弹出菜单时（已经取消了）要做的事
        var onMenu: ((NSMenu) -> Void)?
        var menusClosed = 0
        let menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                  object: nil, queue: nil) { note in
            menus += 1
            guard let menu = note.object as? NSMenu else { return }
            guard let handle = onMenu else { return menu.cancelTrackingWithoutAnimation() }
            // 等菜单真的开始跟踪再关、再选里面的项
            DispatchQueue.main.async {
                handle(menu)
                menu.cancelTrackingWithoutAnimation()
            }
        }
        let menuEndObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                                     object: nil, queue: nil) { _ in menusClosed += 1 }
        defer {
            NotificationCenter.default.removeObserver(menuObserver)
            NotificationCenter.default.removeObserver(menuEndObserver)
            fileSearch.hide()
            closeFinderWindows { $0 == "gpt" || $0 == "style_reference" }
            try? fm.removeItem(at: root)
            for trashed in [junk, junk2] {
                try? fm.removeItem(at: fm.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(trashed.lastPathComponent)"))
            }
        }

        await tapControl()
        await tapControl()
        let shown = await waitUntil(timeout: 2) { fileSearch.isVisible }
        check("连按两下 Ctrl 打开搜索框", shown)
        guard shown else { return }
        await pause(400)
        await tapControl()
        await tapControl()
        await pause(400)
        check("开着时再连按两下 Ctrl 不会关掉", fileSearch.isVisible)

        let query = "桌面/\(rootName)/art/gpt/style_reference.png"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(query, forType: .string)
        // 按一下 Ctrl 马上接着 Ctrl+V：以前会被当成连按两下，把搜索框关掉
        await tapControl()
        await press(KeyCode.v, [.ctrl], settle: 300)
        check("按一下 Ctrl 接着 Ctrl+V 粘贴进去", fileSearch.isVisible && fileSearch.currentQuery == query,
              "显示：\(fileSearch.isVisible)，搜索框里：\(fileSearch.currentQuery.debugDescription)")
        let found = await waitUntil(timeout: 8) { fileSearch.visibleResults.first?.path == file.path }
        check("按“桌面/…”路径搜到文件", found,
              "第一条：\(fileSearch.visibleResults.first?.path ?? "无")，共 \(fileSearch.visibleResults.count) 条")
        guard found else { return }

        let downloads = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        let shownName = fm.displayName(atPath: downloads)
        let byShownName = await withCheckedContinuation { done in
            FileIndex.shared.search(shownName) { done.resume(returning: $0) }
        }
        check("按访达里显示的名字（\(shownName)）搜到个人文件夹里的“下载”", byShownName.first?.path == downloads,
              "第一条：\(byShownName.first?.path ?? "无")")

        // 在搜索框里按 Win+V：剪贴板面板叠在上面，搜索框不关；Esc 回到搜索框；选一条填进搜索框
        if config.clipboard.enabled {
            clipboard.store.add(ClipboardCapture(kind: .text, text: query, fingerprint: ClipboardStore.fingerprint([Data(query.utf8)])),
                                maxItems: 50)
            await press(KeyCode.v, [.win], settle: 500)
            check("在搜索框里按 Win+V：剪贴板面板打开，搜索框还在", clipboard.isVisible && fileSearch.isVisible,
                  "剪贴板面板：\(clipboard.isVisible)，搜索框：\(fileSearch.isVisible)")
            await press(KeyCode.escape, settle: 300)
            check("Esc 关掉剪贴板面板，回到搜索框", !clipboard.isVisible && fileSearch.isVisible && fileSearch.isKey,
                  "剪贴板面板：\(clipboard.isVisible)，搜索框：\(fileSearch.isVisible)，在接收按键：\(fileSearch.isKey)")
            await press(KeyCode.a, [.ctrl], settle: 100)
            await press(KeyCode.backspace, settle: 300)
            await press(KeyCode.v, [.win], settle: 500)
            await press(KeyCode.returnKey, settle: 300)
            let filled = await waitUntil(timeout: 4) { fileSearch.visibleResults.first?.path == file.path }
            check("从剪贴板历史选的路径填进搜索框并搜到", filled && !clipboard.isVisible && fileSearch.isKey,
                  "搜索框里：\(fileSearch.currentQuery.debugDescription)，第一条：\(fileSearch.visibleResults.first?.path ?? "无")")

            // 剪贴板面板叠在上面时连按两下 Ctrl：剪贴板面板关掉，回到搜索框
            await press(KeyCode.v, [.win], settle: 500)
            await tapControl()
            await tapControl()
            let back = await waitUntil(timeout: 2) { !self.clipboard.isVisible && fileSearch.isVisible && fileSearch.isKey }
            check("剪贴板面板开着时连按两下 Ctrl：回到搜索框", back,
                  "剪贴板面板：\(clipboard.isVisible)，搜索框：\(fileSearch.isVisible)，在接收按键：\(fileSearch.isKey)")
        }

        // Alt+Enter（Windows 上是“属性”）不往搜索框里插换行
        let before = fileSearch.currentQuery
        await press(KeyCode.returnKey, [.alt], settle: 300)
        check("Alt+Enter 不往搜索框里插换行", fileSearch.currentQuery == before && fileSearch.isVisible,
              "搜索框里：\(fileSearch.currentQuery.debugDescription)")

        menus = 0
        await press(KeyCode.returnKey, [.ctrl], settle: 300)
        let revealed = await waitUntil(timeout: 4) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppCatalog.finder && self.finderTitle() == "gpt"
        }
        check("Ctrl+Enter 在访达中显示", revealed && !fileSearch.isVisible && menus == 0,
              "访达窗口：\(finderTitle() ?? "无")，搜索框还开着：\(fileSearch.isVisible)，弹出菜单 \(menus) 次")

        // 右键菜单
        let menuQuery = "桌面/\(rootName)/art/gpt/style_reference"
        func search(_ expected: [URL]) async -> Bool {
            await tapControl()
            await tapControl()
            guard await waitUntil(timeout: 2, { fileSearch.isVisible }) else { return false }
            await pause(300)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(menuQuery, forType: .string)
            await press(KeyCode.a, [.ctrl], settle: 100)
            await press(KeyCode.v, [.ctrl], settle: 300)
            return await waitUntil(timeout: 6) {
                Set(fileSearch.visibleResults.map(\.path)).isSuperset(of: expected.map(\.path))
            }
        }
        func row(_ url: URL) -> Int { fileSearch.visibleResults.firstIndex { $0.path == url.path } ?? -1 }
        /// 在这一条上点右键，选菜单里的某一项
        func rightClick(_ url: URL, choose title: String) async -> (titles: [String], selected: Int, visible: Bool, onTop: Bool) {
            var seen: (titles: [String], selected: Int, visible: Bool, onTop: Bool) = ([], -1, false, false)
            let closedBefore = menusClosed
            onMenu = { menu in
                seen = (menu.items.filter { !$0.isSeparatorItem }.map(\.title), fileSearch.selectedIndex, fileSearch.isVisible,
                        self.menuAbove(fileSearch.windowNumber))
                if let index = menu.items.firstIndex(where: { $0.title == title }) {
                    DispatchQueue.main.async { menu.performActionForItem(at: index) }
                }
            }
            defer { onMenu = nil }
            postRightClick(at: fileSearch.rowCenter(row(url)))
            // 菜单关掉了才算完，不然下一次点击会被还开着的菜单接走
            if !(await waitUntil(timeout: 2) { menusClosed > closedBefore }) { seen.titles.append("（菜单没关掉）") }
            await pause(200)
            return seen
        }
        guard await search([folder, file, junk]) else {
            return fail("右键菜单测试准备", "没搜到：\(fileSearch.visibleResults.map(\.name))")
        }
        let junkRow = row(junk), selectedBefore = fileSearch.selectedIndex
        let expected = [L("打开"), L("打开方式"), L("在访达中显示"), L("复制"), L("复制路径"), L("移到废纸篓")]
        let trashMenu = await rightClick(junk, choose: L("移到废纸篓"))
        check("在没选中的一条上点右键：弹出菜单，在搜索框上面，先选中这一条，搜索框不关",
              trashMenu.titles == expected && trashMenu.onTop && junkRow != selectedBefore && trashMenu.selected == junkRow && trashMenu.visible,
              "菜单：\(trashMenu.titles)，在上面：\(trashMenu.onTop)，选中第 \(selectedBefore) → \(trashMenu.selected) 条（点的第 \(junkRow) 条），"
                + "搜索框开着：\(trashMenu.visible)")
        let trashed = await waitUntil(timeout: 4) { !fm.fileExists(atPath: junk.path) && row(junk) < 0 }
        check("右键“移到废纸篓”：文件进了废纸篓，从结果里拿掉，搜索框不关", trashed && fileSearch.isVisible,
              "文件还在：\(fm.fileExists(atPath: junk.path))，结果里还有：\(row(junk) >= 0)，搜索框开着：\(fileSearch.isVisible)")

        NSPasteboard.general.clearContents()
        let fileRow = row(file)
        let copyMenu = await rightClick(file, choose: L("复制路径"))
        let copied = await waitUntil(timeout: 2) { NSPasteboard.general.string(forType: .string) == file.path }
        check("右键“复制路径”：完整路径放进剪贴板，搜索框关掉", copied && !fileSearch.isVisible,
              "剪贴板：\(NSPasteboard.general.string(forType: .string)?.debugDescription ?? "空")，搜索框开着：\(fileSearch.isVisible)，"
                + "点的第 \(fileRow) 条，菜单：\(copyMenu.titles)，结果：\(fileSearch.visibleResults.map(\.path))")

        // 结果右边的按钮：鼠标移上去才显示；删除点两下才删，双击不算；复制、定位做完关掉搜索框
        func hoverButton(_ button: FileRowButton, on url: URL) async -> CGPoint? {
            let index = row(url)
            guard index >= 0 else { return nil }
            postMouse(.mouseMoved, at: fileSearch.rowCenter(index))
            guard await waitUntil(timeout: 2, { fileSearch.buttonCenter(button, for: url.path) != nil }) else { return nil }
            return fileSearch.buttonCenter(button, for: url.path)
        }
        if await search([folder, file, junk2]), let delete = await hoverButton(.delete, on: junk2) {
            postClick(at: delete, clickState: 1)
            postClick(at: delete, clickState: 2)
            await pause(400)
            check("双击结果右边的“删除”：只变成“确定删除”，文件还在，搜索框不关",
                  fileSearch.confirmingDelete == junk2.path && fm.fileExists(atPath: junk2.path) && fileSearch.isVisible,
                  "等确认的：\(fileSearch.confirmingDelete ?? "无")，文件还在：\(fm.fileExists(atPath: junk2.path))，"
                    + "搜索框开着：\(fileSearch.isVisible)")
            // 过了双击时间再点才算确认
            await pause(UInt64(min(NSEvent.doubleClickInterval, 2) * 1000) + 150)
            postClick(at: fileSearch.buttonCenter(.delete, for: junk2.path) ?? delete, clickState: 1)
            let deleted = await waitUntil(timeout: 4) { !fm.fileExists(atPath: junk2.path) && row(junk2) < 0 }
            check("再点一下“确定删除”：移到废纸篓，从结果里拿掉，搜索框不关", deleted && fileSearch.isVisible,
                  "文件还在：\(fm.fileExists(atPath: junk2.path))，结果里还有：\(row(junk2) >= 0)，搜索框开着：\(fileSearch.isVisible)")

            NSPasteboard.general.clearContents()
            if let copy = await hoverButton(.copy, on: file) {
                // 鼠标在这一条的文字上（按钮显示着），再移到“复制”上：按钮底色变深
                let before = fileSearch.buttonFill(.copy, for: file.path)
                postMouse(.mouseMoved, at: copy)
                await pause(300)
                let after = fileSearch.buttonFill(.copy, for: file.path)
                func level(_ c: NSColor?) -> CGFloat { c.map { $0.redComponent + $0.greenComponent + $0.blueComponent } ?? -1 }
                check("鼠标停在结果右边的按钮上：底色变了", before != nil && after != nil && abs(level(after) - level(before)) > 0.04,
                      "停上去之前：\(before.map(String.init(describing:)) ?? "无")，之后：\(after.map(String.init(describing:)) ?? "无")")
                postClick(at: copy)
                let copied = await waitUntil(timeout: 2) {
                    (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.path == file.path
                }
                check("点结果右边的“复制”：文件放进剪贴板，搜索框关掉", copied && !fileSearch.isVisible,
                      "剪贴板：\(NSPasteboard.general.types?.map(\.rawValue) ?? [])，搜索框开着：\(fileSearch.isVisible)")
            } else {
                fail("点结果右边的“复制”", "按钮没显示，结果：\(fileSearch.visibleResults.map(\.name))")
            }
        } else {
            fail("双击结果右边的“删除”", "没搜到或按钮没显示：\(fileSearch.visibleResults.map(\.name))")
        }
        closeFinderWindows { $0 == "gpt" }
        if await search([file]), let reveal = await hoverButton(.reveal, on: file) {
            postClick(at: reveal)
            let revealed = await waitUntil(timeout: 4) {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppCatalog.finder && self.finderTitle() == "gpt"
            }
            check("点结果右边的“定位”：在访达中显示，搜索框关掉", revealed && !fileSearch.isVisible,
                  "访达窗口：\(finderTitle() ?? "无")，搜索框还开着：\(fileSearch.isVisible)")
        } else {
            fail("点结果右边的“定位”", "没搜到或按钮没显示：\(fileSearch.visibleResults.map(\.name))")
        }

        // 盖在结果上接右键的那层不能挡住左键
        if await search([folder, file]) {
            postClick(at: fileSearch.rowCenter(row(folder)))
            let opened = await waitUntil(timeout: 4) { self.finderTitle() == "style_reference" && !fileSearch.isVisible }
            check("左键点一条照常打开", opened, "访达窗口：\(finderTitle() ?? "无")，搜索框还开着：\(fileSearch.isVisible)")
        } else {
            fail("左键点一条照常打开", "没搜到：\(fileSearch.visibleResults.map(\.name))")
        }
    }

    /// 单独按一下 Ctrl
    private func tapControl() async {
        postModifier(KeyCode.control, .maskControl)
        await pause(40)
        postModifier(KeyCode.control, [])
        await pause(90)
    }

    // MARK: - M3、M4、M5：鼠标

    private func mouseTests() async {
        say("— 鼠标（M3、M4、M5）")
        guard config.mouse.enabled else { return say("跳过：鼠标功能已关闭") }
        _ = await ensureFocus()
        let point = windowCenter()
        CGWarpMouseCursorPosition(point)
        await pause(200)

        let settings = config.mouse.defaults
        if settings.linearScroll && config.mouse.devices.isEmpty {
            for (wheel, label) in [(Int32(-1), "慢转一格"), (Int32(-6), "快转")] {
                scrollLog.removeAll()
                postScroll(wheel, at: point)
                await pause(250)
                let dy = scrollLog.last?.dy
                check("按行滚动（\(label)）每次 \(settings.scrollLines) 行", dy.map { abs($0) == CGFloat(settings.scrollLines) } ?? false,
                      "收到 \(dy.map { "\($0)" } ?? "无滚动事件")")
            }
        } else {
            say("跳过按行滚动：设置里关掉了，或者有按鼠标单独的设置")
        }

        if config.mouse.ctrlWheelZoom {
            keyLog.removeAll()
            scrollLog.removeAll()
            postModifier(KeyCode.control, .maskControl)
            await pause(30)
            postScroll(1, at: point, flags: .maskControl)
            await pause(30)
            postModifier(KeyCode.control, [])
            await pause(250)
            expectKey("Ctrl+滚轮往上 → ⌘=（放大）", KeyCode.equal, .command)
            check("Ctrl+滚轮不再滚动", scrollLog.isEmpty)
        }

        if config.mouse.backButton.action == .back && config.mouse.forwardButton.action == .forward {
            for (button, key, label) in [(Int64(3), KeyCode.leftBracket, "后退键 → ⌘["), (Int64(4), KeyCode.rightBracket, "前进键 → ⌘]")] {
                keyLog.removeAll()
                postOtherMouse(button, at: point)
                await pause(250)
                expectKey("侧键：\(label)", key, .command)
            }
        }
        await sideButtonSettingsTest(at: point)
    }

    /// 侧键改成自定义快捷键、不处理：临时改设置，测完改回去
    private func sideButtonSettingsTest(at point: CGPoint) async {
        let saved = (config.mouse.backButton, config.mouse.forwardButton)
        updateConfig {
            $0.mouse.forwardButton = SideButtonSetting(.shortcut, shortcut: WinShortcut(keyCode: KeyCode.a, modifiers: .ctrl))
            $0.mouse.backButton = SideButtonSetting(.none)
        }
        defer { updateConfig { $0.mouse.backButton = saved.0; $0.mouse.forwardButton = saved.1 } }
        await pause(200)

        // 按 Ctrl+A 的效果要和键盘上按的一样：经过键盘规则变成 ⌘A，全选
        let text = "hello side button"
        await setText(text, caret: 3)
        postOtherMouse(4, at: point)
        let selected = await waitUntil(timeout: 1) {
            self.textView.selectedRange() == NSRange(location: 0, length: (text as NSString).length)
        }
        if config.keyboard.enabled && config.keyboard.ctrlAsCommand {
            check("侧键设成 Ctrl+A：和按 Ctrl+A 一样全选", selected, "选区 \(textView.selectedRange())")
        }

        keyLog.removeAll()
        buttonLog.removeAll()
        postOtherMouse(3, at: point)
        await pause(250)
        check("侧键设成不处理：原样交给程序", keyLog.isEmpty && buttonLog == [3],
              "收到按键 \(keyLog.count) 个，侧键 \(buttonLog)")
    }

    // MARK: - M1：指针速度

    /// 把所有鼠标临时调到 3.5 倍（比系统设置最快的 3 倍还快），读回来确认系统收下了，再恢复。
    /// 指针移动本身没法自动测：模拟的鼠标移动不经过系统的指针加速。
    private func pointerSpeedTest() async {
        guard config.mouse.enabled else { return }
        let pointer = PointerAccelerationController()
        let before = pointer.currentSpeeds()
        guard !before.isEmpty else { return say("跳过指针速度：没有检测到鼠标") }
        var faster = config.mouse
        faster.devices = [:]
        faster.defaults.linearPointer = true
        faster.defaults.pointerSpeed = 3.5
        pointer.apply(faster)
        await pause(100)
        let applied = pointer.currentSpeeds()
        pointer.apply(config.mouse)
        await pause(100)
        let after = pointer.currentSpeeds()
        check("指针速度能调到 3.5 倍（系统最快 3 倍）", applied.values.allSatisfy { $0 == 3.5 }, "读到 \(applied)")
        check("指针速度恢复原样", after == before, "原来 \(before)，现在 \(after)")
    }

    // MARK: - 设置窗口

    /// 正在用别的程序（刚在 Finder 窗口里点过）时打开设置，窗口要到最前面，不能被挡住。
    /// macOS 14 起的协作式激活下，程序自己请求激活会被拒绝。
    private func settingsWindowTest() async {
        say("— 设置窗口")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WinShun自测-设置-\(Int(Date().timeIntervalSince1970))")
        let file = root.appendingPathComponent("测试文件.txt")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data("Win顺".utf8).write(to: file)
        defer {
            closeFinderWindows { $0 == root.lastPathComponent }
            try? fm.removeItem(at: root)
        }
        guard await revealInFinder(file),
              let finderWindow = finderWindows().first(where: { FocusInspector.string($0, kAXTitleAttribute) == root.lastPathComponent }),
              let frame = frame(of: finderWindow) else {
            return say("跳过：没能打开 Finder 窗口")
        }
        // 像用户一样在 Finder 窗口里点一下（点在文件列表的空白处）。
        postClick(at: CGPoint(x: frame.midX, y: frame.maxY - 40))
        await pause(800)

        openSettings()
        let settingsWindow = { NSApp.keyWindow.flatMap { $0 !== self.window && $0.isVisible ? $0 : nil } }
        let ok = await waitUntil(timeout: 2) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == self.ownBundleID && settingsWindow() != nil
        }
        check("正在用别的程序时，设置窗口到最前面", ok,
              "前台：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")，本程序\(NSApp.isActive ? "已" : "未")激活")
        settingsWindow()?.close()
    }

    // MARK: - K3：系统快捷键

    private func altF4Test() async {
        guard config.keyboard.systemShortcuts else { return }
        say("— 系统快捷键（K3）")
        _ = await ensureFocus()
        // 本程序的主菜单里故意没有“退出”，所以 ⌘Q 在这里不会退出。
        await press(KeyCode.f4, [.alt])
        expectKey("Alt+F4 → ⌘Q", KeyCode.q, .command)
        // 键盘切换了模式时 Alt 发出的是另一个修饰键，也要能退出。
        await press(KeyCode.f4, [.win])
        expectKey("另一种模式下的 Alt+F4 → ⌘Q", KeyCode.q, .command)
    }

    private func winSpaceTest() async {
        guard config.keyboard.systemShortcuts, await ensureFocus() else { return }
        let before = FrontAppTracker.shared.inputSourceID.get()
        await press(KeyCode.space, [.win], settle: 900)
        let after = FrontAppTracker.shared.inputSourceID.get()
        if before != after {
            pass("Win+Space 切换输入法（\(before ?? "?") → \(after ?? "?")）")
            await press(KeyCode.space, [.win], settle: 900)  // 切回来
        } else {
            say("Win+Space：输入法没有变化（只有一个输入法时正常），需要人工确认")
        }
    }

    private func altTabTest() async {
        guard config.keyboard.systemShortcuts, await ensureFocus() else { return }
        let alt = physical(.alt)
        postModifier(alt.key, alt.flag)
        await pause(60)
        postKey(KeyCode.tab, down: true, flags: alt.flag)
        await pause(30)
        postKey(KeyCode.tab, down: false, flags: alt.flag)
        await pause(500)
        postModifier(alt.key, [])
        let switched = await waitUntil(timeout: 2) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier != self.ownBundleID
        }
        check("Alt+Tab 切换到上一个程序", switched,
              "前台程序：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        let held = CGEventSource.flagsState(.combinedSessionState).intersection(.modifierKeys)
        check("松开 Alt 后 ⌘ 也松开了", !held.contains(.maskCommand), "仍按着：\(held.rawValue)")
        _ = await ensureFocus()
    }

    private func winETest() async {
        guard config.keyboard.systemShortcuts, await ensureFocus() else { return }
        let before = Set(finderWindowTitles())
        await press(KeyCode.e, [.win], settle: 300)
        let opened = await waitUntil(timeout: 3) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppCatalog.finder
        }
        check("Win+E 打开 Finder", opened)
        await pause(500)
        closeFinderWindows { !before.contains($0) }
        _ = await ensureFocus()
    }

    private func spotlightTest() async {
        guard config.keyboard.systemShortcuts, await ensureFocus() else { return }
        await press(KeyCode.s, [.win], settle: 300)
        let shown = await waitUntil(timeout: 2) { self.spotlightVisible() }
        if shown {
            pass("Win+S 打开聚焦搜索")
        } else {
            say("Win+S：没检测到聚焦搜索窗口，需要人工确认")
        }
        await press(KeyCode.escape, settle: 400)
        _ = await ensureFocus()
    }

    // MARK: - K4：Finder

    private func finderTests() async {
        guard config.keyboard.finderShortcuts else { return }
        say("— Finder（K4）")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("WinShun自测-\(Int(Date().timeIntervalSince1970))")
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        let file = a.appendingPathComponent("测试文件.txt")
        do {
            try fm.createDirectory(at: a, withIntermediateDirectories: true)
            try fm.createDirectory(at: b, withIntermediateDirectories: true)
            try Data("Win顺".utf8).write(to: file)
        } catch {
            return fail("Finder 测试准备", error.localizedDescription)
        }
        let ourTitles: Set<String> = [root.lastPathComponent, "A", "B"]
        defer {
            closeFinderWindows { ourTitles.contains($0) }
            try? fm.removeItem(at: root)
        }

        guard await revealInFinder(file) else {
            return fail("Finder 焦点", "选中文件后，焦点不在文件列表上（\(FocusInspector().focusKind())）")
        }

        await press(KeyCode.f2, settle: 600)
        check("F2 进入重命名", FocusInspector().focusKind() == .text, "焦点：\(FocusInspector().focusKind())")
        await press(KeyCode.escape, settle: 500)

        await press(KeyCode.x, [.ctrl], settle: 700)
        await press(KeyCode.backspace, settle: 900)
        check("Backspace 返回上一级", finderTitle() == root.lastPathComponent, "窗口标题：\(finderTitle() ?? "?")")

        guard await revealInFinder(b) else { return fail("Finder 焦点", "选中文件夹 B 后焦点不在文件列表上") }
        await press(KeyCode.returnKey, settle: 900)
        check("Enter 打开文件夹", finderTitle() == "B", "窗口标题：\(finderTitle() ?? "?")")

        await press(KeyCode.v, [.ctrl], settle: 300)
        let moved = await waitUntil(timeout: 3) {
            fm.fileExists(atPath: b.appendingPathComponent("测试文件.txt").path) && !fm.fileExists(atPath: file.path)
        }
        check("Ctrl+X、Ctrl+V 移动文件", moved,
              "A 里还有：\(fm.fileExists(atPath: file.path))，B 里有：\(fm.fileExists(atPath: b.appendingPathComponent("测试文件.txt").path))")
    }

    // MARK: - 分屏

    /// W1、W3：用一个 Finder 窗口按真实的 Win+方向键，检查窗口最后的位置。
    private func windowTests() async {
        guard config.window.enabled else { return say("分屏没打开，跳过") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Win顺分屏自测-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            closeFinderWindows { $0 == folder.lastPathComponent }
            try? FileManager.default.removeItem(at: folder)
        }
        NSWorkspace.shared.open(folder)
        let opened = await waitUntil(timeout: 5) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppCatalog.finder
                && WindowElement.focused()?.title == folder.lastPathComponent
        }
        guard opened, let finder = WindowElement.focused() else {
            return fail("分屏", "没能把 Finder 窗口切到前台")
        }
        let screens = ScreenGeometry.screens()
        guard let index = finder.frame.flatMap({ ScreenGeometry.index(of: $0, in: screens) }) else {
            return fail("分屏", "读不到 Finder 窗口的位置")
        }
        let area = screens[index].area
        // 先摆成一个普通大小的窗口
        let start = CGRect(x: area.midX - 450, y: area.midY - 300, width: 900, height: 600).integral
        finder.setFrame(start)
        await pause(300)
        let begin = finder.frame ?? start

        func near(_ a: CGRect?, _ b: CGRect, _ tolerance: CGFloat = 3) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
                && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
        }
        func describe(_ rect: CGRect?) -> String {
            rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?"
        }

        await press(KeyCode.leftArrow, [.win], settle: 500)
        check("Win+← 分到左半边", near(finder.frame, WindowLayout.Position.leftHalf.frame(in: area)), describe(finder.frame))
        if config.window.snapAssist {
            if windowSnapper?.isAssistVisible == true {
                pass("分屏后在另一半弹出贴靠助手")
                await press(KeyCode.escape, settle: 300)
                check("Esc 关掉贴靠助手", windowSnapper?.isAssistVisible == false)
            } else {
                say("贴靠助手：屏幕上没有别的窗口，没有弹出")
            }
        }
        await press(KeyCode.upArrow, [.win], settle: 400)
        check("Win+↑ 左半边变成左上四分之一", near(finder.frame, WindowLayout.Position.topLeft.frame(in: area)), describe(finder.frame))
        await press(KeyCode.downArrow, [.win], settle: 400)
        check("Win+↓ 回到左半边", near(finder.frame, WindowLayout.Position.leftHalf.frame(in: area)), describe(finder.frame))
        await press(KeyCode.rightArrow, [.win], settle: 400)
        check("Win+→ 恢复原来的大小和位置", near(finder.frame, begin), describe(finder.frame))
        await press(KeyCode.upArrow, [.win], settle: 400)
        check("Win+↑ 最大化", near(finder.frame, area), describe(finder.frame))
        await press(KeyCode.downArrow, [.win], settle: 400)
        check("Win+↓ 从最大化恢复", near(finder.frame, begin), describe(finder.frame))
        if screens.count > 1 {
            await press(KeyCode.rightArrow, [.win, .shift], settle: 500)
            let other = (index + 1) % screens.count
            let moved = finder.frame.flatMap { ScreenGeometry.index(of: $0, in: screens) }
            check("Win+Shift+→ 移到另一块屏幕", moved == other, "在第 \(moved.map { $0 + 1 } ?? 0) 块屏幕")
            await press(KeyCode.leftArrow, [.win, .shift], settle: 500)
            let back = finder.frame.flatMap { ScreenGeometry.index(of: $0, in: screens) }
            check("Win+Shift+← 移回来", back == index, "在第 \(back.map { $0 + 1 } ?? 0) 块屏幕")
        }
        await press(KeyCode.upArrow, [.win, .shift], settle: 400)
        let stretched = finder.frame
        check("Win+Shift+↑ 拉到和屏幕一样高",
              stretched.map { abs($0.minY - area.minY) <= 3 && abs($0.height - area.height) <= 3 } ?? false, describe(stretched))
        await dragTests(finder, screens: screens)
        if NativeTiling.dragTilingEnabled {
            say("系统自带的拖动分屏开着，平时拖窗口用的是系统的（设置里可以一键关掉）；上面的拖动测试临时用了 Win顺 的")
        }
    }

    /// W2：用模拟的鼠标拖 Finder 窗口经过两块屏幕相接的边。
    /// 每一下都从光标现在的位置往前移一点，和真鼠标一样，这样光标被挡住时下一下也从挡住的地方算。
    private func dragTests(_ finder: WindowElement, screens: [ScreenGeometry.Screen]) async {
        guard let snapper = windowSnapper, config.window.dragToSnap else { return say("拖动分屏没打开，跳过拖动测试") }
        // 找左右相邻、有一段挨着的两块屏幕
        var pair: (left: ScreenGeometry.Screen, right: ScreenGeometry.Screen, shared: ClosedRange<CGFloat>)?
        for a in screens {
            for b in screens where abs(a.frame.maxX - b.frame.minX) < 1 {
                let top = max(a.frame.minY, b.frame.minY), bottom = min(a.frame.maxY, b.frame.maxY)
                if bottom - top > 300 { pair = (a, b, top ... bottom) }
            }
        }
        guard let (left, right, shared) = pair else { return say("没有左右相邻的两块屏幕，跳过拖动测试") }
        snapper.ignoresNativeTiling = true
        defer {
            snapper.ignoresNativeTiling = false
            postMouse(.leftMouseUp, at: cursorLocation)
        }
        func near(_ a: CGRect?, _ b: CGRect) -> Bool {
            guard let a else { return false }
            return abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
        }
        func describe(_ rect: CGRect?) -> String {
            rect.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?"
        }
        /// 抓住标题栏（窗口顶上中间、工具栏按钮上面一点）
        func grab() async -> Bool {
            guard let frame = finder.frame else { return false }
            let point = CGPoint(x: frame.midX, y: frame.minY + 6)
            CGWarpMouseCursorPosition(point)
            await pause(150)
            postMouse(.leftMouseDown, at: point)
            await pause(150)
            return true
        }
        func release() async {
            postMouse(.leftMouseUp, at: cursorLocation)
            await pause(600)
            if snapper.isAssistVisible { await press(KeyCode.escape, settle: 300) }
        }
        let y = (shared.lowerBound + shared.upperBound) / 2
        let edgeX = left.frame.maxX - 1
        let pushes = 6   // 每下 8 点，一共 48 点，没到挡不住的距离

        // 1. 拖到交界处停住，松开分到左边屏幕的右半边
        let start = WindowLayout.clamped(CGRect(x: edgeX - 900, y: y - 10, width: 700, height: 450), to: left.area)
        finder.setFrame(start)
        await pause(300)
        let before = finder.frame
        guard await grab() else { return fail("拖动分屏", "读不到 Finder 窗口的位置") }
        await drag(toward: CGPoint(x: edgeX - 60, y: y), step: 8)
        guard let moved = finder.frame, let before, moved.minX > before.minX + 20 else {
            await release()
            return fail("拖动分屏", "模拟的拖动没有拖动窗口：\(describe(before)) → \(describe(finder.frame))")
        }
        await drag(toward: CGPoint(x: edgeX + 400, y: y), step: 8, maxSteps: 60 / 8 + pushes)
        let held = cursorLocation
        check("拖到两块屏幕交界处，光标停在边上", abs(held.x - edgeX) <= 1, "光标在 \(Int(held.x)),\(Int(held.y))，边在 x=\(Int(edgeX))")
        let leftRight = WindowLayout.Position.rightHalf.frame(in: left.area)
        check("停住时预览左边屏幕的右半边", near(snapper.previewFrame, leftRight), "预览 \(describe(snapper.previewFrame))")
        await release()
        check("松开分到左边屏幕的右半边", near(finder.frame, leftRight), describe(finder.frame))

        // 2. 再拖：先恢复原来的大小，往外多推一段就过去，松开时不分屏
        guard await grab() else { return }
        await drag(toward: CGPoint(x: edgeX - 100, y: y), step: 10)
        let unsnapped = finder.frame
        check("拖动分好的窗口，恢复原来的大小",
              unsnapped.map { abs($0.width - start.width) <= 3 && abs($0.height - start.height) <= 3 } ?? false, describe(unsnapped))
        await drag(toward: CGPoint(x: right.frame.minX + 250, y: y), step: 12)
        let crossed = cursorLocation
        check("继续往外推，光标过到另一块屏幕", right.frame.contains(crossed), "光标在 \(Int(crossed.x)),\(Int(crossed.y))")
        check("推过去以后不预览", snapper.previewFrame == nil, "预览 \(describe(snapper.previewFrame))")
        await release()
        let inRight = finder.frame.map { right.frame.intersects($0) && WindowLayout.position(of: $0, in: right.area) == nil } ?? false
        check("松开时窗口在另一块屏幕上、没有分屏", inRight, describe(finder.frame))

        // 3. 往回拖到交界处，停在右边屏幕的左边上，松开分到右边屏幕的左半边
        guard await grab() else { return }
        await drag(toward: CGPoint(x: right.frame.minX + 60, y: y), step: 8)
        await drag(toward: CGPoint(x: right.frame.minX - 400, y: y), step: 8, maxSteps: 60 / 8 + pushes)
        let heldBack = cursorLocation
        check("往回拖，光标停在另一边的边上", abs(heldBack.x - right.frame.minX) <= 1, "光标在 \(Int(heldBack.x)),\(Int(heldBack.y))")
        let rightLeft = WindowLayout.Position.leftHalf.frame(in: right.area)
        check("停住时预览右边屏幕的左半边", near(snapper.previewFrame, rightLeft), "预览 \(describe(snapper.previewFrame))")
        await release()
        check("松开分到右边屏幕的左半边", near(finder.frame, rightLeft), describe(finder.frame))
    }

    private var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func postMouse(_ type: CGEventType, at point: CGPoint, delta: CGVector = .zero) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.dy.rounded()))
        event.post(tap: .cghidEventTap)
    }

    /// 按着左键往 target 拖，每下最多移动 step 点
    private func drag(toward target: CGPoint, step: CGFloat, maxSteps: Int = 400) async {
        for _ in 0 ..< maxSteps {
            let cursor = cursorLocation
            let distance = hypot(target.x - cursor.x, target.y - cursor.y)
            if distance < 0.5 { return }
            let scale = min(1, step / distance)
            let delta = CGVector(dx: (target.x - cursor.x) * scale, dy: (target.y - cursor.y) * scale)
            postMouse(.leftMouseDragged, at: CGPoint(x: cursor.x + delta.dx, y: cursor.y + delta.dy), delta: delta)
            await pause(10)
        }
    }

    private func revealInFinder(_ url: URL) async -> Bool {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return await waitUntil(timeout: 4) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == AppCatalog.finder
                && FocusInspector().focusKind() == .browsing
        }
    }

    // MARK: - 模拟输入

    private func physical(_ mod: Mod) -> (key: CGKeyCode, flag: CGEventFlags) {
        switch mod {
        case .ctrl: return (KeyCode.control, .maskControl)
        case .shift: return (KeyCode.shift, .maskShift)
        case .alt: return mapper.altFlag == .maskAlternate ? (KeyCode.option, .maskAlternate) : (KeyCode.command, .maskCommand)
        case .win: return mapper.winFlag == .maskCommand ? (KeyCode.command, .maskCommand) : (KeyCode.option, .maskAlternate)
        }
    }

    private func press(_ key: CGKeyCode, _ mods: [Mod] = [], settle: UInt64 = 250) async {
        keyLog.removeAll()
        var flags: CGEventFlags = []
        for mod in mods {
            let p = physical(mod)
            flags.insert(p.flag)
            postModifier(p.key, flags)
            await pause(15)
        }
        postKey(key, down: true, flags: flags)
        await pause(15)
        postKey(key, down: false, flags: flags)
        await pause(15)
        for mod in mods.reversed() {
            let p = physical(mod)
            flags.remove(p.flag)
            postModifier(p.key, flags)
            await pause(15)
        }
        await pause(settle)
    }

    private func postKey(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        var f = flags
        if KeyCode.functionFlagKeys.contains(key) { f.insert(.maskSecondaryFn) }
        if KeyCode.arrows.contains(key) { f.insert(.maskNumericPad) }
        event.flags = f
        event.post(tap: .cghidEventTap)
    }

    private func postModifier(_ key: CGKeyCode, _ flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postScroll(_ wheel: Int32, at point: CGPoint, flags: CGEventFlags = []) {
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                                  wheel1: wheel, wheel2: 0, wheel3: 0) else { return }
        event.location = point
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// clickState 是连点的第几下（双击的第二下是 2）
    private func postClick(at point: CGPoint, clickState: Int64? = nil) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            else { continue }
            if let clickState { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
            event.post(tap: .cghidEventTap)
        }
    }

    /// 本程序的窗口里，排在这个窗口前面的有没有一个是弹出的菜单（窗口层级不低于它）
    private func menuAbove(_ windowNumber: Int) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() }
        guard let target = mine.firstIndex(where: { $0[kCGWindowNumber as String] as? Int == windowNumber }) else { return false }
        let layer = mine[target][kCGWindowLayer as String] as? Int ?? 0
        return mine[..<target].contains { ($0[kCGWindowLayer as String] as? Int ?? 0) >= layer }
    }

    private func postRightClick(at point: CGPoint) {
        for type in [CGEventType.rightMouseDown, .rightMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .right)?
                .post(tap: .cghidEventTap)
        }
    }

    private func postOtherMouse(_ button: Int64, at point: CGPoint) {
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                      mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center) else { continue }
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 测试窗口

    private func setUpWindow() {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as? NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 16)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Win顺 自测中，请不要操作键盘和鼠标"
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        window.center()

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                self.keyLog.append((event.keyCode, event.modifierFlags.intersection([.command, .option, .control, .shift])))
            } else if event.type == .otherMouseDown {
                self.buttonLog.append(event.buttonNumber)
            } else {
                self.scrollLog.append((event.scrollingDeltaY, event.hasPreciseScrollingDeltas))
            }
            return event
        }
    }

    /// 确保测试窗口在前台、文本框接收键盘输入。做不到就不发按键，免得打到别的程序里。
    private func ensureFocus() async -> Bool {
        if isFocused { return true }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate()
        if await waitUntil(timeout: 0.5, { self.isFocused }) { return true }
        // macOS 14 起程序不能自己抢到前台（协作式激活），改用辅助功能接口把本程序设为前台。
        let me = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetAttributeValue(me, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        return await waitUntil(timeout: 3) { self.isFocused }
    }

    /// 程序必须真正激活：只是窗口成为主窗口时，方向键已经能用，但 ⌘A、⌘C 这类菜单快捷键还不生效。
    private var isFocused: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleID
            && NSApp.isActive && window.isKeyWindow && window.firstResponder === textView
    }

    private func setText(_ text: String, caret: Int) async {
        _ = await ensureFocus()
        textView.string = text
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        await pause(50)
    }

    private var caret: Int { textView.selectedRange().location }

    private func windowCenter() -> CGPoint {
        let frame = window.frame
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
    }

    // MARK: - Finder、聚焦搜索

    private func finderApplication() -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: AppCatalog.finder).first else {
            return nil
        }
        return AXUIElementCreateApplication(app.processIdentifier)
    }

    private func finderTitle() -> String? {
        guard let app = finderApplication() else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return FocusInspector.string(window as! AXUIElement, kAXTitleAttribute)
    }

    private func finderWindows() -> [AXUIElement] {
        guard let app = finderApplication() else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// 窗口在屏幕上的位置（左上角为原点，和 CGEvent 的坐标一致）。
    private func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private func finderWindowTitles() -> [String] {
        finderWindows().compactMap { FocusInspector.string($0, kAXTitleAttribute) }
    }

    private func closeFinderWindows(where shouldClose: (String) -> Bool) {
        for window in finderWindows() {
            guard let title = FocusInspector.string(window, kAXTitleAttribute), shouldClose(title) else { continue }
            var button: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
               let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }
    }

    private func spotlightVisible() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { info in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            return (owner == "Spotlight" || owner == "聚焦") && layer > 0
        }
    }

    // MARK: - 结果

    private func expectKey(_ name: String, _ code: CGKeyCode, _ mods: NSEvent.ModifierFlags) {
        guard let first = keyLog.first else { return fail(name, "测试窗口没收到按键") }
        if first.code == UInt16(code) && first.mods == mods {
            pass(name)
        } else {
            fail(name, "收到键码 \(first.code)，修饰键 \(describe(first.mods))")
        }
    }

    private func describe(_ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option) { s += "⌥" }
        if mods.contains(.shift) { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        return s.isEmpty ? "无" : s
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        ok ? pass(name) : fail(name, detail)
    }

    private func pass(_ name: String) {
        passed += 1
        say("✅ \(name)")
    }

    private func fail(_ name: String, _ detail: String) {
        failed += 1
        say("❌ \(name)：\(detail)")
    }

    private func say(_ line: String) {
        print(line)
        fflush(stdout)
        Log.app.notice("自测：\(line, privacy: .public)")
    }

    private func pause(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(50)
        }
        return condition()
    }
}
