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

    private enum BubbleRole {
        case outgoingSource
        case incomingTranslation
        case speechCapsule
        case speechTranscript

        var alignment: Alignment {
            switch self {
            case .outgoingSource, .speechCapsule, .speechTranscript:
                return .trailing
            case .incomingTranslation:
                return .leading
            }
        }

        var horizontalAlignment: HorizontalAlignment {
            switch self {
            case .outgoingSource, .speechCapsule, .speechTranscript:
                return .trailing
            case .incomingTranslation:
                return .leading
            }
        }

        var fillStyle: AnyShapeStyle {
            switch self {
            case .outgoingSource, .speechCapsule, .speechTranscript:
                return AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
            case .incomingTranslation:
                return AnyShapeStyle(Color.accentColor)
            }
        }

        var cornerRadii: RectangleCornerRadii {
            switch self {
            case .outgoingSource, .speechCapsule:
                return RectangleCornerRadii(
                    topLeading: 24,
                    bottomLeading: 24,
                    bottomTrailing: 8,
                    topTrailing: 24
                )
            case .incomingTranslation:
                return RectangleCornerRadii(
                    topLeading: 24,
                    bottomLeading: 8,
                    bottomTrailing: 24,
                    topTrailing: 24
                )
            case .speechTranscript:
                return RectangleCornerRadii(
                    topLeading: 22,
                    bottomLeading: 22,
                    bottomTrailing: 8,
                    topTrailing: 22
                )
            }
        }
    }

    private struct LanguageChip: View {
        let language: SupportedLanguage
        let isBusy: Bool
        let isDisabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.accentColor)
                    } else {
                        Text(language.flagEmoji)
                            .font(.caption)
                    }

                    Text(language.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(
                    isDisabled
                        ? Color.secondary.opacity(0.78)
                        : Color.primary.opacity(0.88)
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(uiColor: .systemBackground).opacity(0.92))
                )
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let message: ChatMessage
    let streamingState: ExchangeStreamingState?
    let sourceLanguage: SupportedLanguage
    let targetLanguage: SupportedLanguage
    let showsTranslatedPlaybackButton: Bool
    let isPlayingTranslatedMessage: Bool
    let isTranslatedPlaybackDisabled: Bool
    let isSourcePlaybackDisabled: Bool
    let isPlayingSourceMessage: Bool
    let showsSpeechTranscript: Bool
    let isSpeechTranscriptToggleDisabled: Bool
    let hasPlayableSourceRecording: Bool
    let isSourceLanguageSwitchDisabled: Bool
    let isTargetLanguageSwitchDisabled: Bool
    let isSourceLanguageSwitching: Bool
    let isTargetLanguageSwitching: Bool
    let onTranslatedPlayback: () -> Void
    let onSourcePlayback: () -> Void
    let onSpeechTranscriptToggle: () -> Void
    let onSourceLanguageSelection: () -> Void
    let onTargetLanguageSelection: () -> Void

    init(
        message: ChatMessage,
        streamingState: ExchangeStreamingState?,
        sourceLanguage: SupportedLanguage = .chinese,
        targetLanguage: SupportedLanguage = .english,
        showsTranslatedPlaybackButton: Bool,
        isPlayingTranslatedMessage: Bool,
        isTranslatedPlaybackDisabled: Bool,
        isSourcePlaybackDisabled: Bool,
        isPlayingSourceMessage: Bool,
        showsSpeechTranscript: Bool,
        isSpeechTranscriptToggleDisabled: Bool,
        hasPlayableSourceRecording: Bool,
        isSourceLanguageSwitchDisabled: Bool = false,
        isTargetLanguageSwitchDisabled: Bool = false,
        isSourceLanguageSwitching: Bool = false,
        isTargetLanguageSwitching: Bool = false,
        onTranslatedPlayback: @escaping () -> Void,
        onSourcePlayback: @escaping () -> Void,
        onSpeechTranscriptToggle: @escaping () -> Void,
        onSourceLanguageSelection: @escaping () -> Void = {},
        onTargetLanguageSelection: @escaping () -> Void = {}
    ) {
        self.message = message
        self.streamingState = streamingState
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.showsTranslatedPlaybackButton = showsTranslatedPlaybackButton
        self.isPlayingTranslatedMessage = isPlayingTranslatedMessage
        self.isTranslatedPlaybackDisabled = isTranslatedPlaybackDisabled
        self.isSourcePlaybackDisabled = isSourcePlaybackDisabled
        self.isPlayingSourceMessage = isPlayingSourceMessage
        self.showsSpeechTranscript = showsSpeechTranscript
        self.isSpeechTranscriptToggleDisabled = isSpeechTranscriptToggleDisabled
        self.hasPlayableSourceRecording = hasPlayableSourceRecording
        self.isSourceLanguageSwitchDisabled = isSourceLanguageSwitchDisabled
        self.isTargetLanguageSwitchDisabled = isTargetLanguageSwitchDisabled
        self.isSourceLanguageSwitching = isSourceLanguageSwitching
        self.isTargetLanguageSwitching = isTargetLanguageSwitching
        self.onTranslatedPlayback = onTranslatedPlayback
        self.onSourcePlayback = onSourcePlayback
        self.onSpeechTranscriptToggle = onSpeechTranscriptToggle
        self.onSourceLanguageSelection = onSourceLanguageSelection
        self.onTargetLanguageSelection = onTargetLanguageSelection
    }

    var body: some View {
        VStack(spacing: 8) {
            sourceSection
            translatedSection
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var sourceSection: some View {
        alignedGroup(alignment: .trailing, horizontalAlignment: .trailing) {
            languageChipRow(alignment: .trailing) {
                LanguageChip(
                    language: sourceLanguage,
                    isBusy: isSourceLanguageSwitching,
                    isDisabled: isSourceLanguageSwitchDisabled,
                    action: onSourceLanguageSelection
                )
            }

            switch message.inputType {
            case .text:
                bubble(role: .outgoingSource) {
                    sourceTranscriptBody(
                        primaryColor: .primary,
                        placeholderColor: .secondary
                    )
                }

                actionRow(alignment: .trailing) {
                    bubbleActionButton(
                        systemName: isPlayingSourceMessage ? "stop.fill" : "speaker.wave.2.fill",
                        title: isPlayingSourceMessage ? "停止" : "朗读",
                        tint: isPlayingSourceMessage ? Color.accentColor : Color.secondary,
                        isDisabled: isSourcePlaybackDisabled,
                        accessibilityLabel: isPlayingSourceMessage ? "停止播放原文语音" : "播放原文语音",
                        action: onSourcePlayback
                    )
                }
            case .speech:
                speechCapsuleButton

                actionRow(alignment: .trailing) {
                    bubbleActionButton(
                        systemName: "text.justify",
                        title: speechTranscriptButtonTitle,
                        tint: showsSpeechTranscript ? Color.accentColor : Color.secondary,
                        isDisabled: isSpeechTranscriptToggleDisabled,
                        accessibilityLabel: showsSpeechTranscript ? "收起转换文字" : "查看转换文字",
                        action: onSpeechTranscriptToggle
                    )
                }

                if showsSpeechTranscript {
                    bubble(role: .speechTranscript) {
                        sourceTranscriptBody(
                            primaryColor: .primary,
                            placeholderColor: .secondary
                        )
                    }
                }
            }
        }
    }

    private var translatedSection: some View {
        alignedGroup(alignment: .leading, horizontalAlignment: .leading) {
            languageChipRow(alignment: .leading) {
                LanguageChip(
                    language: targetLanguage,
                    isBusy: isTargetLanguageSwitching,
                    isDisabled: isTargetLanguageSwitchDisabled,
                    action: onTargetLanguageSelection
                )
            }

            bubble(role: .incomingTranslation) {
                translatedBubbleBody
            }

            if showsTranslatedPlaybackButton {
                actionRow(alignment: .leading) {
                    bubbleActionButton(
                        systemName: isPlayingTranslatedMessage ? "stop.fill" : "speaker.wave.2.fill",
                        title: isPlayingTranslatedMessage ? "停止" : "朗读",
                        tint: isPlayingTranslatedMessage ? Color.accentColor : Color.secondary,
                        isDisabled: isTranslatedPlaybackDisabled,
                        accessibilityLabel: isPlayingTranslatedMessage ? "停止播放译文语音" : "播放译文语音",
                        action: onTranslatedPlayback
                    )
                }
            }
        }
    }

    private var translatedBubbleBody: some View {
        Group {
            if shouldShowTranslationThinkingIndicator {
                TranslationThinkingIndicator()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let statusText = translatedStatusText {
                        HStack(spacing: 6) {
                            if isTranslationFailed {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(translatedFailureAccentColor)
                            }

                            Text(statusText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(translatedStatusColor)
                        }
                    }

                    Text(translatedContent.text)
                        .font(.body)
                        .foregroundStyle(translatedTextColor)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var speechCapsuleButton: some View {
        Button(action: onSourcePlayback) {
            bubble(
                role: .speechCapsule,
                borderColor: hasPlayableSourceRecording ? Color.primary.opacity(0.06) : Color.clear
            ) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 34, height: 34)

                        Image(systemName: isPlayingSourceMessage ? "stop.fill" : "waveform")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(sourcePlaybackGlyphColor)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("原始语音")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)

                        waveformRow
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isPlayingSourceMessage ? "stop.fill" : "play.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(sourcePlaybackGlyphColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(isSourcePlaybackDisabled)
        .accessibilityLabel(isPlayingSourceMessage ? "停止播放原始语音" : "播放原始语音")
    }

    private var waveformRow: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(waveHeights.enumerated()), id: \.offset) { _, height in
                Capsule(style: .continuous)
                    .fill(sourceWaveformColor)
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 16, alignment: .center)
    }

    private var waveHeights: [CGFloat] {
        [8, 12, 6, 14, 10, 16, 9, 13, 7, 11, 5]
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

    private var translatedStatusText: String? {
        let statusText = streamingState?.translationStatusText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let statusText, !statusText.isEmpty else { return nil }
        return statusText
    }

    private var translatedStatusColor: Color {
        if isTranslationFailed {
            return Color.white.opacity(0.94)
        }

        return translatedContent.isPlaceholder ? Color.white.opacity(0.78) : Color.white.opacity(0.84)
    }

    private var translatedFailureAccentColor: Color {
        Color.white.opacity(0.94)
    }

    private var translatedTextColor: Color {
        if isTranslationFailed {
            return .white
        }

        return translatedContent.isPlaceholder ? Color.white.opacity(0.84) : .white
    }

    private var shouldShowTranslationThinkingIndicator: Bool {
        guard let streamingState else { return false }

        if case .translating = streamingState.translationPhase {
            return !hasResolvedTranslatedText
        }

        return false
    }

    private var hasResolvedTranslatedText: Bool {
        let streamingText = streamingState?.translatedDisplayText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !streamingText.isEmpty {
            return true
        }

        return !message.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isTranslationFailed: Bool {
        guard let streamingState else { return false }

        if case .failed = streamingState.translationPhase {
            return true
        }

        return false
    }

    private var sourceWaveformColor: Color {
        if isSourcePlaybackDisabled {
            return Color.secondary.opacity(0.45)
        }

        return isPlayingSourceMessage ? Color.accentColor.opacity(0.92) : Color.secondary.opacity(0.88)
    }

    private var sourcePlaybackGlyphColor: Color {
        if isSourcePlaybackDisabled {
            return Color.secondary.opacity(0.55)
        }

        return isPlayingSourceMessage ? Color.accentColor : Color.primary.opacity(0.88)
    }

    private var speechTranscriptButtonTitle: String {
        if isSpeechTranscriptToggleDisabled {
            return "转写中"
        }

        return showsSpeechTranscript ? "收起转写" : "查看转写"
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
    private func sourceTranscriptBody(
        primaryColor: Color,
        placeholderColor: Color
    ) -> some View {
        if sourceContent.hasLayeredText {
            layeredSourceText(
                stableText: sourceContent.stableText,
                provisionalText: sourceContent.provisionalText,
                liveText: sourceContent.liveText,
                baseColor: primaryColor
            )
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(sourceContent.fallbackText ?? "…")
                .font(.body)
                .foregroundStyle(sourceContent.isPlaceholder ? placeholderColor : primaryColor)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func layeredSourceText(
        stableText: String,
        provisionalText: String,
        liveText: String,
        baseColor: Color
    ) -> Text {
        Text(stableText).foregroundColor(baseColor) +
        Text(provisionalText).foregroundColor(baseColor.opacity(0.72)) +
        Text(liveText).foregroundColor(baseColor.opacity(0.48))
    }

    private struct TranslationThinkingIndicator: View {
        private static let cycleDuration = 0.9
        private static let phaseOffset = 0.18

        var body: some View {
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
                let timestamp = context.date.timeIntervalSinceReferenceDate

                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        let emphasis = dotEmphasis(for: index, timestamp: timestamp)

                        Text("·")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(Color.white.opacity(0.42 + (0.46 * emphasis)))
                            .scaleEffect(0.9 + (0.22 * emphasis))
                            .frame(width: 10, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("翻译中")
            }
        }

        private func dotEmphasis(for index: Int, timestamp: TimeInterval) -> Double {
            let progress = timestamp.remainder(dividingBy: Self.cycleDuration) / Self.cycleDuration
            let phase = progress - (Double(index) * Self.phaseOffset)
            let wave = (sin(phase * .pi * 2) + 1) / 2
            return max(0, min(1, wave))
        }
    }

    private func alignedGroup<Content: View>(
        alignment: Alignment,
        horizontalAlignment: HorizontalAlignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: horizontalAlignment, spacing: 6) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func bubble<Content: View>(
        role: BubbleRole,
        borderColor: Color = .clear,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, role == .speechCapsule ? 14 : 12)
            .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
            .background {
                bubbleShape(for: role)
                    .fill(role.fillStyle)
            }
            .overlay {
                bubbleShape(for: role)
                    .stroke(borderColor, lineWidth: borderColor == .clear ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: role.alignment)
    }

    private func bubbleShape(for role: BubbleRole) -> some InsettableShape {
        UnevenRoundedRectangle(
            cornerRadii: role.cornerRadii,
            style: .continuous
        )
    }

    private func actionRow<Content: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func languageChipRow<Content: View>(
        alignment: Alignment,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func bubbleActionButton(
        systemName: String,
        title: String,
        tint: Color,
        isDisabled: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.caption.weight(.semibold))

                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(isDisabled ? Color.secondary.opacity(0.72) : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(uiColor: .systemBackground).opacity(0.92))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var bubbleMaxWidth: CGFloat {
        let screenWidth = UIScreen.main.bounds.width
        let widthRatio: CGFloat = horizontalSizeClass == .regular ? 0.58 : 0.72
        let maxWidth = screenWidth * widthRatio
        return min(maxWidth, horizontalSizeClass == .regular ? 520 : 320)
    }
}

#Preview("Text Exchange") {
    ScrollView {
        VStack(spacing: 18) {
            HomeChatMessageBubble(
                message: PreviewFactory.textMessage(
                    sourceText: "今晚七点的会议能提前到六点半吗？",
                    translatedText: "Could we move tonight's meeting up to 6:30?"
                ),
                streamingState: nil,
                showsTranslatedPlaybackButton: true,
                isPlayingTranslatedMessage: false,
                isTranslatedPlaybackDisabled: false,
                isSourcePlaybackDisabled: false,
                isPlayingSourceMessage: false,
                showsSpeechTranscript: false,
                isSpeechTranscriptToggleDisabled: false,
                hasPlayableSourceRecording: false,
                onTranslatedPlayback: {},
                onSourcePlayback: {},
                onSpeechTranscriptToggle: {}
            )
        }
        .padding()
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Speech Exchange") {
    ScrollView {
        VStack(spacing: 18) {
            HomeChatMessageBubble(
                message: PreviewFactory.speechMessage(
                    sourceText: "我大概二十分钟后到。",
                    translatedText: "I'll arrive in about twenty minutes."
                ),
                streamingState: nil,
                showsTranslatedPlaybackButton: true,
                isPlayingTranslatedMessage: false,
                isTranslatedPlaybackDisabled: false,
                isSourcePlaybackDisabled: false,
                isPlayingSourceMessage: false,
                showsSpeechTranscript: true,
                isSpeechTranscriptToggleDisabled: false,
                hasPlayableSourceRecording: true,
                onTranslatedPlayback: {},
                onSourcePlayback: {},
                onSpeechTranscriptToggle: {}
            )
        }
        .padding()
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Streaming Translation") {
    ScrollView {
        VStack(spacing: 18) {
            let message = PreviewFactory.textMessage(
                sourceText: "请帮我预订两张周五晚上的电影票。",
                translatedText: ""
            )

            HomeChatMessageBubble(
                message: message,
                streamingState: ExchangeStreamingState(
                    messageID: message.id,
                    sourceStableText: message.sourceText,
                    sourceProvisionalText: "",
                    sourceLiveText: "",
                    sourcePhase: .completed,
                    sourceRevision: 0,
                    translatedCommittedText: "Please help me book two tickets",
                    translatedLiveText: "Please help me book two tickets for Friday night.",
                    translationPhase: .typing,
                    translationRevision: 2
                ),
                showsTranslatedPlaybackButton: false,
                isPlayingTranslatedMessage: false,
                isTranslatedPlaybackDisabled: true,
                isSourcePlaybackDisabled: false,
                isPlayingSourceMessage: false,
                showsSpeechTranscript: false,
                isSpeechTranscriptToggleDisabled: false,
                hasPlayableSourceRecording: false,
                onTranslatedPlayback: {},
                onSourcePlayback: {},
                onSpeechTranscriptToggle: {}
            )
        }
        .padding()
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Translation Loading") {
    ScrollView {
        VStack(spacing: 18) {
            let message = PreviewFactory.textMessage(
                sourceText: "请帮我联系前台确认一下入住时间。",
                translatedText: ""
            )

            HomeChatMessageBubble(
                message: message,
                streamingState: ExchangeStreamingState(
                    messageID: message.id,
                    sourceStableText: message.sourceText,
                    sourceProvisionalText: "",
                    sourceLiveText: "",
                    sourcePhase: .completed,
                    sourceRevision: 0,
                    translatedCommittedText: "",
                    translatedLiveText: nil,
                    translationPhase: .translating,
                    translationRevision: 0
                ),
                showsTranslatedPlaybackButton: false,
                isPlayingTranslatedMessage: false,
                isTranslatedPlaybackDisabled: true,
                isSourcePlaybackDisabled: false,
                isPlayingSourceMessage: false,
                showsSpeechTranscript: false,
                isSpeechTranscriptToggleDisabled: false,
                hasPlayableSourceRecording: false,
                onTranslatedPlayback: {},
                onSourcePlayback: {},
                onSpeechTranscriptToggle: {}
            )
        }
        .padding()
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

#Preview("Failure State") {
    ScrollView {
        VStack(spacing: 18) {
            let message = PreviewFactory.textMessage(
                sourceText: "请把这个地址发给司机。",
                translatedText: ""
            )

            HomeChatMessageBubble(
                message: message,
                streamingState: ExchangeStreamingState(
                    messageID: message.id,
                    sourceStableText: message.sourceText,
                    sourceProvisionalText: "",
                    sourceLiveText: "",
                    sourcePhase: .completed,
                    sourceRevision: 0,
                    translatedCommittedText: "翻译失败了，请稍后再试。",
                    translatedLiveText: nil,
                    translationPhase: .failed("翻译失败了，请稍后再试。"),
                    translationRevision: 1
                ),
                showsTranslatedPlaybackButton: false,
                isPlayingTranslatedMessage: false,
                isTranslatedPlaybackDisabled: true,
                isSourcePlaybackDisabled: false,
                isPlayingSourceMessage: false,
                showsSpeechTranscript: false,
                isSpeechTranscriptToggleDisabled: false,
                hasPlayableSourceRecording: false,
                onTranslatedPlayback: {},
                onSourcePlayback: {},
                onSpeechTranscriptToggle: {}
            )
        }
        .padding()
    }
    .background(Color(uiColor: .systemGroupedBackground))
}

private enum PreviewFactory {
    static func textMessage(
        sourceText: String,
        translatedText: String
    ) -> ChatMessage {
        let session = ChatSession(
            sourceLanguage: .chinese,
            targetLanguage: .english
        )
        return ChatMessage(
            inputType: .text,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: .chinese,
            targetLanguage: .english,
            sequence: 0,
            session: session
        )
    }

    static func speechMessage(
        sourceText: String,
        translatedText: String
    ) -> ChatMessage {
        let session = ChatSession(
            sourceLanguage: .chinese,
            targetLanguage: .english
        )
        return ChatMessage(
            inputType: .speech,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: .chinese,
            targetLanguage: .english,
            audioURL: URL(fileURLWithPath: "/tmp/preview-audio.m4a").absoluteString,
            sequence: 0,
            session: session
        )
    }
}
