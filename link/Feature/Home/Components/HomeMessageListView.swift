//
//  HomeMessageListView.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

enum HomeMessageListBottomTracking {
    static let threshold: CGFloat = 120

    static func isNearBottom(
        bottomAnchorMaxY: CGFloat,
        containerHeight: CGFloat
    ) -> Bool {
        bottomAnchorMaxY <= containerHeight + threshold
    }
}

struct HomeMessageListView: View {
    private static let scrollCoordinateSpaceName = "home-message-list-scroll"

    let messageItems: [HomeStore.MessageItemState]
    let bottomAnchorID: String
    let bottomSpacerHeight: CGFloat
    let onTranslatedPlayback: (ChatMessage) -> Void
    let onRetrySpeechTranslation: (ChatMessage) -> Void
    let onSourcePlayback: (ChatMessage) -> Void
    let onSpeechTranscriptToggle: (ChatMessage) -> Void
    let onSourceLanguageSelection: (ChatMessage) -> Void
    let onTargetLanguageSelection: (ChatMessage) -> Void
    let onMessageListBottomProximityChanged: (Bool) -> Void

    @State private var containerHeight: CGFloat = 0
    @State private var bottomAnchorMaxY: CGFloat?
    @State private var lastReportedBottomProximity: Bool?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(messageItems) { messageItem in
                        HomeChatMessageBubble(
                            message: messageItem.message,
                            streamingState: messageItem.streamingState,
                            sourceLanguage: messageItem.sourceLanguage,
                            targetLanguage: messageItem.targetLanguage,
                            showsTranslatedPlaybackButton: messageItem.showsTranslatedPlaybackButton,
                            showsRetrySpeechTranslationButton: messageItem.showsRetrySpeechTranslationButton,
                            isPlayingTranslatedMessage: messageItem.isPlayingTranslatedMessage,
                            isTranslatedPlaybackDisabled: messageItem.isTranslatedPlaybackDisabled,
                            isRetrySpeechTranslationDisabled: messageItem.isRetrySpeechTranslationDisabled,
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
                            onRetrySpeechTranslation: {
                                onRetrySpeechTranslation(messageItem.message)
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
                        .id(messageItem.renderKey)
                    }

                    Color.clear
                        .frame(height: bottomSpacerHeight)
                        .background {
                            GeometryReader { anchorProxy in
                                Color.clear.preference(
                                    key: HomeMessageListBottomAnchorMaxYPreferenceKey.self,
                                    value: anchorProxy.frame(
                                        in: .named(Self.scrollCoordinateSpaceName)
                                    ).maxY
                                )
                            }
                        }
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpaceName)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .onAppear {
                handleContainerHeightChange(proxy.size.height)
            }
            .onChange(of: proxy.size.height) { _, newValue in
                handleContainerHeightChange(newValue)
            }
            .onPreferenceChange(HomeMessageListBottomAnchorMaxYPreferenceKey.self) { maxY in
                bottomAnchorMaxY = maxY
                reportBottomProximityIfNeeded()
            }
        }
    }

    private func handleContainerHeightChange(_ newValue: CGFloat) {
        guard containerHeight != newValue else { return }
        containerHeight = newValue
        reportBottomProximityIfNeeded()
    }

    private func reportBottomProximityIfNeeded() {
        guard
            containerHeight > 0,
            let bottomAnchorMaxY
        else {
            return
        }

        let isNearBottom = HomeMessageListBottomTracking.isNearBottom(
            bottomAnchorMaxY: bottomAnchorMaxY,
            containerHeight: containerHeight
        )

        guard lastReportedBottomProximity != isNearBottom else {
            return
        }

        lastReportedBottomProximity = isNearBottom
        onMessageListBottomProximityChanged(isNearBottom)
    }
}

private struct HomeMessageListBottomAnchorMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
