//
//  HomeToolbarTranslationItem.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeToolbarTranslationItem: View {
    let sourceTitle: String
    let targetTitle: String

    var body: some View {
        HStack(spacing: 8) {
            Text(sourceTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Image(systemName: "arrow.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.accentColor)

            Text(targetTitle)
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
        sourceTitle: "中文",
        targetTitle: "英文"
    )
    .padding()
}
