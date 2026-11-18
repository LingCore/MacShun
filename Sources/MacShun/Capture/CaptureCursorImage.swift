// SPDX-License-Identifier: MIT

import AppKit

/// 按显示器的实际像素挑选系统光标图像，保留它在辅助功能放大后的尺寸和热点。
@MainActor
struct CaptureCursorImage {
    let bitmap: CGImage
    let size: CGSize
    let anchor: CGPoint

    init?(cursor: NSCursor, magnification: CGFloat, backingScale: CGFloat) {
        let image = cursor.image
        let original = image.size
        guard original.width > 0, original.height > 0 else { return nil }
        let pixels = CGSize(width: max(1, (original.width * magnification * backingScale).rounded()),
                            height: max(1, (original.height * magnification * backingScale).rounded()))
        let representations = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .sorted { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        let best = representations.first { CGFloat($0.pixelsWide) >= pixels.width && CGFloat($0.pixelsHigh) >= pixels.height }
            ?? representations.last
        var rect = CGRect(origin: .zero, size: pixels)
        guard let bitmap = best?.cgImage ?? image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }

        self.bitmap = bitmap
        size = CGSize(width: pixels.width / backingScale, height: pixels.height / backingScale)
        anchor = CGPoint(x: cursor.hotSpot.x / original.width, y: 1 - cursor.hotSpot.y / original.height)
    }

    static func magnification(in defaults: UserDefaults?) -> CGFloat {
        let scale = defaults?.double(forKey: "mouseDriverCursorSize") ?? 1
        return scale.isFinite && scale >= 1 ? CGFloat(scale) : 1
    }
}
