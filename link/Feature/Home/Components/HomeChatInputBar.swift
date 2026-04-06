//
//  HomeChatInputBar.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatInputBar: View {
    private enum Metrics {
        static let fieldMinHeight: CGFloat = 56
        static let fieldHorizontalPadding: CGFloat = 16
        static let fieldVerticalPadding: CGFloat = 13
        static let actionInset: CGFloat = 9
        static let actionSpacing: CGFloat = 8
        static let primaryActionSize: CGFloat = 38
        static let secondaryActionSize: CGFloat = 38
        static let actionTextSpacing: CGFloat = 12
        static let actionReservedWidth: CGFloat =
            secondaryActionSize + actionSpacing + primaryActionSize
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    let isRecordingSpeech: Bool
    let isSpeechBusy: Bool

    @Environment(\.colorScheme) private var colorScheme

    let isImmersiveVoiceModeActive: Bool
    let onFocusActivated: () -> Void
    let onSend: () -> Void
    let onVoiceInput: () -> Void
    let onImmersiveVoiceInput: () -> Void

    @FocusState private var isTextFieldFocused: Bool
    @State private var textFieldHeight: CGFloat = Metrics.fieldMinHeight

    private var dynamicCornerRadius: CGFloat {
        let h = textFieldHeight
        let capsule = h / 2
        let minRadius: CGFloat = 16
        // 单行(56pt)→胶囊，多行(56→116pt)插值收缩到 16
        let t = min(max((h - 56) / 60, 0), 1)
        return capsule * (1 - t) + minRadius * t
    }

    var body: some View {
        currentBarContent
            .onChange(of: isTextFieldFocused) { oldValue, newValue in
                if !oldValue && newValue {
                    onFocusActivated()
                }

                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    isFocused = newValue
                }
            }
            .onChange(of: isFocused) { _, newValue in
                if isTextFieldFocused != newValue {
                    isTextFieldFocused = newValue
                }
            }
            .onChange(of: isImmersiveVoiceModeActive) { _, newValue in
                guard newValue else { return }
                isTextFieldFocused = false
            }
    }

    @ViewBuilder
    private var currentBarContent: some View {
        if isImmersiveVoiceModeActive {
            immersiveVoiceBar
        } else {
            composerField
        }
    }

    private var composerField: some View {
        TextField("发送要翻译的内容", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($isTextFieldFocused)
            .submitLabel(.send)
            .lineLimit(1...5)
            .disabled(isInputDisabled)
            .onSubmit {
                handleSend()
            }
            .padding(.leading, Metrics.fieldHorizontalPadding)
            .padding(.vertical, Metrics.fieldVerticalPadding)
            .padding(.trailing, composerTrailingPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.fieldMinHeight, alignment: .leading)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            textFieldHeight = proxy.size.height
                        }
                        .onChange(of: proxy.size.height) { _, newValue in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                textFieldHeight = newValue
                            }
                        }
                }
            )
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: dynamicCornerRadius, style: .continuous))
//            .shadow(color: Color.black.opacity(0.12), radius: 18, y: 10)
            .contentShape(RoundedRectangle(cornerRadius: dynamicCornerRadius, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                actionButtons
                    .padding(.trailing, Metrics.actionInset)
                    .padding(.bottom, Metrics.actionInset)
            }
    }

    private var immersiveVoiceBar: some View {
        Group {
            if isRecordingSpeech {
                Button(action: onVoiceInput) {
                    immersiveVoiceBarContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel("结束语音录音")
            } else {
                immersiveVoiceBarContent
                    .accessibilityLabel("正在处理语音翻译")
            }
        }
    }

    private var immersiveVoiceBarContent: some View {
        HStack {
            Spacer(minLength: 0)

            ImmersiveWaveformRow(
                barColor: invertedActionGlyphColor,
                isEmphasized: isRecordingSpeech
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.fieldHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: Metrics.fieldMinHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.fieldMinHeight / 2, style: .continuous)
                .fill(invertedActionBackgroundColor)
        )
        .opacity(isRecordingSpeech ? 1 : 0.74)
    }

    private var sendButton: some View {
        Button(action: handleSend) {
            Image(systemName: "arrow.up")
                .font(.headline.weight(.bold))
                .frame(width: Metrics.primaryActionSize, height: Metrics.primaryActionSize)
                .modifier(
                    InvertedActionButtonStyle(
                        glyphColor: invertedActionGlyphColor,
                        backgroundColor: invertedActionBackgroundColor,
                        isEnabled: isSendEnabled
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isSendEnabled)
        .contentShape(Circle())
        .accessibilityLabel("发送消息")
    }

    private var waveformButton: some View {
        Button(action: onImmersiveVoiceInput) {
            Image(systemName: "waveform.mid")
                .font(.headline.weight(.bold))
                .frame(width: Metrics.primaryActionSize, height: Metrics.primaryActionSize)
                .modifier(
                    InvertedActionButtonStyle(
                        glyphColor: invertedActionGlyphColor,
                        backgroundColor: invertedActionBackgroundColor
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(isInputDisabled)
        .contentShape(Circle())
        .accessibilityLabel("语音波形")
    }

    private var primaryVoiceButton: some View {
        Group {
            if isSpeechBusy && !isRecordingSpeech {
                ProgressView()
                    .controlSize(.small)
                    .tint(primaryVoiceGlyphColor)
                    .frame(width: Metrics.primaryActionSize, height: Metrics.primaryActionSize)
                    .glassEffect(.regular.tint(primaryVoiceGlassTint), in: Circle())
            } else {
                Button(action: onVoiceInput) {
                    Image(systemName: isRecordingSpeech ? "stop.fill" : "mic.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(primaryVoiceGlyphColor)
                        .frame(width: Metrics.primaryActionSize, height: Metrics.primaryActionSize)
                        .glassEffect(.regular.tint(primaryVoiceGlassTint), in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel(isRecordingSpeech ? "结束录音" : "开始录音")
                .disabled(isSpeechBusy && !isRecordingSpeech)
            }
        }
    }

    private var secondaryVoiceButton: some View {
        Group {
            if isSpeechBusy && !isRecordingSpeech {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
                    .frame(width: Metrics.secondaryActionSize, height: Metrics.secondaryActionSize)
                    .glassEffect(.regular.tint(secondaryVoiceGlassTint), in: Circle())
            } else {
                Button(action: onVoiceInput) {
                    Image(systemName: isRecordingSpeech ? "stop.fill" : "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isRecordingSpeech ? Color.red : Color.secondary)
                        .frame(width: Metrics.secondaryActionSize, height: Metrics.secondaryActionSize)
                        .glassEffect(.regular.tint(secondaryVoiceGlassTint), in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel(isRecordingSpeech ? "结束录音" : "开始录音")
                .disabled(isSpeechBusy && !isRecordingSpeech)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: Metrics.actionSpacing) {
            if hasTypedText {
                secondaryVoiceButton
                sendButton
            } else {
                primaryVoiceButton
                waveformButton
            }
        }
        .frame(height: Metrics.primaryActionSize, alignment: .center)
    }

    private var composerTrailingPadding: CGFloat {
        Metrics.fieldHorizontalPadding
            + Metrics.actionReservedWidth
            + Metrics.actionInset
            + Metrics.actionTextSpacing
    }

    private var hasTypedText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var invertedActionGlyphColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var invertedActionBackgroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var primaryVoiceGlyphColor: Color {
        isRecordingSpeech ? .red : .accentColor
    }

    private var primaryVoiceGlassTint: Color {
        isRecordingSpeech ? Color.red.opacity(0.18) : Color.accentColor.opacity(0.16)
    }

    private var secondaryVoiceGlassTint: Color {
        isRecordingSpeech ? Color.red.opacity(0.12) : Color.white.opacity(0.08)
    }

    private var isSendEnabled: Bool {
        hasTypedText && !isInputDisabled
    }

    private var isInputDisabled: Bool {
        isRecordingSpeech || isSpeechBusy
    }

    private func handleSend() {
        guard isSendEnabled else { return }
        onSend()
    }
}

private struct InvertedActionButtonStyle: ViewModifier {
    let glyphColor: Color
    let backgroundColor: Color
    var isEnabled: Bool = true

    func body(content: Content) -> some View {
        content
            .foregroundStyle(glyphColor)
            .background(
                Circle()
                    .fill(backgroundColor)
            )
            .opacity(isEnabled ? 1 : 0.42)
    }
}

private struct ImmersiveWaveformRow: View {
    private static let cycleDuration = 1.28
    private static let phaseOffset = 0.11
    private let baseHeights: [CGFloat] = [7, 15, 11, 20, 14, 24, 15, 22, 13, 18, 10, 14, 8]

    let barColor: Color
    let isEmphasized: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { context in
            let timestamp = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 4) {
                ForEach(Array(baseHeights.enumerated()), id: \.offset) { index, baseHeight in
                    Capsule(style: .continuous)
                        .fill(barColor)
                        .frame(
                            width: 4,
                            height: animatedHeight(
                                for: index,
                                baseHeight: baseHeight,
                                timestamp: timestamp
                            )
                        )
                }
            }
            .frame(height: 30, alignment: .center)
        }
    }

    private func animatedHeight(
        for index: Int,
        baseHeight: CGFloat,
        timestamp: TimeInterval
    ) -> CGFloat {
        let progress = timestamp.remainder(dividingBy: Self.cycleDuration) / Self.cycleDuration
        let phase = (progress - (Double(index) * Self.phaseOffset)) * .pi * 2
        let wave = (sin(phase) + 1) / 2
        let amplitude: CGFloat = isEmphasized ? 10 : 5
        return max(6, baseHeight + CGFloat(wave) * amplitude)
    }
}

#Preview("Empty Composer") {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        isImmersiveVoiceModeActive: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Empty Composer Dark") {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        isImmersiveVoiceModeActive: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Typing Composer") {
    HomeChatInputBar(
        text: .constant("Can you translate this into Japanese?"),
        isFocused: .constant(true),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        isImmersiveVoiceModeActive: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Typing Composer Dark") {
    HomeChatInputBar(
        text: .constant("Can you translate this into Japanese?"),
        isFocused: .constant(true),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        isImmersiveVoiceModeActive: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Immersive Voice") {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        isRecordingSpeech: true,
        isSpeechBusy: false,
        isImmersiveVoiceModeActive: true,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.light)
}

#Preview("Immersive Voice Finalizing") {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        isRecordingSpeech: false,
        isSpeechBusy: true,
        isImmersiveVoiceModeActive: true,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.dark)
}
