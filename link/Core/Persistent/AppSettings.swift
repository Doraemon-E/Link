//
//  AppSettings.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum UserDefaultsKey {
        static let selectedTargetLanguage = "app.selectedTargetLanguage"
        static let hasShownInitialTargetLanguagePicker = "app.hasShownInitialTargetLanguagePicker"
    }

    var selectedTargetLanguage: SupportedLanguage {
        didSet {
            persistSelectedTargetLanguage()
        }
    }
    var hasShownInitialTargetLanguagePicker: Bool {
        didSet {
            persistHasShownInitialTargetLanguagePicker()
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.selectedTargetLanguage = Self.loadSelectedTargetLanguage(from: userDefaults)
        self.hasShownInitialTargetLanguagePicker = Self.loadHasShownInitialTargetLanguagePicker(from: userDefaults)
    }

    private func persistSelectedTargetLanguage() {
        userDefaults.set(selectedTargetLanguage.rawValue, forKey: UserDefaultsKey.selectedTargetLanguage)
    }

    private func persistHasShownInitialTargetLanguagePicker() {
        userDefaults.set(
            hasShownInitialTargetLanguagePicker,
            forKey: UserDefaultsKey.hasShownInitialTargetLanguagePicker
        )
    }

    private static func loadSelectedTargetLanguage(from userDefaults: UserDefaults) -> SupportedLanguage {
        guard
            let rawValue = userDefaults.string(forKey: UserDefaultsKey.selectedTargetLanguage),
            let language = SupportedLanguage(rawValue: rawValue)
        else {
            return .english
        }

        return language
    }

    private static func loadHasShownInitialTargetLanguagePicker(from userDefaults: UserDefaults) -> Bool {
        userDefaults.bool(forKey: UserDefaultsKey.hasShownInitialTargetLanguagePicker)
    }
}
