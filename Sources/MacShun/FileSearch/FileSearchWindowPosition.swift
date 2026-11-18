// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// The search bar stays anchored while results or the expanded body change size.
struct FileSearchWindowPosition: Codable {
    static let defaultsKey = "fileSearch.windowPosition"
    let point: CGPoint

    init(point: CGPoint) { self.point = point }

    init(frame: CGRect) {
        point = CGPoint(x: frame.midX, y: frame.maxY)
    }

    func frame(size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let x = min(max(point.x - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(point.y - height, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func isOn(_ frame: CGRect) -> Bool {
        point.x.isFinite && point.y.isFinite && frame.contains(CGPoint(x: point.x, y: point.y - 1))
    }
}

struct FileSearchExpandedGeometry: Codable {
    static let defaultsKey = "fileSearch.expandedGeometry"
    static let defaultSize = CGSize(width: 920, height: 600)
    let position: FileSearchWindowPosition
    let size: CGSize

    static func resizedFrame(_ frame: CGRect, by delta: CGSize, in visible: CGRect) -> CGRect {
        let maxWidth = max(1, visible.maxX - frame.minX)
        let maxHeight = max(1, frame.maxY - visible.minY)
        let width = min(max(frame.width + delta.width, min(420, maxWidth)), maxWidth)
        let height = min(max(frame.height - delta.height, min(310, maxHeight)), maxHeight)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }
}

struct FileSearchWindowGrip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var interaction = Interaction()
    let height: CGFloat
    let toggle: () -> Void

    var body: some View {
        let hovering = interaction.hovering
        let pressed = interaction.pressed
        let changesSize = !reduceMotion && (hovering || pressed)
        return Capsule()
            .fill(Color.primary.opacity(pressed ? 0.68 : hovering ? 0.46 : 0.24))
            .frame(width: changesSize ? (pressed ? 36 : 43) : 31, height: changesSize ? 4 : 3)
            .frame(width: 84, height: height)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: pressed)
            .overlay {
                FileSearchDragRegion(toggle: toggle, onHover: { interaction.hovering = $0 },
                                     onPress: { interaction.pressed = $0 })
            }
            .accessibilityHidden(true)
    }

    private final class Interaction: ObservableObject {
        @Published var hovering = false
        @Published var pressed = false
    }
}

/// Only this hit area moves the window. The field editor and list handle their own drags.
struct FileSearchDragRegion: NSViewRepresentable {
    let toggle: () -> Void
    var onHover: ((Bool) -> Void)? = nil
    var onPress: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.toolTip = L("拖动窗口，双击展开或收起")
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.toggle = toggle
        view.onHover = onHover
        view.onPress = onPress
    }

    final class DragView: NSView {
        var toggle: () -> Void = {}
        var onHover: ((Bool) -> Void)?
        var onPress: ((Bool) -> Void)?
        private var pointerTracking: NSTrackingArea?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let panel = window as? FileSearchPanel else { return }
            if event.clickCount == 2 {
                toggle()
                return
            }
            panel.beginHandleDrag(at: panel.convertPoint(toScreen: event.locationInWindow)) { [weak self] in
                self?.releaseGrip()
            }
            onPress?(true)
            NSCursor.closedHand.set()
        }

        private func releaseGrip() {
            onPress?(false)
            let inside = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
            onHover?(inside)
            if inside { NSCursor.openHand.set() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                                          owner: self, userInfo: nil)
            addTrackingArea(tracking)
            pointerTracking = tracking
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

struct FileSearchResizeRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> ResizeView {
        let view = ResizeView()
        view.toolTip = L("拖动调整面板大小")
        return view
    }

    func updateNSView(_ view: ResizeView, context: Context) {}

    final class ResizeView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let panel = window as? FileSearchPanel else { return }
            panel.beginHandleDrag(at: panel.convertPoint(toScreen: event.locationInWindow), resizing: true)
        }

        override func resetCursorRects() {
            if #available(macOS 15, *) {
                addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
            } else {
                addCursorRect(bounds, cursor: .crosshair)
            }
        }
    }
}
