//
//  HomeToolbarTranslationItem.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeToolbarTranslationItem: View {
    let flagEmoji: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(flagEmoji)
                .font(.body)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.9)
    }

}

#Preview {
    HomeToolbarTranslationItem(
        flagEmoji: "🇺🇸",
        title: "英文"
    )
    .padding()
}
