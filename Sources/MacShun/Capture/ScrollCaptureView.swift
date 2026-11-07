// SPDX-License-Identifier: MIT

import SwiftUI

@MainActor
final class ScrollCaptureStatus: ObservableObject {
    @Published var height: Int
    @Published var message = L("正在准备长截图…")
    @Published var canFinish = false
    @Published var needsBacktrack = false
    init(height: Int) { self.height = height }
}

/// 长截图的控制窗、结果页和标注页共用一套操作按钮。
struct CaptureActionButton: View {
    let title: String
    var symbol: String?
    var primary = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let button = Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title)
            }
            .font(.callout.weight(primary ? .semibold : .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minHeight: 30)
            .fixedSize()
        }
        if primary {
            button
                .foregroundStyle(.white)
                .buttonStyle(HoverTintStyle(shape: shape))
                .background(shape.fill(Color.accentColor))
                .opacity(enabled ? 1 : 0.45)
        } else {
            button.buttonStyle(.chip(cornerRadius: 7))
                .opacity(enabled ? 1 : 0.45)
        }
    }
}

struct ScrollCaptureControls: View {
    @ObservedObject var status: ScrollCaptureStatus
    let finish: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heading; Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: 8) { heading; actions }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if status.needsBacktrack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                }
                Text(status.message).foregroundStyle(status.needsBacktrack ? .primary : .secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.controlActiveState, .key)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.primary.opacity(0.16)) }
    }

    private var heading: some View {
        HStack(spacing: 8) {
            Group {
                if status.canFinish { Image(systemName: "arrow.up.and.down.text.horizontal").foregroundStyle(Color.accentColor) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
            Text(L("长截图 · %ld px", status.height)).font(.headline).monospacedDigit().fixedSize()
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            CaptureActionButton(title: L("取消"), action: cancel)
            CaptureActionButton(title: L("完成"), symbol: "checkmark", primary: true, action: finish)
                .disabled(!status.canFinish)
        }
    }
}

struct ScrollCapturePreview: View {
    let image: CGImage
    let message: String?
    let position: CGFloat
    let attach: (CaptureImageViewport) -> Void
    let edit: () -> Void
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollPreviewImage(image: image, position: position, attach: attach)
                .accessibilityLabel(L("长截图预览"))
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let message {
                    Label(message, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        dimensions
                        Spacer(minLength: 0)
                        actionStrip
                    }
                    VStack(alignment: .leading, spacing: 8) { dimensions; actionStrip }
                    VStack(alignment: .leading, spacing: 8) {
                        dimensions
                        editActions
                        exportActions
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dimensions: some View {
        Text("\(image.width) × \(image.height) px")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
    }

    private var actionStrip: some View {
        HStack(spacing: 8) {
            editActions
            Divider().frame(height: 16)
            exportActions
        }
    }

    private var editActions: some View {
        HStack(spacing: 6) {
            CaptureActionButton(title: L("标注"), symbol: "pencil", action: edit)
            CaptureActionButton(title: L("贴到屏幕"), symbol: "pin", action: pin)
        }
    }

    private var exportActions: some View {
        HStack(spacing: 6) {
            CaptureActionButton(title: L("保存 PNG…"), symbol: "square.and.arrow.down", action: save)
            CaptureActionButton(title: L("复制图片"), symbol: "doc.on.doc", primary: true, action: copy)
                .keyboardShortcut(.defaultAction)
        }
    }
}
