//
//  HomeLanguageSheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeLanguageSheet: View {
    enum Mode: Equatable {
        case full
        case targetOnly
    }

    @Binding var sourceLanguage: SupportedLanguage
    @Binding var selectedLanguage: SupportedLanguage
    @Binding var isPresented: Bool
    let mode: Mode
    let onResolveSelection: @Sendable (SupportedLanguage, SupportedLanguage) async -> HomeLanguageSelectionResolution
    let onCommitSelection: @Sendable (SupportedLanguage, SupportedLanguage) -> Void
    let onCommitSelectionRequiringDownload: @Sendable (SupportedLanguage, SupportedLanguage, HomeLanguageDownloadPrompt) -> Void

    @State private var draftSourceLanguage: SupportedLanguage
    @State private var draftSelectedLanguage: SupportedLanguage
    @State private var errorMessage: String?
    @State private var isWorking = false

    init(
        sourceLanguage: Binding<SupportedLanguage>,
        selectedLanguage: Binding<SupportedLanguage>,
        isPresented: Binding<Bool>,
        mode: Mode,
        onResolveSelection: @escaping @Sendable (SupportedLanguage, SupportedLanguage) async -> HomeLanguageSelectionResolution = { _, _ in .ready },
        onCommitSelection: @escaping @Sendable (SupportedLanguage, SupportedLanguage) -> Void = { _, _ in },
        onCommitSelectionRequiringDownload: @escaping @Sendable (SupportedLanguage, SupportedLanguage, HomeLanguageDownloadPrompt) -> Void = { _, _, _ in }
    ) {
        self._sourceLanguage = sourceLanguage
        self._selectedLanguage = selectedLanguage
        self._isPresented = isPresented
        self.mode = mode
        self.onResolveSelection = onResolveSelection
        self.onCommitSelection = onCommitSelection
        self.onCommitSelectionRequiringDownload = onCommitSelectionRequiringDownload
        _draftSourceLanguage = State(initialValue: sourceLanguage.wrappedValue)
        _draftSelectedLanguage = State(initialValue: selectedLanguage.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            Group {
                if mode == .full {
                    HStack(alignment: .top, spacing: 16) {
                        languageColumn(
                            title: "源语言",
                            selection: draftSourceLanguage,
                            onSelect: selectSourceLanguage
                        )

                        VStack(spacing: 12) {
                            Spacer(minLength: 44)

                            Image(systemName: "arrow.right")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 42, height: 42)
                                .background(Color(uiColor: .secondarySystemBackground), in: Circle())

                            Text("翻译方向")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()
                        }

                        languageColumn(
                            title: "目标语言",
                            selection: draftSelectedLanguage,
                            onSelect: selectTargetLanguage
                        )
                    }
                } else {
                    languageColumn(
                        title: "目标语言",
                        selection: draftSelectedLanguage,
                        onSelect: selectTargetLanguage
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .navigationTitle(mode == .full ? "选择语言" : "选择目标语言")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await confirmSelection()
                        }
                    } label: {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("完成")
                        }
                    }
                    .disabled(isWorking)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .alert(
            "暂时无法使用该翻译方向",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func languageColumn(
        title: String,
        selection: SupportedLanguage,
        onSelect: @escaping (SupportedLanguage) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(SupportedLanguage.allCases) { language in
                        let isSelected = language == selection

                        Button {
                            guard !isWorking else { return }
                            onSelect(language)
                        } label: {
                            HStack {
                                Text(language.displayName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)

                                Spacer(minLength: 8)

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(cardBackground(isSelected: isSelected))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        (isSelected ? Color.accentColor : Color(uiColor: .separator))
                                            .opacity(isSelected ? 0.4 : 0.15),
                                        lineWidth: 1
                                    )
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func cardBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
    }

    private func selectSourceLanguage(_ language: SupportedLanguage) {
        draftSourceLanguage = language
    }

    private func selectTargetLanguage(_ language: SupportedLanguage) {
        draftSelectedLanguage = language
    }

    private func confirmSelection() async {
        guard !isWorking else { return }

        isWorking = true
        defer { isWorking = false }

        let resolution = await onResolveSelection(draftSourceLanguage, draftSelectedLanguage)

        switch resolution {
        case .ready:
            commitDraftSelection()
        case .requiresDownload(let prompt):
            commitDraftSelection(requiringDownload: prompt)
        case .failure(let message):
            errorMessage = message
        }
    }

    private func commitDraftSelection() {
        onCommitSelection(draftSourceLanguage, draftSelectedLanguage)
        sourceLanguage = draftSourceLanguage
        selectedLanguage = draftSelectedLanguage
        isPresented = false
    }

    private func commitDraftSelection(requiringDownload prompt: HomeLanguageDownloadPrompt) {
        onCommitSelectionRequiringDownload(draftSourceLanguage, draftSelectedLanguage, prompt)
        sourceLanguage = draftSourceLanguage
        selectedLanguage = draftSelectedLanguage
        isPresented = false
    }
}

#Preview {
    HomeLanguageSheet(
        sourceLanguage: .constant(.chinese),
        selectedLanguage: .constant(.english),
        isPresented: .constant(true),
        mode: .full
    )
}
