//
//  HomeHeroLanguageChip.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeHeroLanguageChip: View {
    let flagEmoji: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(flagEmoji)
                .font(.title2)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .glassEffect()
    }
}

#Preview {
    VStack(spacing: 16) {
        HomeHeroLanguageChip(flagEmoji: "🇺🇸", title: "英文")
        HomeHeroLanguageChip(flagEmoji: "🇯🇵", title: "日文")
    }
    .padding()
}
