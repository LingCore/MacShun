// SPDX-License-Identifier: MIT

import SwiftUI

struct ClipboardPreview: View {
    @ObservedObject var model: ClipboardPanelModel
    let item: ClipboardItem
    let showsFeedback: Bool

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

    private var content: some View {
        ScrollView {
            if item.kind == .image {
                VStack(alignment: .leading, spacing: 10) {
                    ClipboardImageView(url: model.store.imageURL(for: item), cache: model.previews)
                        .aspectRatio(CGFloat(max(item.imageWidth ?? 1, 1)) / CGFloat(max(item.imageHeight ?? 1, 1)), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 240)
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
            } else {
                excerpt(item.text ?? "")
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func excerpt(_ text: String) -> some View {
        let end = text.index(text.startIndex, offsetBy: 12_000, limitedBy: text.endIndex) ?? text.endIndex
        Text(String(text[..<end]))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        if end < text.endIndex {
            Text(L("预览仅显示开头，复制和粘贴使用完整内容"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.onCopy(item) } label: {
                Label(L("复制"), systemImage: "doc.on.doc")
            }
            Spacer(minLength: 0)
            Button { model.onPaste(item) } label: {
                Label(L("粘贴"), systemImage: "return")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }
}
