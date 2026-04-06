//
//  HomePresentationModifier.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import SwiftUI

struct HomePresentationModifier: ViewModifier {
    let store: HomeStore
    let viewState: HomeStore.ViewState
    let runtimeContext: HomeRuntimeContext

    func body(content: Content) -> some View {
        content
            .sheet(
                item: itemBinding(\.languageSheetContext),
                onDismiss: store.dismissLanguageSheet
            ) { context in
                HomeLanguageSheet(
                    title: context.title,
                    selectedLanguage: context.selectedLanguage,
                    onCommitSelection: { language in
                        store.commitLanguageSheetSelection(
                            language,
                            in: runtimeContext
                        )
                    }
                )
            }
            .sheet(isPresented: boolBinding(\.isSessionHistoryPresented)) {
                HomeSessionHistorySheet(
                    sessions: viewState.historySessions,
                    currentSessionID: viewState.currentSessionID,
                    onSelect: { sessionID in
                        store.selectSession(
                            id: sessionID,
                            in: runtimeContext
                        )
                    },
                    isPresented: boolBinding(\.isSessionHistoryPresented)
                )
            }
            .confirmationDialog(
                store.activeDownloadPrompt?.title ?? "",
                isPresented: presenceBinding(
                    for: \.activeDownloadPrompt,
                    onDismiss: store.dismissDownloadPrompt
                ),
                presenting: store.activeDownloadPrompt
            ) { prompt in
                Button("前往下载管理") {
                    store.openDownloadManagerForActiveTranslationPrompt()
                }

                Button("取消", role: .cancel) {
                    store.dismissDownloadPrompt()
                }
            } message: { prompt in
                Text(prompt.message)
            }
            .confirmationDialog(
                store.activeSpeechDownloadPrompt?.title ?? "",
                isPresented: presenceBinding(
                    for: \.activeSpeechDownloadPrompt,
                    onDismiss: store.dismissSpeechDownloadPrompt
                ),
                presenting: store.activeSpeechDownloadPrompt
            ) { prompt in
                Button("前往下载管理") {
                    let packageId = prompt.packageId
                    let shouldResumeRecording = store.pendingVoiceStartAfterInstall

                    store.openDownloadManagerForSpeechPrompt(
                        packageId: packageId,
                        shouldResumeRecording: shouldResumeRecording
                    )
                }

                Button("取消", role: .cancel) {
                    store.dismissSpeechDownloadPrompt()
                }
            } message: { prompt in
                Text(prompt.message)
            }
            .alert(
                "模型下载失败",
                isPresented: messagePresenceBinding(\.downloadErrorMessage)
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(store.downloadErrorMessage ?? "")
            }
            .alert(
                "输入语言识别失败",
                isPresented: messagePresenceBinding(\.messageErrorMessage)
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(store.messageErrorMessage ?? "")
            }
            .alert(
                "消息更新失败",
                isPresented: messagePresenceBinding(\.messageMutationErrorMessage)
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(store.messageMutationErrorMessage ?? "")
            }
            .alert(
                "语音识别失败",
                isPresented: messagePresenceBinding(\.speechErrorMessage)
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(store.speechErrorMessage ?? "")
            }
            .alert(
                "语音播放失败",
                isPresented: messagePresenceBinding(\.playbackErrorMessage)
            ) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(store.playbackErrorMessage ?? "")
            }
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<HomeStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store[keyPath: keyPath] },
            set: { store[keyPath: keyPath] = $0 }
        )
    }

    private func boolBinding(
        _ keyPath: ReferenceWritableKeyPath<HomeStore, Bool>
    ) -> Binding<Bool> {
        binding(keyPath)
    }

    private func itemBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<HomeStore, Value?>
    ) -> Binding<Value?> {
        binding(keyPath)
    }

    private func presenceBinding<Value>(
        for keyPath: KeyPath<HomeStore, Value?>,
        onDismiss: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { store[keyPath: keyPath] != nil },
            set: { isPresented in
                if !isPresented {
                    onDismiss()
                }
            }
        )
    }

    private func messagePresenceBinding(
        _ keyPath: ReferenceWritableKeyPath<HomeStore, String?>
    ) -> Binding<Bool> {
        Binding(
            get: { store[keyPath: keyPath] != nil },
            set: { isPresented in
                if !isPresented {
                    store[keyPath: keyPath] = nil
                }
            }
        )
    }
}

extension View {
    func homePresentation(
        store: HomeStore,
        viewState: HomeStore.ViewState,
        runtimeContext: HomeRuntimeContext
    ) -> some View {
        modifier(
            HomePresentationModifier(
                store: store,
                viewState: viewState,
                runtimeContext: runtimeContext
            )
        )
    }
}
