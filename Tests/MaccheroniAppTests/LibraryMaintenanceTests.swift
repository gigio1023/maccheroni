import CryptoKit
import Foundation
import MaccheroniCore
import Testing
@testable import MaccheroniApp

/// Renaming a recording and moving one to the Trash: the two library
/// operations `docs/ui-design.md` promised and nothing implemented.
///
/// Both are written against judgment rule 3 — no stage overwrites an original.
/// A rename never reaches a file, and the move uses the Trash rather than a
/// delete so Finder's Put Back is the recovery path. The tests that matter most
/// here are the failing ones: a failure has to leave the library entry and the
/// files exactly as they were.
@MainActor
struct LibraryMaintenanceTests {
    // MARK: - Rename

    @Test
    func renamingEditsOnlyTheLibraryNameAndTouchesNoFile() throws {
        let world = try LibraryMaintenanceWorld()
        let before = try world.fileFingerprints()

        world.model.rename(world.record, to: "Weekly sync, 1 September")

        #expect(world.model.records.count == 1)
        #expect(world.model.records[0].displayName == "Weekly sync, 1 September")
        #expect(world.model.records[0].sourceURL == world.record.sourceURL)
        #expect(world.model.records[0].runURL == world.record.runURL)
        #expect(world.model.errorMessage == nil)
        // The index on disk carries it too, so the name survives a relaunch.
        let saved = try world.repository.loadRecords()
        #expect(saved.count == 1)
        #expect(saved[0].displayName == "Weekly sync, 1 September")
        // And nothing under the recording or the run moved, was renamed, or
        // changed a byte.
        #expect(try world.fileFingerprints() == before)
    }

    @Test
    func renamingTrimsWhitespaceAndRefusesANameThatIsOnlyWhitespace() throws {
        let world = try LibraryMaintenanceWorld()

        world.model.rename(world.record, to: "   Padded name  ")
        #expect(world.model.records[0].displayName == "Padded name")

        world.model.rename(world.model.records[0], to: "   \n ")
        #expect(world.model.records[0].displayName == "Padded name")
        #expect(try world.repository.loadRecords()[0].displayName == "Padded name")
    }

    @Test
    func aRenameThatCannotBeSavedLeavesTheLibraryNameExactlyAsItWas() throws {
        let world = try LibraryMaintenanceWorld(recordSaverFails: true)

        world.model.rename(world.record, to: "Never saved")

        // Not "reported and applied anyway": the index is written before the
        // change is adopted, so the name a reader sees is a name on disk.
        #expect(world.model.records[0].displayName == world.record.displayName)
        #expect(try world.repository.loadRecords()[0].displayName == world.record.displayName)
        #expect(world.model.errorMessage != nil)
    }

    // MARK: - What a move to the Trash would take

    @Test
    func theTrashPlanNamesOnlyTheRecordingsOwnFilesAndOnlyThoseOnDisk() throws {
        let world = try LibraryMaintenanceWorld()

        let full = world.model.trashPlan(for: world.record)
        #expect(full.sourceURL == world.sourceURL)
        #expect(full.runURL == world.runURL)
        #expect(full.targets.count == 2)
        #expect(!full.movesNothing)
        // The library index, the recordings root and the runs root are shared
        // and are never in a plan.
        #expect(!full.targets.contains(world.repository.indexURL))
        #expect(!full.targets.contains(world.repository.runsRoot))
        #expect(!full.targets.contains(world.repository.recordingsRoot))

        try FileManager.default.removeItem(at: world.runURL)
        let sourceOnly = world.model.trashPlan(for: world.record)
        #expect(sourceOnly.runURL == nil)
        #expect(sourceOnly.targets == [world.sourceURL])

        try FileManager.default.removeItem(at: world.sourceURL)
        let empty = world.model.trashPlan(for: world.record)
        #expect(empty.movesNothing)
        #expect(empty.targets.isEmpty)
    }

    // MARK: - The move itself

    @Test
    func movingToTrashRecyclesTheAudioAndTheRunTogetherAndThenDropsTheEntry() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(recycler: recycler)
        world.model.select(.record(world.record.id))
        let plan = world.model.trashPlan(for: world.record)

        await world.model.moveToTrash(plan)

