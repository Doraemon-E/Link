//
//  HomeDependencies.swift
//  link
//
//  Created by Codex on 2026/4/6.
//

import Foundation

@MainActor
struct HomeDependencies {
    let appSettings: AppSettings
    let textLanguageRecognitionService: TextLanguageRecognitionService
    let translationService: TranslationService
    let speechRecognitionService: SpeechRecognitionService
    let textToSpeechService: TextToSpeechService
    let audioFilePlaybackService: AudioFilePlaybackService
    let speechPackageManager: SpeechModelPackageManager
    let translationAssetReadinessProvider: any TranslationAssetReadinessProviding
    let modelAssetService: ModelAssetService
    let microphoneRecordingService: MicrophoneRecordingService
}
