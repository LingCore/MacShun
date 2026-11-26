// SPDX-License-Identifier: MIT

import AppKit

/// 截图选区的尺寸/比例预设（如 `1920x1080` 表示物理像素尺寸，`16:9` 表示锁定宽高比）。
struct CaptureSizePreset: Equatable {
    static let maxValue = 99999
    static let limit = 12
    static let defaultsString = "1920x1080,1280x720,800x600,16:9,4:3,1:1"

    let width: Int
    let height: Int
    let isRatio: Bool

    var ratioValue: CGFloat {
        height > 0 ? CGFloat(width) / CGFloat(height) : 1
    }

    var serialized: String {
        "\(width)\(isRatio ? ":" : "x")\(height)"
    }

    var displayTitle: String {
        isRatio ? "\(width) : \(height)" : "\(width) × \(height)"
    }

    static func parse(_ raw: String) -> CaptureSizePreset? {
        let compact = raw.filter { !$0.isWhitespace }.lowercased()
        guard let sepIndex = compact.firstIndex(where: { "x×*:：".contains($0) }),
              sepIndex > compact.startIndex,
              sepIndex < compact.index(before: compact.endIndex) else { return nil }
        let sep = compact[sepIndex]
        let wStr = compact[..<sepIndex]
        let hStr = compact[compact.index(after: sepIndex)...]
        guard let w = Int(wStr), let h = Int(hStr),
              w >= 1, h >= 1, w <= maxValue, h <= maxValue else { return nil }
        return CaptureSizePreset(width: w, height: h, isRatio: sep == ":" || sep == "：")
    }

    static func parseList(_ raw: String, limit: Int = limit) -> [CaptureSizePreset] {
        var result: [CaptureSizePreset] = []
        for part in raw.split(separator: ",") {
            guard let preset = parse(String(part)), !result.contains(preset) else { continue }
            result.append(preset)
            if result.count >= limit { break }
        }
        return result
    }

    static func serialize(_ list: [CaptureSizePreset]) -> String {
        list.map(\.serialized).joined(separator: ",")
    }
}

/// 原地尺寸编辑与预设面板：点击 `W × H px` 气泡或按 `F` 呼出，支持输入精确像素、锁比例与快选预设。
@MainActor
final class CaptureSizePopoverView: NSView, NSTextFieldDelegate {
    private let widthField = NSTextField()
    private let timesLabel = NSTextField(labelWithString: "×")
    private let heightField = NSTextField()
    private let lockButton = NSButton()
    private let addButton = NSButton()
    private let closeButton = NSButton()
    private let presetsContainer = NSView()
    private var presetRows: [NSView] = []

    private var presets: [CaptureSizePreset] = []
    private var ratioLocked = false
    private var lockedRatio: CGFloat = 1
    private var leadWidth = true
    private var suppressFieldChange = false

    var onApplyPixelSize: ((_ width: Int, _ height: Int) -> Void)?
    var onToggleRatioLock: ((_ ratio: CGFloat?) -> Void)?
    var onSelectPreset: ((CaptureSizePreset) -> Void)?
    var onAddPreset: ((CaptureSizePreset) -> Void)?
    var onRemovePreset: ((CaptureSizePreset) -> Void)?
    var onClose: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        self.shadow = shadow

        for field in [widthField, heightField] {
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.alignment = .center
            field.bezelStyle = .roundedBezel
            field.controlSize = .small
            field.delegate = self
            field.placeholderString = field === widthField ? "W" : "H"
            addSubview(field)
        }
        timesLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timesLabel.textColor = .secondaryLabelColor
        timesLabel.alignment = .center
        addSubview(timesLabel)

