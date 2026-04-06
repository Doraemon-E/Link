//
//  HomeMessageListView.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

struct HomeMessageListView: View {
    let messageItems: [HomeStore.MessageItemState]
    let bottomAnchorID: String
    let bottomSpacerHeight: CGFloat
    let onTranslatedPlayback: (ChatMessage) -> Void
    let onSourcePlayback: (ChatMessage) -> Void
    let onSpeechTranscriptToggle: (ChatMessage) -> Void
    let onSourceLanguageSelection: (ChatMessage) -> Void
    let onTargetLanguageSelection: (ChatMessage) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(messageItems) { messageItem in
                    HomeChatMessageBubble(
                        message: messageItem.message,
                        streamingState: messageItem.streamingState,
                        sourceLanguage: messageItem.sourceLanguage,
                        targetLanguage: messageItem.targetLanguage,
                        showsTranslatedPlaybackButton: messageItem.showsTranslatedPlaybackButton,
                        isPlayingTranslatedMessage: messageItem.isPlayingTranslatedMessage,
                        isTranslatedPlaybackDisabled: messageItem.isTranslatedPlaybackDisabled,
                        isSourcePlaybackDisabled: messageItem.isSourcePlaybackDisabled,
                        isPlayingSourceMessage: messageItem.isPlayingSourceMessage,
                        showsSpeechTranscript: messageItem.showsSpeechTranscript,
                        isSpeechTranscriptToggleDisabled: messageItem.isSpeechTranscriptToggleDisabled,
                        hasPlayableSourceRecording: messageItem.hasPlayableSourceRecording,
                        isSourceLanguageSwitchDisabled: messageItem.isSourceLanguageSwitchDisabled,
                        isTargetLanguageSwitchDisabled: messageItem.isTargetLanguageSwitchDisabled,
                        isSourceLanguageSwitching: messageItem.isSourceLanguageSwitching,
                        isTargetLanguageSwitching: messageItem.isTargetLanguageSwitching,
                        onTranslatedPlayback: {
                            onTranslatedPlayback(messageItem.message)
                        },
                        onSourcePlayback: {
                            onSourcePlayback(messageItem.message)
                        },
                        onSpeechTranscriptToggle: {
                            onSpeechTranscriptToggle(messageItem.message)
                        },
                        onSourceLanguageSelection: {
                            onSourceLanguageSelection(messageItem.message)
                        },
                        onTargetLanguageSelection: {
                            onTargetLanguageSelection(messageItem.message)
                        }
                    )
                    .id(messageItem.id)
                }

                Color.clear
                    .frame(height: bottomSpacerHeight)
                    .id(bottomAnchorID)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }
}
