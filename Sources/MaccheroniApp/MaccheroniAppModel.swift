import AVFoundation
import AppKit
import Foundation
import MaccheroniCore
import MaccheroniPostprocess
import Observation

@MainActor
@Observable
final class MaccheroniAppModel {
    private(set) var profiles: [AppProfile]
    private(set) var records: [LibraryRecord]
    private(set) var selectedRun: LoadedRun?
    private(set) var progress: RunProgressSnapshot?
    private(set) var captureMeters = CaptureMeters.silent
    private(set) var captureElapsedS: Double = 0
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    private(set) var activeRecordID: UUID?
    private(set) var runFailures: [UUID: Failure]
    private(set) var codexAvailability: CodexAvailability

    var selection: AppSelection = .capture {
        didSet { refreshSelectedRun() }
    }
    var selectedProfileID: AppProfileID {
        didSet { defaults.set(selectedProfileID.rawValue, forKey: "selectedProfile") }
    }
    var selectedPostprocess: PostprocessChoice {
        didSet { defaults.set(selectedPostprocess.rawValue, forKey: "selectedPostprocess") }
    }
    var selectedPostprocessMode: PostprocessOperationChoice {
        didSet {
            defaults.set(
                selectedPostprocessMode.rawValue,
                forKey: "selectedPostprocessMode"
            )
        }
    }
    var selectedTranslationTarget: AppLanguage {
        didSet {
            defaults.set(
                selectedTranslationTarget.rawValue,
                forKey: "selectedTranslationTarget"
            )
        }
    }

    private let repository: LibraryRepository
    private let runner: any TranscriptionRunning
    private let recorder: any RecordingControlling
    private let defaults: UserDefaults
    private var activeTask: Task<Void, Never>?
    private var captureTimer: Task<Void, Never>?
    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var activeSecurityURL: URL?
    private var activeRecordingSelection: RecordingSelection?

    init(
        repository: LibraryRepository,
        profiles: [AppProfile],
        runner: any TranscriptionRunning,
        recorder: any RecordingControlling,
        defaults: UserDefaults = .standard,
        codexAvailability: CodexAvailability = .unavailable
    ) throws {
        self.repository = repository
        self.profiles = profiles
        self.runner = runner
        self.recorder = recorder
        self.defaults = defaults
        self.codexAvailability = codexAvailability
        let storedProfile = defaults.string(forKey: "selectedProfile")
            .flatMap(AppProfileID.init(rawValue:))
        let storedPostprocess = defaults.string(forKey: "selectedPostprocess")
            .flatMap(PostprocessChoice.init(rawValue:))
        let storedPostprocessMode = defaults.string(
            forKey: "selectedPostprocessMode"
        ).flatMap(PostprocessOperationChoice.init(rawValue:))
        let storedTranslationTarget = defaults.string(
            forKey: "selectedTranslationTarget"
        ).flatMap(AppLanguage.init(rawValue:))
        let initialPostprocess = storedPostprocess
            ?? (codexAvailability.isAuthenticated ? .codex : .local)
        let initialPostprocessMode = storedPostprocessMode ?? .correction
        let initialTranslationTarget = storedTranslationTarget == .system
            ? .english
            : (storedTranslationTarget ?? .english)
        selectedProfileID = storedProfile ?? .koreanITMeeting
        selectedPostprocess = initialPostprocess
        selectedPostprocessMode = initialPostprocessMode
        selectedTranslationTarget = initialTranslationTarget
        if storedPostprocess == nil {
            defaults.set(initialPostprocess.rawValue, forKey: "selectedPostprocess")
        }
        if storedPostprocessMode == nil {
            defaults.set(
                initialPostprocessMode.rawValue,
                forKey: "selectedPostprocessMode"
            )
        }
        if storedTranslationTarget == nil || storedTranslationTarget == .system {
            defaults.set(
                initialTranslationTarget.rawValue,
                forKey: "selectedTranslationTarget"
            )
        }
        try repository.prepareDirectories()
        let loadedRecords = try repository.loadRecords().sorted {
            $0.createdAt > $1.createdAt
        }
        records = loadedRecords
        runFailures = Dictionary(
            uniqueKeysWithValues: loadedRecords.compactMap { record in
                guard let runURL = record.runURL,
                      let failure = Self.readFailure(at: runURL)
                else { return nil }
                return (record.id, failure)
            }
        )
        recorder.setMeterHandler { [weak self] meters in
            self?.captureMeters = meters
        }
    }

