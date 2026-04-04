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
    let hasLastSpeechRecording: Bool
    let isPlayingLastSpeechRecording: Bool

    let onFocusActivated: () -> Void
    let onSend: () -> Void
    let onVoiceInput: () -> Void
    let onPlayLastSpeechRecording: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            TextField("请输入对话内容", text: $text)
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .submitLabel(.send)
                .disabled(isInputDisabled)
                .onSubmit {
                    handleSend()
                }

            speechButton
            playbackButton

            Button(action: handleSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isSendEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!isSendEnabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(Color(uiColor: .systemBackground))
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

    private var isSendEnabled: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isInputDisabled
    }

    private var isInputDisabled: Bool {
        isRecordingSpeech || isSpeechBusy
    }

    @ViewBuilder
    private var speechButton: some View {
        if isSpeechBusy && !isRecordingSpeech {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
        } else {
            Button(action: onVoiceInput) {
                Image(systemName: isRecordingSpeech ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isRecordingSpeech ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRecordingSpeech ? "结束录音" : "开始录音")
            .disabled(isSpeechBusy && !isRecordingSpeech)
        }
    }

    @ViewBuilder
    private var playbackButton: some View {
        if hasLastSpeechRecording {
            Button(action: onPlayLastSpeechRecording) {
                Image(systemName: isPlayingLastSpeechRecording ? "stop.circle" : "play.circle")
                    .font(.title3)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlayingLastSpeechRecording ? "停止播放录音" : "播放最近一次录音")
            .disabled(isRecordingSpeech)
        }
    }

    private func handleSend() {
        guard isSendEnabled else { return }
        onSend()
    }
}

#Preview {
    HomeChatInputBar(
        text: .constant(""),
        isFocused: .constant(false),
        isRecordingSpeech: false,
        isSpeechBusy: false,
        hasLastSpeechRecording: true,
        isPlayingLastSpeechRecording: false,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onPlayLastSpeechRecording: {}
    )
}
