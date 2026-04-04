//
//  HomeHeroLanguageChip.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeHeroLanguageChip: View {
    let sourceTitle: String?
    let targetTitle: String

    var body: some View {
        HStack(spacing: 10) {
            if let sourceTitle {
                Text(sourceTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(targetTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

#Preview {
    VStack(spacing: 16) {
        HomeHeroLanguageChip(sourceTitle: "中文", targetTitle: "英文")
        HomeHeroLanguageChip(sourceTitle: nil, targetTitle: "英文")
    }
    .padding()
}
