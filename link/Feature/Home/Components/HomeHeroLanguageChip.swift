//
//  HomeHeroLanguageChip.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeHeroLanguageChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .layoutPriority(1)
//        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .glassEffect()
    }
}

#Preview {
    VStack(spacing: 16) {
        HomeHeroLanguageChip(title: "英文")
        HomeHeroLanguageChip(title: "English")
    }
    .padding()
}
