//
//  HomeChatInputBar.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeChatInputBar: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isRecordingSpeech: Bool
    let isSpeechBusy: Bool

    let onFocusActivated: () -> Void
    let onSend: () -> Void
    let onVoiceInput: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.black.opacity(0.06))

            HStack(alignment: .bottom, spacing: 10) {
                composerField

                if hasTypedText {
                    secondaryVoiceButton
                    sendButton
                } else {
                    primaryVoiceButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .background(.regularMaterial)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            }
    }

    private var sendButton: some View {
        Button(action: handleSend) {
            Image(systemName: "arrow.up")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(isSendEnabled ? Color.accentColor : Color.secondary.opacity(0.35))
                )
        }
        .buttonStyle(.plain)
        .disabled(!isSendEnabled)
        .accessibilityLabel("发送消息")
    }

    private var primaryVoiceButton: some View {
        Group {
            if isSpeechBusy && !isRecordingSpeech {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(Color.secondary.opacity(0.6))
                    )
            } else {
                Button(action: onVoiceInput) {
                    Image(systemName: isRecordingSpeech ? "stop.fill" : "mic.fill")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(isRecordingSpeech ? Color.red : Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
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
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
            } else {
                Button(action: onVoiceInput) {
                    Image(systemName: isRecordingSpeech ? "stop.fill" : "mic.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isRecordingSpeech ? Color.red : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRecordingSpeech ? "结束录音" : "开始录音")
                .disabled(isSpeechBusy && !isRecordingSpeech)
            }
        }
    }

    private var hasTypedText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
