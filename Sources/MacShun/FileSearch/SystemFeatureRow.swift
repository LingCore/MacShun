// SPDX-License-Identifier: MIT

import SwiftUI

struct SystemFeatureRow: View {
    let feature: SystemFeature
    let selected: Bool
    let expanded: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HoverReader { hovering in
                let iconSize = FileSearchRowStyle.iconSize(expanded: expanded)
                HStack(spacing: FileSearchRowStyle.spacing) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: expanded ? 14 : 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: iconSize, height: iconSize)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: expanded ? 5 : 7))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.localizedTitle).font(.system(size: 14))
                        Text(feature.category).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                        .opacity(selected || hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .modifier(FileSearchRowStyle(expanded: expanded, selected: selected, hovering: hovering))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
