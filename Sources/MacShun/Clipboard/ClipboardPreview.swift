// SPDX-License-Identifier: MIT

import SwiftUI
import AppKit

struct ClipboardPreview: View {
    @ObservedObject var model: ClipboardPanelModel
    let item: ClipboardItem
    let showsFeedback: Bool
    @StateObject private var files = FileStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
                .id(item.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsFeedback, let feedback = model.copyFeedback {
                Text(feedback)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: item.fileURLs) {
            guard item.kind == .files else { return }
            let available = await ClipboardController.filesAvailable(item.fileURLs ?? [])
            if !Task.isCancelled { files.unavailable = !available }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("预览")).font(.headline)
                if let source = item.sourceApp {
                    Text(AppInfo.name(source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { model.cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.chip())
            .help(L("关闭预览"))
            .accessibilityLabel(L("关闭预览"))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            GeometryReader { geometry in
                let hasText = item.imageText.map { !$0.isEmpty } ?? false
                VStack(alignment: .leading, spacing: 8) {
                    ClipboardImageView(url: model.store.imageURL(for: item), cache: model.previews)
                        .aspectRatio(CGFloat(max(item.imageWidth ?? 1, 1)) / CGFloat(max(item.imageHeight ?? 1, 1)), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: min(240, geometry.size.height * (hasText ? 0.48 : 0.82)))
                    if let width = item.imageWidth, let height = item.imageHeight {
                        Text(L("图片 %@×%@", "\(width)", "\(height)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let text = item.imageText, !text.isEmpty {
                        Text(L("图中文字")).font(.caption.weight(.semibold))
                        excerpt(text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        case .text:
            excerpt(item.text ?? "")
                .padding(10)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if files.unavailable {
                        Label(L("部分文件已移动、删除或暂不可用"), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                    ForEach(Array(item.fileNames.enumerated()), id: \.offset) { _, name in
                        Text(name).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func excerpt(_ text: String) -> some View {
        let end = text.index(text.startIndex, offsetBy: 12_000, limitedBy: text.endIndex) ?? text.endIndex
        VStack(alignment: .leading, spacing: 4) {
            ClipboardPreviewText(text: String(text[..<end])) { selection in
                model.selectPreviewText(selection, for: item.id)
            }
            if end < text.endIndex {
                Text(L("预览仅显示开头，仍可粘贴完整内容"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.onCopy(item) } label: {
                Label(L("复制"), systemImage: "doc.on.doc")
            }
            Spacer(minLength: 0)
            Button { model.pastePreview(item) } label: {
                Label(model.previewSelection == nil ? L("粘贴") : L("粘贴选中文字"), systemImage: "return")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }

    private final class FileStatus: ObservableObject {
        @Published var unavailable = false
    }
}

final class ClipboardPreviewTextView: NSTextView {
    var selectedText: String? {
        let selection = selectedRange()
        guard selection.length > 0, let range = Range(selection, in: string) else { return nil }
        return String(string[range])
    }
}

private struct ClipboardPreviewText: NSViewRepresentable {
    let text: String
    let onSelection: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelection: onSelection) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = ClipboardPreviewTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onSelection = onSelection
        guard let view = scroll.documentView as? ClipboardPreviewTextView, view.string != text else { return }
        view.string = text
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.setSelectedRange(NSRange(location: 0, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelection: (String?) -> Void

        init(onSelection: @escaping (String?) -> Void) { self.onSelection = onSelection }

        func textViewDidChangeSelection(_ notification: Notification) {
            let view = notification.object as? ClipboardPreviewTextView
            onSelection(view?.selectedText)
        }
    }
}
