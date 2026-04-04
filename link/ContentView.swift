//
//  ContentView.swift
//  link
//
//  Created by Doracmon on 2026/4/3.
//

import SwiftUI

struct ContentView: View {
    let translationService: TranslationService

    var body: some View {
        HomeView(translationService: translationService)
    }
}

#Preview {
    ContentView(translationService: MarianTranslationService())
}
