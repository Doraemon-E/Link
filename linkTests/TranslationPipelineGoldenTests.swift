//
//  TranslationPipelineGoldenTests.swift
//  linkTests
//
//  Created by Codex on 2026/4/4.
//

import XCTest
@testable import link

final class TranslationPipelineGoldenTests: XCTestCase {
    private static let autoInstallModels = ProcessInfo.processInfo.environment["LINK_TEST_AUTO_INSTALL_MODELS"] == "1"

    private var testCases: [TranslationGoldenCase] = []
    private var packageManager: TranslationModelPackageManager!
    private var translationService: TranslationService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true

        let catalogRepository = TranslationModelCatalogRepository(
            remoteCatalogURL: nil,
            bundle: testBundle
        )
        let packageManager = TranslationModelPackageManager(catalogRepository: catalogRepository)
        self.packageManager = packageManager
        self.translationService = MarianTranslationService(modelProvider: packageManager)
        self.testCases = try TranslationGoldenCaseStore.load()
    }

    override func tearDownWithError() throws {
        testCases = []
        translationService = nil
        packageManager = nil
        try super.tearDownWithError()
    }

    func testFixtureCountIs90() {
        XCTAssertEqual(testCases.count, 90, "固定测试用例数量应该保持为 90 条。")
    }

    func testChineseToEnglishGoldenCases() async throws {
        try await runCases(for: .chinese)
    }

    func testJapaneseToEnglishGoldenCases() async throws {
        try await runCases(for: .japanese)
    }

    func testKoreanToEnglishGoldenCases() async throws {
        try await runCases(for: .korean)
    }

    func testFrenchToEnglishGoldenCases() async throws {
        try await runCases(for: .french)
    }

    func testGermanToEnglishGoldenCases() async throws {
        try await runCases(for: .german)
    }

    func testRussianToEnglishGoldenCases() async throws {
        try await runCases(for: .russian)
    }

    func testSpanishToEnglishGoldenCases() async throws {
        try await runCases(for: .spanish)
    }

    func testItalianToEnglishGoldenCases() async throws {
        try await runCases(for: .italian)
    }

    func testEnglishToChineseGoldenCases() async throws {
        try await runCases(for: .english)
    }

    private func runCases(for sourceLanguage: SupportedLanguage) async throws {
        let cases = testCases.filter { $0.sourceLanguage == sourceLanguage }
        XCTAssertEqual(cases.count, 10, "\(sourceLanguage.displayName) 应该固定有 10 条测试用例。")

        for testCase in cases {
            try await runSingleCase(testCase)
        }
    }

    private func runSingleCase(_ testCase: TranslationGoldenCase) async throws {
        let initialRoute = try await translationService.route(
            source: testCase.sourceLanguage,
            target: testCase.targetLanguage
        )

        let initialRequirement = try await packageManager.assetRequirement(for: initialRoute)

        if !initialRequirement.isReady {
            let missingPackageIDs = initialRequirement.packageIds

            if Self.autoInstallModels {
                for packageID in missingPackageIDs {
                    _ = try await packageManager.install(packageId: packageID)
                }
            } else {
                let summary = summaryText(
                    for: testCase,
                    route: describe(route: initialRoute),
                    actual: nil,
                    error: "缺少模型包：\(missingPackageIDs.joined(separator: ", "))"
                )
                recordActivity(named: testCase.id, summary: summary)
                XCTFail(summary)
                return
            }
        }

        let resolvedRoute = try await translationService.route(
            source: testCase.sourceLanguage,
            target: testCase.targetLanguage
        )
        let actual = try await translationService.translate(
            text: testCase.input,
            source: testCase.sourceLanguage,
            target: testCase.targetLanguage
        )

        let normalizedExpected = normalize(testCase.expected)
        let normalizedActual = normalize(actual)
        let summary = summaryText(
            for: testCase,
            route: describe(route: resolvedRoute),
            actual: actual,
            error: nil
        )

        recordActivity(named: testCase.id, summary: summary)
        XCTAssertEqual(normalizedActual, normalizedExpected, summary)
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describe(route: TranslationRoute) -> String {
        guard !route.steps.isEmpty else {
            return "\(route.source.displayName)->\(route.target.displayName) | direct"
        }

        return route.steps.map { step in
            "\(step.source.displayName)->\(step.target.displayName)"
        }
        .joined(separator: " | ")
    }

    private func summaryText(
        for testCase: TranslationGoldenCase,
        route: String,
        actual: String?,
        error: String?
    ) -> String {
        var lines = [
            "case: \(testCase.id)",
            "category: \(testCase.category)",
            "source: \(testCase.sourceLanguage.rawValue)",
            "target: \(testCase.targetLanguage.rawValue)",
            "route: \(route)",
            "input: \(testCase.input)",
            "expected: \(testCase.expected)",
            "actual: \(actual ?? "<nil>")"
        ]

        if let error {
            lines.append("error: \(error)")
        }

        return lines.joined(separator: "\n")
    }

    private func recordActivity(named name: String, summary: String) {
        let attachment = XCTAttachment(string: summary)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print(summary)
    }
}
