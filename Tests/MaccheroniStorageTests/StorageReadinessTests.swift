import Foundation
import Testing
@testable import MaccheroniStorage

@Suite
struct StorageReadinessTests {
    @Test
    func groupsRolesSharingOneVolumeWithoutDuplicatingFreeBytes() {
        let inspector = FixtureInspector(values: [
            "/Library": .volume(id: "volume-a", name: "Archive", bytes: 900),
            "/Recordings": .volume(id: "volume-a", name: "Archive", bytes: 900),
            "/Runs": .volume(id: "volume-a", name: "Archive", bytes: 900),
        ])

        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(id: "library", role: .libraryMetadata, url: URL(fileURLWithPath: "/Library")),
            StorageRoot(id: "recordings", role: .recordings, url: URL(fileURLWithPath: "/Recordings")),
            StorageRoot(id: "runs", role: .runs, url: URL(fileURLWithPath: "/Runs")),
        ])

        #expect(report.volumes == [StorageVolume(
            id: "volume-a",
            name: "Archive",
            roles: [.recordings, .runs, .libraryMetadata],
            availableBytes: 900
        )])
        #expect(report.roots.map(\.volumeID) == ["volume-a", "volume-a", "volume-a"])
        #expect(report.isObservable)
    }

    @Test
    func keepsDistinctVolumesWithTheSameDisplayNameSeparate() {
        let inspector = FixtureInspector(values: [
            "/one": .volume(id: "one", name: "Data", bytes: 100),
            "/two": .volume(id: "two", name: "Data", bytes: 200),
        ])
        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(id: "recordings", role: .recordings, url: URL(fileURLWithPath: "/one")),
            StorageRoot(id: "runs", role: .runs, url: URL(fileURLWithPath: "/two")),
        ])

        #expect(report.volumes.map(\.id) == ["one", "two"])
        #expect(report.volumes.map(\.availableBytes) == [100, 200])
    }

    @Test
    func resolvesANotYetCreatedRootThroughItsNearestExistingParent() {
        let inspector = FixtureInspector(values: [
            "/Archive/New/Recordings": .failure(.notFound),
            "/Archive/New": .failure(.notFound),
            "/Archive": .volume(id: "archive", name: "Archive", bytes: 800),
        ])
        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(
                id: "recordings",
                role: .recordings,
                url: URL(fileURLWithPath: "/Archive/New/Recordings")
            ),
        ])

        #expect(report.roots.first?.status == .notCreated)
        #expect(report.roots.first?.volumeID == "archive")
        #expect(report.volumes.first?.availableBytes == 800)
        #expect(report.isObservable)
    }

    @Test
    func doesNotAttributeAMissingExternalMountToTheSystemVolume() {
        let inspector = FixtureInspector(values: [
            "/Volumes/Archive/Maccheroni": .failure(.notFound),
            "/Volumes/Archive": .failure(.notFound),
            "/Volumes": .volume(id: "system", name: "Macintosh HD", bytes: 500),
        ])
        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(
                id: "runs",
                role: .runs,
                url: URL(fileURLWithPath: "/Volumes/Archive/Maccheroni")
            ),
        ])

        #expect(report.roots.first?.status == .unmounted)
        #expect(report.roots.first?.volumeID == nil)
        #expect(report.volumes.isEmpty)
        #expect(!report.isObservable)
    }

    @Test
    func reportsUnreadableAndCapacityUnavailableWithoutFabricatedBytes() {
        let inspector = FixtureInspector(values: [
            "/Unreadable": .failure(.unreadable),
            "/Cache": .volume(id: "cache", name: "Cache", bytes: nil),
        ])
        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(id: "cache", role: .asrModelCache, url: URL(fileURLWithPath: "/Cache")),
            StorageRoot(id: "runs", role: .runs, url: URL(fileURLWithPath: "/Unreadable")),
        ])

        #expect(report.roots.map(\.status) == [.available, .unreadable])
        #expect(report.volumes.first?.availableBytes == nil)
        #expect(!report.isObservable)
    }

    @Test
    func zeroFreeBytesRemainsAnObservedFact() {
        let inspector = FixtureInspector(values: [
            "/Runs": .volume(id: "full", name: "Full Disk", bytes: 0),
        ])
        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(id: "runs", role: .runs, url: URL(fileURLWithPath: "/Runs")),
        ])

        #expect(report.volumes.first?.availableBytes == 0)
        #expect(report.isObservable)
    }

    @Test
    func securityScopedBookmarkIsBalancedAndStalenessIsReported() {
        let access = BookmarkAccessRecorder()
        let reporter = StorageReadinessReporter(
            inspector: FixtureInspector(values: [
                "/Moved/Recordings": .volume(id: "external", name: "External", bytes: 700),
            ]).adapter,
            bookmarks: StorageBookmarkAccess(
                resolve: { data in
                    #expect(data == Data("bookmark".utf8))
                    return StorageBookmarkResolution(
                        url: URL(fileURLWithPath: "/Moved/Recordings"),
                        isStale: true
                    )
                },
                startAccessing: { url in access.start(url) },
                stopAccessing: { url in access.stop(url) }
            )
        )
        let report = reporter.report(roots: [
            StorageRoot(
                id: "recordings",
                role: .recordings,
                url: URL(fileURLWithPath: "/Old/Recordings"),
                bookmark: Data("bookmark".utf8)
            ),
        ])

        #expect(report.roots.first?.bookmarkStatus == .stale)
        #expect(report.roots.first?.volumeID == "external")
        #expect(access.started == ["/Moved/Recordings"])
        #expect(access.stopped == ["/Moved/Recordings"])
    }

    @Test
    func unresolvableBookmarkDoesNotFallBackToTheStoredPath() {
        let reporter = StorageReadinessReporter(
            inspector: FixtureInspector(values: [
                "/Stored/Runs": .volume(id: "wrong", name: "Wrong", bytes: 1),
            ]).adapter,
            bookmarks: StorageBookmarkAccess(
                resolve: { _ in throw StorageBookmarkError.unavailable },
                startAccessing: { _ in true },
                stopAccessing: { _ in }
            )
        )
        let report = reporter.report(roots: [
            StorageRoot(
                id: "runs",
                role: .runs,
                url: URL(fileURLWithPath: "/Stored/Runs"),
                bookmark: Data("missing".utf8)
            ),
        ])

        #expect(report.roots.first?.status == .bookmarkUnavailable)
        #expect(report.volumes.isEmpty)
        #expect(!report.isObservable)
    }

    @Test
    func libraryAndActiveBackendInventoryDeclaresEveryIndependentRoot() {
        let recordingsBookmark = Data("recordings".utf8)
        let runsBookmark = Data("runs".utf8)
        let library = LibraryStorageConfiguration(
            root: URL(fileURLWithPath: "/Library"),
            recordingsURL: URL(fileURLWithPath: "/Recordings"),
            runsURL: URL(fileURLWithPath: "/Runs"),
            recordingsBookmark: recordingsBookmark,
            runsBookmark: runsBookmark
        )

        let roots = StorageRootInventory.current(
            library: library,
            profiles: [
                ConfiguredStorageProfile(
                    diarizationBackend: "fluid",
                    postprocessBackend: nil
                ),
                ConfiguredStorageProfile(
                    diarizationBackend: "community1",
                    postprocessBackend: "local"
                ),
            ]
        )

        #expect(roots.map(\.id) == [
            "library.metadata",
            "library.requests",
            "library.glossaries",
            "library.recordings",
            "library.runs",
            "models.asr",
            "models.vad.data",
            "models.vad.revision",
            "models.diarization.community1",
            "models.diarization.fluid",
            "work.diarization.fluid",
            "models.postprocess.local",
        ])
        #expect(roots.first { $0.id == "library.recordings" }?.bookmark == recordingsBookmark)
        #expect(roots.first { $0.id == "library.runs" }?.bookmark == runsBookmark)
        #expect(roots.first { $0.id == "work.diarization.fluid" }?.role == .temporaryWork)
    }

    @Test
    func unavailableCapacityEncodesAsANullFactWithAnExplicitStatus() throws {
        let report = StorageReport(
            volumes: [StorageVolume(
                id: "archive",
                name: "Archive",
                roles: [.recordings],
                availableBytes: nil
            )],
            roots: [StorageRootObservation(
                id: "recordings",
                role: .recordings,
                status: .available,
                bookmarkStatus: .none,
                volumeID: "archive"
            )]
        )

        let data = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let volumes = try #require(object["volumes"] as? [[String: Any]])

        #expect(volumes[0]["available_bytes"] is NSNull)
        #expect(volumes[0]["capacity_status"] as? String == "unavailable")
        #expect(object["observable"] as? Bool == false)
    }

    @Test
    func productionInspectorRejectsAConfiguredRootThatIsARegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccheroni-storage-file-\(UUID().uuidString)"
        )
        try Data("not a directory".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = StorageReadinessReporter().report(roots: [
            StorageRoot(id: "runs", role: .runs, url: root),
        ])

        #expect(report.roots.first?.status == .unreadable)
        #expect(report.volumes.isEmpty)
        #expect(!report.isObservable)
    }

    @Test
    func laterProbeCanSupplyCapacityForAnAlreadyGroupedVolume() {
        let inspector = FixtureInspector(values: [
            "/Recordings": .groupedVolume(group: "shared", id: "archive", name: "Archive", bytes: nil),
            "/Runs": .groupedVolume(group: "shared", id: "archive", name: "Archive", bytes: 400),
        ])

        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(id: "recordings", role: .recordings, url: URL(fileURLWithPath: "/Recordings")),
            StorageRoot(id: "runs", role: .runs, url: URL(fileURLWithPath: "/Runs")),
        ])

        #expect(report.volumes.first?.availableBytes == 400)
        #expect(report.isObservable)
    }

    @Test
    func disambiguatesDuplicatePublicVolumeIdentifiersWithinAReport() {
        let inspector = FixtureInspector(values: [
            "/One": .groupedVolume(group: "one", id: "duplicate", name: "Data", bytes: 100),
            "/Two": .groupedVolume(group: "two", id: "duplicate", name: "Data", bytes: 200),
        ])

        let report = StorageReadinessReporter(inspector: inspector.adapter).report(roots: [
            StorageRoot(id: "recordings", role: .recordings, url: URL(fileURLWithPath: "/One")),
            StorageRoot(id: "runs", role: .runs, url: URL(fileURLWithPath: "/Two")),
        ])

        #expect(report.volumes.map(\.id) == ["duplicate", "duplicate-2"])
        #expect(report.roots.map(\.volumeID) == ["duplicate", "duplicate-2"])
    }
}

