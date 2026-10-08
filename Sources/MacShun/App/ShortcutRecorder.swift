// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 录一组快捷键（鼠标侧键用）。点一下开始，按下组合键就记下，Esc 取消。
/// 录的时候 Mac顺 的键盘规则先停一下，记下用户实际按的键（按 Ctrl+C 就记 Ctrl+C，不是改写后的 ⌘C）。
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: WinShortcut?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton()
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onRecord = { shortcut = $0 }
    }
}

final class ShortcutRecorderButton: NSButton {
    var shortcut: WinShortcut? { didSet { updateTitle() } }
    var onRecord: (WinShortcut) -> Void = { _ in }

    private var recording = false {
        didSet {
            FrontAppTracker.shared.recordingShortcut.set(recording)
            updateTitle()
        }
    }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func stopRecording() {
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
        shortcut = recorded
        onRecord(recorded)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func updateTitle() {
        title = recording ? L("请按快捷键（Esc 取消）") : (shortcut?.title ?? L("点这里录快捷键"))
    }
}
