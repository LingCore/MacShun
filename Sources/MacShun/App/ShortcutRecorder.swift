// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 录一组快捷键（鼠标侧键用）。点一下开始，按下组合键就记下，Esc 取消。
/// 录制期间暂时放行原始按键，记下用户实际按的组合。
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: WinShortcut?

    var validationMessage: ((WinShortcut) -> String?)? = nil

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton()
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.shortcut = shortcut
        button.validationMessage = validationMessage
        button.onRecord = { shortcut = $0 }
    }
}

final class ShortcutRecorderButton: NSButton {
    /// 当前正在录制的按钮及其身份标识（同一时刻最多一个）；deinit 时 weak 引用已置空，用 activeRecorderID 兜底复位全局标志。
    private static weak var activeRecorder: ShortcutRecorderButton?
    private static var activeRecorderID: ObjectIdentifier?

    var shortcut: WinShortcut? { didSet { if oldValue != shortcut { updateTitle() } } }
    var validationMessage: ((WinShortcut) -> String?)?
    var onRecord: (WinShortcut) -> Void = { _ in }
    private var windowObservers: [NSObjectProtocol] = []

    override var isEnabled: Bool {
        didSet { if !isEnabled { stopRecording() } }
    }

    private var recording = false {
        didSet {
            guard recording != oldValue else { return }
            if recording {
                if let previous = Self.activeRecorder, previous !== self {
                    previous.stopRecording()
                }
                Self.activeRecorder = self
                Self.activeRecorderID = ObjectIdentifier(self)
                FrontAppTracker.shared.recordingShortcut.set(true)
            } else if Self.activeRecorderID == ObjectIdentifier(self) {
                Self.activeRecorder = nil
                Self.activeRecorderID = nil
                FrontAppTracker.shared.recordingShortcut.set(false)
            }
            updateTitle()
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        imagePosition = .imageLeading
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    deinit {
        removeWindowObservers()
        if recording, Self.activeRecorderID == ObjectIdentifier(self) {
            Self.activeRecorder = nil
            Self.activeRecorderID = nil
            FrontAppTracker.shared.recordingShortcut.set(false)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        guard isEnabled, let window else { return }
        if window.firstResponder !== self {
            guard window.makeFirstResponder(self) else { return }
        }
        recording = true
    }

    func stopRecording() {
        if recording { recording = false }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        record(event)
    }

    /// 带 ⌘ 的键先走这里（菜单快捷键），录的时候也要接住
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        record(event)
        return true
    }

    private func record(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(.modifierKeys)
        if event.keyCode == KeyCode.escape && flags.isEmpty {
            stopRecording()
            return
        }
        let modifiers = SideButtons.modifiers(of: flags, layout: FrontAppTracker.shared.keyboardLayout.get())
        let recorded = WinShortcut(keyCode: CGKeyCode(event.keyCode), modifiers: modifiers)
        stopRecording()
        if let message = validationMessage?(recorded) {
            let alert = NSAlert()
            alert.messageText = message
            if let window { alert.beginSheetModal(for: window) }
            return
        }
        shortcut = recorded
        onRecord(recorded)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeWindowObservers()
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObservers()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.willMiniaturizeNotification,
        ]
        windowObservers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.stopRecording()
            }
        }
    }

    private func removeWindowObservers() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
    }

    private func updateTitle() {
        let keyboard = NSImage(systemSymbolName: recording ? "keyboard.fill" : "keyboard", accessibilityDescription: nil)
        image = recording ? keyboard?.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor])) : keyboard
        toolTip = recording ? L("请按快捷键（Esc 取消）") : L("点这里录快捷键")
        title = recording ? L("请按快捷键（Esc 取消）") : (shortcut?.title ?? L("点这里录快捷键"))
    }
}