        #expect(world.model.errorMessage == nil)
        // One call, both files, in the same call: "together or not at all"
        // cannot hold across two.
        let calls = await recycler.calls
        #expect(calls.count == 1)
        #expect(Set(calls[0]) == Set([world.sourceURL, world.runURL]))
        #expect(!FileManager.default.fileExists(atPath: world.sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: world.runURL.path))
        // Recycled, not deleted: both are recoverable from where they went.
        let trashed = await recycler.moved
        #expect(trashed.count == 2)
        for url in trashed.values {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(world.model.records.isEmpty)
        #expect(try world.repository.loadRecords().isEmpty)
        #expect(world.model.selection == .capture)
    }

    @Test
    func aRecordingWithNoFilesLeftOnDiskLosesItsEntryAndNothingIsRecycled() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(recycler: recycler)
        try FileManager.default.removeItem(at: world.sourceURL)
        try FileManager.default.removeItem(at: world.runURL)
        let plan = world.model.trashPlan(for: world.record)
        #expect(plan.movesNothing)

        await world.model.moveToTrash(plan)

        #expect(await recycler.calls.isEmpty)
        #expect(world.model.records.isEmpty)
        #expect(try world.repository.loadRecords().isEmpty)
        #expect(world.model.errorMessage == nil)
    }

    // MARK: - Failure leaves the entry

    @Test
    func aPartialMovePutsBackWhatMovedAndLeavesTheLibraryEntryInPlace() async throws {
        // The run directory is refused; the audio moves. This is the case
        // `NSWorkspace.recycle` can actually produce, and the one that would
        // otherwise split a recording between the Trash and its folder.
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(recycler: recycler)
        await recycler.refuse(world.runURL, message: "The run folder is in use.")
        let before = try world.fileFingerprints()
        let plan = world.model.trashPlan(for: world.record)

        await world.model.moveToTrash(plan)

        #expect(try world.fileFingerprints() == before)
        #expect(FileManager.default.fileExists(atPath: world.sourceURL.path))
        #expect(FileManager.default.fileExists(atPath: world.runURL.path))
        #expect(world.model.records.count == 1)
        #expect(try world.repository.loadRecords().count == 1)
        let message = try #require(world.model.errorMessage)
        #expect(message.contains(world.record.displayName))
        #expect(message.contains("still in your library"))
        #expect(message.contains("The run folder is in use."))
    }

    @Test
    func aFileThatVanishedBetweenTheConfirmationAndTheMoveStopsBeforeAnythingMoves() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(recycler: recycler)
        let plan = world.model.trashPlan(for: world.record)
        try FileManager.default.removeItem(at: world.sourceURL)

        await world.model.moveToTrash(plan)

        // The preflight is the whole point: the run directory is still where
        // it was because the move never started.
        #expect(await recycler.calls.isEmpty)
        #expect(FileManager.default.fileExists(atPath: world.runURL.path))
        #expect(world.model.records.count == 1)
        #expect(try world.repository.loadRecords().count == 1)
        let message = try #require(world.model.errorMessage)
        #expect(message.contains(world.sourceURL.lastPathComponent))
        #expect(message.contains("nothing was moved"))
    }

    @Test
    func aRunStillBeingWrittenIntoIsNotMovedAndTheReaderIsToldToWait() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(recycler: recycler)
        // A settled recording is movable; the guard is about work in flight.
        #expect(world.model.canMoveToTrash(world.record))
        var transcribing = world.record
        transcribing.state = .transcribing
        #expect(!world.model.canMoveToTrash(transcribing))

        // A derived post-process claims the run directory. Moving it out from
        // under the CLI would turn a live operation into a failure with no
        // cause a reader could name.
        world.model.select(.record(world.record.id))
        world.model.postprocessSelectedRun(operation: .correction, backend: .local)
        #expect(world.model.isPostprocessingExistingRun(recordID: world.record.id))
        #expect(!world.model.canMoveToTrash(world.record))
        let plan = world.model.trashPlan(for: world.record)

        await world.model.moveToTrash(plan)

        #expect(await recycler.calls.isEmpty)
        #expect(world.model.records.count == 1)
        #expect(FileManager.default.fileExists(atPath: world.runURL.path))
        #expect(FileManager.default.fileExists(atPath: world.sourceURL.path))
        let message = try #require(world.model.errorMessage)
        #expect(message.contains("Wait for this recording's transcription"))
    }

    // MARK: - The two steps a reader sees

    @Test
    func theConfirmationNamesTheRecordingAndExactlyWhatWouldMove() {
        let id = UUID()
        let audio = URL(fileURLWithPath: "/tmp/maccheroni-fixture/meeting.wav")
        let run = URL(fileURLWithPath: "/tmp/maccheroni-fixture/run", isDirectory: true)
        let en = Locale(identifier: "en")

        let both = LibraryTrashPlan(
            recordID: id,
            displayName: "Weekly sync",
            sourceURL: audio,
            runURL: run
        )
        #expect(
            LibraryTrashWording.title(for: both, locale: en)
                == "Move \u{201C}Weekly sync\u{201D} to the Trash?"
        )
        let bothMessage = LibraryTrashWording.message(for: both, locale: en)
        #expect(bothMessage.contains("source audio and the run output"))
        #expect(bothMessage.contains("Nothing is deleted"))
        #expect(bothMessage.contains("Put Back"))

        let audioOnly = LibraryTrashPlan(recordID: id, displayName: "A", sourceURL: audio)
        #expect(LibraryTrashWording.message(for: audioOnly, locale: en)
            .contains("moves the source audio to the Trash"))

        let runOnly = LibraryTrashPlan(recordID: id, displayName: "A", runURL: run)
        #expect(LibraryTrashWording.message(for: runOnly, locale: en)
            .contains("moves the run output to the Trash"))

        // Nothing left on disk is a different sentence and a different button:
        // no first-order action deletes anything, and this one moves nothing.
        let nothing = LibraryTrashPlan(recordID: id, displayName: "Gone meeting")
        #expect(
            LibraryTrashWording.title(for: nothing, locale: en)
                == "Remove \u{201C}Gone meeting\u{201D} from the library?"
        )
        #expect(LibraryTrashWording.message(for: nothing, locale: en)
            .contains("no longer on disk"))
        #expect(
            String(localized: LibraryTrashWording.confirmLabel(for: nothing, locale: en))
                == "Remove from Library"
        )
        #expect(
            String(localized: LibraryTrashWording.confirmLabel(for: both, locale: en))
                == "Move to Trash"
        )
        #expect(LibraryTrashWording.title(for: nil, locale: en).isEmpty)
    }

    @Test
    func everyStringTheseTwoOperationsAddIsCarriedByAllTenLocales() throws {
        let locales = ["de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "zh-Hans"]
        let keys = [
            "Rename…",
            "Move to Trash…",
            "Move to Trash",
            "Remove from Library",
            "Recording Name",
            "Move \u{201C}%@\u{201D} to the Trash?",
            "Remove \u{201C}%@\u{201D} from the library?",
            "This moves the source audio and the run output to the Trash together. Nothing is deleted, and the Finder's Put Back restores them.",
            "This moves the source audio to the Trash. Nothing is deleted, and the Finder's Put Back restores it.",
            "This moves the run output to the Trash. Nothing is deleted, and the Finder's Put Back restores it.",
            "The files this recording named are no longer on disk, so this removes its library entry and nothing else.",
            "Wait for this recording's transcription to finish before moving it to the Trash.",
            "%@ is no longer where the library expects it, so nothing was moved.",
            "%@ could not be moved because its folder is not writable. Nothing was moved.",
            "%@ could not be moved to the Trash. Its files are where they were, and the recording is still in your library.",
            "%@ could not be moved to the Trash, and part of it is in the Trash now. Put it back in the Finder. The recording is still in your library.",
            "%@ The system reported: %@",
            "Speaker Proposal",
            "Renames this recording in the library only. The audio file and the run folder keep their names.",
        ]

        let catalogURL = try #require(appResourcesBundle.url(
            forResource: "Localizable",
            withExtension: "xcstrings"
        ))
        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: catalogURL)
        ) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])

        for key in keys {
            #expect(strings[key] != nil, "missing from the catalog: \(key)")
        }

        // The shipped `.lproj` plists are what the app actually reads, and a
        // naive `"k" = "v";` parser reports a false pass on them: they are XML
        // property lists.
        for locale in locales {
            let resourceLocale = try #require(appResourcesBundle.localizations.first {
                $0.caseInsensitiveCompare(locale) == .orderedSame
            })
            let path = try #require(appResourcesBundle.path(
                forResource: resourceLocale,
                ofType: "lproj"
            ))
            let stringsURL = URL(fileURLWithPath: path)
                .appendingPathComponent("Localizable.strings")
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: stringsURL),
                format: nil
            )
            let table = try #require(plist as? [String: String])
            for key in keys {
                let value = try #require(table[key], "missing in \(locale): \(key)")
                #expect(!value.isEmpty)
                if locale != "en" {
                    // A locale that merely copied the English is not localized.
                    #expect(value != key, "untranslated in \(locale): \(key)")
                }
            }
        }
    }

    // MARK: - Two handovers from the derived-layer task

    @Test
    func theInspectorNamesASpeakerProposalSetInsteadOfCallingItCorrect() {
        let en = Locale(identifier: "en")
        func summary(
            operation: PostprocessMode,
            kind: DerivedOperationKind
        ) -> DerivedResultSummary {
            DerivedResultSummary(
                id: "20260901T230950Z-8f6b5c",
                createdAt: Date(timeIntervalSince1970: 1_756_000_000),
                operation: operation,
                kind: kind,
                targetLanguage: nil,
                glossarySHA256: nil,
                directory: URL(fileURLWithPath: "/tmp/derived"),
                isCurrent: true
            )
        }

        // The defect: a proposal manifest keeps `mode == .correction`, so a
        // panel that reads `mode` calls a set that corrected nothing "Correct".
        let proposal = summary(operation: .correction, kind: .speakerProposal)
        #expect(
            String(localized: RunInspectorWording.derivedSet(proposal, locale: en))
                == "Speaker Proposal"
        )
        let correction = summary(operation: .correction, kind: .textPostprocess)
        #expect(
            String(localized: RunInspectorWording.derivedSet(correction, locale: en))
                == "Correct"
        )
        let translation = summary(operation: .translation, kind: .textPostprocess)
        #expect(
            String(localized: RunInspectorWording.derivedSet(translation, locale: en))
                == "Translate"
        )
    }

    @Test
    func theSpeakerLabelledLayerReadsTheSourceTextWhenItSurvivedBesideATranslation() {
        var fixture = TranscriptFixtures.translationShaped()
        // Before: the loader threw the merged document away, so the layer had
        // to say the source text was not in memory.
        #expect(fixture.run.sourceTranscript == nil)
        let withoutSource = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )
        #expect(withoutSource[0].unavailability == .sourceTextNotLoadedWithTranslation)

        var source = fixture.run.transcript
        for index in source.segments.indices {
            source.segments[index].text = "Source line \(index)."
        }
        fixture.run.sourceTranscript = source

        let options = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )
        #expect(options[0].layer == .speakerLabelled)
        #expect(options[0].isAvailable)
        #expect(options[2].isAvailable)

        let item = fixture.run.segments[3]
        #expect(
            TranscriptLayerCatalog.text(
                .speakerLabelled,
                for: item,
                run: fixture.run,
                record: fixture.record
            ) == "Source line 3."
        )
        // The translated layer still shows the translation, unchanged.
        #expect(
            TranscriptLayerCatalog.text(
                .translated,
                for: item,
                run: fixture.run,
                record: fixture.record
            ) == item.segment.text
        )
        // And the default a translation opens on does not move.
        #expect(
            TranscriptLayerCatalog.defaultLayer(run: fixture.run, record: fixture.record)
                == .translated
        )
    }
}

