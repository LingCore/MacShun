// SPDX-License-Identifier: MIT

import SwiftUI

private final class TopDownDocument: NSView {
    override var isFlipped: Bool { true }
}

/// 长图预览和标注使用完全相同的留白、滚动方向和适宽比例。
@MainActor
final class CaptureImageViewport: NSScrollView {
    private let container = TopDownDocument()
    private let imageView: NSView
    private let photo: CaptureImage
    private var initialPosition: CGFloat?

    init(photo: CaptureImage, showing imageView: NSView, position: CGFloat) {
        self.photo = photo
        self.imageView = imageView
        initialPosition = position
        super.init(frame: .zero)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .underPageBackgroundColor
        documentView = container
        container.addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var position: CGFloat {
        let travel = container.bounds.height - contentSize.height
        return travel > 0 ? min(1, max(0, documentVisibleRect.minY / travel)) : 0
    }

    override func layout() {
        super.layout()
        let area = contentSize
        guard area.width > 24, area.height > 0 else { return }
        let width = min(area.width - 24, CGFloat(photo.image.width))
        let height = width * photo.size.height / photo.size.width
        let size = CGSize(width: area.width, height: max(area.height, height + 24))
        if container.frame.size != size { container.setFrameSize(size) }
        let frame = CGRect(x: floor((area.width - width) / 2), y: 12, width: width, height: height)
        if imageView.frame != frame || imageView.bounds != photo.bounds {
            imageView.frame = frame
            imageView.bounds = photo.bounds
        }
        if let initialPosition {
            self.initialPosition = nil
            contentView.scroll(to: CGPoint(x: 0, y: (size.height - area.height) * initialPosition))
            reflectScrolledClipView(contentView)
        }
    }
}

private final class FlatImageView: NSView {
    let photo: CaptureImage
    init(_ image: CGImage) {
        photo = CaptureImage(image: image, size: CGSize(width: image.width, height: image.height))
        super.init(frame: photo.bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let px = photo.pixelRect(dirtyRect)
        if !px.isEmpty, let crop = photo.image.cropping(to: px) {
            NSGraphicsContext.current?.cgContext.draw(crop, in: photo.pointRect(px))
        }
    }
}

struct ScrollPreviewImage: NSViewRepresentable {
    let image: CGImage
    let position: CGFloat
    let attach: (CaptureImageViewport) -> Void

    func makeNSView(context: Context) -> CaptureImageViewport {
        let imageView = FlatImageView(image)
        let view = CaptureImageViewport(photo: imageView.photo, showing: imageView, position: position)
        attach(view)
        return view
    }

    func updateNSView(_ view: CaptureImageViewport, context: Context) {}
}
