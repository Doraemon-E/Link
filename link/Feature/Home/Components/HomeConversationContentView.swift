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
    let onOpenLanguagePicker: () -> Void
    let onDismissInputFocus: () -> Void
    let onTranslatedPlayback: (ChatMessage) -> Void
    let onSourcePlayback: (ChatMessage) -> Void
    let onSpeechTranscriptToggle: (ChatMessage) -> Void
    let onSourceLanguageSelection: (ChatMessage) -> Void
    let onTargetLanguageSelection: (ChatMessage) -> Void

    var body: some View {
        Group {
            if viewState.shouldShowEmptyState {
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
                    onSourcePlayback: onSourcePlayback,
                    onSpeechTranscriptToggle: onSpeechTranscriptToggle,
                    onSourceLanguageSelection: onSourceLanguageSelection,
                    onTargetLanguageSelection: onTargetLanguageSelection
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismissInputFocus)
    }
}
