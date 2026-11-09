// SPDX-License-Identifier: MIT

import SwiftUI

struct PinnedFolderRow: View {
    let project: PinnedSearchFolder
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HoverReader { hovering in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.system(size: 14)).truncationMode(.middle)
                        Text(((project.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11)).foregroundStyle(.secondary).truncationMode(.head)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(height: FileSearchView.rowHeight)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovering ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(project.path)
    }
}
