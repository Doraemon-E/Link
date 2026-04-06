//
//  HomeChatMessageBubble.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatMessageBubble: View {
    private struct MessageBlockContent {
        let text: String
        let isPlaceholder: Bool
    }

    private struct SourceBlockContent {
        let stableText: String
        let provisionalText: String
        let liveText: String
        let fallbackText: String?
        let isPlaceholder: Bool

        var hasLayeredText: Bool {
            let transcript = stableText + provisionalText + liveText
            return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    let message: ChatMessage
    let streamingState: ExchangeStreamingState?
    let showsSpeechPlaybackButton: Bool
    let isSpeakingMessage: Bool
    let isSpeechPlaybackDisabled: Bool
    let onSpeechPlayback: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 52)

            VStack(alignment: .trailing, spacing: 6) {
                VStack(alignment: .leading, spacing: 14) {
                    sourceMessageSection

                    Divider()

                    messageSection(
                        title: "译文",
                        content: translatedContent,
                        textColor: .primary,
                        font: .body
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .frame(maxWidth: 320, alignment: .trailing)

                footer
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var sourceContent: SourceBlockContent {
        let stableText = streamingState?.sourceStableText ?? ""
        let provisionalText = streamingState?.sourceProvisionalText ?? ""
        let liveText = streamingState?.sourceLiveText ?? ""
        let layeredTranscript = stableText + provisionalText + liveText

        if !layeredTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SourceBlockContent(
                stableText: stableText,
                provisionalText: provisionalText,
                liveText: liveText,
                fallbackText: nil,
                isPlaceholder: false
            )
        }

        if let placeholderText = streamingState?.sourcePlaceholderText,
           !placeholderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return SourceBlockContent(
                stableText: "",
                provisionalText: "",
                liveText: "",
                fallbackText: placeholderText,
                isPlaceholder: true
            )
        }

        let persistedText = message.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : message.sourceText
        return SourceBlockContent(
            stableText: "",
            provisionalText: "",
            liveText: "",
            fallbackText: persistedText ?? "…",
            isPlaceholder: persistedText == nil
        )
    }

    private var translatedContent: MessageBlockContent {
        content(
            persistedText: message.translatedText,
            liveText: streamingState?.translatedDisplayText,
            placeholderText: streamingState?.translatedPlaceholderText
        )
    }

    private func content(
        persistedText: String,
        liveText: String?,
        placeholderText: String?
    ) -> MessageBlockContent {
        if let liveText {
            let normalizedLiveText = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedLiveText.isEmpty {
                return MessageBlockContent(text: liveText, isPlaceholder: false)
            }
        }

        if let placeholderText {
            let normalizedPlaceholder = placeholderText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedPlaceholder.isEmpty {
                return MessageBlockContent(text: placeholderText, isPlaceholder: true)
            }
        }

        let normalizedPersistedText = persistedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedPersistedText.isEmpty {
            return MessageBlockContent(text: persistedText, isPlaceholder: false)
        }

        return MessageBlockContent(text: "…", isPlaceholder: true)
    }

    @ViewBuilder
    private var sourceMessageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("原文")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            if sourceContent.hasLayeredText {
                layeredSourceText(
                    stableText: sourceContent.stableText,
                    provisionalText: sourceContent.provisionalText,
                    liveText: sourceContent.liveText
                )
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(sourceContent.fallbackText ?? "…")
                    .font(.subheadline)
                    .foregroundStyle(sourceContent.isPlaceholder ? Color.secondary : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func layeredSourceText(
        stableText: String,
        provisionalText: String,
        liveText: String
    ) -> Text {
        Text("\(Text(stableText).foregroundStyle(Color.secondary))\(Text(provisionalText).foregroundStyle(Color.secondary.opacity(0.72)))\(Text(liveText).foregroundStyle(Color.secondary.opacity(0.45)))")
    }

    @ViewBuilder
    private func messageSection(
        title: String,
        content: MessageBlockContent,
        textColor: Color,
        font: Font
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            Text(content.text)
                .font(font)
                .foregroundStyle(content.isPlaceholder ? Color.secondary : textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if showsSpeechPlaybackButton {
            Button(action: onSpeechPlayback) {
                Image(systemName: isSpeakingMessage ? "stop.circle.fill" : "speaker.wave.2.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(isSpeakingMessage ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSpeechPlaybackDisabled)
            .accessibilityLabel(isSpeakingMessage ? "停止语音播放" : "播放译文语音")
            .padding(.horizontal, 4)
        }
    }
}
