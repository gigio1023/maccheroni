import Foundation
import MaccheroniCore
import MaccheroniPostprocess
import MaccheroniStorage
import Testing
@testable import MaccheroniApp

struct LibraryStorageSettingsTests {
    @Test
    func resolvesDefaultDirectoriesWhenThereAreNoOverrides() {
        let applicationSupport = URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true)

        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: applicationSupport,
            environment: [:],
            recordingsPath: nil,
            runsPath: nil
        )

        #expect(repository.root.path == "/fixtures/Application Support/Maccheroni")
        #expect(repository.recordingsRoot.path == "/fixtures/Application Support/Maccheroni/Recordings")
        #expect(repository.runsRoot.path == "/fixtures/Application Support/Maccheroni/Runs")
    }

    @Test
    func resolvesAbsoluteStoredDirectoriesAndStandardizesThem() {
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true),
            environment: [:],
            recordingsPath: "/fixtures/recordings/../recordings-final",
            runsPath: "/fixtures/runs/../runs-final"
        )

        #expect(repository.recordingsRoot.path == "/fixtures/recordings-final")
        #expect(repository.runsRoot.path == "/fixtures/runs-final")
    }

    @Test
    func environmentRootTakesPrecedenceOverStoredDirectories() {
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true),
            environment: [LibraryStorageSettings.libraryRootEnvironmentKey: "/fixture-override/library"],
            recordingsPath: "/stored/recordings",
            runsPath: "/stored/runs"
        )

        #expect(repository.root.path == "/fixture-override/library")
        #expect(repository.recordingsRoot.path == "/fixture-override/library/Recordings")
        #expect(repository.runsRoot.path == "/fixture-override/library/Runs")
    }

    @Test
    func malformedStoredDirectoriesBlockUseInsteadOfSilentlyFallingBack() {
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support", isDirectory: true),
            environment: [LibraryStorageSettings.libraryRootEnvironmentKey: "   "],
            recordingsPath: "   ",
            runsPath: "relative/runs"
        )

        #expect(repository.recordingsRoot.path == "/fixtures/Application Support/Maccheroni/Recordings")
        #expect(repository.runsRoot.path == "/fixtures/Application Support/Maccheroni/Runs")
        #expect(throws: (any Error).self) {
            try repository.prepareDirectories()
        }
    }

    @Test
    func configuredDirectoryBookmarksResolveMovedRootsBeforeUse() {
        let recordingsBookmark = Data("recordings".utf8)
        let runsBookmark = Data("runs".utf8)
        let access = LibraryBookmarkAccess(
            resolve: { bookmark in
                if bookmark == recordingsBookmark {
                    return LibraryBookmarkResolution(
                        url: URL(fileURLWithPath: "/Volumes/Archive/Recordings"),
                        isStale: false
                    )
                }
                #expect(bookmark == runsBookmark)
                return LibraryBookmarkResolution(
                    url: URL(fileURLWithPath: "/Volumes/Work/Runs"),
                    isStale: true
                )
            },
            create: { _ in Data() }
        )

        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support"),
            environment: [:],
            recordingsPath: "/old/Recordings",
            runsPath: "/old/Runs",
            recordingsBookmark: recordingsBookmark,
            runsBookmark: runsBookmark,
            bookmarkAccess: access
        )

        #expect(repository.recordingsRoot.path == "/Volumes/Archive/Recordings")
        #expect(repository.runsRoot.path == "/Volumes/Work/Runs")
        #expect(repository.recordingsBookmark == recordingsBookmark)
        #expect(repository.runsBookmark == runsBookmark)
    }

    @Test
    func environmentRootIgnoresStoredBookmarks() {
        let access = LibraryBookmarkAccess(
            resolve: { _ in Issue.record("environment override must not resolve bookmarks"); throw TestStorageError.unexpectedBookmark },
            create: { _ in Data() }
        )
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: URL(fileURLWithPath: "/fixtures/Application Support"),
            environment: [LibraryStorageSettings.libraryRootEnvironmentKey: "/override"],
            recordingsPath: "/old/Recordings",
            runsPath: "/old/Runs",
            recordingsBookmark: Data("recordings".utf8),
            runsBookmark: Data("runs".utf8),
            bookmarkAccess: access
        )

        #expect(repository.recordingsRoot.path == "/override/Recordings")
        #expect(repository.runsRoot.path == "/override/Runs")
        #expect(repository.recordingsBookmark == nil)
        #expect(repository.runsBookmark == nil)
    }

    @Test
    func unresolvedConfiguredBookmarkPreventsUseOfTheStoredFallbackPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccheroni-unresolved-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: root,
            environment: [:],
            recordingsPath: root.appendingPathComponent("OldRecordings").path,
            runsPath: nil,
            recordingsBookmark: Data("unavailable".utf8),
            bookmarkAccess: LibraryBookmarkAccess(
                resolve: { _ in throw TestStorageError.unexpectedBookmark },
                create: { _ in Data() }
            )
        )

        #expect(throws: (any Error).self) {
            try repository.prepareDirectories()
        }
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("OldRecordings").path
        ))
    }

    @Test
    func directoryPreparationBalancesConfiguredSecurityScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccheroni-scoped-roots-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let runs = root.appendingPathComponent("Runs", isDirectory: true)
        let access = RootAccessRecorder()
        let repository = LibraryRepository.resolve(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            environment: [:],
            recordingsPath: "/old/Recordings",
            runsPath: "/old/Runs",
            recordingsBookmark: Data("recordings".utf8),
            runsBookmark: Data("runs".utf8),
            bookmarkAccess: LibraryBookmarkAccess(
                resolve: { bookmark in
                    LibraryBookmarkResolution(
                        url: bookmark == Data("recordings".utf8) ? recordings : runs,
                        isStale: false
                    )
                },
                create: { _ in Data() },
                startAccessing: { access.start($0) },
                stopAccessing: { access.stop($0) }
            )
        )

        try repository.prepareDirectories()

        #expect(access.started == [recordings.path, runs.path])
        #expect(access.stopped == [recordings.path, runs.path])
    }

    @Test
    func failedSecurityScopeStartPreventsDirectoryUse() {
        let access = RootAccessRecorder()
        access.allowsStart = false
        let repository = LibraryRepository(
            root: URL(fileURLWithPath: "/Library"),
            runsRoot: URL(fileURLWithPath: "/Runs"),
            recordingsRoot: URL(fileURLWithPath: "/Recordings"),
            runsBookmark: Data("runs".utf8),
            recordingsBookmark: Data("recordings".utf8),
            bookmarkAccess: LibraryBookmarkAccess(
                resolve: { _ in throw TestStorageError.unexpectedBookmark },
                create: { _ in Data() },
                startAccessing: { access.start($0) },
                stopAccessing: { access.stop($0) }
            )
        )

        #expect(throws: (any Error).self) {
            try repository.prepareDirectories()
        }
        #expect(access.started == ["/Recordings"])
        #expect(access.stopped.isEmpty)
    }

    @Test
    func storagePresentationUsesOneGroupedReportForVolumesAndIssues() {
        let report = StorageReport(
            volumes: [StorageVolume(
                id: "archive",
                name: "Archive",
                roles: [.recordings, .runs],
                availableBytes: 1_024
            )],
            roots: [
                StorageRootObservation(
                    id: "recordings",
                    role: .recordings,
                    status: .notCreated,
                    bookmarkStatus: .stale,
                    volumeID: "archive"
                ),
                StorageRootObservation(
                    id: "runs",
                    role: .runs,
                    status: .available,
                    bookmarkStatus: .none,
                    volumeID: "archive"
                ),
            ]
        )

        let presentation = StorageReportPresentation(report: report)

        #expect(presentation.volumes == [StorageVolumePresentation(
            id: "archive",
            name: "Archive",
            roles: [.recordings, .runs],
            availableBytes: 1_024
        )])
        #expect(presentation.issues == [StorageIssuePresentation(
            id: "recordings",
            role: .recordings,
            status: .notCreated,
            bookmarkStatus: .stale
        )])
    }

    @Test
    func modelStorageIdentifiersKeepDistinctModelFiguresOnTheirMeasuredVolumes() {
        let vad = ModelDescriptor(
            role: .vad,
            hfModelID: "fixture/vad",
            revision: String(repeating: "a", count: 40),
            quantization: "fixture"
        )
        let diarization = ModelDescriptor(
            role: .diarization,
            hfModelID: "fixture/diarization",
            revision: String(repeating: "b", count: 40),
            quantization: "fixture"
        )
        let report = StorageReport(
            volumes: [
                StorageVolume(id: "vad-volume", name: "VAD Disk", roles: [.vadModelCache], availableBytes: 10),
                StorageVolume(id: "diarization-volume", name: "Diarization Disk", roles: [.diarizationModelCache], availableBytes: 20),
            ],
            roots: [
                StorageRootObservation(
                    id: ModelRegistry.storageRootID(for: vad),
                    role: .vadModelCache,
                    status: .available,
                    bookmarkStatus: .none,
                    volumeID: "vad-volume"
                ),
                StorageRootObservation(
                    id: ModelRegistry.storageRootID(for: diarization),
                    role: .diarizationModelCache,
                    status: .available,
                    bookmarkStatus: .none,
                    volumeID: "diarization-volume"
                ),
            ]
        )

        let vadVolumeID = report.roots.first {
            $0.id == ModelRegistry.storageRootID(for: vad)
        }?.volumeID
        let diarizationVolumeID = report.roots.first {
            $0.id == ModelRegistry.storageRootID(for: diarization)
        }?.volumeID

        #expect(vadVolumeID.flatMap { storageVolumeName(volumeID: $0, in: report) } == "VAD Disk")
        #expect(diarizationVolumeID.flatMap {
            storageVolumeName(volumeID: $0, in: report)
        } == "Diarization Disk")
    }

    @Test
    func modelRegistryIncludesTheOnlyVerifiedLocalPostprocessModel() {
        let descriptors = ModelRegistry.descriptors(in: [])

        #expect(descriptors == [LocalPostprocessBackend.pinnedModel])
        #expect(ModelRegistry.localPostprocessModelSelection.contains(
            LocalPostprocessBackend.pinnedModel.hfModelID
        ))
    }

    @Test
    func communityModelCardUsesTheDiarizerHFHomeResolution() throws {
        let descriptor = ModelDescriptor(
            role: .diarization,
            hfModelID: "aufklarer/Pyannote-Community-1-CoreML",
            revision: "a14e6c420d56e8472850649b016a486fd0acbe81",
            quantization: "coreml-fp32"
        )

        let location = try #require(ModelCacheInspector.location(
            for: descriptor,
            environment: ["MACCHERONI_HF_HOME": "/Volumes/Models/huggingface"],
            homeDirectory: URL(fileURLWithPath: "/unused-home", isDirectory: true)
        ))

        #expect(location.path == "/Volumes/Models/huggingface/hub/models--aufklarer--Pyannote-Community-1-CoreML/snapshots/a14e6c420d56e8472850649b016a486fd0acbe81")
    }

    @Test
    func sharedInventoryAddsPerModelRootsForBothProfileEntryPoints() {
        let descriptor = ModelDescriptor(
            role: .asr,
            hfModelID: "fixture/model",
            revision: "revision",
            quantization: "int8"
        )
        let profile = ConfiguredStorageProfile(
            diarizationBackend: nil,
            postprocessBackend: nil,
            models: [descriptor]
        )
        let library = LibraryStorageConfiguration(
            root: URL(fileURLWithPath: "/Library"),
            recordingsURL: URL(fileURLWithPath: "/Recordings"),
            runsURL: URL(fileURLWithPath: "/Runs")
        )

        let appRoots = StorageRootInventory.current(library: library, profiles: [profile])
        let cliRoots = StorageRootInventory.current(library: library, profile: profile)

        #expect(appRoots == cliRoots)
        #expect(appRoots.contains { $0.id == StorageModelRoot.id(for: descriptor) })
    }
}

private enum TestStorageError: Error {
    case unexpectedBookmark
}

private final class RootAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStarted: [String] = []
    private var storedStopped: [String] = []
    private var storedAllowsStart = true

    var started: [String] { lock.withLock { storedStarted } }
    var stopped: [String] { lock.withLock { storedStopped } }
    var allowsStart: Bool {
        get { lock.withLock { storedAllowsStart } }
        set { lock.withLock { storedAllowsStart = newValue } }
    }

    func start(_ url: URL) -> Bool {
        lock.withLock {
            storedStarted.append(url.path)
            return storedAllowsStart
        }
    }

    func stop(_ url: URL) {
        lock.withLock { storedStopped.append(url.path) }
    }
}
