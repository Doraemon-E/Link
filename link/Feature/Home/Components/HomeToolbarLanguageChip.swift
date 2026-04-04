//
//  HomeToolbarLanguageChip.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeLanguageChip: View {
    enum Style {
        case hero
        case toolbar
    }

    let sourceTitle: String?
    let targetTitle: String
    let style: Style

    var body: some View {
        HStack(spacing: contentSpacing) {
            if let sourceTitle {
                Text(sourceTitle)
                    .font(font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Image(systemName: "arrow.right")
                    .font(arrowFont)
                    .foregroundStyle(.secondary)
            }

            Text(targetTitle)
                .font(font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .minimumScaleFactor(style == .toolbar ? 0.85 : 1)
        .frame(maxWidth: style == .hero ? .infinity : nil)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private var font: Font {
        switch style {
        case .hero:
            return .title3.weight(.semibold)
        case .toolbar:
            return .subheadline.weight(.medium)
        }
    }

    private var arrowFont: Font {
        switch style {
        case .hero:
            return .body.weight(.semibold)
        case .toolbar:
            return .footnote.weight(.semibold)
        }
    }

    private var contentSpacing: CGFloat {
        switch style {
        case .hero:
            return 10
        case .toolbar:
            return 6
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .hero:
            return 20
        case .toolbar:
            return 0
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .hero:
            return 18
        case .toolbar:
            return 0
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        HomeLanguageChip(sourceTitle: "中文", targetTitle: "英文", style: .hero)
        HomeLanguageChip(sourceTitle: nil, targetTitle: "英文", style: .hero)
        HomeLanguageChip(sourceTitle: "中文", targetTitle: "英文", style: .toolbar)
    }
    .padding()
}
