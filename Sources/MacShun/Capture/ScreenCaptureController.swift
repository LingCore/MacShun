// SPDX-License-Identifier: MIT

import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
private final class CapturePanel: NSPanel {
    let canvas: CaptureCanvas
    let displayID: CGDirectDisplayID
    let axFrame: CGRect
    var onResignKey: (() -> Void)?
    var onInputEvent: ((NSEvent) -> Void)?

    init(frame: CGRect, displayID: CGDirectDisplayID, axFrame: CGRect, canvas: CaptureCanvas) {
        self.displayID = displayID
        self.axFrame = axFrame
        self.canvas = canvas
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = canvas
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown { onInputEvent?(event) }
        return canvas.handleKey(event) || super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        onInputEvent?(event)
        _ = canvas.handleKey(event)
    }

    override func sendEvent(_ event: NSEvent) {
        onInputEvent?(event)
        switch event.type {
        case .keyDown where event.keyCode == KeyCode.tab && !canvas.isEditingText && !canvas.isEditingSize:
            if canvas.handleKey(event) { return }
        case .keyUp: canvas.releaseDirectionKey(event)
        case .flagsChanged: canvas.updateDirectionModifiers(event)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            canvas.stopDirectionRepeat()
            canvas.restoreSystemCursor()
        default: break
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        canvas.stopDirectionRepeat()
        onResignKey?()
        super.resignKey()
    }
}

/// 记本次运行中最近成功输出的屏幕和选区（最多保留 10 条）。显示器移动后仍使用该屏内的位置。
private struct CaptureRegionMemory: Equatable {
    let display: CGDirectDisplayID
    let screenSize: CGSize
    let pixels: CGSize
    let rect: CGRect
    let polygon: CapturePolygon?

    init(display: CGDirectDisplayID, photo: CaptureImage, selection: CGRect, polygon: CapturePolygon?) {
        self.display = display
        screenSize = photo.size
        pixels = CGSize(width: photo.image.width, height: photo.image.height)
        rect = photo.pixelRect(selection)
        self.polygon = polygon
    }

    func matches(_ id: CGDirectDisplayID, _ photo: CaptureImage) -> Bool {
        display == id && screenSize == photo.size && pixels == CGSize(width: photo.image.width, height: photo.image.height)
    }
}

/// 截图历史回看快照（`,` / `.` 翻回之前的冻结图继续标注、打码、取字或贴图）。
/// 以压缩 PNG 存放在内存中（最多 6 条），避免多张 4K 原始位图常驻占满内存。
@MainActor
private final class CaptureHistorySnapshot {
    let displayID: CGDirectDisplayID
    let screenSize: CGSize
    let selection: CGRect
    let polygon: CapturePolygon?
    let marks: [CaptureMark]
    private var pngData: Data?
    private var fallbackImage: CGImage?

    init(displayID: CGDirectDisplayID, photo: CaptureImage, selection: CGRect, polygon: CapturePolygon?, marks: [CaptureMark]) {
        self.displayID = displayID
        self.screenSize = photo.size
        self.selection = selection
        self.polygon = polygon
        self.marks = marks
        self.fallbackImage = photo.image
        let rawImage = photo.image
        Task { [weak self] in
            let encoded = await Task.detached(priority: .utility) {
                CaptureImage.pngData(rawImage)
            }.value
            guard let self, let encoded else { return }
            self.pngData = encoded
            self.fallbackImage = nil
        }
    }

    func decodePhoto() -> CaptureImage? {
        if let fallbackImage {
            return CaptureImage(image: fallbackImage, size: screenSize)
        }
        guard let pngData,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return CaptureImage(image: cg, size: screenSize)
    }
}

/// 一次只保留一组冻结画面；全部屏幕取完才显示选区窗口。取消时不写剪贴板或磁盘。
@MainActor
final class ScreenCaptureController: NSObject {
    private static let colorFormatKey = "captureColorFormat"
    private static let windowsOnlyKey = "captureWindowsOnly"
    private static let sizePresetsKey = "captureSizePresets"
    private static let hideKeyHintsKey = "captureHideKeyHints"
    private static let regionHistoryLimit = 10
    private static let captureHistoryLimit = 6

