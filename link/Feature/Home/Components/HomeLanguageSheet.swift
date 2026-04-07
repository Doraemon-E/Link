//
//  HomeLanguageSheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeLanguageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let selectedLanguage: SupportedLanguage
    let onCommitSelection: @MainActor @Sendable (SupportedLanguage) -> Void

    @State private var draftSelectedLanguage: SupportedLanguage

    init(
        title: String,
        selectedLanguage: SupportedLanguage,
        onCommitSelection: @escaping @MainActor @Sendable (SupportedLanguage) -> Void = { _ in }
    ) {
        self.title = title
        self.selectedLanguage = selectedLanguage
        self.onCommitSelection = onCommitSelection
        _draftSelectedLanguage = State(initialValue: selectedLanguage)
    }

    var body: some View {
        NavigationStack {
            languageGrid
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        commitDraftSelection()
                    } label: {
                        Text("完成")
                    }
                }
            }
        }
        .presentationDetents([.fraction(0.8), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            draftSelectedLanguage = selectedLanguage
        }
    }

    private var languageGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                ForEach(SupportedLanguage.allCases) { language in
                    languageCard(for: language)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func languageCard(for language: SupportedLanguage) -> some View {
        let isSelected = language == draftSelectedLanguage

        return Button {
            draftSelectedLanguage = language
        } label: {
            VStack(spacing: 2) {
                Text(language.flagEmoji)
                    .font(.system(size: 40))
                    .frame(maxWidth: .infinity)

                Text(language.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            // .background(cardBackground(isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .systemGroupedBackground))
            )
    }

    private func commitDraftSelection() {
        onCommitSelection(draftSelectedLanguage)
        dismiss()
    }
}

#Preview {
    HomeLanguageSheet(
        title: "选择目标语言",
        selectedLanguage: .english
    )
}
