//
//  HomeView.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeView: View {
    @Namespace private var languageChipAnimation

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
                        HomeLanguageChip(
                            title: selectedLanguage.displayName,
                            style: .hero
                        )
                        .matchedGeometryEffect(
                            id: "selected-language-chip",
                            in: languageChipAnimation
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if isChatInputFocused {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                        isChatInputFocused = false
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .animation(.easeInOut(duration: 0.35), value: isChatInputFocused)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            topBar
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

    private var topBar: some View {
        ZStack {
            if isChatInputFocused {
                HStack(spacing: 10) {
                    HomeLanguageChip(
                        title: HomeLanguage.chinese.displayName,
                        style: .toolbar
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))

                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity.animation(.easeInOut(duration: 0.35)))

                    Button {
                        isLanguageSheetPresented = true
                    } label: {
                        HomeLanguageChip(
                            title: selectedLanguage.displayName,
                            style: .toolbar
                        )
                        .matchedGeometryEffect(
                            id: "selected-language-chip",
                            in: languageChipAnimation
                        )
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .padding(.horizontal, 16)
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview {
    HomeView()
}
