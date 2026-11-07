// SPDX-License-Identifier: MIT

import SwiftUI

/// 工具条固定在窗口中；下面的画布沿用普通截图的手势和坐标，只滚动图片。
@MainActor
final class LongCaptureEditor: NSView {
    let canvas: CaptureCanvas
    let scroller: CaptureImageViewport
    private let onDone: (CaptureAnnotations) -> Void
    private let onBack: () -> Void
    private var rendering = false
    private lazy var footer = NSHostingView(rootView: EditorFooter(rendering: false,
        done: { [weak self] in self?.applyMarks() }, back: { [weak self] in self?.goBack() }))

    init(photo: CaptureImage, annotations: CaptureAnnotations, frame: CGRect, position: CGFloat,
         onDone: @escaping (CaptureAnnotations) -> Void, onBack: @escaping () -> Void) {
        self.canvas = CaptureCanvas(photo: photo, mode: .image, windowRects: [], document: annotations)
        scroller = CaptureImageViewport(photo: photo, showing: canvas, position: position)
        self.onDone = onDone
        self.onBack = onBack
        super.init(frame: frame)
        canvas.onCopy = { [weak self] in self?.applyMarks() }
        canvas.onCancel = { [weak self] in self?.goBack() }
        addSubview(canvas.toolbar)
        addSubview(scroller)
        addSubview(footer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        canvas.toolbar.fit(within: bounds.width - 12)
        let toolSize = canvas.toolbar.frame.size
        canvas.toolbar.setFrameOrigin(CGPoint(x: floor((bounds.width - toolSize.width) / 2),
                                              y: bounds.maxY - toolSize.height - 8))
        let bottom = ceil(footer.fittingSize.height)
        footer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bottom)
        scroller.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: max(1, canvas.toolbar.frame.minY - 8 - bottom))
    }

    private func goBack() { if !rendering { onBack() } }
    private func applyMarks() {
        guard !rendering else { return }
        canvas.finishText(commit: true)
        onDone(canvas.annotations)
    }

    func setRendering(_ busy: Bool) {
        rendering = busy
        footer.rootView.rendering = busy
        canvas.isHidden = busy
        canvas.toolbar.isHidden = busy
        needsLayout = true
    }
}

private struct EditorFooter: View {
    var rendering: Bool
    let done: () -> Void
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if rendering { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
                CaptureActionButton(title: L("取消"), action: back)
                CaptureActionButton(title: rendering ? L("正在应用标注…") : L("完成标注"), symbol: "checkmark",
                                    primary: true, action: done)
            }
            .disabled(rendering)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
