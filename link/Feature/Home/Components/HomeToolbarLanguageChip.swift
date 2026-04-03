//
//  HomeToolbarLanguageChip.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeToolbarLanguageChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .frame(minWidth: 88)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(uiColor: .separator), lineWidth: 1)
            )
    }
}

#Preview {
    HomeToolbarLanguageChip(title: "英文")
}