    private var panels: [CapturePanel] = []
    private var liveSnapshots: [CGDirectDisplayID: (photo: CaptureImage, targets: [CaptureWindowTarget])] = [:]
    private var captureHistory: [CaptureHistorySnapshot] = []
    private var browsingHistoryIndex: Int?
    private var regionHistory: [CaptureRegionMemory] = []
    private var recalledRegionIndex: Int?
    private var session: UUID?
    private var savePanel: NSSavePanel?
    private var isSaving = false
    private var activatedForSave = false
    private var isRecognizingText = false
    private var ocrCancelled: Locked<Bool>?
    private var previousApp: NSRunningApplication?
    private var notice: NSPanel?
    private var scrolling: ScrollingCapture?
    private weak var keyboardPointerCanvas: CaptureCanvas?
    private let colorDefaults: UserDefaults
    private var colorFormat: CaptureColorFormat
    private var windowsOnly: Bool
    private var sizePresets: [CaptureSizePreset]
    private var hideKeyHints: Bool
    private var shiftDown = false
    private var shiftAlone = false
    private var axProbe: CaptureAXProbe?
    private var axGate = CaptureAXProbeGate()
    private var probedCells: Set<CaptureAXProbeCell> = []
    private var inFlightAXCell: CaptureAXProbeCell?
    private let visualQueue = DispatchQueue(label: "MacShun.CaptureVisualRegions", qos: .userInteractive)
    private var visualAnalyzedWindows: Set<CGWindowID> = []

    private let captureClipboard: CaptureClipboard
    private var pasteboard: NSPasteboard { captureClipboard.pasteboard }
    private let makeScrollSource: ScrollCaptureSource.Factory
    private let freeze: @MainActor () async throws -> [FrozenScreen]
    private let mouseLocation: @MainActor () -> CGPoint
    private let warpPointer: @MainActor (CGPoint) -> CGError
    private let detectVisualRegions: @Sendable (CaptureImage, CGRect) -> [CGRect]
    private let defaultSaveDirectory: @MainActor () -> URL?

    init(clipboard: CaptureClipboard = .general,
         makeScrollSource: @escaping ScrollCaptureSource.Factory = ScrollCaptureSource.stream,
         freeze: (@MainActor () async throws -> [FrozenScreen])? = nil,
         mouseLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
         warpPointer: @escaping @MainActor (CGPoint) -> CGError = { CGWarpMouseCursorPosition(ScreenGeometry.axPoint($0)) },
         colorDefaults: UserDefaults = .standard,
         detectVisualRegions: @escaping @Sendable (CaptureImage, CGRect) -> [CGRect] = { CaptureVisualRegions.detect(in: $0, windowLocalRect: $1) },
         defaultSaveDirectory: @escaping @MainActor () -> URL? = { nil }) {
        self.captureClipboard = clipboard
        self.freeze = freeze ?? {
            let excluded = Self.excludedSurfaceWindowIDs()
            return try await FrozenScreen.captureAll(excludingWindowIDs: excluded)
        }
        self.mouseLocation = mouseLocation
        self.warpPointer = warpPointer
        self.colorDefaults = colorDefaults
        self.detectVisualRegions = detectVisualRegions
        self.defaultSaveDirectory = defaultSaveDirectory
        colorFormat = colorDefaults.string(forKey: Self.colorFormatKey).flatMap(CaptureColorFormat.init(rawValue:)) ?? .hex
        windowsOnly = colorDefaults.bool(forKey: Self.windowsOnlyKey)
        let savedPresets = colorDefaults.string(forKey: Self.sizePresetsKey)
        let parsed = savedPresets.map { CaptureSizePreset.parseList($0) } ?? []
        sizePresets = parsed.isEmpty ? CaptureSizePreset.parseList(CaptureSizePreset.defaultsString) : parsed
        hideKeyHints = colorDefaults.bool(forKey: Self.hideKeyHintsKey)
        self.makeScrollSource = makeScrollSource
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(cancelScreenBoundCapture), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelScreenBoundCapture), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancelScreenBoundCapture), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    private static func excludedSurfaceWindowIDs() -> Set<CGWindowID> {
        var ids = Set<CGWindowID>()
        for pin in ScreenPins.shared.windows where pin.windowNumber > 0 {
            ids.insert(CGWindowID(pin.windowNumber))
        }
        for window in NSApp.windows where window is CapturePanel && window.windowNumber > 0 {
            ids.insert(CGWindowID(window.windowNumber))
        }
        return ids
    }

