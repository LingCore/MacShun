// SPDX-License-Identifier: MIT

import AppKit

/// 只在系统剪贴板仍保留本次复制的截图时支持 Ctrl+V。
struct CaptureClipboard {
    static let general = CaptureClipboard(pasteboard: .general)

    let pasteboard: NSPasteboard
    private let tracker: Tracker

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        self.tracker = Tracker(pasteboard: pasteboard)
    }

    func copy(_ png: Data) -> Bool {
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png) else { return false }
        let changeCount = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        tracker.markCopied(changeCount)
        return true
    }

    /// 供主线程调用（例如剪贴板监听或应用切换时）同步最新变化计数。
    func refreshIfNeeded() {
        tracker.refreshIfNeeded()
    }

    var containsScreenshot: Bool {
        tracker.containsScreenshot
    }

    private final class Tracker: @unchecked Sendable {
        let pasteboard: NSPasteboard
        let copiedChangeCount = Locked<Int?>(nil)
        private var timer: Timer?
        private var observers: [NSObjectProtocol] = []
        private var asleep = false
        private var screenAsleep = false
        private var sessionInactive = false
        private var paused: Bool { asleep || screenAsleep || sessionInactive }

        init(pasteboard: NSPasteboard) {
            self.pasteboard = pasteboard
        }

        deinit {
            timer?.invalidate()
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        }

        func markCopied(_ changeCount: Int) {
            copiedChangeCount.set(changeCount)
            guard pasteboard === NSPasteboard.general else { return }
            let startTimer = { [weak self] in
                guard let self else { return }
                self.installObservers()
                self.scheduleTimer()
            }
            if Thread.isMainThread { startTimer() } else { DispatchQueue.main.async(execute: startTimer) }
        }

        private func scheduleTimer() {
            guard Thread.isMainThread, !paused, copiedChangeCount.get() != nil else { return }
            timer?.invalidate()
            let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshIfNeeded()
            }
            t.tolerance = 0.25
            RunLoop.main.add(t, forMode: .default)
            timer = t
        }

        private func setLifecycleFlag(_ update: (Tracker) -> Void) {
            let wasPaused = paused
            update(self)
            let nowPaused = paused
            guard wasPaused != nowPaused else { return }
            if nowPaused {
                timer?.invalidate()
                timer = nil
            } else {
                refreshIfNeeded()
                scheduleTimer()
            }
        }

        private func installObservers() {
            guard observers.isEmpty else { return }
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLifecycleFlag { $0.asleep = true }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLifecycleFlag { $0.asleep = false }
            })
            observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLifecycleFlag { $0.screenAsleep = true }
            })
            observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLifecycleFlag { $0.screenAsleep = false }
            })
            observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLifecycleFlag { $0.sessionInactive = true }
            })
            observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.setLifecycleFlag { $0.sessionInactive = false }
            })
        }

        func refreshIfNeeded() {
            guard Thread.isMainThread, let copied = copiedChangeCount.get() else { return }
            if pasteboard.changeCount != copied {
                copiedChangeCount.set(nil)
                timer?.invalidate()
                timer = nil
            }
        }

        var containsScreenshot: Bool {
            guard let copied = copiedChangeCount.get() else { return false }
            if Thread.isMainThread {
                let matches = pasteboard.changeCount == copied
                if !matches {
                    copiedChangeCount.set(nil)
                    timer?.invalidate()
                    timer = nil
                }
                return matches
            }
            // 事件拦截线程禁止调用 AppKit 的 NSPasteboard.changeCount，直接读取主线程维护的状态。
            return true
        }
    }
}
