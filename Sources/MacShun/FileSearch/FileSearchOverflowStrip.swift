// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 搜索的横向筛选栏共用滚动、渐隐和溢出按钮。
struct FileSearchOverflowStrip<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var scroller = Scroller()
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            content.background { ScrollBridge(scroller: scroller) }
        }
        .scrollIndicators(.never)
        .mask {
            HStack(spacing: 0) {
                let fadeWidth: CGFloat = scroller.hovering ? 32 : 20
                if scroller.canScrollLeft {
                    fade(from: .leading, to: .trailing).frame(width: fadeWidth)
                }
                Rectangle()
                if scroller.canScrollRight {
                    fade(from: .trailing, to: .leading).frame(width: fadeWidth)
                }
            }
        }
        .overlay(alignment: .leading) { arrow(left: true, available: scroller.canScrollLeft) }
        .overlay(alignment: .trailing) { arrow(left: false, available: scroller.canScrollRight) }
        .onHover { inside in
            if inside { scroller.setHover(true) }
            else { scroller.updateHover() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: scroller.hovering)
    }

    private func fade(from: UnitPoint, to: UnitPoint) -> some View {
        LinearGradient(colors: [.clear, .black], startPoint: from, endPoint: to)
    }

    private func arrow(left: Bool, available: Bool) -> some View {
        let title = left ? L("向左滚动") : L("向右滚动")
        let shape = RoundedRectangle(cornerRadius: 6)
        let visible = scroller.hovering && available
        return Button { scroller.page(left: left) } label: {
            Image(systemName: left ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 23, height: 23)
                .background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
        .disabled(!visible)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }

    private final class Scroller: ObservableObject {
        weak var scrollView: NSScrollView?
        @Published private(set) var edges: Edge.Set = []
        @Published private(set) var hovering = false
        var canScrollLeft: Bool { edges.contains(.leading) }
        var canScrollRight: Bool { edges.contains(.trailing) }

        private var scrollRange: ClosedRange<CGFloat>? {
            guard let clip = scrollView?.contentView, clip.bounds.width > 0 else { return nil }
            let document = clip.documentRect
            return document.minX...max(document.minX, document.maxX - clip.bounds.width)
        }

        func updateEdges() {
            var available: Edge.Set = []
            if let clip = scrollView?.contentView, let range = scrollRange {
                if clip.bounds.minX - range.lowerBound > 0.5 { available.insert(.leading) }
                if range.upperBound - clip.bounds.minX > 0.5 { available.insert(.trailing) }
            }
            if available != edges { edges = available }
        }

        func updateHover() {
            guard let clip = scrollView?.contentView, let window = clip.window, window.isKeyWindow else {
                setHover(false)
                return
            }
            let pointer = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            setHover(clip.bounds.contains(clip.convert(pointer, from: nil)))
        }

        func setHover(_ inside: Bool) {
            if hovering != inside { hovering = inside }
        }

        func page(left: Bool) {
            guard let clip = scrollView?.contentView else { return }
            let step = max(24, clip.bounds.width - 48)
            scroll(by: left ? -step : step)
        }

        func scroll(by distance: CGFloat) {
            guard let scrollView, let range = scrollRange else { return }
            let clip = scrollView.contentView
            var origin = clip.bounds.origin
            origin.x = min(range.upperBound, max(range.lowerBound, origin.x + distance))
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        func handlePointer(_ event: NSEvent) -> NSEvent? {
            guard let scrollView, let window = scrollView.window else { return event }
            let clip = scrollView.contentView
            let inside = event.window === window && clip.bounds.contains(clip.convert(event.locationInWindow, from: nil))
            setHover(inside && window.isKeyWindow)
            guard inside, event.type == .scrollWheel, event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
                  let range = scrollRange, range.upperBound - range.lowerBound > 0.5 else { return event }
            // 普通滚轮按行报告，触控板按点报告。横向手势仍由原生滚动视图处理。
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            scroll(by: -event.scrollingDeltaY * scale)
            return nil
        }
    }

    private struct ScrollBridge: NSViewRepresentable {
        let scroller: Scroller

        func makeNSView(context: Context) -> Probe { Probe(scroller: scroller) }
        func updateNSView(_ view: Probe, context: Context) {}
        static func dismantleNSView(_ view: Probe, coordinator: ()) { view.disconnect() }

        final class Probe: NSView {
            private let scroller: Scroller
            private weak var observedScrollView: NSScrollView?
            private var observers: [NSObjectProtocol] = []
            private var pointerMonitor: Any?

            init(scroller: Scroller) {
                self.scroller = scroller
                super.init(frame: .zero)
            }

            deinit { disconnect() }

            required init?(coder: NSCoder) { nil }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                disconnect()
                DispatchQueue.main.async { [weak self] in self?.connect() }
            }

            private func connect() {
                guard pointerMonitor == nil, let window, let scrollView = enclosingScrollView,
                      let document = scrollView.documentView else { return }
                observedScrollView = scrollView
                scroller.scrollView = scrollView
                let clip = scrollView.contentView
                clip.postsBoundsChangedNotifications = true
                clip.postsFrameChangedNotifications = true
                document.postsFrameChangedNotifications = true
                let center = NotificationCenter.default
                for (view, name) in [(clip, NSView.boundsDidChangeNotification),
                                     (clip, NSView.frameDidChangeNotification),
                                     (document, NSView.frameDidChangeNotification)] {
                    observers.append(center.addObserver(forName: name, object: view, queue: .main) { [weak scroller] _ in
                        DispatchQueue.main.async { scroller?.updateEdges() }
                    })
                }
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak scroller] _ in
                        DispatchQueue.main.async { scroller?.updateHover() }
                    })
                }
                window.acceptsMouseMovedEvents = true
                pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp,
                                                                            .rightMouseDown, .scrollWheel]) { [weak scroller, weak window] event in
                    guard let scroller, window?.isVisible == true else { return event }
                    return scroller.handlePointer(event)
                }
                scroller.updateEdges()
                scroller.updateHover()
            }

            func disconnect() {
                if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
                pointerMonitor = nil
                observers.forEach(NotificationCenter.default.removeObserver)
                observers.removeAll()
                if scroller.scrollView === observedScrollView { scroller.scrollView = nil }
                observedScrollView = nil
            }
        }
    }
}
