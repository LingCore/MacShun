// SPDX-License-Identifier: MIT

import SwiftUI

struct PinnedFolderRow: View {
    let project: PinnedSearchFolder
    let selected: Bool
    let expanded: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HoverReader { hovering in
                let iconSize = FileSearchRowStyle.iconSize(expanded: expanded)
                HStack(spacing: FileSearchRowStyle.spacing) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: expanded ? 15 : 19))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: iconSize, height: iconSize)
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
                .modifier(FileSearchRowStyle(expanded: expanded, selected: selected, hovering: hovering))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(project.path)
    }
}
