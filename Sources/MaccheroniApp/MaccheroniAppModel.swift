import AVFoundation
import AppKit
import Foundation
import MaccheroniCore
import MaccheroniPostprocess
import MaccheroniPreprocess
import Observation

enum AppAudioImportError: Error, LocalizedError, Equatable {
    case unsupportedFormat

    var errorDescription: String? {
        appString("Choose an M4A, WAV, or MP3 audio file.")
    }
}

enum RunLoadIssue: Equatable {
    case missing
    case missingArtifact(String)
    case decoding(String)
    case integrity(String)

    var canReveal: Bool {
        switch self {
        case .missing: false
        case .missingArtifact, .decoding, .integrity: true
        }
    }
}

/// A user-facing dependency the capture screen can name when a profile cannot run.
///
/// Each group folds a family of `doctor` `check.*` keys, or one capture permission,
/// into one sentence. Raw check keys never reach the screen.
enum ProfileReadinessGroup: String, CaseIterable, Identifiable, Sendable {
    case speechModel
    case speakerSeparation
    case voiceActivity
    case speechRuntime
    case storage
    case otherDependency
    case microphonePermission
    case systemAudioPermission

    var id: String { rawValue }

    /// Groups the `doctor` report can report on, in display order.
    static let dependencyGroups: [ProfileReadinessGroup] = [
        .speechModel,
        .speakerSeparation,
        .voiceActivity,
        .speechRuntime,
        .storage,
        .otherDependency,
    ]

    /// Maps one failed `doctor` check key onto the group that names it in user language.
    static func group(forFailedCheck key: String) -> ProfileReadinessGroup? {
        guard key.hasPrefix("check.") else { return nil }
        let name = String(key.dropFirst("check.".count))
        if name.hasPrefix("asr") || name.hasPrefix("moss_release_helper") {
            return .speechModel
        }
        if name.hasPrefix("diarization") { return .speakerSeparation }
        if name.hasPrefix("vad") { return .voiceActivity }
        if name.hasPrefix("offline_speech_runtime") || name == "afconvert_executable" {
            return .speechRuntime
        }
        if name == "storage" { return .storage }
        return .otherDependency
    }

    /// A missing local dependency makes any run fail, so it blocks capture too.
    /// A denied microphone only makes a new recording fail; an existing audio file
    /// still transcribes.
    var blocksRecording: Bool {
        self != .systemAudioPermission
    }

    var blocksAudioImport: Bool {
        switch self {
        case .microphonePermission, .systemAudioPermission: false
        default: true
        }
    }

    var reason: LocalizedStringResource {
        switch self {
        case .speechModel:
            appLocalized("The speech recognition model this profile needs is not installed on this Mac.")
        case .speakerSeparation:
            appLocalized("The speaker separation model this profile needs is not installed on this Mac.")
        case .voiceActivity:
            appLocalized("The voice activity model this profile needs is not installed on this Mac.")
        case .speechRuntime:
            appLocalized("The local speech runtime this profile needs is missing or does not match its pinned version.")
        case .storage:
            appLocalized("The folder Maccheroni saves recordings and runs in cannot be reached.")
        case .otherDependency:
            appLocalized("Another local component this profile needs is not ready.")
        case .microphonePermission:
            appLocalized("Maccheroni cannot use the microphone. Turn Maccheroni on in System Settings > Privacy & Security > Microphone.")
        case .systemAudioPermission:
            appLocalized("System audio is not recordable yet. Turn Maccheroni on in System Settings > Privacy & Security > Screen & System Audio Recording.")
        }
    }
}

/// Why the readiness answer itself is missing, as opposed to a dependency being absent.
enum ProfileReadinessProbeIssue: Equatable, Sendable {
    case engineMissing
    case engineFailed(String)
    case reportUnreadable

    /// An absent engine is positive evidence that no run can happen: every run launches
    /// this same binary. A report that did not arrive, or did not parse, is absence of
    /// evidence about the machine and does not take a control away.
    var blocksRun: Bool {
        self == .engineMissing
    }

    var message: LocalizedStringResource {
        switch self {
        case .engineMissing:
            appLocalized("The Maccheroni command-line engine is missing.")
        case let .engineFailed(detail):
            appLocalized("Maccheroni could not check whether this profile is ready: \(detail)")
        case .reportUnreadable:
            appLocalized("Maccheroni could not read the readiness report from its command-line engine.")
        }
    }
}

/// The `doctor` schema 1.1.0 readiness envelope, as the app consumes it.
struct ProfileReadinessReport: Equatable, Sendable {
    var ready: Bool
    var schemaVersion: String
    var values: [String: String]

    var failedCheckKeys: [String] {
        values.filter { $0.key.hasPrefix("check.") && $0.value == "false" }
            .keys
            .sorted()
    }
}

enum ProfileReadinessProbeOutcome: Equatable, Sendable {
    case report(ProfileReadinessReport)
    case issue(ProfileReadinessProbeIssue)
}

protocol ProfileReadinessProbing: Sendable {
    func probe(_ profile: AppProfile) async -> ProfileReadinessProbeOutcome
}

enum CapturePermissionState: Equatable, Sendable {
    case granted
    case denied
    case undetermined
}

/// Microphone and screen-recording states, read without prompting the user.
struct CapturePermissions: Equatable, Sendable {
    var microphone: CapturePermissionState
    var systemAudio: CapturePermissionState

    static let unknown = CapturePermissions(
        microphone: .undetermined,
        systemAudio: .undetermined
    )

    /// `undetermined` never blocks: macOS asks for the permission on first capture,
    /// and blocking would put the request itself out of reach. Screen recording has
    /// no API that separates "never asked" from "denied", so it is reported without
    /// blocking and only the microphone can withhold the record button.
    var blockingGroups: [ProfileReadinessGroup] {
        var groups: [ProfileReadinessGroup] = []
        if microphone == .denied { groups.append(.microphonePermission) }
        if systemAudio != .granted { groups.append(.systemAudioPermission) }
        return groups
    }

