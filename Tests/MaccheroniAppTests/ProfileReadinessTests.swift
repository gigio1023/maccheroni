import Foundation
import Testing
@testable import MaccheroniApp

/// The capture screen must state whether the selected profile can run before a run
/// starts, and must block the run controls when it cannot. These tests exercise the
/// gate itself rather than the SwiftUI layout: the model's readiness value decides
/// what the screen shows and which controls stay usable.
struct ProfileReadinessTests {
    @Test @MainActor
    func unprovisionedDoctorReportDisablesTheRunControlsAndNamesTheMissingDependencies() async throws {
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .report(unprovisionedReport()))
        )

        #expect(model.canStartRecording)
        #expect(model.canImportAudio)

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        #expect(model.profileReadiness.blockingGroups == [
            .speechModel,
            .speakerSeparation,
            .voiceActivity,
            .speechRuntime,
        ])
        #expect(model.profileReadiness.showsNotice)
        #expect(!model.profileReadiness.isReady)
        #expect(model.profileReadiness.needsProvisioning)
        #expect(!model.canStartRecording)
        #expect(!model.canImportAudio)
        #expect(model.profileReadiness.probeIssue == nil)
    }

    @Test @MainActor
    func aReadyDoctorReportLeavesTheCaptureScreenUnobstructed() async throws {
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .report(readyReport()))
        )

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        #expect(model.profileReadiness.isReady)
        #expect(model.profileReadiness.blockingGroups.isEmpty)
        #expect(!model.profileReadiness.showsNotice)
        #expect(model.canStartRecording)
        #expect(model.canImportAudio)
    }

    @Test @MainActor
    func changingTheSelectedProfileReevaluatesReadinessForTheNewProfile() async throws {
        let probe = ReadinessStubProbe(outcomes: [
            "ko-it-meeting": .report(unprovisionedReport()),
            "it-dialogue": .report(readyReport()),
        ])
        let model = try readinessModel(probe: probe)

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }
        #expect(!model.canStartRecording)
        #expect(model.profileReadiness.profileID == .koreanITMeeting)

        model.selectedProfileID = .italianDialogue
        #expect(!model.profileReadiness.hasResult)
        await readinessWait { model.profileReadiness.hasResult }

        let requested = await probe.requestedProfiles
        #expect(requested == ["ko-it-meeting", "it-dialogue"])
        #expect(model.profileReadiness.profileID == .italianDialogue)
        #expect(model.profileReadiness.isReady)
        #expect(model.canStartRecording)
        #expect(model.canImportAudio)
    }

    /// `scripts/setup-transcription-runtime.zsh` fetches the VibeVoice, Pyannote and
    /// Silero assets only. A MOSS profile missing its own model is named without being
    /// pointed at a command that would not install it.
    @Test @MainActor
    func theProvisioningCommandIsOfferedOnlyWhenItInstallsWhatIsMissing() async throws {
        let missingSpeechModel = ProfileReadinessReport(
            ready: false,
            schemaVersion: "1.1.0",
            values: [
                "check.asr.model_snapshot": "false",
                "check.asr_doctor": "false",
                "check.storage": "true",
            ]
        )
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .report(missingSpeechModel))
        )

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }
        #expect(model.profileReadiness.blockingGroups == [.speechModel])
        #expect(model.profileReadiness.asrBackend == "vibevoice")
        #expect(model.profileReadiness.needsProvisioning)

        model.selectedProfileID = .italianDialogue
        await readinessWait { model.profileReadiness.hasResult }
        #expect(model.profileReadiness.blockingGroups == [.speechModel])
        #expect(model.profileReadiness.asrBackend == "moss")
        #expect(!model.profileReadiness.needsProvisioning)
        #expect(!model.canStartRecording)
    }

    @Test @MainActor
    func aDeniedMicrophoneBlocksRecordingWhileFileImportStaysAvailable() async throws {
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .report(readyReport())),
            permissions: CapturePermissions(microphone: .denied, systemAudio: .granted)
        )

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        #expect(model.profileReadiness.blockingGroups == [.microphonePermission])
        #expect(model.profileReadiness.showsNotice)
        #expect(!model.canStartRecording)
        #expect(model.canImportAudio)
        #expect(!model.profileReadiness.needsProvisioning)
    }

    @Test @MainActor
    func screenRecordingIsReportedWithoutBlockingBecauseMacOSStillHasToAsk() async throws {
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .report(readyReport())),
            permissions: CapturePermissions(
                microphone: .granted,
                systemAudio: .undetermined
            )
        )

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        #expect(model.profileReadiness.blockingGroups == [.systemAudioPermission])
        #expect(model.profileReadiness.showsNotice)
        #expect(model.canStartRecording)
        #expect(model.canImportAudio)
    }

    /// A missing engine is not an unanswered question. Every run launches that binary,
    /// so its absence blocks, even though no dependency group is named. The engine is
    /// resolved per probe while the runner resolves once at launch, so this state is
    /// reachable when the binary is removed or rebuilt mid-session.
    @Test @MainActor
    func aMissingEngineBlocksTheRunControlsAndNamesTheEngineRatherThanADependency() async throws {
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .issue(.engineMissing))
        )

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        #expect(model.profileReadiness.probeIssue == .engineMissing)
        #expect(model.profileReadiness.blockingGroups.isEmpty)
        #expect(model.profileReadiness.showsNotice)
        #expect(model.profileReadiness.isObstructed)
        #expect(!model.profileReadiness.isReady)
        #expect(!model.profileReadiness.needsProvisioning)
        #expect(!model.canStartRecording)
        #expect(!model.canImportAudio)
        #expect(
            String(localized: ProfileReadinessProbeIssue.engineMissing.message)
                == "The Maccheroni command-line engine is missing."
        )
    }

    /// A report that never arrived, or did not parse, says nothing about the machine.
    @Test @MainActor
    func anUnansweredCheckIsStatedWithoutBlockingTheRunControls() async throws {
        for issue in [
            ProfileReadinessProbeIssue.reportUnreadable,
            .engineFailed("launch path is not executable"),
        ] {
            let model = try readinessModel(
                probe: ReadinessStubProbe(outcome: .issue(issue))
            )

            model.evaluateProfileReadiness()
            await readinessWait { model.profileReadiness.hasResult }

            #expect(model.profileReadiness.probeIssue == issue)
            #expect(model.profileReadiness.showsNotice)
            #expect(!model.profileReadiness.isObstructed)
            #expect(!model.profileReadiness.isReady)
            #expect(model.canStartRecording)
            #expect(model.canImportAudio)
        }
    }

    @Test @MainActor
    func aNotReadyReportWithNoFailedCheckStillBlocksTheRun() async throws {
        let model = try readinessModel(
            probe: ReadinessStubProbe(outcome: .report(ProfileReadinessReport(
                ready: false,
                schemaVersion: "1.1.0",
                values: ["profile": "ko-it-meeting"]
            )))
        )

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        #expect(model.profileReadiness.blockingGroups == [.otherDependency])
        #expect(!model.canStartRecording)
        #expect(!model.canImportAudio)
    }

    /// Between the capture screen appearing and the first answer arriving, the
    /// synchronous guards see no obstruction. A run started in that window must wait
    /// for the answer rather than race it.
    @Test @MainActor
    func aRunStartedBeforeTheFirstAnswerArrivesWaitsForItAndIsRefused() async throws {
        let root = try readinessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReadinessStubProbe(outcome: .report(unprovisionedReport()))
        await probe.hold()
        let model = try readinessModel(root: root, probe: probe)

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.isEvaluating }
        #expect(!model.profileReadiness.hasResult)
        #expect(model.canStartRecording)
        #expect(model.canImportAudio)

        model.startRecording()
        #expect(model.canCancelActiveOperation)
        let audioURL = root.appendingPathComponent("meeting.wav")
        try Data("not audio".utf8).write(to: audioURL)
        await probe.release()
        await readinessWait(attempts: 400, napping: .milliseconds(5)) {
            model.profileReadiness.hasResult && !model.canCancelActiveOperation
        }

        #expect(!model.isRecording)
        #expect(model.errorMessage == appString("This profile is not ready to run."))
        #expect(!model.canStartRecording)

        model.clearError()
        model.importAudio([audioURL])
        await readinessWait(attempts: 400, napping: .milliseconds(5)) {
            model.errorMessage != nil
        }
        #expect(model.errorMessage == appString("This profile is not ready to run."))
        #expect(model.records.isEmpty)
    }

    /// Check Again is a question, so until it is answered there is no answer.
    ///
    /// A new evaluation used to keep the previous result: `hasResult` stayed
    /// true and the blockers stayed the old ones while the probe ran. A run
    /// started in that window read the stale success and proceeded, which is
    /// exactly the race `awaitPendingProfileReadiness` exists to close and
    /// which it cannot see, because it waits on `hasResult`.
    @Test @MainActor
    func reProbingAfterADependencyChangesWaitsForTheNewAnswerRatherThanTheOldOne() async throws {
        let root = try readinessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReadinessStubProbe(outcome: .report(readyReport()))
        let model = try readinessModel(root: root, probe: probe)

        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }
        #expect(model.profileReadiness.isReady)
        #expect(model.canStartRecording)

        // The dependency goes away, and the reader asks again.
        await probe.answer(.report(unprovisionedReport()))
        await probe.hold()
        model.evaluateProfileReadiness()

        // Inside the window: no answer, and none of the old one left standing.
        #expect(!model.profileReadiness.hasResult)
        #expect(!model.profileReadiness.isReady)
        #expect(model.profileReadiness.blockingGroups.isEmpty)
        #expect(model.profileReadiness.probeIssue == nil)
        #expect(model.profileReadiness.isEvaluating)

        let audioURL = root.appendingPathComponent("meeting.wav")
        try Data("not audio".utf8).write(to: audioURL)
        model.importAudio([audioURL])
        // Still waiting: the import has neither succeeded on the stale answer
        // nor been refused on an answer that does not exist yet.
        #expect(model.errorMessage == nil)
        #expect(model.records.isEmpty)

        await probe.release()
        await readinessWait(attempts: 400, napping: .milliseconds(5)) {
            model.errorMessage != nil
        }

        #expect(model.errorMessage == appString("This profile is not ready to run."))
        #expect(model.records.isEmpty)
        #expect(model.profileReadiness.blockingGroups == [
            .speechModel,
            .speakerSeparation,
            .voiceActivity,
            .speechRuntime,
        ])
        #expect(!model.canStartRecording)
        let requested = await probe.requestedProfiles
        #expect(requested == ["ko-it-meeting", "ko-it-meeting"])
    }

    @Test @MainActor
    func blockedImportRefusesAtTheModelAndReportsTheReason() async throws {
        let root = try readinessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try readinessModel(
            root: root,
            probe: ReadinessStubProbe(outcome: .report(unprovisionedReport()))
        )
        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.hasResult }

        let audioURL = root.appendingPathComponent("meeting.wav")
        try Data("not audio".utf8).write(to: audioURL)
        model.importAudio([audioURL])

        #expect(model.errorMessage == appString("This profile is not ready to run."))
        #expect(model.records.isEmpty)
    }

    @Test
    func everyDoctorCheckKeyObservedOnAProvisionedMachineMapsToAUserFacingGroup() {
        let observed: [String: ProfileReadinessGroup] = [
            "check.asr.model_files": .speechModel,
            "check.asr.mlx_audio": .speechModel,
            "check.asr_runner": .speechModel,
            "check.asr_lock": .speechModel,
            "check.asr_doctor": .speechModel,
            "check.asr_model": .speechModel,
            "check.asr_python_3_12": .speechModel,
            "check.moss_release_helper": .speechModel,
            "check.diarization_model_cache": .speakerSeparation,
            "check.diarization_revision": .speakerSeparation,
            "check.diarization_snapshot": .speakerSeparation,
            "check.diarization_executable": .speakerSeparation,
            "check.diarization_runtime_tree": .speakerSeparation,
            "check.vad_model_cache": .voiceActivity,
            "check.vad_executable": .voiceActivity,
            "check.vad_snapshot": .voiceActivity,
            "check.vad_ref": .voiceActivity,
            "check.vad_runtime_tree": .voiceActivity,
            "check.offline_speech_runtime": .speechRuntime,
            "check.offline_speech_runtime_sidecar": .speechRuntime,
            "check.afconvert_executable": .speechRuntime,
            "check.storage": .storage,
            "check.postprocess": .otherDependency,
        ]
        for (key, group) in observed {
            #expect(
                ProfileReadinessGroup.group(forFailedCheck: key) == group,
                "group for \(key)"
            )
        }
        #expect(ProfileReadinessGroup.group(forFailedCheck: "asr_model") == nil)
        #expect(ProfileReadinessGroup.group(forFailedCheck: "profile") == nil)
    }

    @Test
    func theDoctorEnvelopeIsDecodedFromItsPublishedSchemaAndRejectedOtherwise() throws {
        let envelope = """
        {"command":"doctor","ready":false,"schema_version":"1.1.0",\
        "storage":{"observable":true},\
        "values":{"check.asr_runner":"false","check.storage":"true","profile":"ko-it-meeting"}}
        """
        let outcome = ProcessProfileReadinessProbe.decode(Data(envelope.utf8))
        guard case let .report(report) = outcome else {
            Issue.record("expected a decoded report, got \(outcome)")
            return
        }
        #expect(!report.ready)
        #expect(report.schemaVersion == "1.1.0")
        #expect(report.failedCheckKeys == ["check.asr_runner"])

        let futureSchema = Data("""
        {"command":"doctor","ready":true,"schema_version":"2.0.0","values":{}}
        """.utf8)
        #expect(
            ProcessProfileReadinessProbe.decode(futureSchema) == .issue(.reportUnreadable)
        )
        #expect(
            ProcessProfileReadinessProbe.decode(Data("not json".utf8))
                == .issue(.reportUnreadable)
        )
    }

    @Test
    func theProbeAsksTheEngineAboutTheSelectedProfileWithPostprocessingLeftOut() throws {
        let profiles = try AppProfileRegistry.load()
        let korean = try #require(profiles.first(where: { $0.id == .koreanITMeeting }))
        let document = try ProcessProfileReadinessProbe.registryDocument(for: korean)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: document) as? [String: Any]
        )

        #expect(decoded["schema_version"] as? String == "1.0.0")
        let registry = try #require(decoded["profiles"] as? [[String: Any]])
        #expect(registry.count == 1)
        let profile = try #require(registry.first)
        #expect(profile["name"] as? String == korean.cliProfile)
        #expect(profile["asr_backend"] as? String == korean.asrBackend)
        #expect(profile["language_pin"] as? String == korean.languagePin)
        #expect(profile["postprocess"] as? String == "none")
        let diarization = try #require(profile["diarization"] as? [String: Any])
        #expect(diarization["enabled"] as? Bool == true)
        #expect(diarization["backend"] as? String == korean.diarizationBackend)
    }

    /// A wedged engine must end as a stated, non-blocking issue rather than an answer
    /// that never arrives. Exercises the real `Process` path and the watchdog.
    @Test
    func aHungEngineIsTerminatedAndReportedWithoutBlockingTheRunControls() async throws {
        let root = try readinessTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("stalling-engine.sh")
        try "#!/bin/sh\nsleep 120\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let probe = ProcessProfileReadinessProbe(
            timeout: .milliseconds(300),
            executableResolver: { executableURL }
        )
        let profiles = try AppProfileRegistry.load()
        let korean = try #require(profiles.first(where: { $0.id == .koreanITMeeting }))

        let startedAt = ContinuousClock.now
        let outcome = await probe.probe(korean)
        let elapsed = startedAt.duration(to: .now)

        #expect(elapsed < .seconds(20))
        guard case let .issue(issue) = outcome else {
            Issue.record("expected a stated issue, got \(outcome)")
            return
        }
        #expect(!issue.blocksRun)
        guard case let .engineFailed(detail) = issue else {
            Issue.record("expected engineFailed, got \(issue)")
            return
        }
        #expect(detail.contains("did not finish"))
    }

    /// The run guards wait for an in-flight answer, but that wait is bounded: a probe
    /// that never answers must not leave the record button wedged.
    @Test @MainActor
    func aRunWaitsOnlyAsLongAsItsBudgetWhenTheAnswerNeverArrives() async throws {
        let probe = ReadinessStubProbe(outcome: .report(unprovisionedReport()))
        await probe.hold()
        let model = try readinessModel(
            probe: probe,
            readinessWaitBudget: .milliseconds(200)
        )
        model.evaluateProfileReadiness()
        await readinessWait { model.profileReadiness.isEvaluating }

        model.startRecording()
        await readinessWait(attempts: 600, napping: .milliseconds(5)) {
            !model.canCancelActiveOperation
        }

        // No answer arrived, so nothing blocked and the run was attempted: a readiness
        // check that did not answer is not evidence the profile is unready.
        #expect(!model.profileReadiness.hasResult)
        #expect(model.canStartRecording)
        #expect(model.errorMessage != appString("This profile is not ready to run."))
        await probe.release()
    }

    @Test
    func aMissingEngineBinaryIsReportedRatherThanGuessedAt() async throws {
        let probe = ProcessProfileReadinessProbe(executableResolver: { nil })
        let profiles = try AppProfileRegistry.load()
        let korean = try #require(profiles.first(where: { $0.id == .koreanITMeeting }))
        let outcome = await probe.probe(korean)

        #expect(outcome == .issue(.engineMissing))
    }

    @Test
    func everyReadinessGroupCarriesItsOwnSentenceAndNeverLeaksARawCheckKey() {
        var sentences: Set<String> = []
        for group in ProfileReadinessGroup.allCases {
            let sentence = String(localized: group.reason)
            #expect(!sentence.isEmpty, "empty sentence: \(group.rawValue)")
            #expect(!sentence.contains("check."), "raw check key: \(group.rawValue)")
            sentences.insert(sentence)
        }
        #expect(sentences.count == ProfileReadinessGroup.allCases.count)
    }

    @Test
    func readinessSentencesResolveInEnglishKoreanAndItalian() {
        let locales = [
            Locale(identifier: "en"),
            Locale(identifier: "ko"),
            Locale(identifier: "it"),
        ]
        let expected = [
            "This profile is not ready to run.",
            "이 프로필은 실행할 준비가 되지 않았습니다.",
            "Questo profilo non è pronto per l'esecuzione.",
        ]
        for (index, locale) in locales.enumerated() {
            #expect(
                appString("This profile is not ready to run.", locale: locale)
                    == expected[index]
            )
            #expect(!appString(
                "The speech recognition model this profile needs is not installed on this Mac.",
                locale: locale
            ).isEmpty)
        }
    }
}

