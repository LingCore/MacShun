// SPDX-License-Identifier: MIT

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private actor ScrollAssembly {
    private var stitcher: ScrollStitcher

    init?(_ image: CGImage) {
        guard let stitcher = ScrollStitcher(image) else { return nil }
        self.stitcher = stitcher
    }

    func accept(_ image: CGImage) -> (ScrollStitcher.Progress, Int) {
        (stitcher.append(image), stitcher.height)
    }

    func finish() -> (CGImage, Data)? {
        guard let image = stitcher.result() else { return nil }
        guard let png = Self.encode(image) else { return nil }
        return (image, png)
    }

    static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

@MainActor
final class ScrollingCapture: NSObject, NSWindowDelegate {
    private let region: ScrollCaptureRegion
    private let status: ScrollCaptureStatus
    private let pasteboard: NSPasteboard
    private let onClose: () -> Void
    private let hud: NSPanel
    private let outline: NSPanel
    private var preview: NSPanel?
    private var savePanel: NSSavePanel?
    private var original: CaptureImage?
    private var annotations = CaptureAnnotations()
    private var output: (image: CGImage, png: Data)?
    private var previewNotice: String?
    private weak var viewport: CaptureImageViewport?
    var onExport: (() -> Void)?
    private var sampling: Task<Void, Never>?
    private var finishRequested = false
    private var originalApp: NSRunningApplication?

    init(region: ScrollCaptureRegion, pasteboard: NSPasteboard, onClose: @escaping () -> Void) {
        self.region = region
        self.pasteboard = pasteboard
        self.onClose = onClose
        status = ScrollCaptureStatus(height: region.height)
        hud = Self.overlay()
        outline = Self.overlay()
        super.init()
        outline.ignoresMouseEvents = true
        outline.hasShadow = false
        let border = NSView()
        border.wantsLayer = true
        border.layer?.borderWidth = 2
        border.layer?.borderColor = NSColor.systemBlue.cgColor
        outline.contentView = border
        outline.setFrame(region.area.insetBy(dx: -2, dy: -2), display: true)
        hud.title = L("长截图")
        let visible = NSScreen.screens.first(where: { $0.frame == region.screen })?.visibleFrame ?? region.screen
        let width = min(460, visible.width - 12)
        let host = NSHostingView(rootView: ScrollCaptureControls(status: status,
            finish: { [weak self] in self?.requestFinish() }, cancel: { [weak self] in self?.onClose() })
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.placeControls(size: size, in: visible)
            })
        hud.contentView = host
        placeControls(size: host.fittingSize, in: visible)
    }

    private func placeControls(size: CGSize, in visible: CGRect) {
        guard size.width > 0, size.height > 0 else { return }
        let x = max(visible.minX + 6, min(region.area.maxX - size.width, visible.maxX - size.width - 6))
        let yBelow = region.area.minY - size.height - 8
        let y = yBelow >= visible.minY + 6 ? yBelow : min(region.area.maxY + 8, visible.maxY - size.height - 6)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size).integral
        if hud.frame != frame { hud.setFrame(frame, display: true) }
    }

    private static func overlay() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    func start(makeReader: @escaping ScrollCaptureSource.Factory) {
        FrontAppTracker.shared.scrollingCaptureActive.set(true)
        outline.orderFrontRegardless()
        hud.orderFrontRegardless()
        let excluded = Set([CGWindowID(hud.windowNumber), CGWindowID(outline.windowNumber)])
        sampling = Task {
            let read: ScrollCaptureSource.Reader
            let assembly: ScrollAssembly
            do {
                read = try await makeReader(region, excluded)
                try Task.checkCancellation()
                // 从同一个实时选区取第一张和后续帧，初始冻结画面的色彩转换不会被误当成滚动。
                let first = try await read()
                guard let buffer = await Task.detached(priority: .userInitiated, operation: { ScrollAssembly(first) }).value else {
                    throw ScrollCaptureError.noImage
                }
                assembly = buffer
            } catch {
                if !Task.isCancelled { fail(error) }
                return
            }
            var notice: String?
            do {
                try Task.checkCancellation()
                status.message = L("在蓝框内向下滚动，结束后点“完成”。")
                status.canFinish = true
                while !Task.isCancelled {
                    // 点完成时再取最后一帧：包括刚刚滚动、尚未轮到采样的最后几行。
                    let finalSample = finishRequested
                    let frame = try await read()
                    try Task.checkCancellation()
                    let (progress, height) = await assembly.accept(frame)
                    try Task.checkCancellation()
                    status.height = height
                    status.needsBacktrack = progress == .noOverlap
                    switch progress {
                    case .unchanged, .appended:
                        notice = nil
                        status.message = L("在蓝框内向下滚动，结束后点“完成”。")
                    case .backtracked:
                        notice = nil
                        status.message = L("已保留截过的内容，往下滚可继续。")
                    case .noOverlap:
                        notice = L("预览中只包含已成功拼接的部分。")
                        status.message = L("未找到重叠内容，请往回滚一些，再慢慢向下。")
                    case .limit:
                        notice = L("已达到长图尺寸上限，以下是已拼接的内容。")
                    }
                    if progress == .limit || finalSample { break }
                    if !finishRequested {
                        try await Task.sleep(for: .milliseconds(progress == .unchanged ? 220 : 75))
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                notice = L("取屏已停止：%@", error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            status.canFinish = false
            status.needsBacktrack = false
            status.message = L("正在生成长图预览…")
            let output = await assembly.finish()
            guard !Task.isCancelled else { return }
            guard let (image, png) = output else { fail(ScrollCaptureError.noImage); return }
            present(image, png: png, notice: notice)
        }
    }

    func requestFinish() {
        guard status.canFinish else { return }
        finishRequested = true
        status.canFinish = false
    }

    private func present(_ image: CGImage, png: Data, notice: String?) {
        FrontAppTracker.shared.scrollingCaptureActive.set(false)
        hud.orderOut(nil)
        outline.orderOut(nil)
        let visible = NSScreen.screens.first(where: { $0.frame == region.screen })?.visibleFrame ?? region.screen
        let size = CGSize(width: min(660, visible.width - 20), height: min(680, visible.height - 48))
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = L("长截图预览")
        panel.contentMinSize = CGSize(width: min(size.width, 460), height: min(size.height, 220))
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        preview = panel
        let scale = region.source.width / CGFloat(image.width)
        original = CaptureImage(image: image, size: CGSize(width: region.source.width, height: CGFloat(image.height) * scale))
        output = (image, png)
        previewNotice = notice
        showOutput()
        panel.setContentSize(size)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func showOutput(position: CGFloat = 0) {
        guard let preview, let output else { return }
        preview.title = L("长截图预览")
        preview.contentView = NSHostingView(rootView: ScrollCapturePreview(image: output.image, message: previewNotice,
            position: position, attach: { [weak self] in self?.viewport = $0 },
            edit: { [weak self] in self?.edit() }, copy: { [weak self] in
                guard let self, let data = self.output?.png else { return }
                let item = NSPasteboardItem()
                guard item.setData(data, forType: .png) else { NSSound.beep(); return }
                pasteboard.clearContents()
                if pasteboard.writeObjects([item]) { onExport?(); onClose() } else { NSSound.beep() }
            }, save: { [weak self] in
                if let self, let data = self.output?.png { save(data) }
            }, pin: { [weak self] in
                guard let self, let data = self.output?.png, let picture = PinPicture(png: data) else { return }
                if ScreenPins.shared.show(picture, pasteboard: pasteboard) != nil { onExport?(); onClose() }
            }))
    }

    private func edit() {
        guard let preview, let original, let frame = preview.contentView?.bounds else { return }
        let editor = LongCaptureEditor(photo: original, annotations: annotations, frame: frame, position: viewport?.position ?? 0,
            onDone: { [weak self] in self?.apply($0) }, onBack: { [weak self] in
                guard let self, let editor = self.preview?.contentView as? LongCaptureEditor else { return }
                showOutput(position: editor.scroller.position)
            })
        preview.title = L("标注长截图")
        preview.contentView = editor
        preview.makeFirstResponder(editor.canvas)
    }

    private func apply(_ changes: CaptureAnnotations) {
        guard let original, let preview, let editor = preview.contentView as? LongCaptureEditor else { return }
        if changes.marks == annotations.marks {
            annotations = changes
            showOutput(position: editor.scroller.position)
            return
        }
        editor.setRendering(true)
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> (CGImage, Data)? in
                guard let image = original.render(original.bounds, marks: changes.marks),
                      let data = ScrollAssembly.encode(image) else { return nil }
                return (image, data)
            }.value
            guard self.preview === preview, preview.contentView === editor else { return }
            guard let rendered else {
                editor.setRendering(false)
                _ = await NSAlert(error: ScrollCaptureError.noImage).beginSheetModal(for: preview)
                return
            }
            output = rendered
            annotations = changes
            showOutput(position: editor.scroller.position)
        }
    }

    private func save(_ png: Data) {
        guard let preview, savePanel == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = L("长截图") + ".png"
        savePanel = panel
        originalApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        panel.beginSheetModal(for: preview) { [weak self] response in
            guard let self, savePanel === panel else { return }
            savePanel = nil
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic); onExport?(); onClose() }
            catch { NSAlert(error: error).beginSheetModal(for: preview) }
        }
    }

    private func fail(_ error: Error) {
        close()
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
        onClose()
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    func close() {
        FrontAppTracker.shared.scrollingCaptureActive.set(false)
        sampling?.cancel()
        sampling = nil
        let save = savePanel
        savePanel = nil
        save?.cancel(nil)
        preview?.delegate = nil
        preview?.close()
        preview = nil
        original = nil
        output = nil
        hud.orderOut(nil)
        outline.orderOut(nil)
        if NSApp.isActive, let originalApp, originalApp != .current { originalApp.activate(options: []) }
        originalApp = nil
    }
}
