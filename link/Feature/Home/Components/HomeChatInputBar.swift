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

    let onFocusActivated: () -> Void
    let onSend: () -> Void
    let onVoiceInput: () -> Void

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
        composerField
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

    private var sendButton: some View {
        Button(action: handleSend) {
            Image(systemName: "arrow.up")
                .font(.headline.weight(.bold))
                .foregroundStyle(sendButtonGlyphColor)
                .frame(width: Metrics.primaryActionSize, height: Metrics.primaryActionSize)
                .glassEffect(.regular.tint(sendButtonGlassTint), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isSendEnabled)
        .contentShape(Circle())
        .accessibilityLabel("发送消息")
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

    private var sendButtonGlyphColor: Color {
        isSendEnabled ? .accentColor : Color.secondary.opacity(0.45)
    }

    private var sendButtonGlassTint: Color {
        isSendEnabled ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.08)
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

#Preview("Empty Composer") {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {}
    )
}

#Preview("Typing Composer") {
    HomeChatInputBar(
        text: .constant("Can you translate this into Japanese?"),
        isFocused: .constant(true),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {}
    )
}