private func unprovisionedReport() -> ProfileReadinessReport {
    ProfileReadinessReport(
        ready: false,
        schemaVersion: "1.1.0",
        values: [
            "profile": "ko-it-meeting",
            "language": "auto",
            "check.asr.model_files": "false",
            "check.asr.mlx_audio": "false",
            "check.asr_runner": "false",
            "check.asr_python_3_12": "true",
            "check.diarization_model_cache": "false",
            "check.diarization_revision": "false",
            "check.vad_model_cache": "false",
            "check.offline_speech_runtime": "false",
            "check.postprocess": "true",
            "check.storage": "true",
        ]
    )
}

private func readyReport() -> ProfileReadinessReport {
    ProfileReadinessReport(
        ready: true,
        schemaVersion: "1.1.0",
        values: [
            "profile": "ko-it-meeting",
            "check.asr.model_files": "true",
            "check.asr.mlx_audio": "true",
            "check.asr_runner": "true",
            "check.asr_python_3_12": "true",
            "check.diarization_model_cache": "true",
            "check.diarization_revision": "true",
            "check.vad_model_cache": "true",
            "check.offline_speech_runtime": "true",
            "check.postprocess": "true",
            "check.storage": "true",
        ]
    )
}

@MainActor
private func readinessModel(
    root: URL? = nil,
    probe: ReadinessStubProbe,
    permissions: CapturePermissions = CapturePermissions(
        microphone: .granted,
        systemAudio: .granted
    ),
    readinessWaitBudget: Duration = .seconds(10)
) throws -> MaccheroniAppModel {
    let repositoryRoot = try root ?? readinessTemporaryDirectory()
    let suite = "MaccheroniReadinessDefaults-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return try MaccheroniAppModel(
        repository: LibraryRepository(root: repositoryRoot),
        profiles: try AppProfileRegistry.load(),
        runner: ReadinessStubRunner(),
        recorder: ReadinessStubRecorder(),
        defaults: defaults,
        readinessProbe: probe,
        capturePermissions: { permissions },
        readinessWaitBudget: readinessWaitBudget
    )
}