// MARK: - Fixtures

/// A library with one recording that owns a real audio file and a real run
/// directory, plus a model wired to a repository whose Trash is a fake.
@MainActor
private struct LibraryMaintenanceWorld {
    let root: URL
    let sourceURL: URL
    let runURL: URL
    let repository: LibraryRepository
    let model: MaccheroniAppModel
    let record: LibraryRecord
    private let defaultsSuite: String

    init(
        recycler: LibraryMaintenanceRecycler? = nil,
        recordSaverFails: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniLibraryMaintenanceTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let runs = root.appendingPathComponent("Runs", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

        sourceURL = recordings.appendingPathComponent("meeting.wav")
        try Data("immutable source audio".utf8).write(to: sourceURL)
        runURL = runs.appendingPathComponent("20260901T122702Z-f2d938", isDirectory: true)
        try FileManager.default.createDirectory(at: runURL, withIntermediateDirectories: true)
        try Data("{\"run_id\":\"20260901T122702Z-f2d938\"}".utf8)
            .write(to: runURL.appendingPathComponent("manifest.json"))
        let merged = runURL.appendingPathComponent("merged", isDirectory: true)
        try FileManager.default.createDirectory(at: merged, withIntermediateDirectories: true)
        try Data("{\"segments\":[]}".utf8)
            .write(to: merged.appendingPathComponent("segments.json"))

        let trash: LibraryRecycler
        if let recycler {
            trash = recycler.recycle
        } else {
            trash = { _ in LibraryRecycleReport() }
        }
        repository = LibraryRepository(root: root, recycler: trash)
        record = LibraryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A7")!,
            createdAt: Date(timeIntervalSince1970: 1_756_729_620),
            displayName: "Fixture meeting",
            sourceKind: .importedFile,
            sourceURL: sourceURL,
            securityScopedBookmark: nil,
            microphoneURL: nil,
            systemAudioURL: nil,
            runURL: runURL,
            profileID: .koreanITMeeting,
            postprocess: .none,
            durationS: 1_243.08,
            state: .done,
            speakerNames: [:],
            conflictResolutions: [:],
            failureMessage: nil
        )
        try repository.saveRecords([record])

        defaultsSuite = "MaccheroniLibraryMaintenance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defaults.removePersistentDomain(forName: defaultsSuite)
        model = try MaccheroniAppModel(
            repository: repository,
            profiles: AppProfileRegistry.load(),
            runner: LibraryMaintenanceRunner(),
            recorder: LibraryMaintenanceRecorder(),
            defaults: defaults,
            recordSaver: recordSaverFails
                ? { _ in throw LibraryMaintenanceError.saveRefused }
                : repository.saveRecords,
            readinessProbe: LibraryMaintenanceReadinessProbe(),
            capturePermissions: { CapturePermissions(microphone: .granted, systemAudio: .granted) }
        )
    }

