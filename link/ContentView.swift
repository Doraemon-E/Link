//
//  ContentView.swift
//  link
//
//  Created by Doracmon on 2026/4/3.
//

import SwiftUI

struct ContentView: View {
    let translationService: TranslationService
    let translationModelInstaller: TranslationModelInstaller

    var body: some View {
        HomeView(
            translationService: translationService,
            translationModelInstaller: translationModelInstaller
        )
    }
}

#Preview {
    let catalogService = TranslationModelCatalogService(remoteCatalogURL: nil, bundle: .main)
    let installer = TranslationModelInstaller(catalogService: catalogService)
    ContentView(
        translationService: MarianTranslationService(installer: installer),
        translationModelInstaller: installer
    )
}
