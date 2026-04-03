//
//  HomeLanguageSheet.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import SwiftUI

struct HomeLanguageSheet: View {
    @Binding var selectedLanguage: HomeLanguage
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List(HomeLanguage.allCases) { language in
                Button {
                    selectedLanguage = language
                    isPresented = false
                } label: {
                    HStack {
                        Text(language.displayName)
                            .foregroundStyle(.primary)

                        Spacer()

                        if language == selectedLanguage {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("选择语言")
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    HomeLanguageSheet(
        selectedLanguage: .constant(.english),
        isPresented: .constant(true)
    )
}
