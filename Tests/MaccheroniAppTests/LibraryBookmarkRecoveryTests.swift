import Foundation
import Testing
@testable import MaccheroniApp

struct LibraryBookmarkRecoveryTests {
    @Test
    func staleBookmarkResolutionRefreshesAndPersistsTheMovedOriginal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let movedURL = root.appendingPathComponent("moved.aiff")
        try Data("preserved audio".utf8).write(to: movedURL)
        let staleBookmark = Data("stale bookmark".utf8)
        let refreshedBookmark = Data("refreshed bookmark".utf8)
        let access = LibraryBookmarkAccess(
            resolve: { bookmark in
                #expect(bookmark == staleBookmark)
                return LibraryBookmarkResolution(url: movedURL, isStale: true)
            },
            create: { url in
                #expect(url == movedURL)
                return refreshedBookmark
            }
        )
        let repository = LibraryRepository(root: root, bookmarkAccess: access)
        let staleRecord = record(
            sourceURL: root.appendingPathComponent("old-location.aiff"),
            bookmark: staleBookmark
        )
        var unaffected = record(sourceURL: root.appendingPathComponent("other.wav"))
        unaffected.id = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        try repository.saveRecords([staleRecord, unaffected])

        let resolved = try repository.resolveOriginal(for: staleRecord)

        #expect(resolved == movedURL)
        let savedRecords = try repository.loadRecords()
        let refreshed = try #require(savedRecords.first(where: { $0.id == staleRecord.id }))
        #expect(refreshed.sourceURL == movedURL)
        #expect(refreshed.securityScopedBookmark == refreshedBookmark)
        let savedUnaffected = savedRecords.first(where: { $0.id == unaffected.id })
        #expect(savedUnaffected == unaffected)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!names.contains(where: { $0.hasPrefix(".library-") }))
    }

    @Test
    func ordinaryBookmarkResolutionDoesNotRewriteTheIndex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalURL = root.appendingPathComponent("original.caf")
        try Data("preserved audio".utf8).write(to: originalURL)
        let bookmark = Data("current bookmark".utf8)
        let access = LibraryBookmarkAccess(
            resolve: { _ in LibraryBookmarkResolution(url: originalURL, isStale: false) },
            create: { _ in throw TestError.unexpectedBookmarkRefresh }
        )
        let repository = LibraryRepository(root: root, bookmarkAccess: access)
        let record = record(sourceURL: originalURL, bookmark: bookmark)
        try repository.saveRecords([record])
        let indexBefore = try Data(contentsOf: repository.indexURL)

        #expect(try repository.resolveOriginal(for: record) == originalURL)
        #expect(try Data(contentsOf: repository.indexURL) == indexBefore)
        #expect(try repository.loadRecords() == [record])
    }

    @Test
    func staleBookmarkToMissingFileRemainsUnavailableAndDoesNotRefresh() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingURL = root.appendingPathComponent("missing.wav")
        let bookmark = Data("stale bookmark".utf8)
        let access = LibraryBookmarkAccess(
            resolve: { _ in LibraryBookmarkResolution(url: missingURL, isStale: true) },
            create: { _ in throw TestError.unexpectedBookmarkRefresh }
        )
        let repository = LibraryRepository(root: root, bookmarkAccess: access)
        let record = record(sourceURL: missingURL, bookmark: bookmark)
        try repository.saveRecords([record])
        let indexBefore = try Data(contentsOf: repository.indexURL)

        let error = #expect(throws: LibraryRepositoryError.self) {
            try repository.resolveOriginal(for: record)
        }
        guard case .originalUnavailable = error else {
            Issue.record("Expected originalUnavailable")
            return
        }
        #expect(try Data(contentsOf: repository.indexURL) == indexBefore)
    }

    @Test
    func unresolvableBookmarkStillPropagatesTheResolutionFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let access = LibraryBookmarkAccess(
            resolve: { _ in throw TestError.unresolvableBookmark },
            create: { _ in throw TestError.unexpectedBookmarkRefresh }
        )
        let repository = LibraryRepository(root: root, bookmarkAccess: access)
        let record = record(
            sourceURL: root.appendingPathComponent("original.wav"),
            bookmark: Data("invalid bookmark".utf8)
        )

        #expect(throws: TestError.unresolvableBookmark) {
            try repository.resolveOriginal(for: record)
        }
    }
}

private enum TestError: Error {
    case unexpectedBookmarkRefresh
    case unresolvableBookmark
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "LibraryBookmarkRecoveryTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func record(sourceURL: URL, bookmark: Data? = nil) -> LibraryRecord {
    LibraryRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000091")!,
        createdAt: Date(timeIntervalSince1970: 1_722_686_400),
        displayName: "Imported recording",
        sourceKind: .importedFile,
        sourceURL: sourceURL,
        securityScopedBookmark: bookmark,
        microphoneURL: nil,
        systemAudioURL: nil,
        runURL: nil,
        profileID: .automatic,
        postprocess: .none,
        durationS: 1,
        state: .recorded,
        speakerNames: [:],
        conflictResolutions: [:],
        failureMessage: nil
    )
}
