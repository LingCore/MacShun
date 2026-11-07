// SPDX-License-Identifier: MIT

import QuickLookUI
import SwiftUI

/// 预览留在同一个搜索窗口，上下切换不必关闭文件或重新输入查询。
struct FileQuickLook: View {
    @ObservedObject var model: FileSearchModel
    let result: FileSearchResult

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.name).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(((result.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
                control("chevron.up", L("上一个结果"), enabled: model.adjacentPreviewIndex(-1) != nil) { model.move(-1) }
                control("chevron.down", L("下一个结果"), enabled: model.adjacentPreviewIndex(1) != nil) { model.move(1) }
                control("xmark", L("返回搜索结果")) { model.closeQuickLook() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            FileQuickLookView(url: URL(fileURLWithPath: result.path))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func control(_ symbol: String, _ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 25)
        }
        .buttonStyle(.chip())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct FileQuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
