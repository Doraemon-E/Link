//
//  HomeLanguageSheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeLanguageSheet: View {
    @Binding var selectedLanguage: SupportedLanguage
    @Binding var isPresented: Bool
    let onCommitSelection: @MainActor @Sendable (SupportedLanguage) -> Void

    @State private var draftSelectedLanguage: SupportedLanguage

    init(
        selectedLanguage: Binding<SupportedLanguage>,
        isPresented: Binding<Bool>,
        onCommitSelection: @escaping @MainActor @Sendable (SupportedLanguage) -> Void = { _ in }
    ) {
        self._selectedLanguage = selectedLanguage
        self._isPresented = isPresented
        self.onCommitSelection = onCommitSelection
        _draftSelectedLanguage = State(initialValue: selectedLanguage.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            languageGrid
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .navigationTitle("选择目标语言")
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
        .presentationDetents([.large])
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
        }
    }

    private func languageCard(for language: SupportedLanguage) -> some View {
        let isSelected = language == draftSelectedLanguage

        return Button {
            draftSelectedLanguage = language
        } label: {
            VStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Text(language.flagEmoji)
                        .font(.system(size: 40))
                        .frame(maxWidth: .infinity)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 6, y: -6)
                    }
                }

                Text(language.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .top)
            .background(cardBackground(isSelected: isSelected))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor.opacity(0.45)
                            : Color(uiColor: .separator).opacity(0.14),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.14)
                    : Color(uiColor: .secondarySystemBackground)
            )
    }

    private func commitDraftSelection() {
        onCommitSelection(draftSelectedLanguage)
        selectedLanguage = draftSelectedLanguage
        isPresented = false
    }
}

#Preview {
    HomeLanguageSheet(
        selectedLanguage: .constant(.english),
        isPresented: .constant(true)
    )
}