private enum FixtureValue {
    case volume(id: String, name: String, bytes: Int64?)
    case groupedVolume(group: String, id: String, name: String, bytes: Int64?)
    case failure(StorageInspectionFailure)
}

private struct FixtureInspector {
    var values: [String: FixtureValue]

    var adapter: StorageVolumeInspector {
        StorageVolumeInspector { url in
            switch values[url.path] ?? .failure(.notFound) {
            case let .volume(id, name, bytes):
                return StorageVolumeProperties(
                    groupingIdentifier: id,
                    id: id,
                    name: name,
                    availableBytes: bytes
                )
            case let .groupedVolume(group, id, name, bytes):
                return StorageVolumeProperties(
                    groupingIdentifier: group,
                    id: id,
                    name: name,
                    availableBytes: bytes
                )
            case let .failure(error):
                throw error
            }
        }
    }
}

private final class BookmarkAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStarted: [String] = []
    private var storedStopped: [String] = []

    var started: [String] { lock.withLock { storedStarted } }
    var stopped: [String] { lock.withLock { storedStopped } }

    func start(_ url: URL) -> Bool {
        lock.withLock { storedStarted.append(url.path) }
        return true
    }

    func stop(_ url: URL) {
        lock.withLock { storedStopped.append(url.path) }
    }
}
