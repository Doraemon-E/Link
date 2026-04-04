//
//  ContentView.swift
//  link
//
//  Created by Doracmon on 2026/4/3.
//

import SwiftUI

struct ContentView: View {
    let appSettings: AppSettings
    let translationService: TranslationService
    let translationModelInstaller: TranslationModelInstaller
    let speechRecognitionService: SpeechRecognitionService
    let speechModelInstaller: SpeechModelInstaller
    let microphoneRecordingService: MicrophoneRecordingService

    var body: some View {
        HomeView(
            appSettings: appSettings,
            translationService: translationService,
            translationModelInstaller: translationModelInstaller,
            speechRecognitionService: speechRecognitionService,
            speechModelInstaller: speechModelInstaller,
            microphoneRecordingService: microphoneRecordingService
        )
    }
}

#Preview {
    let catalogService = TranslationModelCatalogService(remoteCatalogURL: nil, bundle: .main)
    let installer = TranslationModelInstaller(catalogService: catalogService)
    let speechCatalogService = SpeechModelCatalogService(remoteCatalogURL: nil, bundle: .main)
    let speechInstaller = SpeechModelInstaller(catalogService: speechCatalogService)
    ContentView(
        appSettings: AppSettings(userDefaults: UserDefaults(suiteName: "ContentViewPreview") ?? .standard),
        translationService: MarianTranslationService(installer: installer),
        translationModelInstaller: installer,
        speechRecognitionService: WhisperSpeechRecognitionService(installer: speechInstaller),
        speechModelInstaller: speechInstaller,
        microphoneRecordingService: MicrophoneRecordingService()
    )
}
