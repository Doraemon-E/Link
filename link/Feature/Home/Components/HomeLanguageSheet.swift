//
//  HomeLanguageSheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeLanguageSheet: View {
    @Binding var sourceLanguage: HomeLanguage
    @Binding var selectedLanguage: HomeLanguage
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 16) {
                languageColumn(
                    title: "源语言",
                    selection: sourceLanguage,
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
                    selection: selectedLanguage,
                    onSelect: selectTargetLanguage
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .navigationTitle("选择语言")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func languageColumn(
        title: String,
        selection: HomeLanguage,
        onSelect: @escaping (HomeLanguage) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(HomeLanguage.allCases) { language in
                        let isSelected = language == selection

                        Button {
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

    private func selectSourceLanguage(_ language: HomeLanguage) {
        sourceLanguage = language
    }

    private func selectTargetLanguage(_ language: HomeLanguage) {
        selectedLanguage = language
    }
}

#Preview {
    HomeLanguageSheet(
        sourceLanguage: .constant(.chinese),
        selectedLanguage: .constant(.english),
        isPresented: .constant(true)
    )
}
