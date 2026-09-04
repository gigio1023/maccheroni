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

    /// The files go to the Trash first and the index follows, so the index
    /// save is the step that can leave the two apart. It used to be
    /// best-effort: the recycle succeeded, the entry left the list, the save
    /// failed, and the saved library still pointed at a directory now in the
    /// Trash. Relaunching restored that broken entry.
    ///
    /// The save failure is now undone rather than reported and left. What the
    /// list shows and what the library holds agree again, the message says
    /// where the files went, and one Put Back in the Finder makes the entry
    /// whole. Persisting first instead would delete the entry while the files
    /// stayed put, and nothing in the app brings that entry back.
    @Test
    func anIndexSaveThatFailsAfterTheRecycleKeepsTheEntryAndSaysWhereTheFilesWent() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(
            recycler: recycler,
            recordSaverFails: true
        )
        world.model.select(.record(world.record.id))
        let plan = world.model.trashPlan(for: world.record)

        await world.model.moveToTrash(plan)

        // The recycle did happen, and is not undone: putting files back is the
        // Finder's job and guessing at it here would be a second mover.
        let calls = await recycler.calls
        #expect(calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: world.sourceURL.path))
        #expect(!FileManager.default.fileExists(atPath: world.runURL.path))

        // What the list shows and what the library saved are the same thing.
        #expect(world.model.records.map(\.id) == [world.record.id])
        #expect(try world.repository.loadRecords().map(\.id) == [world.record.id])

        let message = try #require(world.model.errorMessage)
        #expect(message.contains(world.record.displayName))
        #expect(message.contains("is in the Trash"))
        #expect(message.contains("still listed"))
        #expect(message.contains("Put it back in the Finder"))
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

    // MARK: - The engine scratch of a failed run

    /// A failed request keeps its scratch directory because `stderr.log` is
    /// the only complete record of what the engine said. Nothing pruned it,
    /// so failed runs accumulated scratch for ever. The policy
    /// (`EngineRequestScratch`) anchors it on the run's own lifetime: the
    /// record names it, the Trash takes it with the recording, Put Back
    /// brings it back, and only what no record names any more is pruned,
    /// past a declared bound, on one trigger, with a line in the
    /// maintenance log.

    @Test
    func theTrashPlanTakesTheEngineLogOfAFailedRunOnlyWhileItIsOnDisk() throws {
        let world = try LibraryMaintenanceWorld(keepsFailedRequest: true)
        let requestURL = try #require(world.requestURL)

        let plan = world.model.trashPlan(for: world.record)
        #expect(plan.requestURL == requestURL)
        #expect(plan.targets.count == 3)
        #expect(Set(plan.targets) == Set([world.sourceURL, world.runURL, requestURL]))
        #expect(!plan.targets.contains(world.requestsRoot))

        // Gone from disk: not promised.
        try FileManager.default.removeItem(at: requestURL)
        #expect(world.model.trashPlan(for: world.record).requestURL == nil)

        // A record that names no request — every record written before the
        // link existed, and every record whose latest request succeeded —
        // has nothing here.
        var unlinked = world.record
        unlinked.requestID = nil
        #expect(world.model.trashPlan(for: unlinked).requestURL == nil)
    }

    @Test
    func movingAFailedRunToTheTrashTakesItsEngineLogInTheSameMove() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(
            recycler: recycler,
            keepsFailedRequest: true
        )
        let requestURL = try #require(world.requestURL)
        let plan = world.model.trashPlan(for: world.record)

        await world.model.moveToTrash(plan)

        #expect(world.model.errorMessage == nil)
        let calls = await recycler.calls
        #expect(calls.count == 1)
        #expect(Set(calls[0]) == Set([world.sourceURL, world.runURL, requestURL]))
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
        let trashed = await recycler.moved
        let inTrash = try #require(trashed[requestURL])
        // Recycled whole, not emptied: the stderr is still readable where
        // the Finder's Put Back would bring it back from.
        #expect(try String(contentsOf: inTrash.appendingPathComponent("stderr.log"), encoding: .utf8)
            .contains("engine refused the request"))
        #expect(world.model.records.isEmpty)
    }

    @Test
    func aPartialMoveThatRefusesTheRunPutsTheEngineLogBackToo() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(
            recycler: recycler,
            keepsFailedRequest: true
        )
        let requestURL = try #require(world.requestURL)
        await recycler.refuse(world.runURL, message: "The run folder is in use.")
        let before = try world.fileFingerprints()

        await world.model.moveToTrash(world.model.trashPlan(for: world.record))

        // Together or not at all still holds with three targets.
        #expect(try world.fileFingerprints() == before)
        #expect(FileManager.default.fileExists(atPath: requestURL.path))
        #expect(world.model.records.count == 1)
        #expect(world.model.records[0].requestID == world.record.requestID)
        #expect(world.model.errorMessage?.contains("still in your library") == true)
    }

    @Test
    func anEngineLogTheFinderPutBackIsKeptUntilTheBoundAndPrunedAfterIt() async throws {
        let recycler = LibraryMaintenanceRecycler()
        let world = try LibraryMaintenanceWorld(
            recycler: recycler,
            keepsFailedRequest: true
        )
        let requestURL = try #require(world.requestURL)
        await world.model.moveToTrash(world.model.trashPlan(for: world.record))
        #expect(world.model.records.isEmpty)
        let inTrash = try #require(await recycler.moved[requestURL])

        // The Finder's Put Back: the directory returns to where it was. No
        // record names it now, so it is an orphan — recoverable, readable,
        // and subject to the bound rather than dropped on the spot.
        try FileManager.default.moveItem(at: inTrash, to: requestURL)
        let created = try #require(
            try requestURL.resourceValues(forKeys: [.creationDateKey]).creationDate
        )
        let bound = EngineRequestScratch.orphanMaximumAge

        let keptAt = created.addingTimeInterval(bound)
        #expect(world.repository.pruneOrphanedRequestDirectories(records: [], now: keptAt).isEmpty)
        #expect(FileManager.default.fileExists(atPath: requestURL.path))
        #expect(!FileManager.default.fileExists(atPath: world.repository.maintenanceLogURL.path))

        let prunedAt = created.addingTimeInterval(bound + 1)
        #expect(world.repository.pruneOrphanedRequestDirectories(records: [], now: prunedAt) == [requestURL])
        #expect(!FileManager.default.fileExists(atPath: requestURL.path))
        let log = try String(contentsOf: world.repository.maintenanceLogURL, encoding: .utf8)
        #expect(log.contains("request-scratch pruned \(requestURL.lastPathComponent)"))
    }

    @Test
    func anOrphanIsPrunedOnlyPastTheBoundAndTheMaintenanceLogSaysWhich() throws {
        let world = try LibraryMaintenanceWorld()
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let bound = EngineRequestScratch.orphanMaximumAge
        #expect(bound == 30 * 24 * 60 * 60)
        // L - ε, L, and L + ε, with ε one second: the policy's three
        // boundary tests for one limit.
        let younger = try LibraryMaintenanceWorld.writeRequestScratch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A01")!,
            in: world.requestsRoot,
            createdAt: now.addingTimeInterval(-(bound - 1))
        )
        let exact = try LibraryMaintenanceWorld.writeRequestScratch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A02")!,
            in: world.requestsRoot,
            createdAt: now.addingTimeInterval(-bound)
        )
        let older = try LibraryMaintenanceWorld.writeRequestScratch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000A03")!,
            in: world.requestsRoot,
            createdAt: now.addingTimeInterval(-(bound + 1))
        )
        // Things under the requests root that are not the engine's scratch
        // are never candidates, however old: a stray file, a hidden file,
        // and a directory with another name.
        let strayFile = world.requestsRoot.appendingPathComponent("request-notes.txt")
        try Data("keep".utf8).write(to: strayFile)
        let hidden = world.requestsRoot.appendingPathComponent(".DS_Store")
        try Data().write(to: hidden)
        let other = world.requestsRoot.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        for url in [strayFile, hidden, other] {
            try FileManager.default.setAttributes(
                [.creationDate: now.addingTimeInterval(-10 * bound)],
                ofItemAtPath: url.path
            )
        }

        let pruned = world.repository.pruneOrphanedRequestDirectories(
            records: world.model.records,
            now: now
        )

        #expect(pruned == [older])
        #expect(FileManager.default.fileExists(atPath: younger.path))
        #expect(FileManager.default.fileExists(atPath: exact.path))
        #expect(!FileManager.default.fileExists(atPath: older.path))
        for url in [strayFile, hidden, other] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        let log = try String(contentsOf: world.repository.maintenanceLogURL, encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.count == 1)
        // The clock of the load, then the action, the directory, and the
        // numbers a reader needs to check the decision.
        #expect(lines[0].hasPrefix("2026-08-29T10:40:00Z request-scratch pruned \(older.lastPathComponent) created=2026-07-30T10:39:59Z"))
        #expect(lines[0].contains(" age_s=\(Int(bound + 1)) bound_s=\(Int(bound))"))

        // Running again does nothing and writes nothing.
        #expect(world.repository.pruneOrphanedRequestDirectories(records: [], now: now).isEmpty)
        #expect(try String(contentsOf: world.repository.maintenanceLogURL, encoding: .utf8) == log)
    }

    @Test
    func aRequestDirectoryARecordStillNamesIsNeverPrunedWhateverItsAge() throws {
        let bound = EngineRequestScratch.orphanMaximumAge
        let ancient = Date(timeIntervalSince1970: 1_700_000_000)
        let orphanID = UUID(uuidString: "00000000-0000-0000-0000-000000000B01")!
        let liveID = UUID(uuidString: "00000000-0000-0000-0000-000000000B02")!
        var liveURL: URL?
        var orphanURL: URL?
        // A launch is the one trigger. The world's record names its own
        // failed request; a second record still transcribing names another;
        // a third directory is named by nobody. All three are years old.
        let world = try LibraryMaintenanceWorld(keepsFailedRequest: true) { root in
            let repository = LibraryRepository(root: root)
            try FileManager.default.setAttributes(
                [.creationDate: ancient],
                ofItemAtPath: repository.requestsRoot
                    .appendingPathComponent(
                        EngineRequestScratch.directoryName(
                            for: UUID(uuidString: "00000000-0000-0000-0000-00000000E0F1")!
                        )
                    ).path
            )
            liveURL = try LibraryMaintenanceWorld.writeRequestScratch(
                id: liveID,
                in: repository.requestsRoot,
                createdAt: ancient
            )
            orphanURL = try LibraryMaintenanceWorld.writeRequestScratch(
                id: orphanID,
                in: repository.requestsRoot,
                createdAt: ancient
            )
            var records = try repository.loadRecords()
            var transcribing = records[0]
            transcribing.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B7")!
            transcribing.state = .transcribing
            transcribing.requestID = liveID
            records.append(transcribing)
            try repository.saveRecords(records)
        }

        // The launch marked the transcribing record interrupted and kept its
        // request; the failed record kept its own; the orphan is gone.
        #expect(world.model.records.count == 2)
        #expect(world.model.records.contains { $0.state == .interrupted && $0.requestID == liveID })
        #expect(world.model.records.contains { $0.state == .failed && $0.requestID == world.record.requestID })
        #expect(FileManager.default.fileExists(atPath: try #require(world.requestURL).path))
        #expect(FileManager.default.fileExists(atPath: try #require(liveURL).path))
        #expect(!FileManager.default.fileExists(atPath: try #require(orphanURL).path))
        let log = try String(contentsOf: world.repository.maintenanceLogURL, encoding: .utf8)
        #expect(log.split(separator: "\n").count == 1)
        #expect(log.contains(EngineRequestScratch.directoryName(for: orphanID)))
        #expect(!log.contains(EngineRequestScratch.directoryName(for: liveID)))
        #expect(Date().timeIntervalSince(ancient) > bound)

        // And a later prune with the records the launch loaded still leaves
        // both named directories alone.
        #expect(world.repository.pruneOrphanedRequestDirectories(records: world.model.records).isEmpty)
    }

    /// The sidebar row of a readable partial run says what it lost before
    /// the reader opens it, in the row's own units, rounded up so a loss is
    /// never understated; the state word beside it is unchanged.
    @Test
    func aPartialRunsRowNamesItsLossAndTakesTheOpenMark() {
        let en = Locale(identifier: "en")
        #expect(LibraryRowStatus.partialPhrase(missingDurationS: 30.56, locale: en) == "31s not transcribed")
        #expect(LibraryRowStatus.partialPhrase(missingDurationS: 0.5, locale: en) == "1s not transcribed")
        #expect(LibraryRowStatus.partialPhrase(missingDurationS: 406.55, locale: en) == "6m 47s not transcribed")
        #expect(LibraryRowStatus.partialPhrase(missingDurationS: 3_600, locale: en) == "1h not transcribed")
        #expect(LibraryRowStatus.partialPhrase(missingDurationS: .nan, locale: en) == "0s not transcribed")
        #expect(LibraryRowStatus.symbol(.done, isPartial: true) == "exclamationmark.triangle")
        #expect(LibraryRowStatus.symbol(.hasConflicts, isPartial: true) == "exclamationmark.triangle")
        #expect(LibraryRowStatus.symbol(.done, isPartial: false) == "checkmark.circle")
        // A partial mark never reaches a state that is not readable.
        #expect(LibraryRowStatus.symbol(.failed, isPartial: true) == "exclamationmark.triangle")
        #expect(LibraryRowStatus.tint(.failed, isPartial: true) == LibraryRowStatus.tint(.failed))
        #expect(LibraryRowStatus.tint(.done, isPartial: true) == AppTheme.Palette.open)

        var record = TranscriptFixtures.meetingShaped().record
        record.displayName = "Weekly sync"
        record.state = .done
        let coverage = RunPartialCoverage(
            inputDurationS: 1_243.08,
            promotedDurationS: 1_212.52,
            missingDurationS: 30.56,
            missing: []
        )
        #expect(
            LibraryRowStatus.accessibilityLabel(for: record, partialCoverage: coverage, locale: en)
                == "Weekly sync, Done, 31s not transcribed"
        )
        #expect(
            LibraryRowStatus.accessibilityLabel(for: record, partialCoverage: nil, locale: en)
                == "Weekly sync, Done"
        )
    }

    @Test
    func theRequestDirectoryNameIsTheRunnersOwn() {
        let id = UUID(uuidString: "7695E7C7-0059-455F-ABAF-378E935F757A")!
        #expect(EngineRequestScratch.directoryName(for: id) == "request-7695e7c7-0059-455f-abaf-378e935f757a")
        #expect(EngineRequestScratch.isScratchDirectoryName("request-7695e7c7-0059-455f-abaf-378e935f757a"))
        #expect(!EngineRequestScratch.isScratchDirectoryName("request-"))
        #expect(!EngineRequestScratch.isScratchDirectoryName("archive"))
    }

    @Test
    func theConfirmationSaysWhenTheEngineLogMovesToo() {
        let id = UUID()
        let audio = URL(fileURLWithPath: "/tmp/maccheroni-fixture/meeting.wav")
        let run = URL(fileURLWithPath: "/tmp/maccheroni-fixture/run", isDirectory: true)
        let scratch = URL(fileURLWithPath: "/tmp/maccheroni-fixture/request-1", isDirectory: true)
        let en = Locale(identifier: "en")

        let all = LibraryTrashPlan(
            recordID: id, displayName: "A", sourceURL: audio, runURL: run, requestURL: scratch
        )
        #expect(!all.movesNothing)
        #expect(LibraryTrashWording.message(for: all, locale: en)
            .hasSuffix("Put Back restores them. This also moves the engine log kept from the failed run."))
        #expect(String(localized: LibraryTrashWording.confirmLabel(for: all, locale: en)) == "Move to Trash")

        let audioAndLog = LibraryTrashPlan(
            recordID: id, displayName: "A", sourceURL: audio, requestURL: scratch
        )
        #expect(LibraryTrashWording.message(for: audioAndLog, locale: en)
            == "This moves the source audio to the Trash. Nothing is deleted, and the Finder's Put Back restores it. This also moves the engine log kept from the failed run.")

        // Only the log is left: still a move, and the sentence says of what.
        let logOnly = LibraryTrashPlan(recordID: id, displayName: "A", requestURL: scratch)
        #expect(!logOnly.movesNothing)
        #expect(LibraryTrashWording.title(for: logOnly, locale: en) == "Move \u{201C}A\u{201D} to the Trash?")
        #expect(LibraryTrashWording.message(for: logOnly, locale: en)
            == "This moves the engine log kept from the failed run to the Trash. Nothing is deleted, and the Finder's Put Back restores it.")

        // Without a log nothing changes in what a reader has always read.
        let both = LibraryTrashPlan(recordID: id, displayName: "A", sourceURL: audio, runURL: run)
        #expect(LibraryTrashWording.message(for: both, locale: en)
            .hasSuffix("Put Back restores them."))
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
            "This also moves the engine log kept from the failed run.",
            "This moves the engine log kept from the failed run to the Trash. Nothing is deleted, and the Finder's Put Back restores it.",
            "%@ not transcribed",
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
    let requestsRoot: URL
    /// The engine scratch of the record's failed request, when the world was
    /// built with `keepsFailedRequest`.
    let requestURL: URL?
    let repository: LibraryRepository
    let model: MaccheroniAppModel
    let record: LibraryRecord
    private let defaultsSuite: String

    /// - Parameters:
    ///   - keepsFailedRequest: the recording's run failed and the engine's
    ///     scratch for that request is on disk and named by the record.
    ///   - beforeLaunch: runs against the library root after the index is
    ///     saved and before the model loads it, which is the moment the
    ///     retention policy's trigger fires.
    init(
        recycler: LibraryMaintenanceRecycler? = nil,
        recordSaverFails: Bool = false,
        keepsFailedRequest: Bool = false,
        beforeLaunch: ((URL) throws -> Void)? = nil
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
        requestsRoot = repository.requestsRoot
        var requestID: UUID?
        if keepsFailedRequest {
            let id = UUID(uuidString: "00000000-0000-0000-0000-00000000E0F1")!
            requestID = id
            requestURL = try Self.writeRequestScratch(id: id, in: requestsRoot)
        } else {
            requestURL = nil
        }
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
            state: keepsFailedRequest ? .failed : .done,
            speakerNames: [:],
            conflictResolutions: [:],
            failureMessage: keepsFailedRequest ? "engine refused the request" : nil,
            requestID: requestID
        )
        try repository.saveRecords([record])
        try beforeLaunch?(root)

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

    /// One engine scratch directory as the runner leaves it after a failure:
    /// the profile it was handed, an empty stdout, and the stderr the failure
    /// message was cut from.
    @discardableResult
    static func writeRequestScratch(
        id: UUID,
        in requestsRoot: URL,
        createdAt: Date? = nil
    ) throws -> URL {
        let directory = requestsRoot.appendingPathComponent(
            EngineRequestScratch.directoryName(for: id),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("{\"profiles\":[]}".utf8).write(to: directory.appendingPathComponent("profiles.json"))
        try Data().write(to: directory.appendingPathComponent("stdout.log"))
        try Data("engine refused the request\n".utf8)
            .write(to: directory.appendingPathComponent("stderr.log"))
        if let createdAt {
            try FileManager.default.setAttributes(
                [.creationDate: createdAt, .modificationDate: createdAt],
                ofItemAtPath: directory.path
            )
        }
        return directory
    }

    /// Every file under the recording, its run and its request scratch, by
    /// path and content hash. A rename that touched anything, or a failed
    /// move that left something behind, shows up as a difference here.
    func fileFingerprints() throws -> [String: String] {
        var prints: [String: String] = [:]
        for url in [sourceURL, runURL] + (requestURL.map { [$0] } ?? []) {
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