    static func current() -> CapturePermissions {
        let microphone: CapturePermissionState = switch AVCaptureDevice
            .authorizationStatus(for: .audio)
        {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .undetermined
        }
        return CapturePermissions(
            microphone: microphone,
            systemAudio: CGPreflightScreenCaptureAccess() ? .granted : .undetermined
        )
    }
}

/// What the capture screen states about the selected profile before a run starts.
struct ProfileReadiness: Equatable, Sendable {
    var profileID: AppProfileID
    var asrBackend: String = ""
    var blockingGroups: [ProfileReadinessGroup] = []
    var probeIssue: ProfileReadinessProbeIssue?
    var hasResult = false
    var isEvaluating = false

    var isReady: Bool {
        hasResult && blockingGroups.isEmpty && probeIssue == nil
    }

    /// A ready profile adds no chrome; only an obstruction or an unanswered check shows.
    var showsNotice: Bool {
        !blockingGroups.isEmpty || probeIssue != nil
    }

    var blocksRecording: Bool {
        probeIssue?.blocksRun == true || blockingGroups.contains(where: \.blocksRecording)
    }

    var blocksAudioImport: Bool {
        probeIssue?.blocksRun == true || blockingGroups.contains(where: \.blocksAudioImport)
    }

    /// Whether the screen takes a run control away, and so owes the user a headline.
    var isObstructed: Bool {
        blocksRecording || blocksAudioImport
    }

    /// Whether the provisioning command actually installs what is missing. Offering it
    /// for a dependency the script does not fetch would repeat the defect this surface
    /// exists to fix: pointing the user at an action that cannot work.
    var needsProvisioning: Bool {
        blockingGroups.contains { group in
            switch group {
            case .speechModel:
                Self.scriptProvisionedASRBackends.contains(asrBackend)
            case .speakerSeparation, .voiceActivity, .speechRuntime, .otherDependency:
                true
            case .storage, .microphonePermission, .systemAudioPermission:
                false
            }
        }
    }

    /// The command that provisions the local speech dependencies. The script accepts
    /// only `ko-meeting`, and the assets it installs are shared by every app profile.
    static let provisioningCommand =
        "zsh scripts/setup-transcription-runtime.zsh --profile ko-meeting"

    /// ASR backends `scripts/setup-transcription-runtime.zsh` installs. It fetches the
    /// VibeVoice, Pyannote Community-1 and Silero assets; the MOSS model is not among
    /// them, so an it-dialogue speech model is named without offering that command.
    static let scriptProvisionedASRBackends: Set<String> = ["vibevoice"]
}

@MainActor
@Observable
final class MaccheroniAppModel {
    private(set) var profiles: [AppProfile]
    private(set) var records: [LibraryRecord]
    private(set) var selectedRun: LoadedRun?
    private(set) var selectedRunIssue: RunLoadIssue?
    private(set) var progress: RunProgressSnapshot?
    private(set) var captureMeters = CaptureMeters.silent
    private(set) var captureElapsedS: Double = 0
    private(set) var isRecording = false
    private(set) var errorMessage: String?
    private(set) var activeRecordID: UUID?
    private(set) var runFailures: [UUID: Failure]
    private(set) var codexAvailability: CodexAvailability
    private(set) var activeExistingRunPostprocess: ActiveExistingRunPostprocess?
    private(set) var existingRunPostprocessFailures: [UUID: String] = [:]
    private(set) var profileReadiness: ProfileReadiness

