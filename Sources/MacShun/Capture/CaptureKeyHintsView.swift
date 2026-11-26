// SPDX-License-Identifier: MIT

import AppKit

/// 角落上下文快捷键浮卡（参考 WinShun CaptureKeyHints / PixPin）：
/// 仅展示当前截图阶段可用的键帽，自动避让选区/工具栏，指针靠近时半透明以免遮挡画面。
@MainActor
final class CaptureKeyHintsView: NSView {
    struct Row: Equatable {
        let keys: [String]
        let label: String
    }

    private let contentStack = NSView()
    private let divider = NSBox()
    private let footerButton = NSButton()
    private var currentRows: [Row] = []
    private var permanentlyHidden = false

    var onTogglePermanentHide: (() -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.76).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1

        addSubview(contentStack)
        divider.boxType = .separator
        divider.alphaValue = 0.25
        addSubview(divider)

        footerButton.isBordered = false
        footerButton.font = .systemFont(ofSize: 11, weight: .medium)
        footerButton.contentTintColor = NSColor.white.withAlphaComponent(0.78)
        footerButton.target = self
        footerButton.action = #selector(footerTapped)
        addSubview(footerButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(rows: [Row], permanentlyHidden: Bool) {
        let changed = rows != currentRows || permanentlyHidden != self.permanentlyHidden
        guard changed else { return }
        currentRows = rows
        self.permanentlyHidden = permanentlyHidden
        rebuild()
    }

    private func rebuild() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        let padX: CGFloat = 11
        let padY: CGFloat = 9
        let rowH: CGFloat = 20
        let rowGap: CGFloat = 5
        let capGap: CGFloat = 4
        let colGap: CGFloat = 10

        var keyColumnWidth: CGFloat = 0
        var labelColumnWidth: CGFloat = 0
        let capFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)

        struct MeasuredRow {
            let capWidths: [CGFloat]
            let keysTotal: CGFloat
            let labelWidth: CGFloat
            let row: Row
        }

        let measured: [MeasuredRow] = currentRows.map { row in
            let capWidths = row.keys.map { key -> CGFloat in
                let w = ceil((key as NSString).size(withAttributes: [.font: capFont]).width)
                return max(20, w + 10)
            }
            let keysTotal = capWidths.reduce(0, +) + CGFloat(max(0, capWidths.count - 1)) * capGap
            let labelWidth = ceil((row.label as NSString).size(withAttributes: [.font: labelFont]).width)
            keyColumnWidth = max(keyColumnWidth, keysTotal)
            labelColumnWidth = max(labelColumnWidth, labelWidth)
            return MeasuredRow(capWidths: capWidths, keysTotal: keysTotal, labelWidth: labelWidth, row: row)
        }

        var y: CGFloat = 0
        for item in measured {
            var x: CGFloat = 0
            for (i, key) in item.row.keys.enumerated() {
                let w = item.capWidths[i]
                let cap = NSTextField(labelWithString: key)
                cap.font = capFont
                cap.textColor = .white
                cap.alignment = .center
                cap.wantsLayer = true
                cap.layer?.cornerRadius = 4
                cap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                cap.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
                cap.layer?.borderWidth = 0.5
                cap.frame = CGRect(x: x, y: y + 1, width: w, height: 18)
                contentStack.addSubview(cap)
                x += w + capGap
            }
            let desc = NSTextField(labelWithString: item.row.label)
            desc.font = labelFont
            desc.textColor = NSColor.white.withAlphaComponent(0.92)
            desc.frame = CGRect(x: keyColumnWidth + colGap, y: y + 2, width: item.labelWidth + 4, height: 16)
            contentStack.addSubview(desc)
            y += rowH + rowGap
        }
        let rowsHeight = max(0, y - rowGap)
        let innerWidth = max(140, keyColumnWidth + colGap + labelColumnWidth + 4)
        contentStack.frame = CGRect(x: padX, y: padY, width: innerWidth, height: rowsHeight)

        let divY = contentStack.frame.maxY + 7
        divider.frame = CGRect(x: padX, y: divY, width: innerWidth, height: 1)

        footerButton.title = permanentlyHidden ? L("一直显示（?）") : L("不再显示（? 随时呼出）")
        footerButton.sizeToFit()
        footerButton.frame = CGRect(x: padX, y: divY + 5, width: innerWidth, height: 18)
        setFrameSize(CGSize(width: innerWidth + padX * 2, height: footerButton.frame.maxY + 7))
    }

    func updateOpacity(pointer: CGPoint?, loupeFrame: CGRect?) {
        guard !isHidden else { return }
        if let pointer {
            let buttonRect = convert(footerButton.frame, to: superview)
            if buttonRect.contains(pointer) {
                alphaValue = 1
                return
            }
            if frame.insetBy(dx: -36, dy: -36).contains(pointer) {
                alphaValue = 0.16
                return
            }
        }
        if let loupeFrame, frame.intersects(loupeFrame) {
            alphaValue = 0.16
            return
        }
        alphaValue = 1
    }

    /// 只有底部按钮吃点击，其余区域透传给画布，确保在角落也能直接拖选。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return footerButton.frame.contains(local) ? footerButton : nil
    }

    @objc private func footerTapped() {
        onTogglePermanentHide?()
    }
}
