//
//  ModelDownloadCenter.swift
//  link
//
//  Created by Codex on 2026/4/4.
//

import Foundation

actor ModelDownloadCenter {
    private let translationInstaller: TranslationModelInstaller
    private let speechInstaller: SpeechModelInstaller
    private let downloader: ResumableArchiveDownloader

    private var transientItemsByID: [String: ModelDownloadItem] = [:]
    private var installedItemsByID: [String: ModelDownloadItem] = [:]
    private var availableItemsByID: [String: ModelDownloadItem] = [:]
    private var runningTasksByID: [String: Task<Void, Never>] = [:]
    private var continuations: [UUID: AsyncStream<ModelDownloadsSnapshot>.Continuation] = [:]

    init(
        translationInstaller: TranslationModelInstaller,
        speechInstaller: SpeechModelInstaller,
        downloader: ResumableArchiveDownloader = ResumableArchiveDownloader()
    ) {
        self.translationInstaller = translationInstaller
        self.speechInstaller = speechInstaller
        self.downloader = downloader
    }

    func warmUp() async {
        await reloadInstalledItems()
        await reloadPersistedDownloads()
        await reloadAvailableItems()
    }

    func streamSnapshots() -> AsyncStream<ModelDownloadsSnapshot> {
        AsyncStream { continuation in
            let token = UUID()
            Task {
                await self.registerContinuation(continuation, token: token)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeContinuation(token)
                }
            }
        }
    }

    func startTranslationDownloads(packageIDs: [String]) async {
        for packageID in packageIDs {
            await startDownload(kind: .translation, packageId: packageID)
        }
    }

    func startSpeechDownload(packageId: String) async {
        await startDownload(kind: .speech, packageId: packageId)
    }

    func retry(itemID: String) async {
        guard let item = transientItemsByID[itemID] else {
            return
        }

        await startDownload(kind: item.kind, packageId: item.descriptor.packageId)
    }

    func resume(itemID: String) async {
        guard let item = transientItemsByID[itemID] else {
            return
        }

        await startDownload(kind: item.kind, packageId: item.descriptor.packageId)
    }

    func removeInstalled(itemID: String) async throws {
        guard let item = installedItemsByID[itemID] else {
            return
        }

        switch item.kind {
        case .translation:
            try await translationInstaller.remove(packageId: item.descriptor.packageId)
        case .speech:
            try await speechInstaller.remove(packageId: item.descriptor.packageId)
        }

        await reloadInstalledItems()
        await reloadAvailableItems()
    }

    func snapshot() -> ModelDownloadsSnapshot {
        currentSnapshot()
    }

    private func startDownload(kind: ModelAssetKind, packageId: String) async {
        guard let descriptor = try? await resolveDescriptor(kind: kind, packageId: packageId) else {
            return
        }

        let itemID = descriptor.id
        guard runningTasksByID[itemID] == nil else {
            return
        }

        transientItemsByID[itemID] = ModelDownloadItem(
            descriptor: descriptor,
            progress: ModelDownloadProgress(
                phase: .preparing,
                downloadedBytes: 0,
                totalBytes: descriptor.archiveSize
            ),
            errorMessage: nil,
            installedAt: nil,
            isInstalled: false
        )
        installedItemsByID.removeValue(forKey: itemID)
        emitSnapshot()

        let task = Task { [descriptor] in
            await self.runDownload(for: descriptor)
        }
        runningTasksByID[itemID] = task
    }

    private func runDownload(for descriptor: ModelDownloadDescriptor) async {
        let itemID = descriptor.id

        do {
            let archiveURL = try await downloader.download(descriptor: descriptor) { progress in
                await self.updateTransientItem(
                    for: descriptor,
                    progress: progress,
                    errorMessage: nil
                )
            }

            await updateTransientItem(
                for: descriptor,
                progress: ModelDownloadProgress(
                    phase: .verifying,
                    downloadedBytes: descriptor.archiveSize,
                    totalBytes: descriptor.archiveSize
                ),
                errorMessage: nil
            )

            switch descriptor.kind {
            case .translation:
                await updateTransientItem(
                    for: descriptor,
                    progress: ModelDownloadProgress(
                        phase: .installing,
                        downloadedBytes: descriptor.archiveSize,
                        totalBytes: descriptor.archiveSize
                    ),
                    errorMessage: nil
                )
                _ = try await translationInstaller.install(
                    packageId: descriptor.packageId,
                    archiveURL: archiveURL
                )
            case .speech:
                await updateTransientItem(
                    for: descriptor,
                    progress: ModelDownloadProgress(
                        phase: .installing,
                        downloadedBytes: descriptor.archiveSize,
                        totalBytes: descriptor.archiveSize
                    ),
                    errorMessage: nil
                )
                _ = try await speechInstaller.install(
                    packageId: descriptor.packageId,
                    archiveURL: archiveURL
                )
            }

            try? await downloader.removePersistedDownload(for: descriptor)
            transientItemsByID.removeValue(forKey: itemID)
            runningTasksByID[itemID] = nil
            await reloadInstalledItems()
            await reloadAvailableItems()
        } catch {
            runningTasksByID[itemID] = nil
            let previousPhase = transientItemsByID[itemID]?.progress.phase

            if previousPhase == .verifying || previousPhase == .installing {
                try? await downloader.removePersistedDownload(for: descriptor)
            }

            let persistedProgress = try? await downloader.persistedProgress(for: descriptor)
            let progress = persistedProgress ?? ModelDownloadProgress(
                phase: .failed,
                downloadedBytes: 0,
                totalBytes: descriptor.archiveSize
            )

            transientItemsByID[itemID] = ModelDownloadItem(
                descriptor: descriptor,
                progress: ModelDownloadProgress(
                    phase: .failed,
                    downloadedBytes: progress.downloadedBytes,
                    totalBytes: progress.totalBytes,
                    isResumable: progress.downloadedBytes > 0
                ),
                errorMessage: normalizedErrorMessage(from: error),
                installedAt: nil,
                isInstalled: false
            )

            emitSnapshot()
        }
    }

    private func updateTransientItem(
        for descriptor: ModelDownloadDescriptor,
        progress: ModelDownloadProgress,
        errorMessage: String?
    ) {
        transientItemsByID[descriptor.id] = ModelDownloadItem(
            descriptor: descriptor,
            progress: progress,
            errorMessage: errorMessage,
            installedAt: nil,
            isInstalled: false
        )
        emitSnapshot()
    }

    private func reloadInstalledItems() async {
        var items: [String: ModelDownloadItem] = [:]

        if let translationPackages = try? await translationInstaller.installedPackages() {
            for package in translationPackages {
                let descriptor = makeTranslationInstalledDescriptor(from: package)
                items[descriptor.id] = ModelDownloadItem(
                    descriptor: descriptor,
                    progress: ModelDownloadProgress(
                        phase: .completed,
                        downloadedBytes: descriptor.archiveSize,
                        totalBytes: descriptor.archiveSize
                    ),
                    errorMessage: nil,
                    installedAt: package.installedAt,
                    isInstalled: true
                )
            }
        }

        if let speechPackages = try? await speechInstaller.installedPackages() {
            for package in speechPackages {
                let descriptor = makeSpeechInstalledDescriptor(from: package)
                items[descriptor.id] = ModelDownloadItem(
                    descriptor: descriptor,
                    progress: ModelDownloadProgress(
                        phase: .completed,
                        downloadedBytes: descriptor.archiveSize,
                        totalBytes: descriptor.archiveSize
                    ),
                    errorMessage: nil,
                    installedAt: package.installedAt,
                    isInstalled: true
                )
            }
        }

        installedItemsByID = items
        emitSnapshot()
    }

    private func reloadPersistedDownloads() async {
        var restoredItems: [String: ModelDownloadItem] = [:]

        for kind in [ModelAssetKind.translation, .speech] {
            let persistedStates = (try? await downloader.persistedStates(for: kind)) ?? []

            for state in persistedStates {
                guard runningTasksByID[ModelDownloadDescriptor.itemID(kind: kind, packageId: state.packageId)] == nil else {
                    continue
                }

                guard let descriptor = try? await resolveDescriptor(
                    kind: kind,
                    packageId: state.packageId,
                    fallbackURL: state.archiveURL,
                    fallbackArchiveSize: state.archiveSize
                ) else {
                    continue
                }

                let progress = ModelDownloadProgress(
                    phase: .pausedResumable,
                    downloadedBytes: state.downloadedBytes,
                    totalBytes: max(state.archiveSize, descriptor.archiveSize),
                    isResumable: state.downloadedBytes > 0
                )

                restoredItems[descriptor.id] = ModelDownloadItem(
                    descriptor: descriptor,
                    progress: progress,
                    errorMessage: nil,
                    installedAt: nil,
                    isInstalled: false
                )
            }
        }

        for (itemID, item) in restoredItems {
            if installedItemsByID[itemID] == nil {
                transientItemsByID[itemID] = item
            }
        }

        emitSnapshot()
    }

    private func reloadAvailableItems() async {
        var items: [String: ModelDownloadItem] = [:]
        let hiddenIDs = Set(installedItemsByID.keys).union(transientItemsByID.keys)

        if let translationPackages = try? await translationInstaller.packages() {
            for package in translationPackages {
                let descriptor = makeTranslationDescriptor(from: package)
                guard !hiddenIDs.contains(descriptor.id) else {
                    continue
                }

                items[descriptor.id] = ModelDownloadItem(
                    descriptor: descriptor,
                    progress: .idle,
                    errorMessage: nil,
                    installedAt: nil,
                    isInstalled: false
                )
            }
        }

        if let speechPackages = try? await speechInstaller.packages() {
            for package in speechPackages {
                let descriptor = makeSpeechDescriptor(from: package)
                guard !hiddenIDs.contains(descriptor.id) else {
                    continue
                }

                items[descriptor.id] = ModelDownloadItem(
                    descriptor: descriptor,
                    progress: .idle,
                    errorMessage: nil,
                    installedAt: nil,
                    isInstalled: false
                )
            }
        }

        availableItemsByID = items
        emitSnapshot()
    }

    private func resolveDescriptor(
        kind: ModelAssetKind,
        packageId: String,
        fallbackURL: URL? = nil,
        fallbackArchiveSize: Int64? = nil
    ) async throws -> ModelDownloadDescriptor {
        switch kind {
        case .translation:
            if let package = try await translationInstaller.package(packageId: packageId) {
                return makeTranslationDescriptor(from: package)
            }
        case .speech:
            if let package = try await speechInstaller.package(packageId: packageId) {
                return makeSpeechDescriptor(from: package)
            }
        }

        guard let fallbackURL else {
            throw TranslationError.packageMissing(packageId: packageId)
        }

        return ModelDownloadDescriptor(
            kind: kind,
            packageId: packageId,
            version: "",
            title: packageId,
            subtitle: kind.displayName,
            archiveURL: fallbackURL,
            archiveSize: fallbackArchiveSize ?? 0,
            installedSize: 0,
            sha256: ""
        )
    }

    private func makeTranslationDescriptor(from package: TranslationModelPackage) -> ModelDownloadDescriptor {
        let sourceName = HomeLanguage.fromTranslationModelCode(package.source)?.displayName ?? package.source
        let targetName = HomeLanguage.fromTranslationModelCode(package.target)?.displayName ?? package.target

        return ModelDownloadDescriptor(
            kind: .translation,
            packageId: package.packageId,
            version: package.version,
            title: "\(sourceName) -> \(targetName)",
            subtitle: "翻译模型",
            archiveURL: package.archiveURL,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: package.sha256
        )
    }

    private func makeSpeechDescriptor(from package: SpeechModelPackage) -> ModelDownloadDescriptor {
        ModelDownloadDescriptor(
            kind: .speech,
            packageId: package.packageId,
            version: package.version,
            title: "语音识别",
            subtitle: "Whisper",
            archiveURL: package.archiveURL,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: package.sha256
        )
    }

    private func makeTranslationInstalledDescriptor(
        from package: TranslationInstalledPackageSummary
    ) -> ModelDownloadDescriptor {
        let sourceName = package.sourceLanguage?.displayName ?? package.packageId
        let targetName = package.targetLanguage?.displayName ?? ""
        let title = package.targetLanguage == nil ? package.packageId : "\(sourceName) -> \(targetName)"

        return ModelDownloadDescriptor(
            kind: .translation,
            packageId: package.packageId,
            version: package.version,
            title: title,
            subtitle: "翻译模型",
            archiveURL: URL(string: "https://example.invalid/\(package.packageId).zip")!,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: ""
        )
    }

    private func makeSpeechInstalledDescriptor(from package: SpeechInstalledPackageSummary) -> ModelDownloadDescriptor {
        ModelDownloadDescriptor(
            kind: .speech,
            packageId: package.packageId,
            version: package.version,
            title: "语音识别",
            subtitle: "Whisper",
            archiveURL: URL(string: "https://example.invalid/\(package.packageId).zip")!,
            archiveSize: package.archiveSize,
            installedSize: package.installedSize,
            sha256: ""
        )
    }

    private func currentSnapshot() -> ModelDownloadsSnapshot {
        let installedItemIDs = Set(installedItemsByID.keys)
        let transientItemIDs = Set(transientItemsByID.keys)
        let transientItems = transientItemsByID.values.filter { !installedItemIDs.contains($0.id) }
        let availableItems = availableItemsByID.values.filter {
            !installedItemIDs.contains($0.id) && !transientItemIDs.contains($0.id)
        }
        let items = (transientItems + installedItemsByID.values + availableItems)
            .sorted(by: compareItems)

        let summary = ModelDownloadManagerSummary(
            activeCount: items.filter {
                !$0.isInstalled && [.preparing, .downloading, .verifying, .installing].contains($0.progress.phase)
            }.count,
            resumableCount: items.filter {
                !$0.isInstalled && $0.progress.phase == .pausedResumable
            }.count,
            failedCount: items.filter {
                !$0.isInstalled && $0.progress.phase == .failed
            }.count,
            installedCount: items.filter(\.isInstalled).count,
            availableCount: items.filter {
                !$0.isInstalled && $0.progress.phase == .idle
            }.count
        )

        return ModelDownloadsSnapshot(items: items, summary: summary)
    }

    private func compareItems(lhs: ModelDownloadItem, rhs: ModelDownloadItem) -> Bool {
        let phaseOrder: [ModelDownloadPhase: Int] = [
            .preparing: 0,
            .downloading: 1,
            .verifying: 2,
            .installing: 3,
            .pausedResumable: 4,
            .failed: 5,
            .idle: 6,
            .completed: 7
        ]

        let lhsOrder = phaseOrder[lhs.progress.phase, default: 99]
        let rhsOrder = phaseOrder[rhs.progress.phase, default: 99]
        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder
        }

        switch (lhs.installedAt, rhs.installedAt) {
        case let (.some(lhsDate), .some(rhsDate)) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        default:
            return lhs.descriptor.title < rhs.descriptor.title
        }
    }

    private func emitSnapshot() {
        let snapshot = currentSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func normalizedErrorMessage(from error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription,
           !description.isEmpty {
            return description
        }

        return error.localizedDescription
    }

    private func removeContinuation(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private func registerContinuation(
        _ continuation: AsyncStream<ModelDownloadsSnapshot>.Continuation,
        token: UUID
    ) {
        continuations[token] = continuation
        continuation.yield(currentSnapshot())
    }
}
