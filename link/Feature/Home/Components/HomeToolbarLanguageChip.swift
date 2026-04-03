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
            .frame(maxWidth: style == .hero ? .infinity : nil)
            .frame(minWidth: minWidth)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
//            .overlay(
//                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
//                    .stroke(Color(uiColor: .separator), lineWidth: 1)
//            )
    }

    private var font: Font {
        switch style {
        case .hero:
            return .title3.weight(.semibold)
        case .toolbar:
            return .subheadline.weight(.medium)
        }
    }

    private var minWidth: CGFloat {
        switch style {
        case .hero:
            return 0
        case .toolbar:
            return 104
        }
    }

    private var horizontalPadding: CGFloat {
        switch style {
        case .hero:
            return 20
        case .toolbar:
            return 12
        }
    }

    private var verticalPadding: CGFloat {
        switch style {
        case .hero:
            return 18
        case .toolbar:
            return 8
        }
    }

    private var cornerRadius: CGFloat {
        switch style {
        case .hero:
            return 18
        case .toolbar:
            return 12
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        HomeLanguageChip(title: "英文", style: .hero)
        HomeLanguageChip(title: "英文", style: .toolbar)
    }
    .padding()
}
