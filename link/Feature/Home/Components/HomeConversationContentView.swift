//
//  HomeConversationContentView.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

struct HomeConversationContentView: View {
    let viewState: HomeStore.ViewState
    let selectedLanguage: SupportedLanguage
    let messageListBottomAnchorID: String
    let messageListBottomSpacerHeight: CGFloat
    let immersiveVoiceTranslationState: HomeImmersiveVoiceTranslationState?
    let onOpenLanguagePicker: () -> Void
    let onDismissInputFocus: () -> Void
    let onTranslatedPlayback: (ChatMessage) -> Void
    let onRetrySpeechTranslation: (ChatMessage) -> Void
    let onSourcePlayback: (ChatMessage) -> Void
    let onSpeechTranscriptToggle: (ChatMessage) -> Void
    let onSourceLanguageSelection: (ChatMessage) -> Void
    let onTargetLanguageSelection: (ChatMessage) -> Void

    var body: some View {
        Group {
            if let immersiveVoiceTranslationState {
                HomeImmersiveVoiceTranslationView(state: immersiveVoiceTranslationState)
            } else if viewState.shouldShowEmptyState {
                HomeEmptyStateView(
                    selectedLanguage: selectedLanguage,
                    onOpenLanguagePicker: onOpenLanguagePicker
                )
            } else {
                HomeMessageListView(
                    messageItems: viewState.messageItems,
                    bottomAnchorID: messageListBottomAnchorID,
                    bottomSpacerHeight: messageListBottomSpacerHeight,
                    onTranslatedPlayback: onTranslatedPlayback,
                    onRetrySpeechTranslation: onRetrySpeechTranslation,
                    onSourcePlayback: onSourcePlayback,
                    onSpeechTranscriptToggle: onSpeechTranscriptToggle,
                    onSourceLanguageSelection: onSourceLanguageSelection,
                    onTargetLanguageSelection: onTargetLanguageSelection
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismissInputFocus)
        .animation(.easeInOut(duration: 0.22), value: immersiveVoiceTranslationState != nil)
    }
}

private struct HomeImmersiveVoiceTranslationView: View {
    let state: HomeImmersiveVoiceTranslationState

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack {
                    Spacer(minLength: 0)

                    if hasText {
                        Text(state.translatedText)
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.96))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    private var hasText: Bool {
        !state.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