    /// Every file under the recording and its run, by path and content hash.
    /// A rename that touched anything, or a failed move that left something
    /// behind, shows up as a difference here.
    func fileFingerprints() throws -> [String: String] {
        var prints: [String: String] = [:]
        for url in [sourceURL, runURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
                for case let file as URL in enumerator ?? .init() {
                    guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?
                        .isRegularFile == true
                    else { continue }
                    prints[file.path] = try Self.hash(file)
                }
            } else {
                prints[url.path] = try Self.hash(url)
            }
        }
        return prints
    }

    private static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private enum LibraryMaintenanceError: Error {
    case saveRefused
    case notImplemented
}

/// A Trash that keeps the real move semantics — the item leaves its folder for
/// somewhere it can be brought back from — without involving the user's actual
/// Trash, and that can be told to refuse one item so the partial-move path is
/// exercised rather than argued about.
private actor LibraryMaintenanceRecycler {
    private(set) var calls: [[URL]] = []
    private(set) var moved: [URL: URL] = [:]
    private var refused: [URL: String] = [:]
    private let trash: URL

    init() {
        trash = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniFakeTrash-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func refuse(_ url: URL, message: String) {
        refused[url] = message
    }

    nonisolated var recycle: LibraryRecycler {
        { [self] urls in await perform(urls) }
    }

    private func perform(_ urls: [URL]) -> LibraryRecycleReport {
        calls.append(urls)
        var report = LibraryRecycleReport()
        for url in urls {
            if let message = refused[url] {
                report.failure = message
                continue
            }
            let destination = trash.appendingPathComponent(
                "\(UUID().uuidString)-\(url.lastPathComponent)"
            )
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                report.moved[url] = destination
                moved[url] = destination
            } catch {
                report.failure = error.localizedDescription
            }
        }
        return report
    }
}

private final class LibraryMaintenanceRunner: TranscriptionRunning {
    func run(
        _: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        throw LibraryMaintenanceError.notImplemented
    }

    func cancel() {}
}

@MainActor
private final class LibraryMaintenanceRecorder: RecordingControlling {
    var meters = CaptureMeters.silent

    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}

    func start(in _: URL) async throws -> RecordingSessionMetadata {
        throw LibraryMaintenanceError.notImplemented
    }

    func stop() async throws -> RecordingArtifacts {
        throw LibraryMaintenanceError.notImplemented
    }

    func cancel() async {}
}

private struct LibraryMaintenanceReadinessProbe: ProfileReadinessProbing {
    func probe(_: AppProfile) async -> ProfileReadinessProbeOutcome {
        .issue(.reportUnreadable)
    }
}