    func start(_ mode: CaptureMode) {
        guard session == nil else { return }
        notice?.orderOut(nil)
        notice = nil
        let token = UUID()
        session = token
        recalledRegionIndex = nil
        browsingHistoryIndex = nil
        liveSnapshots.removeAll()
        axGate.reset()
        probedCells.removeAll()
        inFlightAXCell = nil
        visualAnalyzedWindows.removeAll()
        previousApp = NSWorkspace.shared.frontmostApplication
        Task {
            do {
                let screens = try await freeze()
                guard session == token else { return }
                let canRestore = regionHistory.contains { memory in
                    screens.contains { memory.matches($0.displayID, $0.photo) }
                }
                for screen in screens { addPanel(for: screen, mode: mode, canRestore: canRestore) }
                showPanels()
            } catch {
                guard session == token else { return }
                cancel()
                let error = error as NSError
                let denied = error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
                if denied || !CGPreflightScreenCaptureAccess() {
                    let alert = NSAlert()
                    alert.messageText = L("允许 Mac顺 截取屏幕")
                    alert.informativeText = L("在系统设置的屏幕录制权限中允许 Mac顺，然后重试。如果系统要求重新打开应用，请按提示操作。")
                    alert.addButton(withTitle: L("打开系统设置"))
                    alert.addButton(withTitle: L("取消"))
                    NSApp.activate()
                    if alert.runModal() == .alertFirstButtonReturn { Permissions.openScreenCaptureSettings() }
                } else {
                    showMessage(L("无法截取屏幕"), detail: error.localizedDescription)
                }
            }
        }
    }

    private func addPanel(for screen: FrozenScreen, mode: CaptureMode, canRestore: Bool) {
        let canvas = CaptureCanvas(photo: screen.photo, mode: mode, windowRects: screen.windowRects,
                                   windowTargets: screen.windowTargets, canRestore: canRestore)
        let panel = CapturePanel(frame: screen.frame, displayID: screen.displayID, axFrame: screen.axFrame, canvas: canvas)
        liveSnapshots[screen.displayID] = (screen.photo, screen.windowTargets)
        canvas.setColorFormat(colorFormat)
        canvas.setWindowsOnly(windowsOnly, announce: false)
        canvas.setSizePresets(sizePresets)
        canvas.setKeyHintsPermanentlyHidden(hideKeyHints)
        canvas.setHasCaptureHistory(captureHistory.contains { $0.displayID == screen.displayID && $0.screenSize == screen.photo.size })
        canvas.onStepCaptureHistory = { [weak self, weak panel] older in
            guard let self, let panel else { return }
            self.stepCaptureHistory(older: older, from: panel)
        }
        canvas.onSizePresetsChanged = { [weak self] presets in
            guard let self else { return }
            self.sizePresets = presets
            self.colorDefaults.set(CaptureSizePreset.serialize(presets), forKey: Self.sizePresetsKey)
            self.panels.forEach { $0.canvas.setSizePresets(presets) }
        }
        canvas.onKeyHintsHiddenChanged = { [weak self] hidden in
            guard let self else { return }
            self.hideKeyHints = hidden
            self.colorDefaults.set(hidden, forKey: Self.hideKeyHintsKey)
            self.panels.forEach { $0.canvas.setKeyHintsPermanentlyHidden(hidden) }
        }
        panel.onInputEvent = { [weak self, weak canvas] event in
            if let canvas { self?.handleColorFormatGesture(event, from: canvas) }
        }
        panel.onResignKey = { [weak self] in
            self?.shiftDown = false
            self?.shiftAlone = false
            self?.keyboardPointerCanvas?.endKeyboardPointer()
        }
        canvas.onChooseAnchorMode = { [weak self, weak panel] in
            guard let self, let panel else { return }
            let target = panel.canvas.selection == nil
                ? self.panel(at: self.mouseLocation()) ?? panel
                : panel
            self.panels.filter { $0 !== target }.forEach { $0.canvas.clearSelection() }
            target.makeKeyAndOrderFront(nil)
            target.canvas.beginAnchors()
        }
        canvas.onRestoreRegion = { [weak self] backward in self?.restoreRegion(backward: backward) }
        canvas.onSelectionChanged = { [weak self] in self?.recalledRegionIndex = nil }
        canvas.onToggleWindowsOnly = { [weak self, weak canvas] in
            if let canvas { self?.toggleWindowsOnly(from: canvas) }
        }
        canvas.onProbeElement = { [weak self, weak panel] target, localPoint in
            guard let self, let panel else { return }
            self.probeElement(target: target, localPoint: localPoint, on: panel)
        }
        canvas.onChooseDisplay = { [weak self, weak panel] in
            self?.panels.filter { $0 !== panel }.forEach { $0.canvas.clearSelection() }
        }
        canvas.onCopy = { [weak self, weak canvas] in
            if let canvas { self?.copy(canvas) }
        }
        canvas.onCopyText = { [weak self, weak canvas] in
            if let canvas { self?.copyText(canvas) }
        }
        canvas.canSampleDisplay = { [weak self, weak canvas] in
            self?.panels.allSatisfy { $0.canvas === canvas || $0.canvas.selection == nil } ?? false
        }
        canvas.onCopyColor = { [weak self] in self?.copyColor() }
        canvas.onNudgePointer = { [weak self, weak panel] dx, dy in
            guard let self, let panel else { return }
            self.nudgePointer(dx: dx, dy: dy, from: panel)
        }
        canvas.onPin = { [weak self, weak canvas] in
            guard let self, let canvas, let selection = canvas.selection, let window = canvas.window,
                  let image = output(canvas), let data = png(image), let picture = PinPicture(cgImage: image, png: data) else { return }
            let frame = window.convertToScreen(canvas.convert(selection, to: nil))
            let region = regionMemory(canvas)
            let snapshot = historySnapshot(canvas)
            cancel()
            if ScreenPins.shared.show(picture, at: frame, pasteboard: pasteboard) != nil {
                rememberRegion(region)
                rememberCaptureHistory(snapshot)
            }
        }
        let display = screen.displayID
        canvas.onScrollCapture = { [weak self, weak canvas] in
            guard let self, let canvas, let selection = canvas.selection, let window = canvas.window,
                  canvas.marks.isEmpty, canvas.polygon == nil else { return }
            let region = ScrollCaptureRegion(display: display, screen: window.frame, photo: canvas.photo, selection: selection)
            let remembered = regionMemory(canvas)
            hidePanels()
            panels.removeAll()
            let token = session
            let capture = ScrollingCapture(region: region, clipboard: captureClipboard) { [weak self] in
                if self?.session == token { self?.cancel() }
            }
            capture.onExport = { [weak self] in self?.rememberRegion(remembered) }
            scrolling = capture
            capture.start(makeSource: makeScrollSource)
        }
        canvas.onSave = { [weak self, weak canvas] forcePrompt in
            if let canvas { self?.save(canvas, forcePrompt: forcePrompt) }
        }
        canvas.onCancel = { [weak self] in self?.cancel() }
        panels.append(panel)
    }

