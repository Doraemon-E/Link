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

    let title: String
    let style: Style

    var body: some View {
        Text(title)
            .font(font)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(style == .toolbar ? 0.85 : 1)
            .frame(maxWidth: style == .hero ? .infinity : nil)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            // .background(backgroundView)
    }

    private var font: Font {
        switch style {
        case .hero:
            return .title3.weight(.semibold)
        case .toolbar:
            return .subheadline.weight(.medium)
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

    // @ViewBuilder
    // private var backgroundView: some View {
    //     if style == .hero {
    //         RoundedRectangle(cornerRadius: 18, style: .continuous)
    //             .fill(Color(uiColor: .secondarySystemBackground))
    //     }
    // }
}

#Preview {
    VStack(spacing: 16) {
        HomeLanguageChip(title: "英文", style: .hero)
        HomeLanguageChip(title: "英文", style: .toolbar)
    }
    .padding()
}
