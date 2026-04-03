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

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()

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

                Spacer()
            }
            .navigationTitle("Home")
        }
        .sheet(isPresented: $isLanguageSheetPresented) {
            HomeLanguageSheet(
                selectedLanguage: $selectedLanguage,
                isPresented: $isLanguageSheetPresented
            )
        }
        .safeAreaInset(edge: .bottom) {
            HomeChatInputBar(text: $messageText)
        }
    }
}

#Preview {
    HomeView()
}