    var selection: AppSelection = .capture {
        didSet { refreshSelectedRun() }
    }
    var selectedProfileID: AppProfileID {
        didSet {
            defaults.set(selectedProfileID.rawValue, forKey: "selectedProfile")
            guard selectedProfileID != oldValue else { return }
            profileReadiness = ProfileReadiness(
                profileID: selectedProfileID,
                asrBackend: selectedProfile.asrBackend
            )
            evaluateProfileReadiness()
        }
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
    private let recordSaver: ([LibraryRecord]) throws -> Void
    private let readinessProbe: any ProfileReadinessProbing
    private let capturePermissions: @Sendable () -> CapturePermissions
    /// How long a run started before the first readiness answer waits for it. Kept well
    /// under the probe's own timeout: the legitimate answer arrives within about four
    /// seconds, and the record button is already disabled while this wait runs, so a
    /// longer budget would only stare back at the user.
    private let readinessWaitBudget: Duration
    private var readinessTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var captureTimer: Task<Void, Never>?
    private var player: AVPlayer?
    private var playbackTask: Task<Void, Never>?
    private var activeSecurityURL: URL?
    private var activeRecordingStorageAccess: LibraryStorageAccessLease?
    private var activeRecordingSelection: RecordingSelection?
    private var activeRecordingRecordID: UUID?

    init(
        repository: LibraryRepository,
        profiles: [AppProfile],
        runner: any TranscriptionRunning,
        recorder: any RecordingControlling,
        defaults: UserDefaults = .standard,
        codexAvailability: CodexAvailability = .unavailable,
        recordSaver: (([LibraryRecord]) throws -> Void)? = nil,
        readinessProbe: (any ProfileReadinessProbing)? = nil,
        capturePermissions: @escaping @Sendable () -> CapturePermissions =
            CapturePermissions.current,
        readinessWaitBudget: Duration = .seconds(10)
    ) throws {
        self.repository = repository
        self.profiles = profiles
        self.runner = runner
        self.recorder = recorder
        self.defaults = defaults
        self.codexAvailability = codexAvailability
        self.recordSaver = recordSaver ?? repository.saveRecords
        self.readinessProbe = readinessProbe ?? ProcessProfileReadinessProbe()
        self.capturePermissions = capturePermissions
        self.readinessWaitBudget = readinessWaitBudget
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
        let initialProfile = storedProfile ?? .koreanITMeeting
        selectedProfileID = initialProfile
        profileReadiness = ProfileReadiness(
            profileID: initialProfile,
            asrBackend: profiles.first(where: { $0.id == initialProfile })?.asrBackend
                ?? profiles[0].asrBackend
        )
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
        var loadedRecords = try repository.loadRecords().sorted {
            $0.createdAt > $1.createdAt
        }
        let recoveredCaptureRecords = try Self.recoverUnindexedCaptureSessions(
            recordingsRoot: repository.recordingsRoot,
            existingRecords: loadedRecords,
            profileID: initialProfile,
            postprocess: initialPostprocess,
            postprocessMode: initialPostprocessMode,
            translationTarget: initialTranslationTarget
        )
        loadedRecords.append(contentsOf: recoveredCaptureRecords)
        loadedRecords.sort { $0.createdAt > $1.createdAt }
        var reconciledInterruptedRun = false
        for index in loadedRecords.indices where loadedRecords[index].state == .transcribing {
            loadedRecords[index].state = .interrupted
            loadedRecords[index].failureMessage = appString("Interrupted")
            reconciledInterruptedRun = true
        }
        records = loadedRecords
        selectedRunIssue = nil
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
        if reconciledInterruptedRun || !recoveredCaptureRecords.isEmpty {
            try self.recordSaver(loadedRecords)
        }
    }

    func shutdown() {
        activeTask?.cancel()
        readinessTask?.cancel()
        captureTimer?.cancel()
        stopPlayback()
        activeRecordingSelection = nil
        if isRecording || activeRecordingStorageAccess != nil {
            Task { [weak self] in
                await self?.recorder.cancel()
                self?.finishRecordingStorageAccess()
            }
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
    var canCancelActiveOperation: Bool { activeTask != nil }
    var canImportAudio: Bool {
        !isRecording && activeTask == nil && !profileReadiness.blocksAudioImport
    }

    var canStartTranscription: Bool { !isRecording && activeTask == nil }

    var canStartRecording: Bool {
        !isRecording && activeTask == nil && !profileReadiness.blocksRecording
    }

    func canPostprocess(_ record: LibraryRecord) -> Bool {
        canStartTranscription
            && (record.state == .done || record.state == .hasConflicts)
            && record.runURL != nil
    }

    func isPostprocessingExistingRun(recordID: UUID) -> Bool {
        activeExistingRunPostprocess?.recordID == recordID && activeTask != nil
    }

    func existingRunPostprocessFailure(for recordID: UUID) -> String? {
        existingRunPostprocessFailures[recordID]
    }

    func canRetryTranscription(_ record: LibraryRecord) -> Bool {
        guard canStartTranscription,
              !(isMOSSLimitExhausted(record) && usesUnchangedMOSSConfiguration(record))
        else { return false }
        if isReadableAudio(record) {
            return true
        }
        return record.sourceKind == .appRecording
            && record.microphoneURL.map(Self.isDecodableInternalAudio(at:)) == true
            && record.systemAudioURL.map(Self.isDecodableInternalAudio(at:)) == true
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

    func usesUnchangedMOSSConfiguration(_ record: LibraryRecord) -> Bool {
        selectedProfileID == record.profileID
    }

    var storageRoot: URL { repository.root }
    var recordingsRoot: URL { repository.recordingsRoot }
    var runsRoot: URL { repository.runsRoot }

    func clearError() {
        errorMessage = nil
    }

    /// Re-asks `doctor` and the capture permissions whether the selected profile can run.
    /// The capture screen calls this when it appears and when the user asks again; the
    /// profile picker calls it through `selectedProfileID`.
    func evaluateProfileReadiness() {
        let profile = selectedProfile
        readinessTask?.cancel()
        profileReadiness.profileID = profile.id
        profileReadiness.isEvaluating = true
        let probe = readinessProbe
        let permissions = capturePermissions
        readinessTask = Task { [weak self] in
            let outcome = await probe.probe(profile)
            let observedPermissions = permissions()
            guard !Task.isCancelled else { return }
            self?.applyProfileReadiness(
                profileID: profile.id,
                outcome: outcome,
                permissions: observedPermissions
            )
        }
    }

    /// Closes the window between the capture screen appearing and the first readiness
    /// answer arriving. The synchronous guards see `blocks… == false` while no result
    /// exists yet, so a run started inside that window waits for the answer it was
    /// about to race, and is refused with the reason if the profile turns out not ready.
    ///
    /// The wait is bounded and gives up quietly. A budget that expires leaves
    /// `hasResult` false, so nothing blocks and the run proceeds: a readiness answer
    /// that did not arrive is a fact about one attempt, not about the machine. Polling
    /// rather than awaiting `readinessTask.value` is deliberate — a `Task<Void, Never>`
    /// does not return early on cancellation, so awaiting it is exactly the wedge this
    /// budget exists to prevent. Cancelling the run's own task ends the wait at once;
    /// `readinessTask` is not cancelled with it, because the capture screen still owns
    /// that evaluation and needs its answer.
    private func awaitPendingProfileReadiness() async {
        guard !profileReadiness.hasResult, readinessTask != nil else { return }
        let deadline = ContinuousClock.now.advanced(by: readinessWaitBudget)
        while !profileReadiness.hasResult,
              !Task.isCancelled,
              ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func applyProfileReadiness(
        profileID: AppProfileID,
        outcome: ProfileReadinessProbeOutcome,
        permissions: CapturePermissions
    ) {
        guard profileID == selectedProfileID else { return }
        let profile = selectedProfile
        var groups: [ProfileReadinessGroup] = []
        var issue: ProfileReadinessProbeIssue?
        switch outcome {
        case let .report(report):
            let failed = Set(report.failedCheckKeys.compactMap(
                ProfileReadinessGroup.group(forFailedCheck:)
            ))
            groups = ProfileReadinessGroup.dependencyGroups.filter(failed.contains)
            if groups.isEmpty, !report.ready {
                groups = [.otherDependency]
            }
        case let .issue(probeIssue):
            issue = probeIssue
        }
        groups += permissions.blockingGroups
        profileReadiness = ProfileReadiness(
            profileID: profileID,
            asrBackend: profile.asrBackend,
            blockingGroups: groups,
            probeIssue: issue,
            hasResult: true,
            isEvaluating: false
        )
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
        guard !profileReadiness.blocksAudioImport else {
            errorMessage = appString("This profile is not ready to run.")
            return
        }
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTranscription() }
            await awaitPendingProfileReadiness()
            guard !profileReadiness.blocksAudioImport else {
                errorMessage = appString("This profile is not ready to run.")
                return
            }
            var pendingRecordIDs: [UUID] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let record = try await makeImportedRecord(url: url)
                    try persist(record)
                    pendingRecordIDs.append(record.id)
                } catch is CancellationError {
                    break
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            for recordID in pendingRecordIDs {
                guard let record = records.first(where: { $0.id == recordID }) else { continue }
                selection = .record(recordID)
                do {
                    try await transcribe(recordID: recordID)
                } catch is CancellationError {
                    markCancelled(recordID: recordID)
                    break
                } catch {
                    let runnerMessage = error.localizedDescription
                    do {
                        try markFailed(recordID: recordID, message: runnerMessage)
                        failures.append("\(record.sourceURL.lastPathComponent): \(runnerMessage)")
                    } catch {
                        failures.append(Self.combinedFailureMessage(
                            operation: runnerMessage,
                            persistence: error
                        ))
                    }
                }
            }
            if !failures.isEmpty {
                errorMessage = failures.joined(separator: "\n")
            }
        }
    }

    func handleImportResult(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            importAudio(urls)
        case let .failure(error):
            let cocoaError = error as NSError
            guard !(cocoaError.domain == NSCocoaErrorDomain
                && cocoaError.code == NSUserCancelledError)
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    func startRecording() {
        guard !isRecording, activeTask == nil, !profileReadiness.blocksRecording else {
            return
        }
        errorMessage = nil
        activeRecordingSelection = RecordingSelection(
            profileID: selectedProfileID,
            postprocess: selectedPostprocess,
            postprocessMode: selectedPostprocessMode,
            translationTarget: selectedTranslationTarget
        )
        activeTask = Task { [weak self] in
            guard let self else { return }
            var captureStarted = false
            do {
                await awaitPendingProfileReadiness()
                guard !profileReadiness.blocksRecording else {
                    throw TranscriptionRunnerError.pipelineFailed(
                        appString("This profile is not ready to run.")
                    )
                }
                activeRecordingStorageAccess = try repository
                    .beginAccessingRecordingsRoot()
                let session = try await recorder.start(in: repository.recordingsRoot)
                captureStarted = true
                let record = LibraryRecord(
                    id: UUID(),
                    createdAt: session.startedAt,
                    displayName: appString("Recording \(session.startedAt.formatted(date: .abbreviated, time: .shortened))"),
                    sourceKind: .appRecording,
                    sourceURL: session.microphoneURL,
                    securityScopedBookmark: nil,
                    microphoneURL: session.microphoneURL,
                    systemAudioURL: session.systemAudioURL,
                    runURL: nil,
                    profileID: activeRecordingSelection?.profileID ?? selectedProfileID,
                    postprocess: activeRecordingSelection?.postprocess ?? selectedPostprocess,
                    postprocessMode: activeRecordingSelection?.postprocessMode.mode,
                    translationTargetLanguage: activeRecordingSelection?.postprocessMode == .translation
                        ? activeRecordingSelection?.translationTarget.rawValue
                        : nil,
                    durationS: 0,
                    state: .interrupted,
                    speakerNames: [:],
                    conflictResolutions: [:],
                    failureMessage: appString("Interrupted")
                )
                try persist(record)
                activeRecordingRecordID = record.id
                isRecording = true
                captureElapsedS = 0
                startCaptureTimer()
            } catch {
                if captureStarted {
                    await recorder.cancel()
                }
                finishRecordingStorageAccess()
                errorMessage = error.localizedDescription
                activeRecordingSelection = nil
                activeRecordingRecordID = nil
            }
            activeTask = nil
        }
    }

    func stopRecordingAndTranscribe() {
        guard isRecording,
              activeTask == nil,
              activeRecordingSelection != nil,
              let provisionalRecordID = activeRecordingRecordID
        else { return }
        syncPostprocessSelectionsFromDefaults()
        activeTask = Task { [weak self] in
            guard let self else { return }
            let recordID = provisionalRecordID
            defer {
                finishRecordingStorageAccess()
                finishActiveTranscription()
            }
            captureTimer?.cancel()
            do {
                let artifacts = try await recorder.stop()
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                try updateRecordingRecord(
                    id: recordID,
                    sourceURL: artifacts.combinedURL,
                    microphoneURL: artifacts.microphoneURL,
                    systemAudioURL: artifacts.systemAudioURL,
                    durationS: artifacts.durationS,
                    state: .recorded,
                    failureMessage: nil
                )
                activeRecordingRecordID = nil
                selection = .record(recordID)
                try await transcribe(recordID: recordID)
            } catch let error as RecordingFinalizationError {
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                let artifacts = error.artifacts
                do {
                    try updateRecordingRecord(
                        id: recordID,
                        sourceURL: artifacts.microphoneURL,
                        microphoneURL: artifacts.microphoneURL,
                        systemAudioURL: artifacts.systemAudioURL,
                        durationS: artifacts.durationS,
                        state: .failed,
                        failureMessage: error.localizedDescription
                    )
                    activeRecordingRecordID = nil
                    selection = .record(recordID)
                    errorMessage = error.localizedDescription
                } catch {
                    errorMessage = error.localizedDescription
                }
            } catch is CancellationError {
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                activeRecordingRecordID = nil
                markCancelled(recordID: recordID)
            } catch {
                isRecording = false
                captureMeters = .silent
                activeRecordingSelection = nil
                errorMessage = error.localizedDescription
                activeRecordingRecordID = nil
                do {
                    try markFailed(recordID: recordID, message: error.localizedDescription)
                } catch {
                    errorMessage = Self.combinedFailureMessage(
                        operation: errorMessage ?? "",
                        persistence: error
                    )
                }
            }
        }
    }

    func cancelTranscription() {
        guard activeRecordID != nil || activeExistingRunPostprocess != nil else { return }
        runner.cancel()
    }

    func retrySelectedTranscription() {
        guard !isRecording else {
            errorMessage = appString("Stop the active recording before starting transcription.")
            return
        }
        guard activeTask == nil, let record = selectedRecord else { return }
        guard !(isMOSSLimitExhausted(record) && usesUnchangedMOSSConfiguration(record)) else {
            errorMessage = appString(
                "This run reached the MOSS output limit after bounded splitting. Choose a different profile or use a shorter copy before retrying."
            )
            return
        }
        guard canRetryTranscription(record) else { return }
        errorMessage = nil
        runFailures.removeValue(forKey: record.id)
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { finishActiveTranscription() }
            do {
                try applySelectedExecutionConfigurationForRetry(recordID: record.id)
                try prepareRetrySource(recordID: record.id)
                try await transcribe(recordID: record.id)
            } catch is CancellationError {
                markCancelled(recordID: record.id)
            } catch {
                let runnerMessage = error.localizedDescription
                do {
                    try markFailed(recordID: record.id, message: runnerMessage)
                    errorMessage = runnerMessage
                } catch {
                    errorMessage = Self.combinedFailureMessage(
                        operation: runnerMessage,
                        persistence: error
                    )
                }
            }
        }
    }

    func postprocessSelectedRun(
        operation: PostprocessMode,
        backend: PostprocessChoice,
        targetLanguage: AppLanguage? = nil,
        glossarySemantics: DerivedGlossarySemantics = .currentProfile
    ) {
        guard !isRecording, activeTask == nil, let record = selectedRecord,
              canPostprocess(record), let runURL = record.runURL,
              let profile = profiles.first(where: { $0.id == record.profileID }),
              backend != .none
        else { return }
        if operation == .translation, targetLanguage == nil || targetLanguage == .system {
            return
        }

        existingRunPostprocessFailures.removeValue(forKey: record.id)
        activeExistingRunPostprocess = ActiveExistingRunPostprocess(
            recordID: record.id,
            operation: operation,
            progress: ExistingRunPostprocessProgress(
                operation: operation,
                elapsedS: 0,
                modelID: backend.requestedModelID,
                message: nil
            )
        )
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                activeExistingRunPostprocess = nil
                activeTask = nil
            }
            do {
                let runsAccess = try repository.beginAccessingRunsRoot()
                defer { runsAccess?.end() }
                if backend == .codex {
                    if !codexAvailability.isAuthenticated {
                        await refreshCodexAvailability()
                    }
                    guard codexAvailability.isAuthenticated else {
                        throw TranscriptionRunnerError.pipelineFailed(
                            appString(
                                "Your Codex sign-in is expired or too close to expiry. Refresh or sign in through Codex, then retry, or select Local."
                            )
                        )
                    }
                }
                _ = try RunIntegrityVerifier.verifyCompletedRun(at: runURL)
                let request = ExistingRunPostprocessRequest(
                    sourceRunURL: runURL,
                    profile: profile,
                    postprocess: backend,
                    operation: operation,
                    translationTargetLanguage: operation == .translation
                        ? targetLanguage?.rawValue
                        : nil,
                    glossarySemantics: glossarySemantics,
                    glossaryURL: glossarySemantics == .currentProfile
                        ? try activeGlossaryURL(
                            at: glossaryURL(for: record.profileID)
                        )
                        : nil
                )
                _ = try await runner.postprocess(request) { [weak self] progress in
                    guard let self,
                          activeExistingRunPostprocess?.recordID == record.id
                    else { return }
                    activeExistingRunPostprocess?.progress = progress
                }
                let loaded = try repository.loadRun(at: runURL)
                guard let index = records.firstIndex(where: { $0.id == record.id }) else {
                    return
                }
                records[index].state = loaded.requiresReview(for: records[index])
                    ? .hasConflicts
                    : .done
                try recordSaver(records)
                if selection == .record(record.id) {
                    selectedRun = loaded
                    selectedRunIssue = nil
                }
            } catch is CancellationError {
                return
            } catch {
                existingRunPostprocessFailures[record.id] = error.localizedDescription
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
              let index = records.firstIndex(where: { $0.id == id }),
              let selectedRun,
              !selectedRun.isTranslation
        else { return }
        if selectedRun.resultID == nil {
            records[index].conflictResolutions[segmentIndex] = text
        } else {
            var resolutions = records[index].derivedCorrectionResolutions ?? []
            resolutions.removeAll {
                $0.resultID == selectedRun.effectiveResultID
                    && $0.segmentIndex == segmentIndex
            }
            resolutions.append(DerivedCorrectionResolution(
                resultID: selectedRun.effectiveResultID,
                segmentIndex: segmentIndex,
                resolvedText: text
            ))
            records[index].derivedCorrectionResolutions = resolutions
        }
        records[index].state = selectedRun.requiresReview(for: records[index])
            ? .hasConflicts
            : .done
        saveRecordsReportingErrors()
    }

    func acknowledgeTranslation(at segmentIndex: Int, text: String) {
        guard case let .record(id) = selection,
              let index = records.firstIndex(where: { $0.id == id }),
              let selectedRun,
              selectedRun.isTranslation,
              selectedRun.transcript.segments.indices.contains(segmentIndex),
              selectedRun.transcript.segments[segmentIndex].text == text
        else { return }
        var acknowledgements = records[index].translationReviewAcknowledgements ?? []
        acknowledgements.removeAll {
            $0.resultID == selectedRun.effectiveResultID
                && $0.segmentIndex == segmentIndex
        }
        acknowledgements.append(TranslationReviewAcknowledgement(
            resultID: selectedRun.effectiveResultID,
            segmentIndex: segmentIndex,
            translatedText: text
        ))
        records[index].translationReviewAcknowledgements = acknowledgements
        records[index].state = selectedRun.requiresReview(for: records[index])
            ? .hasConflicts
            : .done
        saveRecordsReportingErrors()
    }

    func play(segment: MaccheroniCore.Segment) {
        guard let record = selectedRecord else { return }
        do {
            stopPlayback()
            let source = try resolveOriginalRefreshingRecord(record)
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
            let source = try resolveOriginalRefreshingRecord(record)
            NSWorkspace.shared.activateFileViewerSelecting([source])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealRun(_ record: LibraryRecord) {
        guard let runURL = record.runURL,
              FileManager.default.fileExists(atPath: runURL.path)
        else {
            errorMessage = appString("Recording Not Found")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([runURL])
    }

    func canRevealRun(_ record: LibraryRecord) -> Bool {
        record.runURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
    }

    func glossaryURL(for profileID: AppProfileID) -> URL {
        repository.glossariesRoot.appendingPathComponent("\(profileID.rawValue).txt")
    }

    func loadGlossary(for profileID: AppProfileID) throws -> String {
        let url = glossaryURL(for: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func saveGlossary(_ text: String, for profileID: AppProfileID) throws {
        try repository.prepareDirectories()
        let data = Data(text.utf8)
        _ = try glossaryRevisionStore.createRevision(from: data)
        let target = glossaryURL(for: profileID)
        let temporary = repository.glossariesRoot.appendingPathComponent(
            ".\(UUID().uuidString)-\(profileID.rawValue).txt"
        )
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: target)
        }
    }

    private func makeImportedRecord(url: URL) async throws -> LibraryRecord {
        guard AudioPreprocessor.supportsInputFile(url) else {
            throw AppAudioImportError.unsupportedFormat
        }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let seconds = try Self.readableAudioDuration(at: url)
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
                        "Your Codex sign-in is expired or too close to expiry. Refresh or sign in through Codex, then retry, or select Local."
                    )
                )
            }
        }
        records[index].state = .transcribing
        records[index].failureMessage = nil
        runFailures.removeValue(forKey: recordID)
        activeRecordID = recordID
        try recordSaver(records)
        let glossaryURL = try activeGlossaryURL(at: glossaryURL(for: record.profileID))
        let source = try resolveOriginalRefreshingRecord(record)
        let sourceAccess = try repository.beginAccessingOriginal(
            source,
            bookmark: record.securityScopedBookmark
        )
        defer { sourceAccess?.end() }
        let storageAccesses = try repository.beginAccessingRunnerRoots()
        defer { storageAccesses.forEach { $0.end() } }
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
        try recordSaver(records)
        if selection == .record(recordID) {
            selectedRun = loaded
        }
    }

    private func activeGlossaryURL(at url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try glossaryRevisionStore.createRevision(
            from: Data(contentsOf: url)
        )?.url
    }

    private var glossaryRevisionStore: GlossaryRevisionStore {
        GlossaryRevisionStore(
            root: repository.glossariesRoot.appendingPathComponent(
                "Revisions",
                isDirectory: true
            )
        )
    }

    private func prepareRetrySource(recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            throw TranscriptionRunnerError.resultMissing
        }
        let record = records[index]
        let sourceIsPreservedChannel = record.sourceKind == .appRecording
            && (record.sourceURL == record.microphoneURL
                || record.sourceURL == record.systemAudioURL)
        if !sourceIsPreservedChannel, isReadableAudio(record) {
            return
        }
        guard record.sourceKind == .appRecording,
              let microphoneURL = record.microphoneURL,
              let systemAudioURL = record.systemAudioURL
        else {
            throw LibraryRepositoryError.originalUnavailable
        }

        let outputURL = microphoneURL.deletingLastPathComponent().appendingPathComponent(
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
        try recordSaver(records)
    }

    private func applySelectedExecutionConfigurationForRetry(recordID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].profileID = selectedProfileID
        if records[index].postprocess == .codex, selectedPostprocess != .codex {
            records[index].postprocess = selectedPostprocess
        }
        try recordSaver(records)
    }

    private func persist(_ record: LibraryRecord) throws {
        records.append(record)
        records.sort { $0.createdAt > $1.createdAt }
        try recordSaver(records)
    }

    private func refreshSelectedRun() {
        selectedRun = nil
        selectedRunIssue = nil
        guard let selectedRecord else { return }
        guard let runURL = selectedRecord.runURL else {
            if selectedRecord.state == .done || selectedRecord.state == .hasConflicts {
                selectedRunIssue = .missing
            }
            return
        }
        let manifestURL = runURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: runURL.path) else {
            selectedRunIssue = .missing
            return
        }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            selectedRunIssue = .missingArtifact(
                LibraryRepositoryError.artifactMissing("manifest.json").localizedDescription
            )
            return
        }
        do {
            selectedRun = try repository.loadRun(at: runURL)
        } catch let error as LibraryRepositoryError {
            switch error {
            case .artifactHashMismatch, .unsafeArtifactPath,
                 .derivedManifestInvalid, .derivedLineageMismatch:
                selectedRunIssue = .integrity(error.localizedDescription)
            case .artifactMissing:
                selectedRunIssue = .missingArtifact(error.localizedDescription)
            case .originalUnavailable:
                selectedRunIssue = .missing
            }
        } catch let error as RunIntegrityError {
            selectedRunIssue = .integrity(error.localizedDescription)
        } catch let error as DecodingError {
            selectedRunIssue = .decoding(error.localizedDescription)
        } catch {
            selectedRunIssue = .decoding(error.localizedDescription)
        }
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
        runFailures.removeValue(forKey: recordID)
        saveRecordsReportingErrors()
    }

    private func markFailed(recordID: UUID, message: String) throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].state = .failed
        records[index].failureMessage = message
        try recordSaver(records)
    }

    private func finishActiveTranscription() {
        activeRecordID = nil
        activeTask = nil
        progress = nil
    }

    private func finishRecordingStorageAccess() {
        activeRecordingStorageAccess?.end()
        activeRecordingStorageAccess = nil
    }

    private func saveRecordsReportingErrors() {
        do {
            try recordSaver(records)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateRecordingRecord(
        id: UUID,
        sourceURL: URL,
        microphoneURL: URL,
        systemAudioURL: URL,
        durationS: Double,
        state: LibraryItemState,
        failureMessage: String?
    ) throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw TranscriptionRunnerError.resultMissing
        }
        records[index].sourceURL = sourceURL
        records[index].microphoneURL = microphoneURL
        records[index].systemAudioURL = systemAudioURL
        records[index].durationS = durationS
        records[index].state = state
        records[index].failureMessage = failureMessage
        try recordSaver(records)
    }

    private func resolveOriginalRefreshingRecord(_ record: LibraryRecord) throws -> URL {
        let resolved = try repository.resolveOriginal(for: record)
        guard record.securityScopedBookmark != nil,
              let refreshed = try repository.loadRecords().first(where: { $0.id == record.id }),
              let index = records.firstIndex(where: { $0.id == record.id })
        else { return resolved }
        records[index] = refreshed
        return resolved
    }

    private func isReadableAudio(_ record: LibraryRecord) -> Bool {
        guard let source = try? resolveOriginalRefreshingRecord(record) else { return false }
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        return Self.isReadableAudio(at: source)
    }

    private static func isReadableAudio(at url: URL) -> Bool {
        (try? readableAudioDuration(at: url)) != nil
    }

    private static func isDecodableInternalAudio(at url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return false }
        let duration = Double(file.length) / sampleRate
        return duration.isFinite && duration > 0
    }

    private static func readableAudioDuration(at url: URL) throws -> Double {
        guard AudioPreprocessor.supportsInputFile(url) else {
            throw AppAudioImportError.unsupportedFormat
        }
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.processingFormat.sampleRate
            let seconds = sampleRate > 0 ? Double(file.length) / sampleRate : 0
            guard seconds.isFinite, seconds > 0 else {
                throw TranscriptionRunnerError.pipelineFailed(
                    appString("The selected file has no readable audio duration.")
                )
            }
            return seconds
        } catch let error as TranscriptionRunnerError {
            throw error
        } catch {
            throw TranscriptionRunnerError.pipelineFailed(
                appString("The selected file has no readable audio duration.")
            )
        }
    }

    private static func recoverUnindexedCaptureSessions(
        recordingsRoot: URL,
        existingRecords: [LibraryRecord],
        profileID: AppProfileID,
        postprocess: PostprocessChoice,
        postprocessMode: PostprocessOperationChoice,
        translationTarget: AppLanguage
    ) throws -> [LibraryRecord] {
        let indexedURLs = Set(existingRecords.flatMap { record in
            [record.sourceURL, record.microphoneURL, record.systemAudioURL]
                .compactMap { $0?.standardizedFileURL }
        })
        let directories = try FileManager.default.contentsOfDirectory(
            at: recordingsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values?.isDirectory == true else { return nil }
            let microphoneURL = directory.appendingPathComponent("microphone.caf")
                .standardizedFileURL
            let systemAudioURL = directory.appendingPathComponent("system-audio.caf")
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: microphoneURL.path),
                  FileManager.default.fileExists(atPath: systemAudioURL.path),
                  !indexedURLs.contains(microphoneURL),
                  !indexedURLs.contains(systemAudioURL)
            else { return nil }
            guard let duration = recoverableCaptureDuration(
                microphoneURL: microphoneURL,
                systemAudioURL: systemAudioURL
            ) else { return nil }
            let startedAt = values?.creationDate ?? Date()
            return LibraryRecord(
                id: UUID(),
                createdAt: startedAt,
                displayName: appString(
                    "Recording \(startedAt.formatted(date: .abbreviated, time: .shortened))"
                ),
                sourceKind: .appRecording,
                sourceURL: microphoneURL,
                securityScopedBookmark: nil,
                microphoneURL: microphoneURL,
                systemAudioURL: systemAudioURL,
                runURL: nil,
                profileID: profileID,
                postprocess: postprocess,
                postprocessMode: postprocessMode.mode,
                translationTargetLanguage: postprocessMode == .translation
                    ? translationTarget.rawValue
                    : nil,
                durationS: duration,
                state: .interrupted,
                speakerNames: [:],
                conflictResolutions: [:],
                failureMessage: appString("Interrupted")
            )
        }
    }

    private static func recoverableCaptureDuration(
        microphoneURL: URL,
        systemAudioURL: URL
    ) -> Double? {
        guard let microphone = try? AVAudioFile(forReading: microphoneURL),
              let systemAudio = try? AVAudioFile(forReading: systemAudioURL),
              isCanonicalRecordingFile(microphone),
              isCanonicalRecordingFile(systemAudio)
        else { return nil }
        let frames = max(microphone.length, systemAudio.length)
        guard frames > 0 else { return nil }
        return Double(frames) / RecordingStorage.sampleRate
    }

    private static func isCanonicalRecordingFile(_ file: AVAudioFile) -> Bool {
        let format = file.processingFormat
        return format.sampleRate == RecordingStorage.sampleRate
            && format.channelCount == RecordingStorage.channelCount
            && format.commonFormat == .pcmFormatFloat32
    }

    private static func combinedFailureMessage(
        operation: String,
        persistence: any Error
    ) -> String {
        [operation, persistence.localizedDescription]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

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

/// Asks the shipped command-line engine `maccheroni doctor --json` about the selected
/// profile. The engine owns the readiness contract; the app only reads its answer.
///
/// The profile is handed over as a one-profile registry, the same way a run does, because
/// the app's profile names are not in the engine's bundled registry. Post-processing is
/// pinned to `none` here: this surface answers whether the transcription pipeline can run,
/// and the post-processing backend keeps its own notice next to its picker.
struct ProcessProfileReadinessProbe: ProfileReadinessProbing {
    /// Accepted `schema_version` major component of the doctor envelope.
    static let supportedSchemaMajorVersion = "1"

    /// How long `doctor` may take before the probe stops waiting for it. Measured cost
    /// is 0.49 s against an empty cache, which fails before reaching Python, and 3.91 s
    /// against a provisioned one, where the Python import dominates; a partly
    /// provisioned cache fails late and lands near the top of that range. Thirty
    /// seconds leaves roughly 7x headroom over the slowest legitimate case, so reaching
    /// it means the engine is stuck rather than slow.
    var timeout: Duration = .seconds(30)

    var executableResolver: @Sendable () -> URL? = ProcessProfileReadinessProbe.resolveExecutable

    func probe(_ profile: AppProfile) async -> ProfileReadinessProbeOutcome {
        guard let executableURL = executableResolver(),
              FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            return .issue(.engineMissing)
        }
        return await Task.detached(priority: .userInitiated) {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "maccheroni-readiness-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: scratch) }
            let profilesURL = scratch.appendingPathComponent("profiles.json")
            let stdoutURL = scratch.appendingPathComponent("stdout")
            let stderrURL = scratch.appendingPathComponent("stderr")
            do {
                try FileManager.default.createDirectory(
                    at: scratch,
                    withIntermediateDirectories: false
                )
                try Self.registryDocument(for: profile).write(to: profilesURL)
                guard FileManager.default.createFile(atPath: stdoutURL.path, contents: nil),
                      FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
                else {
                    return .issue(.engineFailed(
                        "could not create readiness output capture files"
                    ))
                }
            } catch {
                return .issue(.engineFailed(error.localizedDescription))
            }
            let stdout = try? FileHandle(forWritingTo: stdoutURL)
            let stderr = try? FileHandle(forWritingTo: stderrURL)
            defer {
                try? stdout?.close()
                try? stderr?.close()
            }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [
                "doctor",
                "--profile", profile.cliProfile,
                "--profiles", profilesURL.path,
                "--json",
            ]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HF_HUB_OFFLINE": "1",
            ]) { current, _ in current }
            process.standardOutput = stdout
            process.standardError = stderr
            do {
                try process.run()
            } catch {
                return .issue(.engineFailed(error.localizedDescription))
            }
            // A hung `doctor` must not hold the readiness answer open forever: the
            // capture screen waits on it before starting a run. The watchdog signals
            // the process by pid rather than capturing the non-Sendable `Process`.
            let startedAt = ContinuousClock.now
            let pid = process.processIdentifier
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                kill(pid, SIGTERM)
            }
            process.waitUntilExit()
            watchdog.cancel()
            try? stdout?.synchronize()
            if process.terminationReason == .uncaughtSignal,
               startedAt.duration(to: .now) >= timeout
            {
                return .issue(.engineFailed(
                    "the readiness check did not finish within \(timeout.components.seconds) seconds"
                ))
            }
            // `doctor` exits nonzero when the profile is not ready and still writes the
            // envelope, so the exit status is not read: the envelope is the answer.
            guard let data = try? Data(contentsOf: stdoutURL) else {
                return .issue(.reportUnreadable)
            }
            return Self.decode(data)
        }.value
    }

    static func decode(_ data: Data) -> ProfileReadinessProbeOutcome {
        struct Envelope: Decodable {
            var ready: Bool
            var schemaVersion: String
            var values: [String: String]

            enum CodingKeys: String, CodingKey {
                case ready, values
                case schemaVersion = "schema_version"
            }
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion.split(separator: ".").first.map(String.init)
              == supportedSchemaMajorVersion
        else {
            return .issue(.reportUnreadable)
        }
        return .report(ProfileReadinessReport(
            ready: envelope.ready,
            schemaVersion: envelope.schemaVersion,
            values: envelope.values
        ))
    }

    static func registryDocument(for profile: AppProfile) throws -> Data {
        struct Diarization: Encodable {
            var enabled = true
            var backend: String
        }
        struct Profile: Encodable {
            var name: String
            var asrBackend: String
            var languagePin: String
            var diarization: Diarization
            var postprocess = "none"

            enum CodingKeys: String, CodingKey {
                case name, diarization, postprocess
                case asrBackend = "asr_backend"
                case languagePin = "language_pin"
            }
        }
        struct Document: Encodable {
            var schemaVersion = "1.0.0"
            var profiles: [Profile]

            enum CodingKeys: String, CodingKey {
                case profiles
                case schemaVersion = "schema_version"
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(profiles: [Profile(
            name: profile.cliProfile,
            asrBackend: profile.asrBackend,
            languagePin: profile.languagePin,
            diarization: Diarization(backend: profile.diarizationBackend)
        )]))
    }

    /// Mirrors the lookup order `ProcessTranscriptionRunner.resolveExecutable` uses, so
    /// readiness is answered by the same engine binary a run would launch.
    static func resolveExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MACCHERONI_CLI_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let current = Bundle.main.executableURL {
            let sibling = current.deletingLastPathComponent()
                .appendingPathComponent("maccheroni")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [".build/release/maccheroni", ".build/debug/maccheroni"] {
            let candidate = repository.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