    private func toggleWindowsOnly(from activeCanvas: CaptureCanvas) {
        windowsOnly.toggle()
        colorDefaults.set(windowsOnly, forKey: Self.windowsOnlyKey)
        for panel in panels {
            panel.canvas.setWindowsOnly(windowsOnly, announce: panel.canvas === activeCanvas)
        }
    }

    private func scheduleVisualAnalysis(for target: CaptureWindowTarget, on panel: CapturePanel) {
        guard !windowsOnly, target.windowID != 0,
              visualAnalyzedWindows.insert(target.windowID).inserted,
              let token = session else { return }
        let displayID = panel.displayID
        let photo = panel.canvas.photo
        let windowID = target.windowID
        let localRect = target.localRect
        let detect = detectVisualRegions
        visualQueue.async { [weak self] in
            let regions = detect(photo, localRect)
            guard !regions.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.session == token, !self.panels.isEmpty,
                      let targetPanel = self.panels.first(where: { $0.displayID == displayID }) else { return }
                targetPanel.canvas.addDiscoveredControls(regions, for: windowID)
            }
        }
    }

    private func prewarmVisualRegions(on panel: CapturePanel) {
        guard !windowsOnly else { return }
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        if let frontWindow = panel.canvas.windowTargets.first(where: { $0.layer == normalLevel }) {
            scheduleVisualAnalysis(for: frontWindow, on: panel)
        }
    }

    private func probeElement(target: CaptureWindowTarget, localPoint: CGPoint, on panel: CapturePanel) {
        guard !windowsOnly else { return }

        // 引擎 1：基于冻结像素的一次性窗口视觉分区与闭合框检测（覆盖 Electron / Chrome / 微信 / Flutter / 本进程及所有窗口）。
        scheduleVisualAnalysis(for: target, on: panel)

        // 引擎 2：原生窗口按需 AX 指针探测（与视觉分区互补，提供精确按钮/列表/图标边界）。
        guard target.supportsAXProbe, axGate.allowed(target.windowID), Permissions.accessibility else { return }
        let cell = CaptureAXProbeCell(windowID: target.windowID, cellX: Int(floor(localPoint.x / 6)), cellY: Int(floor(localPoint.y / 6)))
        guard !probedCells.contains(cell), inFlightAXCell != cell else { return }
        inFlightAXCell = cell
        if axProbe == nil {
            axProbe = CaptureAXProbe { [weak self] answer in
                self?.handleAXProbeAnswer(answer)
            }
        }
        let axPoint = CaptureWindowSnapshot.axPoint(for: localPoint, in: panel.axFrame)
        axProbe?.ask(CaptureAXProbe.Request(
            displayID: panel.displayID,
            screenAXFrame: panel.axFrame,
            target: target,
            axPoint: axPoint,
            cell: cell
        ))
    }

    private func handleAXProbeAnswer(_ answer: CaptureAXProbe.Answer) {
        guard session != nil, !panels.isEmpty else { return }
        // 仅在某格实际完成探测后标记已探，避免被合并跳过的中间格永久失效。
        probedCells.insert(answer.cell)
        if inFlightAXCell == answer.cell { inFlightAXCell = nil }
        axGate.record(answer.windowID, elapsedMs: answer.elapsedMs, controlCount: answer.localControls.count)
        guard answer.ok, answer.elapsedMs <= CaptureAXProbeGate.budgetMs, !answer.localControls.isEmpty else { return }
        guard let panel = panels.first(where: { $0.displayID == answer.displayID }) else { return }
        panel.canvas.addDiscoveredControls(answer.localControls, for: answer.windowID)
    }

    private func stopAXProbe() {
        axProbe?.stop()
        axProbe = nil
        axGate.reset()
        probedCells.removeAll()
        inFlightAXCell = nil
        visualAnalyzedWindows.removeAll()
    }

    private func historySnapshot(_ canvas: CaptureCanvas) -> CaptureHistorySnapshot? {
        guard browsingHistoryIndex == nil,
              let panel = canvas.window as? CapturePanel,
              let selection = canvas.selection else { return nil }
        return CaptureHistorySnapshot(
            displayID: panel.displayID,
            photo: canvas.photo,
            selection: selection,
            polygon: canvas.polygon,
            marks: canvas.marks
        )
    }

    private func rememberCaptureHistory(_ snapshot: CaptureHistorySnapshot?) {
        guard let snapshot else { return }
        captureHistory.insert(snapshot, at: 0)
        if captureHistory.count > Self.captureHistoryLimit {
            captureHistory.removeLast(captureHistory.count - Self.captureHistoryLimit)
        }
    }

    private func stepCaptureHistory(older: Bool, from sourcePanel: CapturePanel) {
        let matching: [(snapshot: CaptureHistorySnapshot, panel: CapturePanel)] = captureHistory.compactMap { entry in
            guard let target = panels.first(where: { $0.displayID == entry.displayID && $0.canvas.bounds.size == entry.screenSize }) else {
                return nil
            }
            return (entry, target)
        }
        guard !matching.isEmpty else {
            sourcePanel.canvas.showNotice(L("暂无历史截图"))
            return
        }
        let nextIndex: Int?
        if let current = browsingHistoryIndex {
            if older {
                if current + 1 >= matching.count {
                    sourcePanel.canvas.showNotice(L("已是最早的历史截图（%ld/%ld）", matching.count, matching.count))
                    return
                }
                nextIndex = current + 1
            } else {
                nextIndex = current > 0 ? current - 1 : nil
            }
        } else {
            guard older else { return }
            nextIndex = 0
        }

        if let nextIndex {
            let chosen = matching[nextIndex]
            guard let decoded = chosen.snapshot.decodePhoto() else { return }
            browsingHistoryIndex = nextIndex
            for panel in panels where panel !== chosen.panel {
                restoreLiveSnapshot(on: panel, showNotice: false)
                panel.canvas.clearSelection()
            }
            chosen.panel.canvas.replaceSnapshot(
                photo: decoded,
                windowTargets: [],
                selection: chosen.snapshot.selection,
                polygon: chosen.snapshot.polygon,
                marks: chosen.snapshot.marks,
                noticeText: L("历史截图 %ld/%ld · , / . 翻看", nextIndex + 1, matching.count)
            )
            chosen.panel.makeKeyAndOrderFront(nil)
            chosen.panel.makeFirstResponder(chosen.panel.canvas)
        } else {
            browsingHistoryIndex = nil
            for panel in panels {
                restoreLiveSnapshot(on: panel, showNotice: panel === sourcePanel)
            }
        }
    }

    private func restoreLiveSnapshot(on panel: CapturePanel, showNotice: Bool) {
        guard let live = liveSnapshots[panel.displayID] else { return }
        if panel.canvas.photo.image !== live.photo.image || showNotice {
            panel.canvas.replaceSnapshot(
                photo: live.photo,
                windowTargets: live.targets,
                selection: nil,
                polygon: nil,
                marks: [],
                noticeText: showNotice ? L("已回到当前画面") : nil
            )
        }
    }

    private func regionMemory(_ canvas: CaptureCanvas) -> CaptureRegionMemory? {
        guard let panel = canvas.window as? CapturePanel, let selection = canvas.selection else { return nil }
        return CaptureRegionMemory(display: panel.displayID, photo: canvas.photo, selection: selection, polygon: canvas.polygon)
    }

    private func rememberRegion(_ memory: CaptureRegionMemory?) {
        guard let memory else { return }
        regionHistory.removeAll { $0 == memory }
        regionHistory.insert(memory, at: 0)
        if regionHistory.count > Self.regionHistoryLimit {
            regionHistory.removeLast(regionHistory.count - Self.regionHistoryLimit)
        }
    }

    private func restoreRegion(backward: Bool) {
        guard panels.allSatisfy({ $0.canvas.marks.isEmpty && !$0.canvas.isEditingText }) else { return }
        let matching: [(memory: CaptureRegionMemory, panel: CapturePanel)] = regionHistory.compactMap { memory in
            guard let target = panels.first(where: { memory.matches($0.displayID, $0.canvas.photo) }) else { return nil }
            return (memory, target)
        }
        guard !matching.isEmpty else { return }
        let count = matching.count
        let nextIndex: Int
        if let current = recalledRegionIndex, current < count {
            nextIndex = (current + (backward ? -1 : 1) + count) % count
        } else {
            nextIndex = backward ? count - 1 : 0
        }
        recalledRegionIndex = nextIndex
        let chosen = matching[nextIndex]
        let target = chosen.panel
        for panel in panels where panel !== target { panel.canvas.clearSelection() }
        target.canvas.restoreRegion(target.canvas.photo.pointRect(chosen.memory.rect), polygon: chosen.memory.polygon)
        if count > 1 {
            target.canvas.showNotice(L("最近选区 %ld/%ld · R / ⇧R", nextIndex + 1, count))
        }
        target.canvas.hover(at: target.convertPoint(fromScreen: mouseLocation()))
        target.makeKeyAndOrderFront(nil)
        target.makeFirstResponder(target.canvas)
    }

    private func showPanels(focusing preferred: CaptureCanvas? = nil) {
        let mouse = mouseLocation()
        FrontAppTracker.shared.captureActive.set(true)
        for panel in panels { panel.orderFrontRegardless() }
        let panel = panels.first { $0.canvas === preferred } ?? panel(at: mouse) ?? panels.first
        if let panel {
            panel.canvas.hover(at: panel.convertPoint(fromScreen: mouse))
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.canvas)
            prewarmVisualRegions(on: panel)
        }
    }

    private func hidePanels() {
        FrontAppTracker.shared.captureActive.set(false)
        shiftDown = false
        shiftAlone = false
        stopAXProbe()
        keyboardPointerCanvas?.endKeyboardPointer()
        keyboardPointerCanvas = nil
        for panel in panels {
            panel.canvas.stopDirectionRepeat()
            panel.orderOut(nil)
        }
    }

    func finishScrolling() { scrolling?.requestFinish() }
    func cancelScrolling() {
        if scrolling != nil { cancel() }
    }

    /// 屏幕参数变化、切换桌面或休眠时，只取消依赖当前冻结屏幕或实时取帧的阶段；
    /// 保存对话框、异步写盘阶段、已完成的长截图预览/标注窗口、以及后台文字识别不受影响。
    @objc private func cancelScreenBoundCapture() {
        guard session != nil else { return }
        if savePanel != nil || isSaving || isRecognizingText { return }
        if let scrolling {
            if scrolling.isSampling { cancel() }
            return
        }
        cancel()
    }

    @objc func cancel() {
        guard session != nil else { return }
        session = nil
        recalledRegionIndex = nil
        browsingHistoryIndex = nil
        liveSnapshots.removeAll()
        isSaving = false
        isRecognizingText = false
        ocrCancelled?.set(true)
        ocrCancelled = nil
        let shouldRestoreFocus = activatedForSave
        activatedForSave = false
        scrolling?.close()
        scrolling = nil
        savePanel?.cancel(nil)
        savePanel = nil
        hidePanels()
        panels.removeAll()
        if shouldRestoreFocus { restoreFocusAfterSave() }
        previousApp = nil
    }

    private func output(_ canvas: CaptureCanvas) -> CGImage? {
        guard let selection = canvas.selection else { return nil }
        let image = canvas.photo.render(selection, marks: canvas.marks, polygon: canvas.polygon)
        if image == nil { toast(L("无法生成图片，请重新选择区域。")) }
        return image
    }

    private func copy(_ canvas: CaptureCanvas) {
        if canvas.mode == .text {
            copyText(canvas)
            return
        }
        guard let image = output(canvas), session != nil else { return }
        let remembered = regionMemory(canvas)
        let snapshot = historySnapshot(canvas)
        hidePanels()
        panels.removeAll()
        cancel()
        guard let data = png(image) else { toast(L("无法生成图片，请重新选择区域。")); return }
        if captureClipboard.copy(data) {
            rememberRegion(remembered)
            rememberCaptureHistory(snapshot)
        } else {
            toast(L("未能写入剪贴板"))
        }
    }

    private func copyText(_ canvas: CaptureCanvas) {
        guard let image = output(canvas), let token = session else { return }
        hidePanels()
        panels.removeAll()
        let count = pasteboard.changeCount
        isRecognizingText = true
        let cancelled = Locked(false)
        ocrCancelled?.set(true)
        ocrCancelled = cancelled
        toast(L("正在识别文字…"))
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                ContentExtractor.recognizeTextInSubprocess(in: image, isCancelled: { cancelled.get() })
            }.value
            guard session == token, !cancelled.get() else { return }
            cancel()
            guard !text.isEmpty else { toast(L("选区里没有识别到文字")); return }
            guard pasteboard.changeCount == count else {
                toast(L("剪贴板已更改，请重新取字")); return
            }
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if write(item) { toast(L("已复制识别的文字")) }
        }
    }

    private func colorUnderPointer() -> (canvas: CaptureCanvas, value: String)? {
        // 键盘焦点可能仍在另一块屏幕，按实际鼠标位置找到冻结图。
        let mouse = mouseLocation()
        guard let panel = panel(at: mouse) else { return nil }
        let canvas = panel.canvas
        let point = canvas.convert(panel.convertPoint(fromScreen: mouse), from: nil)
        return canvas.colorToCopy(at: point).map { (canvas, $0) }
    }

    private func cycleColorFormat() {
        guard colorUnderPointer() != nil else { return }
        colorFormat = colorFormat.next
        colorDefaults.set(colorFormat.rawValue, forKey: Self.colorFormatKey)
        panels.forEach { $0.canvas.setColorFormat(colorFormat) }
    }

    private func handleColorFormatGesture(_ event: NSEvent, from canvas: CaptureCanvas) {
        switch event.type {
        case .flagsChanged:
            let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
            let isDown = modifiers.contains(.shift)
            let isShift = event.keyCode == KeyCode.shift || event.keyCode == KeyCode.rightShift
            defer { shiftDown = isDown }
            if isShift, !shiftDown, isDown {
                shiftAlone = modifiers == .shift && canvas.mode == .image && !canvas.isDragging
                    && !canvas.hasHeldDirection && !canvas.isEditingText
            } else {
                let shouldCycle = isShift && shiftDown && !isDown && modifiers.isEmpty && shiftAlone
                shiftAlone = false
                if shouldCycle { cycleColorFormat() }
            }
        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            shiftAlone = false
        default: break
        }
    }

    private func copyColor() {
        guard let (canvas, value) = colorUnderPointer() else { return }
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        guard write(item) else { return }
        if canvas.polygon != nil || canvas.annotations.canUndo || canvas.annotations.canRedo {
            canvas.showColorCopied()
        } else {
            cancel()
            toast(L("已复制色值 %@", value))
        }
    }

    private func nudgePointer(dx: Int, dy: Int, from source: CapturePanel) {
        let mouse = mouseLocation()
        // 按住鼠标时，继续调整拖动开始的那块屏幕。
        let target = source.canvas.isDragging ? source : panel(at: mouse) ?? source
        let canvas = target.canvas
        let point = canvas.effectivePointer(at: canvas.convert(target.convertPoint(fromScreen: mouse), from: nil))
        let moved = canvas.photo.nudgedPointer(point, dx: dx, dy: dy)
        guard moved != point else { return }
        let screenPoint = target.convertPoint(toScreen: canvas.convert(moved, to: nil))
        // Retina 相邻两个像素可能落在同一个系统坐标，避免在这个位置重复移动系统光标。
        let systemPoint = CGPoint(x: floor(screenPoint.x), y: ceil(screenPoint.y))
        if mouse != systemPoint, warpPointer(screenPoint) != .success { return }
        // 系统移动光标不会发鼠标事件。直接更新取色、悬停或拖动终点。
        let systemPosition = canvas.convert(target.convertPoint(fromScreen: mouseLocation()), from: nil)
        if keyboardPointerCanvas !== canvas {
            keyboardPointerCanvas?.endKeyboardPointer()
            keyboardPointerCanvas = canvas
        }
        canvas.nudgePointer(to: moved, systemPosition: systemPosition)
    }

    private func panel(at mouse: CGPoint) -> CapturePanel? {
        // AppKit 换算后，最上面一行像素落在 maxY。
        panels.first { panel in
            let frame = panel.frame
            return mouse.x >= frame.minX && mouse.x < frame.maxX && mouse.y > frame.minY && mouse.y <= frame.maxY
        } ?? panels.first { $0.frame.contains(mouse) }
    }

    /// 由既有 ClipboardWatcher 按记录开关、权限和大小限制入库。
    private func write(_ item: NSPasteboardItem) -> Bool {
        pasteboard.clearContents()
        let ok = pasteboard.writeObjects([item])
        if !ok { toast(L("未能写入剪贴板")) }
        return ok
    }

    private func png(_ image: CGImage) -> Data? {
        CaptureImage.pngData(image)
    }

    private static func uniqueSaveURL(in directory: URL, baseName: String) -> URL {
        let fm = FileManager.default
        let initial = directory.appendingPathComponent("\(baseName).png")
        if !fm.fileExists(atPath: initial.path) { return initial }
        for index in 2 ... 999 {
            let candidate = directory.appendingPathComponent("\(baseName) (\(index)).png")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(baseName)-\(UUID().uuidString.prefix(6)).png")
    }

    private func save(_ canvas: CaptureCanvas, forcePrompt: Bool = false) {
        guard savePanel == nil, let token = session, let image = output(canvas) else { return }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let baseName = L("截图 %@", date.string(from: Date()))

        if !forcePrompt, let directory = defaultSaveDirectory() {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
                let targetURL = Self.uniqueSaveURL(in: directory, baseName: baseName)
                let remembered = regionMemory(canvas)
                let snapshot = historySnapshot(canvas)
                hidePanels()
                isSaving = true
                Task {
                    let error: Error? = await Task.detached(priority: .userInitiated) {
                        do {
                            guard let data = CaptureImage.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
                            try data.write(to: targetURL, options: .atomic)
                            return nil
                        } catch { return error }
                    }.value
                    guard self.session == token else { return }
                    self.isSaving = false
                    if let error {
                        self.showMessage(L("无法保存截图"), detail: error.localizedDescription)
                        self.showPanels(focusing: canvas)
                        return
                    }
                    self.rememberRegion(remembered)
                    self.rememberCaptureHistory(snapshot)
                    self.cancel()
                    self.toast(L("已保存截图 · %@", targetURL.lastPathComponent))
                }
                return
            }
        }

        hidePanels()
        let panel = NSSavePanel()
        savePanel = panel
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(baseName).png"
        activatedForSave = true
        NSApp.activate()
        let snapshot = historySnapshot(canvas)
        panel.begin { [weak self, weak canvas] response in
            guard let self, session == token, let canvas else { return }
            savePanel = nil
            if response == .OK, let url = panel.url {
                let remembered = regionMemory(canvas)
                isSaving = true
                Task {
                    let error: Error? = await Task.detached(priority: .userInitiated) {
                        do {
                            guard let data = CaptureImage.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
                            try data.write(to: url, options: .atomic)
                            return nil
                        } catch { return error }
                    }.value
                    guard self.session == token else { return }
                    self.isSaving = false
                    if let error {
                        self.showMessage(L("无法保存截图"), detail: error.localizedDescription)
                        self.showPanels(focusing: canvas)
                        return
                    }
                    self.rememberRegion(remembered)
                    self.rememberCaptureHistory(snapshot)
                    self.cancel()
                }
                return
            }
            // 取消保存回到选区时不要先激活原前台应用，以免异步切走焦点令选区快捷键失效；
            // 焦点会在本次截图结束时由 cancel() 统一还回。
            showPanels(focusing: canvas)
        }
    }

    /// 非激活式选区面板不改变前台程序；只有系统保存对话框需要把焦点交回去。
    private func restoreFocusAfterSave() {
        if NSApp.isActive, let previousApp, previousApp != .current { previousApp.activate(options: []) }
    }

    private func showMessage(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }

    private func toast(_ message: String) {
        notice?.orderOut(nil)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 28, height: label.frame.height + 18)
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 20,
                           width: size.width, height: size.height).integral
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 选区面板在 .screenSaver 层，选区期间弹出的错误提示必须浮在其上方才可见。
        panel.level = panels.isEmpty ? .popUpMenu : NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        let card = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        card.material = .popover
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 9
        label.setFrameOrigin(CGPoint(x: 14, y: 9))
        card.addSubview(label)
        panel.contentView = card
        notice = panel
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak panel] in
            if self?.notice === panel { panel?.orderOut(nil); self?.notice = nil }
        }
    }
}
