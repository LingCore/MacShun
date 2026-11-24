// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices
import SwiftUI

/// 剪贴板历史：记录、弹出面板、选中后粘贴（C1–C5）。只在主线程上使用。
@MainActor
final class ClipboardController {
    private static let quickPasteKeys = [
        KeyCode.one, KeyCode.two, KeyCode.three, KeyCode.four, KeyCode.five,
        KeyCode.six, KeyCode.seven, KeyCode.eight, KeyCode.nine,
    ]

    let store: ClipboardStore
    let sync: ClipboardSyncService
    private let pasteboard: NSPasteboard
    private let watcher: ClipboardWatcher
    private let configStore: ConfigStore
    private lazy var model = makeModel()
    private lazy var panel = makePanel()
    private var modelLoaded = false
    private var panelLoaded = false
    private var keyMonitor: Any?
    private var pasteTarget: ClipboardPasteTarget?
    private var pendingPaste: UUID?
    private var tiffProvider: LazyTIFFProvider?
    private var fileAction: Task<Void, Never>?
    private var previewOffset: CGFloat?
    private lazy var hoverPreview = ClipboardHoverPreview()
    private var fileToastLoaded = false
    private lazy var fileToast: SyncFileToastController = makeFileToast()
    private(set) var isRecordingPaused = false
    /// 从本程序的文件搜索框里打开时，选中的条目交给它
    private var host: Host?

    /// store 不给时用默认目录。不写成默认参数：默认参数不在主线程上下文里求值，不能调用 ClipboardStore()
    init(
        configStore: ConfigStore,
        store: ClipboardStore? = nil,
        pasteboard: NSPasteboard = .general,
        sync: ClipboardSyncService? = nil
    ) {
        let store = store ?? ClipboardStore()
        self.configStore = configStore
        self.store = store
        self.pasteboard = pasteboard
        self.sync = sync ?? ClipboardSyncService(enableDiscovery: !SelfTest.isRequested)
        watcher = ClipboardWatcher(store: store, pasteboard: pasteboard, config: { configStore.config.clipboard })
        watcher.onLocalCapture = { [weak self] capture in
            self?.sync.broadcastLocalCapture(capture)
        }
        self.sync.onRemoteClipboard = { [weak self] event in
            self?.handleRemoteEvent(event)
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        fileAction?.cancel()
    }

    /// 切换前台应用前立刻补采一次，避免快速 ⌘C 后立刻 ⌘Tab 把来源应用记成新应用。
    func recordBeforeAppSwitch(from bundleID: String?) {
        watcher.recordPendingChange(sourceApp: bundleID)
    }

    /// 按配置开始或停止记录与跨设备共享。
    func applyConfig() {
        let cfg = configStore.config.clipboard
        store.setImageRecognition(enabled: cfg.enabled && cfg.recordImages)
        updateRecording()
        if cfg.enabled {
            store.trim(maxItems: cfg.maxItems)
            sync.apply(config: cfg.sync)
        } else {
            hide()
            var disabled = cfg.sync
            disabled.enabled = false
            sync.apply(config: disabled)
        }
    }

    func toggleSyncPause() {
        sync.togglePause()
    }

    func handleWillSleep() {
        sync.handleWillSleep()
    }

    func handleDidWake() {
        sync.handleDidWake()
    }

    func stopSync() {
        if fileToastLoaded { fileToast.hide() }
        sync.stop()
    }

    private func makeFileToast() -> SyncFileToastController {
        fileToastLoaded = true
        let toast = SyncFileToastController()
        toast.onReceiveAndCopy = { [weak self] info, onProgress in
            guard let self else { return }
            let urls = try await self.pullWithProgress(info: info, onProgress: onProgress)
            if !urls.isEmpty {
                _ = self.replacePasteboard(with: urls.map { $0 as NSURL })
            }
        }
        toast.onReceiveAndSaveToDownloads = { [weak self] info, onProgress in
            guard let self else { return }
            let urls = try await self.pullWithProgress(info: info, onProgress: onProgress)
            let saved = try await Task.detached(priority: .userInitiated) {
                try SyncCacheManager.copyToDownloads(urls)
            }.value
            if !saved.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            }
        }
        toast.onCancelTransfer = { [weak self] id in
            self?.sync.cancelTransfer(id)
        }
        return toast
    }

