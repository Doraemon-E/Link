//
//  HomeView.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeView: View {
    @State private var selectedLanguage: HomeLanguage = .english
    @State private var isLanguageSheetPresented = false
    @State private var messageText = ""
    @State private var isChatInputFocused = false

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()

                if !isChatInputFocused {
                    Button {
                        isLanguageSheetPresented = true
                    } label: {
                        Text(selectedLanguage.displayName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .padding(.horizontal, 20)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(Color(uiColor: .separator), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                }

                Spacer()
            }
            .navigationTitle(isChatInputFocused ? "" : "Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isChatInputFocused {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 10) {
                            HomeToolbarLanguageChip(title: HomeLanguage.chinese.displayName)

                            Image(systemName: "arrow.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Button {
                                isLanguageSheetPresented = true
                            } label: {
                                HomeToolbarLanguageChip(title: selectedLanguage.displayName)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .animation(.snappy, value: isChatInputFocused)
        }
        .sheet(isPresented: $isLanguageSheetPresented) {
            HomeLanguageSheet(
                selectedLanguage: $selectedLanguage,
                isPresented: $isLanguageSheetPresented
            )
        }
        .safeAreaInset(edge: .bottom) {
            HomeChatInputBar(
                text: $messageText,
                isFocused: $isChatInputFocused
            )
        }
    }
}

#Preview {
    HomeView()
}
