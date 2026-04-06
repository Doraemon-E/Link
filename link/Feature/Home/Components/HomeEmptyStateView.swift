//
//  HomeEmptyStateView.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

struct HomeEmptyStateView: View {
    let selectedLanguage: SupportedLanguage
    let onOpenLanguagePicker: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Text("开始新的翻译对话")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text("选择当前想要输出的语言，消息会以聊天的方式逐条呈现。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: onOpenLanguagePicker) {
                HomeHeroLanguageChip(
                    flagEmoji: selectedLanguage.flagEmoji,
                    title: selectedLanguage.displayName
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
