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
    let speechRecognitionService: SpeechRecognitionService
    let textToSpeechService: TextToSpeechService
    let speechPackageManager: SpeechModelPackageManager
    let modelAssetService: ModelAssetService
    let microphoneRecordingService: MicrophoneRecordingService

    var body: some View {
        HomeView(
            appSettings: appSettings,
            translationService: translationService,
            speechRecognitionService: speechRecognitionService,
            textToSpeechService: textToSpeechService,
            speechPackageManager: speechPackageManager,
            modelAssetService: modelAssetService,
            microphoneRecordingService: microphoneRecordingService
        )
    }
}

#Preview {
    let catalogRepository = TranslationModelCatalogRepository(remoteCatalogURL: nil, bundle: .main)
    let translationPackageManager = TranslationModelPackageManager(catalogRepository: catalogRepository)
    let speechCatalogRepository = SpeechModelCatalogRepository(remoteCatalogURL: nil, bundle: .main)
    let speechPackageManager = SpeechModelPackageManager(catalogRepository: speechCatalogRepository)
    let textToSpeechService = SystemTextToSpeechService()
    let assetService = ModelAssetService(
        translationPackageManager: translationPackageManager,
        speechPackageManager: speechPackageManager
    )
    ContentView(
        appSettings: AppSettings(userDefaults: UserDefaults(suiteName: "ContentViewPreview") ?? .standard),
        translationService: MarianTranslationService(modelProvider: translationPackageManager),
        speechRecognitionService: WhisperSpeechRecognitionService(packageManager: speechPackageManager),
        textToSpeechService: textToSpeechService,
        speechPackageManager: speechPackageManager,
        modelAssetService: assetService,
        microphoneRecordingService: MicrophoneRecordingService()
    )
}
