// SPDX-License-Identifier: MIT

import SwiftUI

/// 文件、系统功能和固定项目使用同一套行高与选中样式。
struct FileSearchRowStyle: ViewModifier {
    let expanded: Bool
    let selected: Bool
    let hovering: Bool

    static let inset: CGFloat = 10
    static let spacing: CGFloat = 10

    static func iconSize(expanded: Bool) -> CGFloat { expanded ? 22 : 30 }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.inset)
            .frame(height: expanded ? FileSearchView.expandedRowHeight : FileSearchView.rowHeight)
            .background(fill, in: RoundedRectangle(cornerRadius: expanded ? 5 : 8, style: .continuous))
            .overlay(alignment: .leading) {
                if expanded && selected {
                    Capsule().fill(Color.accentColor).frame(width: 2.5, height: 16).padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
    }

    private var fill: Color {
        if selected { return Color.accentColor.opacity(expanded ? 0.16 : 0.22) }
        return Color.primary.opacity(hovering ? 0.05 : 0)
    }
}
