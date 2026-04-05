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
    }

    var selectedTargetLanguage: SupportedLanguage {
        didSet {
            persistSelectedTargetLanguage()
        }
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.selectedTargetLanguage = Self.loadSelectedTargetLanguage(from: userDefaults)
    }

    private func persistSelectedTargetLanguage() {
        userDefaults.set(selectedTargetLanguage.rawValue, forKey: UserDefaultsKey.selectedTargetLanguage)
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
}