    private func pullWithProgress(info: RemoteFileInfo, onProgress: @escaping (Int) -> Void) async throws -> [URL] {
        let watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard let self, !Task.isCancelled else { break }
                if let prog = self.sync.activeTransfers[info.transferID] {
                    onProgress(prog.percent)
                }
            }
        }
        defer { watch.cancel() }
        return try await sync.pullRemoteFiles(info: info)
    }

    /// 在面板右键或预览里将远端文件（或本地文件）保存到“下载”文件夹并在访达中显示。
    private func saveToDownloads(_ item: ClipboardItem) {
        guard item.kind == .files else { return }
        fileAction?.cancel()
        fileAction = nil
        if item.isPendingRemoteFiles, let remote = item.remoteFiles {
            model.showFeedback(L("正在从 %@ 接收文件…", remote.originDeviceName), autoDismiss: false)
            fileAction = Task { [weak self] in
                guard let self else { return }
                do {
                    let urls = try await self.pullWithProgress(info: remote) { [weak self] percent in
                        self?.model.showFeedback(
                            L("正在从 %@ 接收文件… %ld%%", remote.originDeviceName, percent),
                            autoDismiss: false
                        )
                    }
                    guard !Task.isCancelled else { return }
                    let saved = try await Task.detached(priority: .userInitiated) {
                        try SyncCacheManager.copyToDownloads(urls)
                    }.value
                    guard !Task.isCancelled else { return }
                    self.fileAction = nil
                    self.hide()
                    if !saved.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(saved)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.fileAction = nil
                    self.model.showFeedback(error.localizedDescription)
                }
            }
            return
        }
        guard let urls = item.fileURLs, !urls.isEmpty else { return }
        fileAction = Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await Task.detached(priority: .userInitiated) {
                    try SyncCacheManager.copyToDownloads(urls)
                }.value
                guard !Task.isCancelled else { return }
                self.fileAction = nil
                self.hide()
                if !saved.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(saved)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.fileAction = nil
                self.model.showFeedback(error.localizedDescription)
            }
        }
    }

    /// 将敏感文本（如群组邀请码）写入本机剪贴板，不记入剪贴板历史，也不向其他设备广播。
    func copySensitiveTextLocally(_ text: String) {
        let pbItem = NSPasteboardItem()
        pbItem.setString(text, forType: .string)
        pbItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pbItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        _ = replacePasteboard(with: [pbItem])
    }

    private func handleRemoteEvent(_ event: RemoteClipboardEvent) {
        let cfg = configStore.config.clipboard
        guard cfg.enabled else { return }
        switch event {
        case .text(let text, let fingerprint, let deviceID, let deviceName, let platform, let shouldWrite):
            let capture = ClipboardCapture(
                kind: .text,
                text: text,
                fingerprint: fingerprint,
                sourceDeviceID: deviceID,
                sourceDeviceName: deviceName,
                sourcePlatform: platform
            )
            store.add(capture, maxItems: cfg.maxItems)
            if shouldWrite {
                let pbItem = NSPasteboardItem()
                pbItem.setString(text, forType: .string)
                _ = replacePasteboard(with: [pbItem])
            }

        case .image(let png, let width, let height, let fingerprint, let deviceID, let deviceName, let platform, let shouldWrite):
            let capture = ClipboardCapture(
                kind: .image,
                png: png,
                imageSize: CGSize(width: width, height: height),
                fingerprint: fingerprint,
                sourceDeviceID: deviceID,
                sourceDeviceName: deviceName,
                sourcePlatform: platform
            )
            store.add(capture, maxItems: cfg.maxItems)
            if shouldWrite {
                let pbItem = NSPasteboardItem()
                pbItem.setData(png, forType: .png)
                let provider = LazyTIFFProvider(png: png)
                pbItem.setDataProvider(provider, forTypes: [.tiff])
                _ = replacePasteboard(with: [pbItem], tiffProvider: provider)
            }

        case .filesManifest(let info, let fingerprint, let platform):
            let capture = ClipboardCapture(
                kind: .files,
                fingerprint: fingerprint,
                sourceDeviceID: info.originDeviceID,
                sourceDeviceName: info.originDeviceName,
                sourcePlatform: platform,
                remoteFiles: info
            )
            store.add(capture, maxItems: cfg.maxItems)
            if !SelfTest.isRequested && sync.shouldNotifyIncomingFiles(for: info) {
                fileToast.show(info: info, platform: platform)
            }

        case .filesReady(let transferID, let localURLs, _, let shouldWrite):
            store.completeRemoteFiles(transferID: transferID, localURLs: localURLs)
            if shouldWrite, !localURLs.isEmpty {
                _ = replacePasteboard(with: localURLs.map { $0 as NSURL })
            }
        }
    }

    func toggleRecordingPause() {
        guard configStore.config.clipboard.enabled else { return }
        isRecordingPaused.toggle()
        if modelLoaded { model.recordingPaused = isRecordingPaused }
        updateRecording()
    }

    private func updateRecording() {
        if configStore.config.clipboard.enabled && !isRecordingPaused { watcher.start() }
        else { watcher.stop() }
    }

    var isVisible: Bool { panelLoaded && panel.isVisible }
    /// 自测用
    var query: String { model.query }
    var confirmingClear: Bool { model.confirmingClear }
    /// 自测用：“全部清除”按钮上的一点，屏幕坐标（左上角为原点）
    var clearButtonPoint: CGPoint {
        let frame = panel.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let halfHeader = ClipboardPanelView.searchBarHeight / 2
        let y = model.opensAbove ? frame.minY + halfHeader : frame.maxY - halfHeader
        return CGPoint(x: frame.maxX - 16 - 20, y: primaryHeight - y)
    }
    /// 面板里当前显示的条目（自测用）。
    var visibleResults: [ClipboardItem] { model.results }

    /// 从文件搜索框里打开（Win+V）时：面板靠着搜索框，选中的文字直接填进搜索框，Esc 回到搜索框。
    struct Host {
        /// 面板所贴靠的搜索栏（AppKit 坐标）
        let anchor: NSRect
        /// 选中的文字（非文字条目是 nil）
        let insert: (String?) -> Void
        /// 按 Esc 或再按 Win+V 关掉
        let back: () -> Void
        /// 点了别的地方，面板自己关掉
        let resigned: () -> Void
    }

    func show(in host: Host? = nil, at pointer: CGPoint = NSEvent.mouseLocation) {
        guard configStore.config.clipboard.enabled else { return }
        pendingPaste = nil
        // 已经开着：放到前面就行，保留正在输入的查询
        if panelLoaded && panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let target = host == nil
            ? NSWorkspace.shared.frontmostApplication.map { ClipboardPasteTarget(pid: $0.processIdentifier) }
            : nil
        pasteTarget = target
        let placement = placement(at: pointer, beside: host?.anchor, pasteTarget: target)
        watcher.recordPendingChange()
        model.setActive(true)
        model.prepareForShow(opensAbove: placement.opensAbove)
        model.showsQuickPasteNumbers = NSEvent.modifierFlags.contains(.option)
        self.host = host
        previewOffset = nil
        panel.setFrame(placement.frame, display: false)
        FrontAppTracker.shared.clipboardPanelActive.set(true)
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    /// Esc、再按一次 Win+V：关掉；从搜索框打开的回到搜索框
    func close() {
        let host = self.host
        self.host = nil
        hide()
        host?.back()
    }

    /// 关掉。从搜索框打开的，告诉它面板没了（点了别处、在设置里关掉了剪贴板历史），它自己决定接着用还是一起关
    func hide() {
        fileAction?.cancel()
        fileAction = nil
        let host = self.host
        self.host = nil
        pasteTarget = nil
        removeKeyMonitor()
        FrontAppTracker.shared.clipboardPanelActive.set(false)
        if modelLoaded {
            model.hoveredID = nil
            hoverPreview.cancel()
        }
        if panelLoaded && panel.isVisible {
            pendingPaste = nil
            model.cancelTextCopy()
            panel.endEditing(for: nil)
            panel.orderOut(nil)
            model.setPreviewOpen(false)
        }
        if modelLoaded {
            model.setActive(false)
            model.thumbnails.removeAll()
            model.previews.removeAll()
        }
        host?.resigned()
    }

    /// 把选中的条目放进剪贴板，再模拟 ⌘V 粘贴到原来的应用里。
    func paste(_ item: ClipboardItem) {
        paste(item, usedIDs: [item.id])
    }

    private func paste(_ item: ClipboardItem, usedIDs: [UUID]) {
        if let host {
            guard item.kind == .text, let text = item.text else {
                model.showFeedback(L("文件搜索框只能粘贴文字"))
                return
            }
            self.host = nil
            hide()
            store.markUsed(usedIDs)
            host.insert(text)
            return
        }
        prepareWrite(item) { [weak self] in self?.pasteWrittenItems(usedIDs) }
    }

    private func pasteWrittenItems(_ usedIDs: [UUID]) {
        let target = pasteTarget
        let count = pasteboard.changeCount
        hide()
        store.markUsed(usedIDs)
        guard pasteboard.name == .general, let target, Permissions.accessibility else { return }
        let request = UUID()
        pendingPaste = request
        // 等面板消失、原来的窗口重新接收键盘输入，并且用户松开修饰键之后再粘贴。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            Synthetic.afterModifiersReleased {
                guard let self, self.pendingPaste == request else { return }
                self.pendingPaste = nil
                guard self.pasteboard.changeCount == count, target.isCurrent,
                      self.pasteboard.changeCount == count else { return }
                Synthetic.tap(KeyStroke(KeyCode.v, .maskCommand))
            }
        }
    }

    private func copy(_ item: ClipboardItem) {
        prepareWrite(item) { [weak self] in self?.model.showFeedback(L("已复制")) }
    }

    /// 文件引用可能指向慢速磁盘、断开的卷或尚未拉取的远端设备。等待时保留面板和现有剪贴板。
    private func prepareWrite(_ item: ClipboardItem, completed: @escaping () -> Void) {
        fileAction?.cancel()
        fileAction = nil
        guard item.kind == .files else {
            if write(item) { completed() }
            else { model.showFeedback(L("未能写入剪贴板")) }
            return
        }
        if item.isPendingRemoteFiles, let remote = item.remoteFiles {
            let progressMessage = L("正在从 %@ 接收文件…", remote.originDeviceName)
            model.showFeedback(progressMessage, autoDismiss: false)
            fileAction = Task { [weak self] in
                guard let self else { return }
                let progressWatch = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        guard let self, !Task.isCancelled else { break }
                        if let prog = self.sync.activeTransfers[remote.transferID] {
                            self.model.showFeedback(
                                L("正在从 %@ 接收文件… %ld%%", remote.originDeviceName, prog.percent),
                                autoDismiss: false
                            )
                        }
                    }
                }
                defer { progressWatch.cancel() }
                do {
                    let urls = try await self.sync.pullRemoteFiles(info: remote)
                    guard !Task.isCancelled else { return }
                    self.fileAction = nil
                    self.store.completeRemoteFiles(transferID: remote.transferID, localURLs: urls)
                    if !urls.isEmpty, self.replacePasteboard(with: urls.map { $0 as NSURL }) {
                        self.model.clearFeedback()
                        completed()
                    } else {
                        self.model.showFeedback(L("未能写入剪贴板"))
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.fileAction = nil
                    self.model.showFeedback(error.localizedDescription)
                }
            }
            return
        }
        let urls = item.fileURLs ?? []
        let changeCount = pasteboard.changeCount
        let checkingMessage = L("正在检查文件…")
        model.showFeedback(checkingMessage, autoDismiss: false)
        fileAction = Task { [weak self] in
            let available = await Self.filesAvailable(urls)
            guard let self, !Task.isCancelled else { return }
            fileAction = nil
            guard store.items.contains(where: { $0.id == item.id }) else {
                model.clearFeedbackIf(checkingMessage)
                return
            }
            guard available else { model.showFeedback(L("部分文件已移动、删除或暂不可用")); return }
            guard pasteboard.changeCount == changeCount else {
                model.showFeedback(L("剪贴板已更改，请重试"))
                return
            }
            if replacePasteboard(with: urls.map { $0 as NSURL }) {
                model.clearFeedbackIf(checkingMessage)
                completed()
            } else {
                model.showFeedback(L("未能写入剪贴板"))
            }
        }
    }

    static func filesAvailable(_ urls: [URL]) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard !urls.isEmpty else { return false }
            let fm = FileManager.default
            for url in urls {
                if Task.isCancelled { return false }
                guard url.isFileURL, fm.fileExists(atPath: url.path) else { return false }
            }
            return true
        }.value
    }

    /// 写进剪贴板。图片文件丢失等原因写不了时返回 false，这时不能再粘贴，否则会贴出剪贴板里原有的东西。
    private func write(_ item: ClipboardItem) -> Bool {
        let pbItem = NSPasteboardItem()
        var pendingProvider: LazyTIFFProvider?
        switch item.kind {
        case .text:
            pbItem.setString(item.text ?? "", forType: .string)
            for (type, data) in store.extraData(for: item) {
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
        case .image:
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                Log.clipboard.error("找不到图片文件，无法写入剪贴板")
                return false
            }
            if url.pathExtension == "tiff" {
                pbItem.setData(data, forType: .tiff)
                if let png = ClipboardImage.png(fromTIFF: data) { pbItem.setData(png, forType: .png) }
            } else {
                pbItem.setData(data, forType: .png)
                // 按需生成 TIFF，避免粘贴高分辨率 PNG 时在主线程同步展开数十 MB 位图。
                let provider = LazyTIFFProvider(png: data)
                pendingProvider = provider
                pbItem.setDataProvider(provider, forTypes: [.tiff])
            }
        case .files:
            return false
        }
        return replacePasteboard(with: [pbItem], tiffProvider: pendingProvider)
    }

    private func replacePasteboard(with objects: [NSPasteboardWriting], tiffProvider newProvider: LazyTIFFProvider? = nil) -> Bool {
        tiffProvider = newProvider
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else {
            tiffProvider = nil
            return false
        }
        watcher.noteOwnWrite()
        return true
    }

    // MARK: - 面板

    private func makeModel() -> ClipboardPanelModel {
        modelLoaded = true
        let model = ClipboardPanelModel(store: store, pasteboard: pasteboard, sync: sync)
        model.recordingPaused = isRecordingPaused
        model.setActive(false)
        model.onPaste = { [weak self] item in self?.paste(item) }
        model.onPasteBatch = { [weak self] items in self?.pasteBatch(items) }
        model.onCopy = { [weak self] item in self?.copy(item) }
        model.onSaveToDownloads = { [weak self] item in self?.saveToDownloads(item) }
        model.onSendToDevice = { [weak self] item, targetDeviceID in
            guard let self else { return }
            self.sync.sendHistoryItem(item, store: self.store, targetDeviceID: targetDeviceID)
            if let targetDeviceID,
               let peer = self.sync.connectedPeers.first(where: { $0.deviceID == targetDeviceID }) {
                self.model.showFeedback(L("已发送到 %@", peer.deviceName))
            } else {
                self.model.showFeedback(L("已发送到所有在线设备"))
            }
        }
        model.onCopiedToPasteboard = { [weak self] in self?.watcher.noteOwnWrite() }
        model.onPreviewChange = { [weak self] open in self?.resizeForPreview(open) }
        model.onHoverChange = { [weak self] id in self?.updateHoverPreview(id) }
        store.onRemoveFiles = { [weak model] urls in
            for url in urls {
                model?.thumbnails.remove(url)
                model?.previews.remove(url)
            }
        }
        model.onFloat = { [weak self] item in
            guard let self, let url = store.imageURL(for: item),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let png = url.pathExtension == "tiff" ? ClipboardImage.png(fromTIFF: data) : data,
                  let picture = PinPicture(png: png) else {
                NSSound.beep()
                return
            }
            hide()
            ScreenPins.shared.show(picture)
        }
        model.onClose = { [weak self] in self?.close() }
        return model
    }

    func pasteBatch(_ items: [ClipboardItem]) {
        guard var combined = items.first else { return }
        let parts = items.compactMap(\.text)
        var remaining = ClipboardWatcher.maxTextBytes - (parts.count - 1)
        for part in parts {
            remaining -= part.utf8.count
            if remaining < 0 {
                model.showFeedback(L("合并内容太长，请减少选择的条目"))
                return
            }
        }
        combined.text = parts.joined(separator: "\n")
        combined.extraFiles = [:]
        paste(combined, usedIDs: items.map(\.id))
    }

    private func makePanel() -> ClipboardPanel {
        panelLoaded = true
        let panel = ClipboardPanel()
        let host = NSHostingView(rootView: ClipboardPanelView(model: model))
        // 面板带隐藏的标题栏（为了圆角和阴影），不给它让位置，否则搜索框上面会空出一条
        host.safeAreaRegions = []
        host.sizingOptions = []
        panel.contentView = host
        panel.onResignKey = { [weak self] in self?.hide() }
        return panel
    }

    /// 面板快捷键在搜索框之前处理，组字时由输入法优先处理。
    private func installKeyMonitor() {
        removeKeyMonitor()
        let events: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            guard let self else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.type == .flagsChanged, self.panel.isKeyWindow {
                let want = mods.contains(.option)
                if self.model.showsQuickPasteNumbers != want {
                    self.model.showsQuickPasteNumbers = want
                }
            }
            guard event.window === self.panel else { return event }
            self.hoverPreview.cancel()
            guard event.type == .keyDown else { return event }
            let key = CGKeyCode(event.keyCode)
            if let editor = self.panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            if self.model.isEditingNote {
                if key == KeyCode.escape, mods.isEmpty {
                    self.model.cancelNote()
                    return nil
                }
                return event
            }
            if mods == .option, let index = Self.quickPasteKeys.firstIndex(of: key) {
                if !event.isARepeat { self.model.pasteVisibleRow(index + 1) }
                return nil
            }
            if mods.isEmpty, key == KeyCode.returnKey || key == KeyCode.keypadEnter,
               self.panel.firstResponder is ClipboardPreviewTextView, let item = self.model.selectedItem {
                if !event.isARepeat { self.model.pastePreview(item) }
                return nil
            }
            if key == KeyCode.escape, mods.isEmpty {
                self.model.cancel()
                return nil
            }
            if key == KeyCode.y, mods == .command {
                if !event.isARepeat {
                    if self.model.isPreviewOpen { self.model.cancel() }
                    else { self.model.setPreviewOpen(true) }
                }
                return nil
            }
            if key == KeyCode.c, mods == [.command, .shift] || mods == [.control, .shift],
               let item = self.model.selectedItem {
                if !event.isARepeat { self.model.onCopy(item) }
                return nil
            }
            if (key == KeyCode.returnKey || key == KeyCode.keypadEnter), mods == .shift,
               let item = self.model.selectedItem, item.kind == .text {
                if !event.isARepeat { self.model.pasteAsPlainText(item) }
                return nil
            }
            if key == KeyCode.f3, mods.isEmpty, let item = self.model.selectedItem, item.kind == .image {
                if !event.isARepeat { self.model.onFloat(item) }
                return nil
            }
            if key == KeyCode.p, mods == .command || mods == .control {
                if !event.isARepeat { self.model.togglePinSelected() }
                return nil
            }
            if self.model.handleDeleteShortcut(key, modifiers: mods, isRepeat: event.isARepeat) {
                return nil
            }
            return event
        }
    }

    private func updateHoverPreview(_ id: UUID?) {
        hoverPreview.cancel()
        guard panel.isVisible, !model.isPreviewOpen, !model.isEditingNote, let id else { return }
        hoverPreview.schedule(owner: panel) { [weak self] in
            guard let self, self.model.hoveredID == id, !self.model.isPreviewOpen,
                  let item = self.model.results.first(where: { $0.id == id }) else { return nil }
            return ClipboardHoverCard(item: item, imageURL: self.store.imageURL(for: item), cache: self.model.previews)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// 展开预览时优先留住列表的位置。右侧空间不够时向左移动，收起时回到展开前的位置。
    private func resizeForPreview(_ open: Bool) {
        guard panel.isVisible, let screen = panel.screen else { return }
        let inset = ClipboardPanelPlacement.screenInset
        let area = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        var frame = panel.frame
        if open {
            guard area.width >= ClipboardPanel.expandedWidth else { return }
            frame.size.width = ClipboardPanel.expandedWidth
            frame = WindowPlacement.fittedFrame(frame, in: area, centered: false)
            previewOffset = panel.frame.minX - frame.minX
        } else {
            guard let offset = previewOffset else { return }
            previewOffset = nil
            frame.origin.x += offset
            frame.size.width = ClipboardPanel.size.width
            frame = WindowPlacement.fittedFrame(frame, in: area, centered: false)
        }
        panel.setFrame(frame, display: true)
    }

    /// 优先贴着本程序的搜索框或正在输入的文字光标，其次跟随鼠标。
    private func placement(at pointer: CGPoint, beside given: NSRect?, pasteTarget: ClipboardPasteTarget?) -> ClipboardPanelPlacement {
        if let given, let hostScreen = WindowPlacement.screen(containing: CGPoint(x: given.midX, y: given.midY)) {
            return .init(anchor: given, gap: 4, visibleFrame: hostScreen.visibleFrame)
        }
        let caret: NSRect?
        if let element = pasteTarget?.focusedTextElement {
            caret = CaretLocator.caretRect(in: element)
        } else {
            caret = CaretLocator.caretRect()
        }
        if let caret,
           let screen = WindowPlacement.screen(containing: CGPoint(x: caret.minX, y: caret.midY)),
           caret.height <= screen.visibleFrame.height / 4 {
            return .init(anchor: caret, gap: 12, visibleFrame: screen.visibleFrame)
        }
        let visible = WindowPlacement.pointerScreen(at: pointer)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return .init(anchor: NSRect(origin: pointer, size: .zero), gap: 4, visibleFrame: visible)
    }
}

/// 通过辅助功能接口查询文字光标在屏幕上的位置。
enum CaretLocator {
    /// 返回 AppKit 坐标（原点在主屏幕左下角）。
    static func caretRect() -> NSRect? {
        guard Permissions.accessibility,
              let element = FocusInspector().focusedElement(), FocusInspector.focusKind(of: element) == .text
        else { return nil }
        return caretRect(in: element)
    }

    /// 对已确认为文本输入焦点的元素查询光标位置，避免呼出剪贴板时重复 AX 查询。
    static func caretRect(in element: AXUIElement) -> NSRect? {
        AXUIElementSetMessagingTimeout(element, 0.08)
        guard let primary = NSScreen.screens.first,
              let selected: CFRange = element.axValue(kAXSelectedTextRangeAttribute, type: .cfRange),
              selected.location >= 0, selected.length >= 0, selected.location < Int.max - selected.length
        else { return nil }

        // 选中文本时贴着选区末端。部分应用只返回有长度的文字范围。
        let end = selected.location + selected.length
        let rect: CGRect
        let x: CGFloat
        if let insertion = bounds(of: CFRange(location: end, length: 0), in: element) {
            rect = insertion
            x = insertion.minX
        } else if let next = bounds(of: CFRange(location: end, length: 1), in: element) {
            rect = next
            x = next.minX
        } else if end > 0, let previous = bounds(of: CFRange(location: end - 1, length: 1), in: element) {
            rect = previous
            x = previous.maxX
        } else {
            return nil
        }

        // 辅助功能接口的坐标原点在主屏幕左上角，y 向下。
        return NSRect(x: x, y: primary.frame.maxY - rect.maxY, width: 0, height: rect.height)
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &boundsValue
        ) == .success,
            let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect),
              rect.minX.isFinite, rect.maxX.isFinite, rect.minY.isFinite, rect.maxY.isFinite, rect.height > 0
        else { return nil }
        return rect
    }
}

/// 仅在目标应用显式请求 TIFF 格式时才从 PNG 展开位图。
private final class LazyTIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private var png: Data?

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let png, let tiff = NSImage(data: png)?.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        png = nil
    }
}
