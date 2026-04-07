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
        static let immersiveWaveHeight: CGFloat = 30
        static let heroAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)
        static let contentFadeAnimation = Animation.easeInOut(duration: 0.18)
        static let immersiveStartDelay: Duration = .milliseconds(220)
        static let immersiveCollapseDelay: Duration = .milliseconds(260)
    }

    private enum ImmersiveTransitionPhase: Equatable {
        case idle
        case expanding
        case waitingForActivation
        case immersive
        case collapsing

        var showsOverlay: Bool {
            self != .idle
        }

        var blocksComposerInteraction: Bool {
            self != .idle
        }

        var isAwaitingActivation: Bool {
            self == .expanding || self == .waitingForActivation
        }
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    let isRecordingSpeech: Bool
    let isSpeechBusy: Bool
    let shouldAbortImmersiveTransition: Bool

    @Environment(\.colorScheme) private var colorScheme

    let isImmersiveVoiceModeActive: Bool
    let onFocusActivated: () -> Void
    let onSend: () -> Void
    let onVoiceInput: () -> Void
    let onImmersiveVoiceInput: () -> Void

    @FocusState private var isTextFieldFocused: Bool
    @Namespace private var immersiveHeroNamespace
    @State private var textFieldHeight: CGFloat = Metrics.fieldMinHeight
    @State private var immersiveTransitionPhase: ImmersiveTransitionPhase = .idle
    @State private var immersiveActivationTask: Task<Void, Never>?
    @State private var immersiveCollapseTask: Task<Void, Never>?

    private var dynamicCornerRadius: CGFloat {
        let h = textFieldHeight
        let capsule = h / 2
        let minRadius: CGFloat = 16
        // 单行(56pt)→胶囊，多行(56→116pt)插值收缩到 16
        let t = min(max((h - 56) / 60, 0), 1)
        return capsule * (1 - t) + minRadius * t
    }

    var body: some View {
        ZStack {
            composerField

            if immersiveTransitionPhase.showsOverlay {
                immersiveVoiceBar
                    .zIndex(1)
            }
        }
            .onChange(of: isTextFieldFocused) { oldValue, newValue in
                if !oldValue && newValue {
                    onFocusActivated()
                }

                withAnimation(Metrics.heroAnimation) {
                    isFocused = newValue
                }
            }
            .onChange(of: isFocused) { _, newValue in
                if isTextFieldFocused != newValue {
                    isTextFieldFocused = newValue
                }
            }
            .onChange(of: isImmersiveVoiceModeActive) { _, newValue in
                handleImmersiveModeChange(isActive: newValue)
            }
            .onChange(of: shouldAbortImmersiveTransition) { _, newValue in
                guard newValue else { return }
                handleImmersiveTransitionAbort()
            }
            .onAppear {
                immersiveTransitionPhase = isImmersiveVoiceModeActive ? .immersive : .idle
            }
            .onDisappear {
                cancelImmersiveTransitionTasks()
            }
    }

    private var composerField: some View {
        TextField("发送要翻译的内容", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($isTextFieldFocused)
            .submitLabel(.send)
            .lineLimit(1...5)
            .disabled(isInputDisabled || immersiveTransitionPhase.blocksComposerInteraction)
            .onSubmit {
                handleSend()
            }
            .padding(.leading, Metrics.fieldHorizontalPadding)
            .padding(.vertical, Metrics.fieldVerticalPadding)
            .padding(.trailing, composerTrailingPadding)
            .frame(maxWidth: .infinity, minHeight: Metrics.fieldMinHeight, alignment: .leading)
            .opacity(composerTextOpacity)
            .scaleEffect(composerTextScale, anchor: .trailing)
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
            .contentShape(RoundedRectangle(cornerRadius: dynamicCornerRadius, style: .continuous))
            .allowsHitTesting(!immersiveTransitionPhase.blocksComposerInteraction)
            .overlay(alignment: .bottomTrailing) {
                actionButtons
                    .padding(.trailing, Metrics.actionInset)
                    .padding(.bottom, Metrics.actionInset)
            }
    }

    @ViewBuilder
    private var immersiveVoiceBar: some View {
        if immersiveTransitionPhase == .immersive && isRecordingSpeech {
            Button(action: onVoiceInput) {
                immersiveVoiceBarContent
            }
            .buttonStyle(.plain)
            .accessibilityLabel("结束语音录音")
        } else {
            immersiveVoiceBarContent
                .allowsHitTesting(false)
                .accessibilityLabel(immersiveOverlayAccessibilityLabel)
        }
    }

    private var immersiveVoiceBarContent: some View {
        HStack {
            Spacer(minLength: 0)

            ImmersiveWaveformRow(
                barColor: invertedActionGlyphColor,
                isEmphasized: isRecordingSpeech || immersiveTransitionPhase.isAwaitingActivation
            )
            .frame(height: Metrics.immersiveWaveHeight, alignment: .center)
            .opacity(immersiveWaveformOpacity)
            .scaleEffect(immersiveWaveformScale)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.fieldHorizontalPadding)
        .frame(maxWidth: .infinity, minHeight: immersiveOverlayHeight)
        .background(
            RoundedRectangle(cornerRadius: immersiveOverlayCornerRadius, style: .continuous)
                .fill(invertedActionBackgroundColor)
                .matchedGeometryEffect(
                    id: "immersive-wave-hero-background",
                    in: immersiveHeroNamespace,
                    properties: .frame
                )
        )
        .opacity(immersiveOverlayOpacity)
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
        Button(action: beginImmersiveTransition) {
            ZStack {
                Circle()
                    .fill(invertedActionBackgroundColor)
                    .matchedGeometryEffect(
                        id: "immersive-wave-hero-background",
                        in: immersiveHeroNamespace,
                        properties: .frame,
                        isSource: true
                    )
                    .opacity(waveformButtonBackgroundOpacity)

                Image(systemName: "waveform.mid")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(invertedActionGlyphColor)
                    .opacity(waveformButtonIconOpacity)
                    .scaleEffect(waveformButtonIconScale)
                    .animation(Metrics.contentFadeAnimation, value: immersiveTransitionPhase)
            }
            .frame(width: Metrics.primaryActionSize, height: Metrics.primaryActionSize)
            .accessibilityHidden(immersiveTransitionPhase.showsOverlay)
        }
        .buttonStyle(.plain)
        .disabled(isInputDisabled || immersiveTransitionPhase != .idle)
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
            if hasTypedText && !immersiveTransitionPhase.showsOverlay {
                secondaryVoiceButton
                    .opacity(nonHeroActionOpacity)
                    .scaleEffect(nonHeroActionScale, anchor: .trailing)

                sendButton
                    .opacity(nonHeroActionOpacity)
                    .scaleEffect(nonHeroActionScale, anchor: .trailing)
            } else {
                primaryVoiceButton
                    .opacity(nonHeroActionOpacity)
                    .scaleEffect(nonHeroActionScale, anchor: .trailing)

                waveformButton
            }
        }
        .frame(height: Metrics.primaryActionSize, alignment: .center)
    }

    private var composerTrailingPadding: CGFloat {
        if immersiveTransitionPhase.showsOverlay {
            return Metrics.fieldHorizontalPadding
        }

        return Metrics.fieldHorizontalPadding
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

    private var composerTextOpacity: Double {
        immersiveTransitionPhase.showsOverlay ? 0 : 1
    }

    private var composerTextScale: CGFloat {
        immersiveTransitionPhase.showsOverlay ? 0.985 : 1
    }

    private var nonHeroActionOpacity: Double {
        immersiveTransitionPhase.showsOverlay ? 0 : 1
    }

    private var nonHeroActionScale: CGFloat {
        immersiveTransitionPhase.showsOverlay ? 0.88 : 1
    }

    private var waveformButtonBackgroundOpacity: Double {
        immersiveTransitionPhase.showsOverlay ? 0.001 : 1
    }

    private var waveformButtonIconOpacity: Double {
        immersiveTransitionPhase.showsOverlay ? 0 : 1
    }

    private var waveformButtonIconScale: CGFloat {
        immersiveTransitionPhase.showsOverlay ? 0.82 : 1
    }

    private var immersiveOverlayHeight: CGFloat {
        max(textFieldHeight, Metrics.fieldMinHeight)
    }

    private var immersiveOverlayCornerRadius: CGFloat {
        immersiveOverlayHeight / 2
    }

    private var immersiveWaveformOpacity: Double {
        immersiveTransitionPhase.showsOverlay ? 1 : 0
    }

    private var immersiveWaveformScale: CGFloat {
        immersiveTransitionPhase == .expanding ? 0.9 : 1
    }

    private var immersiveOverlayOpacity: Double {
        if immersiveTransitionPhase == .immersive {
            return isRecordingSpeech ? 1 : 0.74
        }

        return 1
    }

    private var immersiveOverlayAccessibilityLabel: String {
        if immersiveTransitionPhase.isAwaitingActivation {
            return "正在展开语音输入"
        }

        return "正在处理语音翻译"
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

    private func beginImmersiveTransition() {
        guard immersiveTransitionPhase == .idle, !isInputDisabled, !hasTypedText else {
            return
        }

        isTextFieldFocused = false
        cancelImmersiveTransitionTasks()

        withAnimation(Metrics.heroAnimation) {
            immersiveTransitionPhase = .expanding
        }

        immersiveActivationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Metrics.immersiveStartDelay)
            } catch {
                return
            }

            guard immersiveTransitionPhase == .expanding else {
                return
            }

            if shouldAbortImmersiveTransition {
                collapseImmersiveTransition()
                return
            }

            withAnimation(Metrics.heroAnimation) {
                immersiveTransitionPhase = .waitingForActivation
            }

            onImmersiveVoiceInput()
        }
    }

    private func handleImmersiveModeChange(isActive: Bool) {
        if isActive {
            isTextFieldFocused = false
            immersiveCollapseTask?.cancel()
            immersiveActivationTask?.cancel()

            withAnimation(Metrics.heroAnimation) {
                immersiveTransitionPhase = .immersive
            }
            return
        }

        guard immersiveTransitionPhase == .immersive else {
            return
        }

        collapseImmersiveTransition()
    }

    private func handleImmersiveTransitionAbort() {
        guard immersiveTransitionPhase.isAwaitingActivation else {
            return
        }

        collapseImmersiveTransition()
    }

    private func collapseImmersiveTransition() {
        guard immersiveTransitionPhase != .idle, immersiveTransitionPhase != .collapsing else {
            return
        }

        immersiveActivationTask?.cancel()
        immersiveActivationTask = nil
        immersiveCollapseTask?.cancel()

        withAnimation(Metrics.heroAnimation) {
            immersiveTransitionPhase = .collapsing
        }

        immersiveCollapseTask = Task { @MainActor in
            do {
                try await Task.sleep(for: Metrics.immersiveCollapseDelay)
            } catch {
                return
            }

            guard immersiveTransitionPhase == .collapsing else {
                return
            }

            immersiveTransitionPhase = .idle
            immersiveCollapseTask = nil
        }
    }

    private func cancelImmersiveTransitionTasks() {
        immersiveActivationTask?.cancel()
        immersiveCollapseTask?.cancel()
        immersiveActivationTask = nil
        immersiveCollapseTask = nil
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
        shouldAbortImmersiveTransition: false,
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
        shouldAbortImmersiveTransition: false,
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
        shouldAbortImmersiveTransition: false,
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
        shouldAbortImmersiveTransition: false,
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
        shouldAbortImmersiveTransition: false,
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
        shouldAbortImmersiveTransition: false,
        isImmersiveVoiceModeActive: true,
        onFocusActivated: {},
        onSend: {},
        onVoiceInput: {},
        onImmersiveVoiceInput: {}
    )
    .preferredColorScheme(.dark)
}