private func readinessTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MaccheroniReadinessTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

@MainActor
private func readinessWait(
    attempts: Int = 500,
    napping: Duration? = nil,
    for condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0 ..< attempts {
        if condition() { return }
        if let napping {
            try? await Task.sleep(for: napping)
        } else {
            await Task.yield()
        }
    }
    #expect(condition())
}

private actor ReadinessStubProbe: ProfileReadinessProbing {
    private var outcomes: [String: ProfileReadinessProbeOutcome]
    private var fallback: ProfileReadinessProbeOutcome?
    private(set) var requestedProfiles: [String] = []
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(outcome: ProfileReadinessProbeOutcome) {
        outcomes = [:]
        fallback = outcome
    }

    init(outcomes: [String: ProfileReadinessProbeOutcome]) {
        self.outcomes = outcomes
        fallback = nil
    }

    /// What the machine answers from now on. A dependency that was there and
    /// then is not is the whole of the re-probe scenario, and a probe that can
    /// only ever give one answer cannot express it.
    func answer(_ outcome: ProfileReadinessProbeOutcome) {
        outcomes.removeAll()
        fallback = outcome
    }

    /// Holds every probe open so a test can act inside the window before the first
    /// readiness answer exists.
    func hold() {
        isHeld = true
    }

    func release() {
        isHeld = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func probe(_ profile: AppProfile) async -> ProfileReadinessProbeOutcome {
        requestedProfiles.append(profile.cliProfile)
        if isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
        return outcomes[profile.cliProfile] ?? fallback ?? .issue(.reportUnreadable)
    }
}

private enum ReadinessStubError: Error { case notImplemented }

private final class ReadinessStubRunner: TranscriptionRunning {
    func run(
        _: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        throw ReadinessStubError.notImplemented
    }

    func cancel() {}
}

private final class ReadinessStubRecorder: RecordingControlling {
    var meters = CaptureMeters.silent

    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}

    func start(in _: URL) async throws -> RecordingSessionMetadata {
        throw ReadinessStubError.notImplemented
    }

    func stop() async throws -> RecordingArtifacts {
        throw ReadinessStubError.notImplemented
    }

    func cancel() async {}
}
