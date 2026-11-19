// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
final class ClipboardHoverPreview {
    private var pending: Task<Void, Never>?
    private var panel: NSPanel?

    func schedule(owner: NSPanel, content: @escaping () -> ClipboardHoverCard?) {
        cancel()
        pending = Task { [weak self, weak owner] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let owner, owner.isVisible, owner.isKeyWindow,
                  let area = owner.screen?.visibleFrame, let card = content() else { return }
            let pointer = NSEvent.mouseLocation
            guard owner.frame.contains(pointer),
                  let frame = Self.frame(beside: owner.frame, pointerY: pointer.y, in: area) else { return }
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = owner.level
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
            panel.appearance = owner.effectiveAppearance
            let host = NSHostingView(rootView: card)
            host.sizingOptions = []
            panel.contentView = host
            panel.setFrame(frame, display: false)
            owner.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
            self.panel = panel
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    static func frame(beside owner: CGRect, pointerY: CGFloat, in visible: CGRect) -> CGRect? {
        let area = visible.insetBy(dx: 8, dy: 8)
        let gap: CGFloat = 8
        let right = area.maxX - owner.maxX - gap
        let left = owner.minX - area.minX - gap
        let width = min(280, max(right, left))
        guard width >= 180, area.height > 0 else { return nil }
        let x = right >= width ? owner.maxX + gap : owner.minX - gap - width
        return WindowPlacement.fittedFrame(CGRect(x: x, y: pointerY - 84, width: width, height: 168),
                                           in: area, centered: false)
    }
}

struct ClipboardHoverCard: View {
    let item: ClipboardItem
    let imageURL: URL?
    let cache: ClipboardImageCache

    var body: some View {
        Group {
            switch item.kind {
            case .text:
                Text(String((item.text ?? "").prefix(500)))
                    .lineLimit(8)
            case .image:
                ClipboardImageView(url: imageURL, cache: cache)
            case .files:
                Text(item.fileNames.prefix(8).joined(separator: "\n"))
                    .lineLimit(8)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: item.kind == .image ? .center : .topLeading)
        .padding(12)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