        configureButton(lockButton, symbol: "lock.open", tip: L("锁定宽高比"), action: #selector(toggleLock))
        configureButton(addButton, symbol: "plus", tip: L("保存为预设尺寸"), action: #selector(saveCurrentPreset))
        configureButton(closeButton, symbol: "xmark", tip: L("关闭（Esc）"), action: #selector(closeTapped))

        addSubview(presetsContainer)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureButton(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        addSubview(button)
    }

    func update(pixelWidth: Int, pixelHeight: Int, lockedRatio: CGFloat?, presets: [CaptureSizePreset]) {
        self.presets = presets
        self.ratioLocked = lockedRatio != nil
        if let lockedRatio, lockedRatio > 0 {
            self.lockedRatio = lockedRatio
        } else if pixelWidth > 0, pixelHeight > 0 {
            self.lockedRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        }

        suppressFieldChange = true
        widthField.stringValue = pixelWidth > 0 ? "\(pixelWidth)" : ""
        heightField.stringValue = pixelHeight > 0 ? "\(pixelHeight)" : ""
        suppressFieldChange = false

        refreshLockAppearance()
        rebuildPresetRows()
        layoutContent()
        updateAddButtonState()
    }

    func focusWidthField() {
        window?.makeFirstResponder(widthField)
        widthField.selectText(nil)
    }

    private func refreshLockAppearance() {
        let symbol = ratioLocked ? "lock.fill" : "lock.open"
        lockButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L("锁定宽高比"))?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        lockButton.contentTintColor = ratioLocked ? .controlAccentColor : .labelColor
        lockButton.layer?.backgroundColor = ratioLocked
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
    }

    private func rebuildPresetRows() {
        presetRows.forEach { $0.removeFromSuperview() }
        presetRows.removeAll()

        let rowH: CGFloat = 26
        let width: CGFloat = 228
        var y: CGFloat = 0
        for (idx, preset) in presets.enumerated() {
            let row = NSView(frame: CGRect(x: 0, y: y, width: width, height: rowH))
            let pick = NSButton(frame: CGRect(x: 0, y: 0, width: width - 24, height: rowH))
            pick.isBordered = false
            pick.alignment = .left
            pick.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let badge = preset.isRatio ? L("比例") : "px"
            pick.title = "  \(preset.displayTitle)   \(badge)"
            pick.tag = idx
            pick.target = self
            pick.action = #selector(pickPreset(_:))
            row.addSubview(pick)

            let del = NSButton(frame: CGRect(x: width - 24, y: 2, width: 22, height: 22))
            del.isBordered = false
            del.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("删除预设"))?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
            del.contentTintColor = .secondaryLabelColor
            del.tag = idx
            del.target = self
            del.action = #selector(removePreset(_:))
            row.addSubview(del)

            presetsContainer.addSubview(row)
            presetRows.append(row)
            y += rowH
        }
        presetsContainer.frame = CGRect(x: 8, y: 42, width: width, height: y)
    }

    private func layoutContent() {
        let pad: CGFloat = 8
        let fieldW: CGFloat = 58
        let rowH: CGFloat = 24
        widthField.frame = CGRect(x: pad, y: pad, width: fieldW, height: rowH)
        timesLabel.frame = CGRect(x: widthField.frame.maxX + 2, y: pad + 3, width: 14, height: 18)
        heightField.frame = CGRect(x: timesLabel.frame.maxX + 2, y: pad, width: fieldW, height: rowH)
        lockButton.frame = CGRect(x: heightField.frame.maxX + 6, y: pad, width: 24, height: rowH)
        addButton.frame = CGRect(x: lockButton.frame.maxX + 4, y: pad, width: 24, height: rowH)
        closeButton.frame = CGRect(x: addButton.frame.maxX + 4, y: pad, width: 24, height: rowH)

        let totalW = closeButton.frame.maxX + pad
        let totalH = presets.isEmpty ? (pad * 2 + rowH) : (presetsContainer.frame.maxY + pad)
        setFrameSize(CGSize(width: totalW, height: totalH))
    }

    private func parsedInt(_ field: NSTextField) -> Int? {
        let digits = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Int(digits), v >= 1, v <= CaptureSizePreset.maxValue else { return nil }
        return v
    }

    private func updateAddButtonState() {
        if let w = parsedInt(widthField), let h = parsedInt(heightField) {
            let candidate = CaptureSizePreset(width: w, height: h, isRatio: false)
            addButton.isEnabled = presets.count < CaptureSizePreset.limit && !presets.contains(candidate)
        } else {
            addButton.isEnabled = false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !suppressFieldChange, let field = obj.object as? NSTextField else { return }
        let filtered = field.stringValue.filter(\.isNumber)
        if filtered != field.stringValue { field.stringValue = filtered }
        leadWidth = field === widthField
        if ratioLocked, lockedRatio > 0 {
            suppressFieldChange = true
            if leadWidth, let w = parsedInt(widthField) {
                let h = max(1, min(CaptureSizePreset.maxValue, Int((CGFloat(w) / lockedRatio).rounded())))
                heightField.stringValue = "\(h)"
            } else if !leadWidth, let h = parsedInt(heightField) {
                let w = max(1, min(CaptureSizePreset.maxValue, Int((CGFloat(h) * lockedRatio).rounded())))
                widthField.stringValue = "\(w)"
            }
            suppressFieldChange = false
        }
        updateAddButtonState()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitFields(closeAfter: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            let next = control === widthField ? heightField : widthField
            window?.makeFirstResponder(next)
            next.selectText(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) || commandSelector == #selector(NSResponder.moveDown(_:)) {
            guard let field = control as? NSTextField else { return false }
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            let step = (commandSelector == #selector(NSResponder.moveUp(_:)) ? 1 : -1) * (shift ? 10 : 1)
            let current = parsedInt(field) ?? 0
            let next = max(1, min(CaptureSizePreset.maxValue, current + step))
            field.stringValue = "\(next)"
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            commitFields(closeAfter: false)
            return true
        }
        return false
    }

    private func commitFields(closeAfter: Bool) {
        if let w = parsedInt(widthField), let h = parsedInt(heightField) {
            onApplyPixelSize?(w, h)
        }
        if closeAfter { onClose?() }
    }

    @objc private func toggleLock() {
        ratioLocked.toggle()
        if ratioLocked {
            if let w = parsedInt(widthField), let h = parsedInt(heightField) {
                lockedRatio = CGFloat(w) / CGFloat(h)
            }
            onToggleRatioLock?(lockedRatio)
        } else {
            onToggleRatioLock?(nil)
        }
        refreshLockAppearance()
    }

    @objc private func saveCurrentPreset() {
        guard let w = parsedInt(widthField), let h = parsedInt(heightField) else { return }
        onAddPreset?(CaptureSizePreset(width: w, height: h, isRatio: false))
    }

    @objc private func pickPreset(_ sender: NSButton) {
        guard presets.indices.contains(sender.tag) else { return }
        onSelectPreset?(presets[sender.tag])
    }

    @objc private func removePreset(_ sender: NSButton) {
        guard presets.indices.contains(sender.tag) else { return }
        onRemovePreset?(presets[sender.tag])
    }

    @objc private func closeTapped() {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}