    func shutdown() {
        activeTask?.cancel()
        captureTimer?.cancel()
        stopPlayback()
        activeRecordingSelection = nil
        if isRecording {
            Task { await recorder.cancel() }
        }
    }

    var selectedProfile: AppProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
    }

    var selectedRecord: LibraryRecord? {
        guard case let .record(id) = selection else { return nil }
        return records.first(where: { $0.id == id })
    }

    var isTranscribing: Bool { activeRecordID != nil && activeTask != nil }
    var canImportAudio: Bool { !isRecording && activeTask == nil }
    var canStartTranscription: Bool { !isRecording && activeTask == nil }

    func canRetryTranscription(_ record: LibraryRecord) -> Bool {
        guard canStartTranscription,
              !isMOSSLimitExhausted(record)
        else { return false }
        if Self.supportedTranscriptionExtensions.contains(
            record.sourceURL.pathExtension.lowercased()
        ) {
            return true
        }
        return record.sourceKind == .appRecording
            && record.microphoneURL != nil
            && record.systemAudioURL != nil
    }

    func isTranscribing(recordID: UUID) -> Bool {
        activeRecordID == recordID && activeTask != nil
    }

    func progress(for recordID: UUID) -> RunProgressSnapshot? {
        activeRecordID == recordID ? progress : nil
    }

    func failure(for record: LibraryRecord) -> Failure? {
        runFailures[record.id]
    }

    func isMOSSLimitExhausted(_ record: LibraryRecord) -> Bool {
        failure(for: record)?.code == "MOSS_LIMIT_EXHAUSTED"
    }

    var storageRoot: URL { repository.root }
    var recordingsRoot: URL { repository.recordingsRoot }
    var runsRoot: URL { repository.runsRoot }

    func clearError() {
        errorMessage = nil
    }

    func refreshCodexAvailability() async {
        codexAvailability = await Task.detached(priority: .utility) {
            await CodexPostprocessBackend.detectAvailability()
        }.value
    }

    func syncPostprocessSelectionsFromDefaults() {
        if let value = defaults.string(forKey: "selectedPostprocess")
            .flatMap(PostprocessChoice.init(rawValue:)),
           value != selectedPostprocess
        {
            selectedPostprocess = value
        }
        if let value = defaults.string(forKey: "selectedPostprocessMode")
            .flatMap(PostprocessOperationChoice.init(rawValue:)),
           value != selectedPostprocessMode
        {
            selectedPostprocessMode = value
        }
        if let value = defaults.string(forKey: "selectedTranslationTarget")
            .flatMap(AppLanguage.init(rawValue:)),
           value != .system,
           value != selectedTranslationTarget
        {
            selectedTranslationTarget = value
        }
    }

    func importAudio(_ urls: [URL]) {
        syncPostprocessSelectionsFromDefaults()
        guard !isRecording else {
            errorMessage = appString("Stop the active recording before importing audio.")
            return
        }
        guard activeTask == nil else {
            errorMessage = appString("Wait for the active transcription to finish.")
            return
        }
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTranscription() }
            for url in urls {
                var recordID: UUID?
                do {
                    let record = try await makeImportedRecord(url: url)
                    recordID = record.id
                    try persist(record)
                    selection = .record(record.id)
                    try await transcribe(recordID: record.id)
                } catch is CancellationError {
                    if let recordID { markCancelled(recordID: recordID) }
                    break
                } catch {
                    if let recordID { markFailed(recordID: recordID, message: error.localizedDescription) }
                    errorMessage = error.localizedDescription
                    break
                }
            }
        }
    }

    func startRecording() {
        guard !isRecording, activeTask == nil else { return }
        errorMessage = nil
        activeRecordingSelection = RecordingSelection(
            profileID: selectedProfileID,
            postprocess: selectedPostprocess,
            postprocessMode: selectedPostprocessMode,
            translationTarget: selectedTranslationTarget
        )
        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await recorder.start(in: repository.recordingsRoot)
                isRecording = true
                captureElapsedS = 0
                startCaptureTimer()
            } catch {
                errorMessage = error.localizedDescription
                activeRecordingSelection = nil
            }
            activeTask = nil
        }
    }

    func stopRecordingAndTranscribe() {
        guard isRecording,
              activeTask == nil,
              let recordingSelection = activeRecordingSelection
        else { return }
        syncPostprocessSelectionsFromDefaults()
        activeTask = Task { [weak self] in
            guard let self else { return }
            var recordID: UUID?
            defer { finishActiveTranscription() }
            captureTimer?.cancel()
            do {
                let artifacts = try await recorder.stop()
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                let record = LibraryRecord(
                    id: UUID(),
                    createdAt: artifacts.startedAt,
                    displayName: appString("Recording \(artifacts.startedAt.formatted(date: .abbreviated, time: .shortened))"),
                    sourceKind: .appRecording,
                    sourceURL: artifacts.combinedURL,
                    securityScopedBookmark: nil,
                    microphoneURL: artifacts.microphoneURL,
                    systemAudioURL: artifacts.systemAudioURL,
                    runURL: nil,
                    profileID: recordingSelection.profileID,
                    postprocess: recordingSelection.postprocess,
                    postprocessMode: recordingSelection.postprocessMode.mode,
                    translationTargetLanguage: recordingSelection.postprocessMode == .translation
                        ? recordingSelection.translationTarget.rawValue
                        : nil,
                    durationS: artifacts.durationS,
                    state: .recorded,
                    speakerNames: [:],
                    conflictResolutions: [:],
                    failureMessage: nil
                )
                try persist(record)
                recordID = record.id
                selection = .record(record.id)
                try await transcribe(recordID: record.id)
            } catch let error as RecordingFinalizationError {
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                let artifacts = error.artifacts
                let record = LibraryRecord(
                    id: UUID(),
                    createdAt: artifacts.startedAt,
                    displayName: appString("Recording \(artifacts.startedAt.formatted(date: .abbreviated, time: .shortened))"),
                    sourceKind: .appRecording,
                    sourceURL: artifacts.microphoneURL,
                    securityScopedBookmark: nil,
                    microphoneURL: artifacts.microphoneURL,
                    systemAudioURL: artifacts.systemAudioURL,
                    runURL: nil,
                    profileID: recordingSelection.profileID,
                    postprocess: recordingSelection.postprocess,
                    postprocessMode: recordingSelection.postprocessMode.mode,
                    translationTargetLanguage: recordingSelection.postprocessMode == .translation
                        ? recordingSelection.translationTarget.rawValue
                        : nil,
                    durationS: artifacts.durationS,
                    state: .failed,
                    speakerNames: [:],
                    conflictResolutions: [:],
                    failureMessage: error.localizedDescription
                )
                do {
                    try persist(record)
                    selection = .record(record.id)
                    errorMessage = error.localizedDescription
                } catch {
                    errorMessage = error.localizedDescription
                }
            } catch is CancellationError {
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                if let recordID { markCancelled(recordID: recordID) }
            } catch {
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                errorMessage = error.localizedDescription
                if let recordID { markFailed(recordID: recordID, message: error.localizedDescription) }
            }
        }
    }

    func cancelTranscription() {
        guard activeRecordID != nil else { return }
        runner.cancel()
    }

    func retrySelectedTranscription() {
        guard !isRecording else {
            errorMessage = appString("Stop the active recording before starting transcription.")
            return
        }
        guard activeTask == nil, let record = selectedRecord else { return }
        guard !isMOSSLimitExhausted(record) else {
            errorMessage = appString(
                "This run reached the MOSS output limit after bounded splitting. Choose a different profile or use a shorter copy before retrying."
            )
            return
        }
        guard canRetryTranscription(record) else { return }
        errorMessage = nil
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTranscription() }
            do {
                try applySelectedFallbackBackendForRetry(recordID: record.id)
                try prepareRetrySource(recordID: record.id)
                try await transcribe(recordID: record.id)
            } catch is CancellationError {
                markCancelled(recordID: record.id)
            } catch {
                markFailed(recordID: record.id, message: error.localizedDescription)
                errorMessage = error.localizedDescription
            }
        }
    }

    func showCapture() {
        stopPlayback()
        selection = .capture
    }

    func select(_ selection: AppSelection) {
        self.selection = selection
    }

    func renameSpeaker(_ speaker: String, to name: String) {
        guard case let .record(id) = selection,
              let index = records.firstIndex(where: { $0.id == id })
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            records[index].speakerNames.removeValue(forKey: speaker)
        } else {
            records[index].speakerNames[speaker] = trimmed
        }
        saveRecordsReportingErrors()
    }

    func resolveConflict(at segmentIndex: Int, with text: String) {
        guard case let .record(id) = selection,
              let index = records.firstIndex(where: { $0.id == id })
        else { return }
        records[index].conflictResolutions[segmentIndex] = text
        saveRecordsReportingErrors()
    }

    func play(segment: MaccheroniCore.Segment) {
        guard let record = selectedRecord else { return }
        do {
            stopPlayback()
            let source = try repository.resolveOriginal(for: record)
            if source.startAccessingSecurityScopedResource() {
                activeSecurityURL = source
            }
            let player = AVPlayer(url: source)
            self.player = player
            let start = CMTime(seconds: segment.startS, preferredTimescale: 600)
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
            player.play()
            playbackTask = Task { [weak self] in
                let duration = max(0, segment.endS - segment.startS)
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                self?.stopPlayback()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        player?.pause()
        player = nil
        activeSecurityURL?.stopAccessingSecurityScopedResource()
        activeSecurityURL = nil
    }

    func revealOriginal(_ record: LibraryRecord) {
        do {
            let source = try repository.resolveOriginal(for: record)
            NSWorkspace.shared.activateFileViewerSelecting([source])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealRun(_ record: LibraryRecord) {
        guard let runURL = record.runURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([runURL])
    }

    func glossaryURL(for profileID: AppProfileID) -> URL {
        repository.glossariesRoot.appendingPathComponent("\(profileID.rawValue).txt")
    }

    func loadGlossary(for profileID: AppProfileID) -> String {
        let url = glossaryURL(for: profileID)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func saveGlossary(_ text: String, for profileID: AppProfileID) throws {
        try repository.prepareDirectories()
        let target = glossaryURL(for: profileID)
        let temporary = repository.glossariesRoot.appendingPathComponent(
            ".\(UUID().uuidString)-\(profileID.rawValue).txt"
        )
        try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    private func makeImportedRecord(url: URL) async throws -> LibraryRecord {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let duration = try await AVURLAsset(url: url).load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw TranscriptionRunnerError.pipelineFailed(
                appString("The selected file has no readable audio duration.")
            )
        }
        return LibraryRecord(
            id: UUID(),
            createdAt: Date(),
            displayName: url.deletingPathExtension().lastPathComponent,
            sourceKind: .importedFile,
            sourceURL: url,
            securityScopedBookmark: try? repository.bookmark(for: url),
            microphoneURL: nil,
            systemAudioURL: nil,
            runURL: nil,
            profileID: selectedProfileID,
            postprocess: selectedPostprocess,
            postprocessMode: selectedPostprocessMode.mode,
            translationTargetLanguage: selectedPostprocessMode == .translation
                ? selectedTranslationTarget.rawValue
                : nil,
            durationS: seconds,
            state: .recorded,
            speakerNames: [:],
            conflictResolutions: [:],
            failureMessage: nil
        )
    }

    private func transcribe(recordID: UUID) async throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              let profile = profiles.first(where: { $0.id == records[index].profileID })
        else { throw TranscriptionRunnerError.resultMissing }
        let record = records[index]
        if record.postprocess == .codex {
            if !codexAvailability.isAuthenticated {
                await refreshCodexAvailability()
            }
            guard codexAvailability.isAuthenticated else {
                throw TranscriptionRunnerError.pipelineFailed(
                    appString(
                        "Codex is not signed in. Run codex login in Terminal, then try again, or select Local."
                    )
                )
            }
        }
        records[index].state = .transcribing
        records[index].failureMessage = nil
        runFailures.removeValue(forKey: recordID)
        activeRecordID = recordID
        try repository.saveRecords(records)
        let glossary = glossaryURL(for: record.profileID)
        let glossaryURL = (try? String(contentsOf: glossary, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) == true
            ? glossary
            : nil
        let source = try repository.resolveOriginal(for: record)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let request = TranscriptionRequest(
            sourceURL: source,
            outputRoot: repository.runsRoot,
            profile: profile,
            postprocess: record.postprocess,
            postprocessMode: record.postprocessMode ?? .correction,
            translationTargetLanguage: record.postprocess == .none
                ? nil
                : (record.postprocessMode == .translation
                    ? record.translationTargetLanguage
                    : nil),
            glossaryURL: glossaryURL
        )
        let runURL = try await runner.run(request) { [weak self] snapshot in
            guard let self else { return }
            progress = snapshot
            if let runURL = snapshot.runURL,
               let currentIndex = records.firstIndex(where: { $0.id == recordID }) {
                records[currentIndex].runURL = runURL
                if let failure = Self.readFailure(at: runURL) {
                    runFailures[recordID] = failure
                }
                saveRecordsReportingErrors()
            }
        }
        guard let finalIndex = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[finalIndex].runURL = runURL
        let loaded = try repository.loadRun(at: runURL)
        records[finalIndex].state = loaded.requiresReview ? .hasConflicts : .done
        records[finalIndex].failureMessage = nil
        runFailures.removeValue(forKey: recordID)
        try repository.saveRecords(records)
        if selection == .record(recordID) {
            selectedRun = loaded
        }
    }

    private func prepareRetrySource(recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            throw TranscriptionRunnerError.resultMissing
        }
        let record = records[index]
        guard !Self.supportedTranscriptionExtensions.contains(
            record.sourceURL.pathExtension.lowercased()
        ) else {
            return
        }
        guard record.sourceKind == .appRecording,
              let microphoneURL = record.microphoneURL,
              let systemAudioURL = record.systemAudioURL
        else {
            throw LibraryRepositoryError.originalUnavailable
        }

        let outputURL = record.sourceURL.deletingLastPathComponent().appendingPathComponent(
            "combined-retry-\(UUID().uuidString.lowercased()).wav"
        )
        try RecordingMixer.mix(
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL,
            outputURL: outputURL
        )

        records[index].sourceURL = outputURL
        records[index].state = .recorded
        records[index].failureMessage = nil
        runFailures.removeValue(forKey: recordID)
        try repository.saveRecords(records)
    }

    private func applySelectedFallbackBackendForRetry(recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }),
              records[index].postprocess == .codex,
              selectedPostprocess != .codex
        else { return }
        records[index].postprocess = selectedPostprocess
        try repository.saveRecords(records)
    }

    private func persist(_ record: LibraryRecord) throws {
        records.append(record)
        records.sort { $0.createdAt > $1.createdAt }
        try repository.saveRecords(records)
    }

    private func refreshSelectedRun() {
        selectedRun = nil
        guard let runURL = selectedRecord?.runURL else { return }
        selectedRun = try? repository.loadRun(at: runURL)
    }

    private func startCaptureTimer() {
        captureTimer?.cancel()
        let started = Date()
        captureTimer = Task { [weak self] in
            while !Task.isCancelled {
                self?.captureElapsedS = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func markCancelled(recordID: UUID) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].state = .cancelled
        records[index].failureMessage = nil
        if let runURL = records[index].runURL,
           let failure = Self.readFailure(at: runURL)
        {
            runFailures[recordID] = failure
        }
        saveRecordsReportingErrors()
    }

    private func markFailed(recordID: UUID, message: String) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].state = .failed
        records[index].failureMessage = message
        if let runURL = records[index].runURL,
           let failure = Self.readFailure(at: runURL)
        {
            runFailures[recordID] = failure
        }
        saveRecordsReportingErrors()
    }

    private func finishActiveTranscription() {
        activeRecordID = nil
        activeTask = nil
        progress = nil
    }

    private func saveRecordsReportingErrors() {
        do {
            try repository.saveRecords(records)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let supportedTranscriptionExtensions: Set<String> = ["m4a", "mp3", "wav"]

    private static func readFailure(at runURL: URL) -> Failure? {
        guard let data = try? Data(
            contentsOf: runURL.appendingPathComponent("manifest.json")
        ), let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return manifest.failure
    }
}

private struct RecordingSelection {
    let profileID: AppProfileID
    let postprocess: PostprocessChoice
    let postprocessMode: PostprocessOperationChoice
    let translationTarget: AppLanguage
}
