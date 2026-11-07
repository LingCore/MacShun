// SPDX-License-Identifier: MIT

import SwiftUI

struct SystemFeatureRow: View {
    let feature: SystemFeature
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HoverReader { hovering in
                HStack(spacing: 10) {
                    Image(systemName: feature.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.localizedTitle).font(.system(size: 14))
                        Text(feature.category).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer()
                    if selected || hovering {
                        Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
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
    }
}
