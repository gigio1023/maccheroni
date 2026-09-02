import AppKit
import CryptoKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import MaccheroniStorage

enum LibraryRepositoryError: Error, LocalizedError {
    case unsafeArtifactPath(String)
    case artifactMissing(String)
    case artifactHashMismatch(String)
    case derivedManifestInvalid(String)
    case derivedLineageMismatch(String)
    case originalUnavailable
    /// A file the move to the Trash was about to take is not there any more.
    /// Raised before anything moves.
    case trashTargetVanished(String)
    /// A file's enclosing folder cannot be written, so the Trash could not
    /// take it. Raised before anything moves.
    case trashRefused(String)
    /// The workspace refused or only partly performed the move. `restored`
    /// says whether whatever did move was put back.
    case trashFailed(name: String, restored: Bool, detail: String?)

    var errorDescription: String? {
        switch self {
        case let .unsafeArtifactPath(path):
            appString("The run contains an unsafe artifact path: \(path)")
        case let .artifactMissing(path):
            appString("A run artifact is missing: \(path)")
        case let .artifactHashMismatch(path):
            appString("A run artifact failed its integrity check: \(path)")
        case let .derivedManifestInvalid(identifier):
            appString("A derived result manifest is invalid: \(identifier)")
        case let .derivedLineageMismatch(identifier):
            appString("A derived result does not match its source run: \(identifier)")
        case .originalUnavailable:
            appString("The original audio is not available.")
        case let .trashTargetVanished(name):
            appString("\(name) is no longer where the library expects it, so nothing was moved.")
        case let .trashRefused(name):
            appString("\(name) could not be moved because its folder is not writable. Nothing was moved.")
        case let .trashFailed(name, restored, detail):
            Self.trashFailureSentence(name: name, restored: restored, detail: detail)
        }
    }

    private static func trashFailureSentence(
        name: String,
        restored: Bool,
        detail: String?
    ) -> String {
        let head = restored
            ? appString("\(name) could not be moved to the Trash. Its files are where they were, and the recording is still in your library.")
            : appString("\(name) could not be moved to the Trash, and part of it is in the Trash now. Put it back in the Finder. The recording is still in your library.")
        guard let detail, !detail.isEmpty else { return head }
        return appString("\(head) The system reported: \(detail)")
    }
}

/// Which of one recording's own files a move to the Trash would take,
/// resolved against the disk when the confirmation opens so the sentence a
/// reader agrees to names what is actually there.
///
/// A recording owns its source audio and its run directory and nothing else.
/// Nothing shared is ever in a plan: not the library index, not the
/// recordings or runs root, not a glossary, not a model cache.
struct LibraryTrashPlan: Equatable, Sendable {
    var recordID: UUID
    var displayName: String
    /// The source audio, when it is still where the record says it is.
    var sourceURL: URL?
    /// This recording's run directory, when it has one on disk.
    var runURL: URL?

    init(
        recordID: UUID,
        displayName: String,
        sourceURL: URL? = nil,
        runURL: URL? = nil
    ) {
        self.recordID = recordID
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.runURL = runURL
    }

    /// What the move would actually touch.
    var targets: [URL] { [sourceURL, runURL].compactMap { $0 } }

    /// Nothing this record names is on disk any more, so confirming drops the
    /// library entry and moves no file. Removing an entry that points at
    /// nothing removes nothing.
    var movesNothing: Bool { targets.isEmpty }
}

/// What the workspace reported after being asked to move items to the Trash:
/// which of them moved, and the failure if one came back.
///
/// Both halves are needed. `NSWorkspace.recycle` is not transactional — it can
/// report a failure and still have moved some of the items — and putting those
/// back is the only way "together or not at all" can hold.
struct LibraryRecycleReport: Sendable {
    /// Original URL to its new location inside the Trash.
    var moved: [URL: URL]
    /// The workspace's own message. Carried as text rather than as an error
    /// value because it crosses a concurrency boundary.
    var failure: String?

    init(moved: [URL: URL] = [:], failure: String? = nil) {
        self.moved = moved
        self.failure = failure
    }
}

/// Moves items to the Finder Trash. Injected so a test can drive the refusing
/// and the partial paths without a real Trash.
typealias LibraryRecycler = @Sendable ([URL]) async -> LibraryRecycleReport

private enum LibraryStorageAccessError: Error, LocalizedError {
    case configuredBookmarkUnavailable

    var errorDescription: String? {
        appString("A configured storage folder is no longer available. Choose the folder again in Settings.")
    }
}

private struct VerifiedDerivedResult {
    var directory: URL
    var manifest: DerivedManifest
    var finishedAt: Date
    var loaded: LoadedRun
    /// The marked speaker proposal this set carries, on a
    /// `.speakerProposal` set only. It is never folded into `loaded`: a
    /// proposal is a layer read beside the transcript, not a transcript.
    var proposal: SpeakerProposalDocument? = nil
}

private struct VerifiedArtifactData {
    var url: URL
    var data: Data
}

enum LibraryStorageSettings {
    static let recordingsDirectoryKey = StoragePreferenceKeys.recordingsDirectory
    static let runsDirectoryKey = StoragePreferenceKeys.runsDirectory
    static let recordingsBookmarkKey = StoragePreferenceKeys.recordingsBookmark
    static let runsBookmarkKey = StoragePreferenceKeys.runsBookmark
    static let localPostprocessModelKey = "maccheroni.postprocess.localModel"
    static let libraryRootEnvironmentKey = StoragePreferenceKeys.libraryRootEnvironment

    static func defaultLibraryRoot(
        applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    ) -> URL {
        LibraryStorageConfiguration.defaultLibraryRoot(
            applicationSupportDirectory: applicationSupportDirectory
        )
    }

    static func normalizedDirectoryURL(storedPath: String?) -> URL? {
        LibraryStorageConfiguration.normalizedDirectoryURL(storedPath: storedPath)
    }

    static func environmentLibraryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        normalizedDirectoryURL(storedPath: environment[libraryRootEnvironmentKey])
    }
}

struct LibraryBookmarkResolution: Sendable {
    var url: URL
    var isStale: Bool
}

struct LibraryBookmarkAccess: Sendable {
    var resolve: @Sendable (Data) throws -> LibraryBookmarkResolution
    var create: @Sendable (URL) throws -> Data
    var startAccessing: @Sendable (URL) -> Bool
    var stopAccessing: @Sendable (URL) -> Void

    init(
        resolve: @escaping @Sendable (Data) throws -> LibraryBookmarkResolution,
        create: @escaping @Sendable (URL) throws -> Data,
        startAccessing: @escaping @Sendable (URL) -> Bool = {
            $0.startAccessingSecurityScopedResource()
        },
        stopAccessing: @escaping @Sendable (URL) -> Void = {
            $0.stopAccessingSecurityScopedResource()
        }
    ) {
        self.resolve = resolve
        self.create = create
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    static let system = LibraryBookmarkAccess(
        resolve: { bookmark in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return LibraryBookmarkResolution(url: url, isStale: isStale)
        },
        create: { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

private struct ResolvedConfiguredRoot {
    var url: URL
    var bookmarkAvailable: Bool
}

final class LibraryStorageAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var stopAccessing: (@Sendable () -> Void)?

    init(stopAccessing: @escaping @Sendable () -> Void) {
        self.stopAccessing = stopAccessing
    }

    func end() {
        let action = lock.withLock {
            let action = stopAccessing
            stopAccessing = nil
            return action
        }
        action?()
    }

    deinit {
        end()
    }
}

private func resolvedConfiguredRoot(
    _ storedURL: URL,
    bookmark: Data?,
    access: LibraryBookmarkAccess
) -> ResolvedConfiguredRoot {
    guard let bookmark else {
        return ResolvedConfiguredRoot(
            url: storedURL.standardizedFileURL,
            bookmarkAvailable: true
        )
    }
    guard let resolution = try? access.resolve(bookmark) else {
        return ResolvedConfiguredRoot(
            url: storedURL.standardizedFileURL,
            bookmarkAvailable: false
        )
    }
    return ResolvedConfiguredRoot(
        url: resolution.url.standardizedFileURL,
        bookmarkAvailable: true
    )
}

struct LibraryRepository: Sendable {
    let root: URL
    let runsRoot: URL
    let recordingsRoot: URL
    let runsBookmark: Data?
    let recordingsBookmark: Data?
    private let configuredBookmarksAvailable: Bool
    private let invalidRootIDs: Set<String>
    private let bookmarkAccess: LibraryBookmarkAccess
    private let onDerivedArtifactVerified: @Sendable (URL) throws -> Void
    private let recycler: LibraryRecycler

    var indexURL: URL { root.appendingPathComponent("library.json") }
    var requestsRoot: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    var glossariesRoot: URL { root.appendingPathComponent("Glossaries", isDirectory: true) }

    init(
        root: URL,
        runsRoot: URL? = nil,
        recordingsRoot: URL? = nil,
        runsBookmark: Data? = nil,
        recordingsBookmark: Data? = nil,
        configuredBookmarksAvailable: Bool = true,
        invalidRootIDs: Set<String> = [],
        bookmarkAccess: LibraryBookmarkAccess = .system,
        onDerivedArtifactVerified: @escaping @Sendable (URL) throws -> Void = { _ in },
        recycler: @escaping LibraryRecycler = LibraryRepository.workspaceRecycler
    ) {
        let standardizedRoot = root.standardizedFileURL
        self.root = standardizedRoot
        self.runsRoot = (runsRoot
            ?? standardizedRoot.appendingPathComponent("Runs", isDirectory: true))
            .standardizedFileURL
        self.recordingsRoot = (recordingsRoot
            ?? standardizedRoot.appendingPathComponent("Recordings", isDirectory: true))
            .standardizedFileURL
        self.runsBookmark = runsBookmark
        self.recordingsBookmark = recordingsBookmark
        self.configuredBookmarksAvailable = configuredBookmarksAvailable
        self.invalidRootIDs = invalidRootIDs
        self.bookmarkAccess = bookmarkAccess
        self.onDerivedArtifactVerified = onDerivedArtifactVerified
        self.recycler = recycler
    }

    /// The real Trash. `NSWorkspace.recycle` reports both what moved and the
    /// failure, and both are kept: a partial move has to be put back, and a
    /// wrapper that dropped the moved map on error could not do that.
    static let workspaceRecycler: LibraryRecycler = { urls in
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { moved, error in
                continuation.resume(returning: LibraryRecycleReport(
                    moved: moved,
                    failure: error?.localizedDescription
                ))
            }
        }
    }

    static var local: LibraryRepository {
        let preferences = LibraryStoragePreferences(defaults: .standard)
        return resolve(
            applicationSupportDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true),
            environment: ProcessInfo.processInfo.environment,
            recordingsPath: preferences.recordingsPath,
            runsPath: preferences.runsPath,
            recordingsBookmark: preferences.recordingsBookmark,
            runsBookmark: preferences.runsBookmark
        )
    }

    static func resolve(
        applicationSupportDirectory: URL,
        environment: [String: String],
        recordingsPath: String?,
        runsPath: String?,
        recordingsBookmark: Data? = nil,
        runsBookmark: Data? = nil,
        bookmarkAccess: LibraryBookmarkAccess = .system
    ) -> LibraryRepository {
        let configuration = LibraryStorageConfiguration(
            applicationSupportDirectory: applicationSupportDirectory,
            environment: environment,
            preferences: LibraryStoragePreferences(
                recordingsPath: recordingsPath,
                runsPath: runsPath,
                recordingsBookmark: recordingsBookmark,
                runsBookmark: runsBookmark
            )
        )
        let resolvedRecordings = configuration.isRootConfigurationValid("library.recordings")
            ? resolvedConfiguredRoot(
                configuration.recordingsURL,
                bookmark: configuration.recordingsBookmark,
                access: bookmarkAccess
            )
            : ResolvedConfiguredRoot(
                url: configuration.recordingsURL,
                bookmarkAvailable: false
            )
        let resolvedRuns = configuration.isRootConfigurationValid("library.runs")
            ? resolvedConfiguredRoot(
                configuration.runsURL,
                bookmark: configuration.runsBookmark,
                access: bookmarkAccess
            )
            : ResolvedConfiguredRoot(
                url: configuration.runsURL,
                bookmarkAvailable: false
            )
        return LibraryRepository(
            root: configuration.root,
            runsRoot: resolvedRuns.url,
            recordingsRoot: resolvedRecordings.url,
            runsBookmark: configuration.runsBookmark,
            recordingsBookmark: configuration.recordingsBookmark,
            configuredBookmarksAvailable: resolvedRecordings.bookmarkAvailable
                && resolvedRuns.bookmarkAvailable,
            invalidRootIDs: configuration.invalidRootIDs,
            bookmarkAccess: bookmarkAccess
        )
    }

    var storageConfiguration: LibraryStorageConfiguration {
        LibraryStorageConfiguration(
            root: root,
            recordingsURL: recordingsRoot,
            runsURL: runsRoot,
            recordingsBookmark: recordingsBookmark,
            runsBookmark: runsBookmark,
            invalidRootIDs: invalidRootIDs
        )
    }

    func prepareDirectories() throws {
        guard configuredBookmarksAvailable else {
            throw LibraryStorageAccessError.configuredBookmarkUnavailable
        }
        var accesses: [LibraryStorageAccessLease] = []
        do {
            if let access = try beginAccessingRecordingsRoot() { accesses.append(access) }
            if let access = try beginAccessingRunsRoot() { accesses.append(access) }
        } catch {
            accesses.forEach { $0.end() }
            throw error
        }
        defer {
            accesses.forEach { $0.end() }
        }
        for directory in [root, runsRoot, recordingsRoot, requestsRoot, glossariesRoot] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }

    func loadRecords() throws -> [LibraryRecord] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LibraryRecord].self, from: Data(contentsOf: indexURL))
    }

    func saveRecords(_ records: [LibraryRecord]) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(records)
        let temporary = root.appendingPathComponent(".library-\(UUID().uuidString).json")
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if FileManager.default.fileExists(atPath: indexURL.path) {
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: indexURL)
        }
    }

    /// What a move to the Trash would take for this record, checked against
    /// the disk now rather than trusted from the index, so the confirmation
    /// never promises to move a file that is already gone.
    func trashPlan(for record: LibraryRecord) -> LibraryTrashPlan {
        let source = (try? resolveOriginal(for: record)) ?? record.sourceURL
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        return LibraryTrashPlan(
            recordID: record.id,
            displayName: record.displayName,
            sourceURL: exists(source) ? source : nil,
            runURL: record.runURL.flatMap { exists($0) ? $0 : nil }
        )
    }

    /// Moves one recording's own files to the Finder Trash, together or not at
    /// all.
    ///
    /// The Trash rather than a delete, so Finder's Put Back stays the recovery
    /// path and judgment rule 3 holds: nothing here erases or overwrites an
    /// original. `NSWorkspace.recycle` offers no transaction, so the move is
    /// checked before it starts and put back if it still comes back partial.
    /// A plan that moves nothing succeeds — dropping a library entry whose
    /// files are already gone removes nothing.
    func moveToTrash(_ plan: LibraryTrashPlan) async throws {
        let targets = plan.targets
        guard !targets.isEmpty else { return }
        for url in targets {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LibraryRepositoryError.trashTargetVanished(url.lastPathComponent)
            }
            guard FileManager.default.isWritableFile(
                atPath: url.deletingLastPathComponent().path
            ) else {
                throw LibraryRepositoryError.trashRefused(url.lastPathComponent)
            }
        }
        let report = await recycler(targets)
        let unmoved = targets.filter { report.moved[$0] == nil }
        guard unmoved.isEmpty, report.failure == nil else {
            throw LibraryRepositoryError.trashFailed(
                name: plan.displayName,
                restored: putBack(report.moved),
                detail: report.failure
            )
        }
    }

    /// Best-effort return of a partial move, so a recording's files are never
    /// left split between the Trash and their folder. Finder's own Put Back
    /// remains available for whatever this cannot return, which is why the
    /// outcome is reported rather than swallowed.
    private func putBack(_ moved: [URL: URL]) -> Bool {
        var complete = true
        for (original, trashed) in moved {
            guard FileManager.default.fileExists(atPath: trashed.path),
                  !FileManager.default.fileExists(atPath: original.path)
            else {
                complete = false
                continue
            }
            do {
                try FileManager.default.moveItem(at: trashed, to: original)
            } catch {
                complete = false
            }
        }
        return complete
    }

    func bookmark(for url: URL) throws -> Data {
        try bookmarkAccess.create(url)
    }

    func beginAccessingRecordingsRoot() throws -> LibraryStorageAccessLease? {
        try beginAccessing(root: recordingsRoot, bookmark: recordingsBookmark)
    }

    func beginAccessingRunsRoot() throws -> LibraryStorageAccessLease? {
        try beginAccessing(root: runsRoot, bookmark: runsBookmark)
    }

    func beginAccessingRunnerRoots() throws -> [LibraryStorageAccessLease] {
        var accesses: [LibraryStorageAccessLease] = []
        do {
            if let access = try beginAccessingRecordingsRoot() { accesses.append(access) }
            if let access = try beginAccessingRunsRoot() { accesses.append(access) }
            return accesses
        } catch {
            accesses.forEach { $0.end() }
            throw error
        }
    }

    func beginAccessingOriginal(
        _ url: URL,
        bookmark: Data?
    ) throws -> LibraryStorageAccessLease? {
        guard bookmark != nil else { return nil }
        guard bookmarkAccess.startAccessing(url) else {
            throw LibraryStorageAccessError.configuredBookmarkUnavailable
        }
        let bookmarkAccess = bookmarkAccess
        return LibraryStorageAccessLease {
            bookmarkAccess.stopAccessing(url)
        }
    }

    private func beginAccessing(
        root: URL,
        bookmark: Data?
    ) throws -> LibraryStorageAccessLease? {
        guard configuredBookmarksAvailable else {
            throw LibraryStorageAccessError.configuredBookmarkUnavailable
        }
        guard bookmark != nil else { return nil }
        guard bookmarkAccess.startAccessing(root) else {
            throw LibraryStorageAccessError.configuredBookmarkUnavailable
        }
        let bookmarkAccess = bookmarkAccess
        return LibraryStorageAccessLease {
            bookmarkAccess.stopAccessing(root)
        }
    }

    func resolveOriginal(for record: LibraryRecord) throws -> URL {
        if let bookmark = record.securityScopedBookmark {
            let resolution = try bookmarkAccess.resolve(bookmark)
            guard FileManager.default.fileExists(atPath: resolution.url.path) else {
                throw LibraryRepositoryError.originalUnavailable
            }
            if resolution.isStale {
                let refreshedBookmark = try bookmarkAccess.create(resolution.url)
                try persistRefreshedBookmark(
                    refreshedBookmark,
                    resolvedURL: resolution.url,
                    recordID: record.id
                )
            }
            return resolution.url
        }
        guard FileManager.default.fileExists(atPath: record.sourceURL.path) else {
            throw LibraryRepositoryError.originalUnavailable
        }
        return record.sourceURL
    }

    private func persistRefreshedBookmark(
        _ bookmark: Data,
        resolvedURL: URL,
        recordID: UUID
    ) throws {
        var records = try loadRecords()
        guard let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        records[index].sourceURL = resolvedURL
        records[index].securityScopedBookmark = bookmark
        try saveRecords(records)
    }

    func loadRun(at runURL: URL) throws -> LoadedRun {
        let runsAccess = try beginAccessingRunsRoot()
        defer { runsAccess?.end() }
        let manifestURL = runURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let postprocessMode = manifest.postprocess?.mode
        let mergedSegmentsArtifact = try requiredArtifact(
            kind: "merged_segments",
            manifest: manifest,
            runURL: runURL
        )
        let segmentsArtifact = try requiredArtifact(
            kind: postprocessMode == .correction
                ? "postprocess_segments"
                : "merged_segments",
            manifest: manifest,
            runURL: runURL
        )
        let conflictsArtifact = try requiredArtifact(
            kind: "merged_conflicts",
            manifest: manifest,
            runURL: runURL
        )
        _ = try requiredArtifact(
            kind: "primary_raw",
            manifest: manifest,
            runURL: runURL
        )
        var transcript = try SegmentsDocumentContract.decode(segmentsArtifact.data)
        var mergedTranscript: SegmentsDocument?
        if postprocessMode == .correction {
            let merged = try SegmentsDocumentContract.decode(
                mergedSegmentsArtifact.data
            )
            mergedTranscript = merged
        }
        var conflicts = try JSONDecoder().decode(
            [MergeConflict].self,
            from: conflictsArtifact.data
        )
        let canonicalConflicts = conflicts
        if postprocessMode == .correction {
            let postprocessConflictsArtifact = try requiredArtifact(
                kind: "postprocess_conflicts",
                manifest: manifest,
                runURL: runURL
            )
            let postprocessConflicts = try JSONDecoder().decode(
                [PostprocessConflict].self,
                from: postprocessConflictsArtifact.data
            )
            guard let mergedTranscript else {
                throw LibraryRepositoryError.artifactMissing("merged_segments")
            }
            try validatePostprocess(
                transcript,
                against: mergedTranscript,
                conflicts: postprocessConflicts,
                artifactName: segmentsArtifact.url.lastPathComponent
            )
            for conflict in postprocessConflicts {
                let mapped = MergeConflict(
                    segmentIndex: conflict.segmentIndex,
                    kind: .asrDisagreement,
                    candidates: [
                        conflict.originalText,
                        conflict.candidateText,
                    ],
                    reason: conflict.reason
                )
                if let index = conflicts.firstIndex(where: {
                    $0.segmentIndex == conflict.segmentIndex
                }) {
                    for candidate in mapped.candidates
                        where !conflicts[index].candidates.contains(candidate)
                    {
                        conflicts[index].candidates.append(candidate)
                    }
                    if !conflicts[index].reason.contains(mapped.reason) {
                        conflicts[index].reason += " \(mapped.reason)"
                    }
                } else {
                    conflicts.append(mapped)
                }
            }
        } else if postprocessMode == .translation {
            // Kept before the translated text is written over it. Discarding
            // it here was the reason the source-language transcript could not
            // be shown beside a translation.
            mergedTranscript = transcript
            guard let provenance = manifest.postprocess,
                  let mergedArtifact = manifest.artifacts.first(where: {
                    $0.kind == "merged_segments"
                  })
            else {
                throw LibraryRepositoryError.artifactMissing("merged_segments")
            }
            let translationArtifact = try requiredArtifact(
                kind: "postprocess_translation",
                manifest: manifest,
                runURL: runURL
            )
            let translation = try JSONDecoder().decode(
                TranslationDocument.self,
                from: translationArtifact.data
            )
            try validateTranslation(
                translation,
                against: transcript,
                provenance: provenance,
                sourceSegmentsSHA256: mergedArtifact.sha256,
                artifactName: translationArtifact.url.lastPathComponent
            )
            for value in translation.translations {
                transcript.segments[value.segmentIndex].text = value.translatedText
            }
            for conflict in conflicts
                where transcript.segments.indices.contains(conflict.segmentIndex)
            {
                var flags = transcript.segments[conflict.segmentIndex].flags ?? []
                if !flags.contains("uncertain") {
                    flags.append("uncertain")
                }
                transcript.segments[conflict.segmentIndex].flags = flags
            }
            // Source-language conflict candidates must never replace translated text.
            conflicts.removeAll()
        }
        let conflictsBySegment = Dictionary(
            conflicts.map { ($0.segmentIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let segments = transcript.segments.enumerated().map { index, segment in
            TranscriptSegment(
                id: TranscriptSegmentID(runID: manifest.runID, index: index),
                index: index,
                segment: segment,
                conflict: conflictsBySegment[index]
            )
        }
        let loaded = LoadedRun(
            manifest: manifest,
            transcript: transcript,
            conflicts: conflicts,
            segments: segments,
            sourceTranscript: mergedTranscript
        )
        return try applyingFreshestDerivedResult(
            to: loaded,
            sourceRunURL: runURL,
            canonicalConflicts: canonicalConflicts
        )
    }
    private func applyingFreshestDerivedResult(
        to sourceResult: LoadedRun,
        sourceRunURL: URL,
        canonicalConflicts: [MergeConflict]
    ) throws -> LoadedRun {
        let derivedRoot = sourceRunURL.appendingPathComponent("derived", isDirectory: true)
        guard FileManager.default.fileExists(atPath: derivedRoot.path) else {
            return sourceResult
        }
        let derivedRootValues: URLResourceValues
        do {
            derivedRootValues = try derivedRoot.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw LibraryRepositoryError.artifactMissing("derived")
        }
        guard derivedRootValues.isDirectory == true,
              derivedRootValues.isSymbolicLink != true
        else {
            throw LibraryRepositoryError.unsafeArtifactPath("derived")
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: derivedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var directories: [URL] = []
        for child in children {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                throw LibraryRepositoryError.unsafeArtifactPath(
                    "derived/\(child.lastPathComponent)"
                )
            }
            if values.isDirectory == true { directories.append(child) }
        }
        guard !directories.isEmpty else { return sourceResult }

        // `verifyMergedRun` rather than `verifyCompletedRun`, per D49. Every
        // integrity check is identical; the single gate it drops is coverage
        // completeness, and that gate is reimposed below for the correction and
        // translation families D39 wrote it for. Without this a run that merely
        // *had* a derived set beside it failed to open whenever its own ASR
        // coverage was partial, which is the state the real 20.7-minute
        // recording is in.
        let verifiedSource = try RunIntegrityVerifier.verifyMergedRun(at: sourceRunURL)
        var textResults: [VerifiedDerivedResult] = []
        var proposalResults: [VerifiedDerivedResult] = []
        var unreadable: [UnreadableDerivedSet] = []
        for directory in directories {
            switch try readDerivedSet(
                at: directory,
                source: verifiedSource,
                canonicalConflicts: canonicalConflicts
            ) {
            case .skipped:
                continue
            case let .unreadable(record):
                unreadable.append(record)
            case let .verified(result):
                switch result.manifest.operation.kind {
                case .textPostprocess: textResults.append(result)
                case .speakerProposal: proposalResults.append(result)
                }
            }
        }
        func freshestFirst(
            _ results: [VerifiedDerivedResult]
        ) -> [VerifiedDerivedResult] {
            results.sorted {
                if $0.finishedAt == $1.finishedAt {
                    return $0.manifest.derivedID > $1.manifest.derivedID
                }
                return $0.finishedAt > $1.finishedAt
            }
        }
        textResults = freshestFirst(textResults)
        proposalResults = freshestFirst(proposalResults)
        unreadable.sort { $0.id < $1.id }

        // Two selections, not one. D39's "freshest set wins" was written when
        // every derived set replaced the transcript's text. A speaker proposal
        // replaces no text, so letting it compete for the same slot would hide
        // a correction behind a set that corrected nothing. Each family
        // therefore has its own current member.
        let currentText = textResults.first
        let currentProposal = proposalResults.first
        guard currentText != nil || currentProposal != nil || !unreadable.isEmpty
        else {
            return sourceResult
        }

        let summaries = freshestFirst(textResults + proposalResults).map { result in
            DerivedResultSummary(
                id: result.manifest.derivedID,
                createdAt: result.finishedAt,
                operation: result.manifest.operation.mode,
                kind: result.manifest.operation.kind,
                targetLanguage: result.manifest.operation.targetLanguage,
                glossarySHA256: result.manifest.operation.glossarySHA256,
                directory: result.directory,
                isCurrent: result.manifest.derivedID == currentText?.manifest.derivedID
                    || result.manifest.derivedID == currentProposal?.manifest.derivedID,
                // Counted from the set's own verified document, not from the
                // layer the transcript ends up showing: only one proposal set
                // is loaded as a document, and the reader has to tell it from
                // the one that is not.
                speakerProposalCounts: result.proposal.map {
                    SpeakerProposalCounts(
                        proposed: $0.proposals.count,
                        declined: $0.declined.count
                    )
                }
            )
        }
        var loaded = currentText?.loaded ?? sourceResult
        loaded.derivedResults = summaries
        loaded.speakerProposal = currentProposal?.proposal
        loaded.unreadableDerivedSets = unreadable
        return loaded
    }

    /// What reading one derived set produced.
    ///
    /// Three outcomes, kept distinct on purpose. `.verified` is a set this
    /// build can read. `.skipped` is a set that never sealed successfully,
    /// which has always been passed over. `.unreadable` is a set this build
    /// does not understand: it is reported rather than applied, and it does not
    /// stop the source run from opening. That last case is why this function
    /// exists in this shape — an unrecognised derived family used to fail the
    /// manifest decode and take `loadRun` down with it, so a run that merely
    /// had a speaker proposal beside it could not be opened at all.
    private enum DerivedSetReadResult {
        case verified(VerifiedDerivedResult)
        case skipped
        case unreadable(UnreadableDerivedSet)
    }

    private func readDerivedSet(
        at directory: URL,
        source: VerifiedRunSource,
        canonicalConflicts: [MergeConflict]
    ) throws -> DerivedSetReadResult {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw LibraryRepositoryError.derivedManifestInvalid(
                directory.lastPathComponent
            )
        }
        let manifest: DerivedManifest
        do {
            manifest = try JSONDecoder().decode(
                DerivedManifest.self,
                from: manifestData
            )
        } catch {
            // A manifest naming a derived family this build has no case for
            // fails to decode exactly like a corrupt one. Separating them is
            // what lets a newer family be reported while a corrupt manifest
            // still fails loudly.
            if let kind = unrecognisedDerivedKind(in: manifestData) {
                return .unreadable(
                    UnreadableDerivedSet(
                        id: directory.lastPathComponent,
                        reason: .unrecognisedKind(kind)
                    )
                )
            }
            throw LibraryRepositoryError.derivedManifestInvalid(
                directory.lastPathComponent
            )
        }
        guard manifest.derivedID == directory.lastPathComponent,
              manifest.schemaVersion == MaccheroniSchema.version
        else {
            throw LibraryRepositoryError.derivedManifestInvalid(directory.lastPathComponent)
        }
        guard manifest.status == .succeeded, manifest.failure == nil else {
            return .skipped
        }
        // A correction rewrites the canonical segments and records no source
        // hash of its own; a translation and a speaker proposal both read them
        // and record the hash they read.
        let expectedPostprocessSourceHash: String? = switch manifest.operation.kind {
        case .speakerProposal:
            source.lineage.segmentsSHA256
        case .textPostprocess:
            manifest.operation.mode == .translation
                ? source.lineage.segmentsSHA256
                : nil
        }
        let sourceHashMatches =
            postprocessSourceHash(manifest) == expectedPostprocessSourceHash
        let glossaryIsConsistent = manifest.operation.glossarySHA256 == nil
            ? manifest.operation.glossaryItemCount == 0
            : manifest.operation.glossaryItemCount > 0
        // Switch rather than compare, so a new semantics case cannot be
        // accepted here without a deliberate decision. Source-run semantics
        // must carry exactly the glossary provenance the source manifest
        // recorded; anything else would label bytes the source run never used.
        let glossarySemanticsIsConsistent: Bool
        switch manifest.operation.glossarySemantics {
        case .currentProfile:
            glossarySemanticsIsConsistent = true
        case .sourceRun:
            let sourceGlossary = source.manifest.glossary
            glossarySemanticsIsConsistent = sourceGlossary.provided
                ? manifest.operation.glossarySHA256 == sourceGlossary.sha256
                    && manifest.operation.glossaryItemCount == sourceGlossary.itemCount
                : manifest.operation.glossarySHA256 == nil
                    && manifest.operation.glossaryItemCount == 0
        }
        guard manifest.source == source.lineage,
              manifest.source.segmentsPath == "merged/segments.json",
              !manifest.operation.profileName
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              glossarySemanticsIsConsistent,
              glossaryIsConsistent,
              manifest.operation.glossarySHA256.map(isLowercaseSHA256) ?? true,
              let postprocess = manifest.postprocess,
              validateDerivedPostprocessProvenance(postprocess),
              postprocess.mode == manifest.operation.mode,
              postprocess.targetLanguage == manifest.operation.targetLanguage,
              postprocess.glossarySHA256 == manifest.operation.glossarySHA256,
              sourceHashMatches
        else {
            throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
        }

        var artifactPaths = Set<String>()
        var artifactKinds = Set<String>()
        var artifactData: [String: VerifiedArtifactData] = [:]
        for artifact in manifest.artifacts {
            guard artifactPaths.insert(artifact.path).inserted,
                  artifactKinds.insert(artifact.kind).inserted
            else {
                throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
            }
            artifactData[artifact.kind] = try verifiedDerivedArtifact(
                artifact,
                root: directory
            )
        }
        guard let finishedAt = derivedDate(manifest.timing.finishedAt) else {
            throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
        }

        var document = source.document
        var conflicts = canonicalConflicts
        var proposal: SpeakerProposalDocument?

        switch manifest.operation.kind {
        case .textPostprocess:
            // D49 relaxed the coverage gate for the speaker-proposal family
            // only. Correction and translation rewrite or mirror every segment,
            // so a transcript with a hole in it would produce a set claiming
            // coverage it does not have. They keep the gate, and the same error
            // `verifyCompletedRun` used to raise for them.
            guard source.coverageIsComplete else {
                throw RunIntegrityError.sourceRunNotComplete
            }
            switch manifest.operation.mode {
            case .correction:
                guard manifest.artifacts.count == 2,
                      manifest.operation.targetLanguage == nil,
                      artifactPaths == [
                        "postprocess/segments.json",
                        "postprocess/conflicts.json",
                      ],
                      let segmentsArtifact = artifactData["postprocess_segments"],
                      let conflictsArtifact = artifactData["postprocess_conflicts"]
                else {
                    throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
                }
                document = try SegmentsDocumentContract.decode(segmentsArtifact.data)
                let postprocessConflicts = try JSONDecoder().decode(
                    [PostprocessConflict].self,
                    from: conflictsArtifact.data
                )
                try validatePostprocess(
                    document,
                    against: source.document,
                    conflicts: postprocessConflicts,
                    artifactName: segmentsArtifact.url.lastPathComponent
                )
                conflicts = merging(postprocessConflicts, into: conflicts)
            case .translation:
                guard manifest.artifacts.count == 1,
                      manifest.operation.targetLanguage?.range(
                        of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$",
                        options: .regularExpression
                      ) != nil,
                      artifactPaths == ["postprocess/translation.json"],
                      let translationArtifact = artifactData["postprocess_translation"]
                else {
                    throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
                }
                let translation = try JSONDecoder().decode(
                    TranslationDocument.self,
                    from: translationArtifact.data
                )
                try validateTranslation(
                    translation,
                    against: source.document,
                    provenance: postprocess,
                    sourceSegmentsSHA256: source.lineage.segmentsSHA256,
                    artifactName: translationArtifact.url.lastPathComponent
                )
                for value in translation.translations {
                    document.segments[value.segmentIndex].text = value.translatedText
                }
                for conflict in conflicts where document.segments.indices.contains(conflict.segmentIndex) {
                    var flags = document.segments[conflict.segmentIndex].flags ?? []
                    if !flags.contains("uncertain") { flags.append("uncertain") }
                    document.segments[conflict.segmentIndex].flags = flags
                }
                conflicts.removeAll()
            }
        case .speakerProposal:
            // Nothing in `document` or `conflicts` changes: a proposal is a
            // layer read beside the acoustic record, never written into it.
            proposal = try verifiedSpeakerProposal(
                manifest: manifest,
                artifactPaths: artifactPaths,
                artifactData: artifactData,
                source: source,
                canonicalConflicts: canonicalConflicts
            )
        }

        let conflictsBySegment = Dictionary(
            conflicts.map { ($0.segmentIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let segments = document.segments.enumerated().map { index, segment in
            TranscriptSegment(
                id: TranscriptSegmentID(
                    runID: "\(source.manifest.runID)/\(manifest.derivedID)",
                    index: index
                ),
                index: index,
                segment: segment,
                conflict: conflictsBySegment[index]
            )
        }
        return .verified(
            VerifiedDerivedResult(
                directory: directory,
                manifest: manifest,
                finishedAt: finishedAt,
                loaded: LoadedRun(
                    manifest: source.manifest,
                    transcript: document,
                    conflicts: conflicts,
                    segments: segments,
                    sourceTranscript: document == source.document ? nil : source.document,
                    resultID: manifest.derivedID,
                    resultPostprocess: postprocess,
                    resultOperation: manifest.operation
                ),
                proposal: proposal
            )
        )
    }

    /// The `operation.kind` of a derived manifest this build cannot decode,
    /// when an unrecognised kind is the reason it cannot. `nil` for every other
    /// decoding failure, so only this one cause is read as "newer" rather than
    /// "broken".
    private func unrecognisedDerivedKind(in manifestData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: manifestData),
              let root = object as? [String: Any],
              let operation = root["operation"] as? [String: Any],
              let kind = operation["kind"] as? String,
              DerivedOperationKind(rawValue: kind) == nil
        else { return nil }
        return kind
    }

    /// The speaker-proposal artifact of a derived set, verified against the
    /// source run it names (D46, D49, D50).
    ///
    /// The artifact hash proves the bytes are the ones the manifest lists. It
    /// does not prove the manifest and the source run agree, so every check the
    /// CLI applies while writing a proposal is applied again while reading one.
    private func verifiedSpeakerProposal(
        manifest: DerivedManifest,
        artifactPaths: Set<String>,
        artifactData: [String: VerifiedArtifactData],
        source: VerifiedRunSource,
        canonicalConflicts: [MergeConflict]
    ) throws -> SpeakerProposalDocument {
        guard manifest.artifacts.count == 1,
              manifest.operation.targetLanguage == nil,
              manifest.operation.glossarySHA256 == nil,
              manifest.operation.glossaryItemCount == 0,
              artifactPaths == ["speaker/proposals.json"],
              let artifact = artifactData["speaker_proposals"]
        else {
            throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
        }
        // D49's two conditions, checked rather than assumed: the manifest
        // records the source coverage the proposal was made over, and that
        // record is the coverage the source run actually has.
        guard manifest.operation.sourceCoverage == source.coverage,
              manifest.operation.sourceCoverageComplete == source.coverageIsComplete
        else {
            throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
        }
        let document: SpeakerProposalDocument
        do {
            document = try JSONDecoder().decode(
                SpeakerProposalDocument.self,
                from: artifact.data
            )
        } catch {
            throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
        }
        guard document.schemaVersion == MaccheroniSchema.version,
              document.layer == SpeakerProposalDocument.layer,
              document.sourceSegmentsSHA256 == source.lineage.segmentsSHA256,
              document.sourceCoverage == source.coverage,
              document.unattributedSpeakers == UnattributedSpeaker.labels,
              document.batches.count == manifest.postprocess?.batching?.batchesPlanned
        else {
            throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
        }

        // Rebuilt from the source run rather than read out of the artifact, so
        // the proposal is checked against the acoustics rather than against
        // itself.
        let expected = speakerEvidenceByIndex(
            source: source,
            conflicts: canonicalConflicts
        )
        var seen = Set<Int>()
        let knownSpeakers = Set(source.document.segments.map(\.speaker))
            .subtracting(UnattributedSpeaker.labels)

        func check(
            segmentIndex: Int,
            reason: String,
            outcome: String,
            coverage: Double,
            candidates: [SpeakerCandidateEvidence]
        ) throws {
            guard seen.insert(segmentIndex).inserted,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let record = expected[segmentIndex],
                  record.outcome == outcome,
                  record.candidates == candidates,
                  record.timelineCoverage == coverage
            else {
                throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
            }
        }

        for proposal in document.proposals {
            try check(
                segmentIndex: proposal.segmentIndex,
                reason: proposal.reason,
                outcome: proposal.acousticOutcome,
                coverage: proposal.acousticTimelineCoverage,
                candidates: proposal.acousticCandidates
            )
            // Judgment rule 4 as amended by D46: a proposal completes acoustic
            // evidence and never replaces it. The segment must still be
            // unattributed in the source, and the proposed speaker must be one
            // the acoustics put in play.
            guard UnattributedSpeaker.isUnattributed(
                source.document.segments[proposal.segmentIndex].speaker
            ) else {
                throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
            }
            let allowed = proposal.acousticCandidates.isEmpty
                ? knownSpeakers
                : Set(proposal.acousticCandidates.map(\.speaker))
            guard allowed.contains(proposal.proposedSpeaker) else {
                throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
            }
            // D50, enforced only where the document claims to have run under
            // it. A set written before the constraint existed carries no
            // `constraint` and is not retroactively judged by it.
            if document.constraint == .confirmOrDecline {
                guard SpeakerProposalConstraint.topRankedCandidate(
                    among: proposal.acousticCandidates
                ) == proposal.proposedSpeaker else {
                    throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
                }
            }
        }
        for decline in document.declined {
            try check(
                segmentIndex: decline.segmentIndex,
                reason: decline.reason,
                outcome: decline.acousticOutcome,
                coverage: decline.acousticTimelineCoverage,
                candidates: decline.acousticCandidates
            )
        }
        // Exactly once over proposals plus declined, across every segment the
        // source left unattributed. A proposal set that quietly skipped
        // segments would read as though they had never been examined.
        guard seen == Set(expected.keys) else {
            throw LibraryRepositoryError.derivedLineageMismatch(manifest.derivedID)
        }
        return document
    }

    /// One acoustic evidence record per unattributed segment, rebuilt from the
    /// source run's merged segments and merged conflicts. This is the same
    /// derivation the CLI hands a proposer, restated on the reading side.
    private func speakerEvidenceByIndex(
        source: VerifiedRunSource,
        conflicts: [MergeConflict]
    ) -> [Int: SegmentSpeakerEvidence] {
        // A segment can raise both an ambiguous-speaker and an
        // overlapping-speech record carrying the same attribution. The
        // ambiguous-speaker record is the one that explains why no speaker was
        // named, so it wins.
        var attributionByIndex: [Int: SpeakerAttribution] = [:]
        for conflict in conflicts {
            guard let attribution = conflict.speakerAttribution else { continue }
            if conflict.kind == .ambiguousSpeaker
                || attributionByIndex[conflict.segmentIndex] == nil
            {
                attributionByIndex[conflict.segmentIndex] = attribution
            }
        }
        var evidence: [Int: SegmentSpeakerEvidence] = [:]
        for index in source.document.segments.indices
            where UnattributedSpeaker.isUnattributed(
                source.document.segments[index].speaker
            )
        {
            guard let attribution = attributionByIndex[index] else {
                evidence[index] = SegmentSpeakerEvidence(
                    segmentIndex: index,
                    outcome: "no_acoustic_record",
                    candidates: [],
                    timelineCoverage: 0
                )
                continue
            }
            evidence[index] = SegmentSpeakerEvidence(
                segmentIndex: index,
                outcome: attribution.outcome.rawValue,
                candidates: attribution.candidates.map {
                    SpeakerCandidateEvidence(
                        speaker: $0.speaker,
                        overlapS: $0.overlapS,
                        share: $0.share
                    )
                },
                timelineCoverage: attribution.timelineCoverage
            )
        }
        return evidence
    }


    private func postprocessSourceHash(_ manifest: DerivedManifest) -> String? {
        manifest.postprocess?.sourceSegmentsSHA256
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }

    private func validateDerivedPostprocessProvenance(
        _ postprocess: ManifestPostprocess
    ) -> Bool {
        guard postprocess.inputMode == .textOnly,
              !postprocess.backend.name.isEmpty,
              !postprocess.backend.version.isEmpty,
              !postprocess.modelID.isEmpty,
              postprocess.glossarySHA256.map(isLowercaseSHA256) ?? true,
              let batching = postprocess.batching,
              batching.maximumPromptUTF8Bytes > 0,
              batching.maximumSegmentsPerBatch > 0,
              batching.outputTokenPlanningBudget > 0,
              batching.outputTokensPerInputUTF8BytePermille > 0,
              batching.baseOutputTokenReserve >= 0,
              batching.perSegmentOutputTokenReserve >= 0,
              batching.batchesPlanned > 0,
              batching.maximumObservedPromptUTF8Bytes > 0,
              batching.maximumObservedPromptUTF8Bytes
                <= batching.maximumPromptUTF8Bytes,
              batching.maximumObservedInputTextUTF8Bytes >= 0,
              batching.maximumObservedEstimatedOutputTokens > 0,
              batching.maximumObservedEstimatedOutputTokens
                <= batching.outputTokenPlanningBudget,
              batching.maximumObservedOutputTextUTF8Bytes >= 0,
              batching.maximumObservedResponseUTF8Bytes
                >= batching.maximumObservedOutputTextUTF8Bytes,
              batching.maximumObservedAcceptedOutputTokenUpperBound >= 0,
              batching.maximumObservedAcceptedOutputTokenUpperBound
                <= batching.outputTokenPlanningBudget,
              (batching.outputTokenLimitStatus == .configured)
                == (batching.maximumOutputTokens != nil),
              batching.maximumOutputTokens.map({
                batching.outputTokenPlanningBudget <= $0
              }) ?? true
        else { return false }
        return true
    }

    private func merging(
        _ postprocessConflicts: [PostprocessConflict],
        into sourceConflicts: [MergeConflict]
    ) -> [MergeConflict] {
        var conflicts = sourceConflicts
        for conflict in postprocessConflicts {
            let mapped = MergeConflict(
                segmentIndex: conflict.segmentIndex,
                kind: .asrDisagreement,
                candidates: [conflict.originalText, conflict.candidateText],
                reason: conflict.reason
            )
            if let index = conflicts.firstIndex(where: {
                $0.segmentIndex == conflict.segmentIndex
            }) {
                for candidate in mapped.candidates where !conflicts[index].candidates.contains(candidate) {
                    conflicts[index].candidates.append(candidate)
                }
                if !conflicts[index].reason.contains(mapped.reason) {
                    conflicts[index].reason += " \(mapped.reason)"
                }
            } else {
                conflicts.append(mapped)
            }
        }
        return conflicts
    }

    private func verifiedDerivedArtifact(
        _ artifact: Artifact,
        root: URL
    ) throws -> VerifiedArtifactData {
        let relative = artifact.path
        guard !relative.isEmpty,
              !(relative as NSString).isAbsolutePath,
              !relative.contains("\\"),
              !relative.split(separator: "/", omittingEmptySubsequences: false)
                .contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else {
            throw LibraryRepositoryError.unsafeArtifactPath(relative)
        }
        let unresolved = root.appendingPathComponent(relative).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let resolved = unresolved.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw LibraryRepositoryError.unsafeArtifactPath(relative)
        }
        let values: URLResourceValues
        do {
            values = try unresolved.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw LibraryRepositoryError.artifactMissing(relative)
        }
        guard values.isSymbolicLink != true else {
            throw LibraryRepositoryError.unsafeArtifactPath(relative)
        }
        guard values.isRegularFile == true else {
            throw LibraryRepositoryError.artifactMissing(relative)
        }
        let data: Data
        do {
            data = try Data(contentsOf: unresolved)
        } catch {
            throw LibraryRepositoryError.artifactMissing(relative)
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else {
            throw LibraryRepositoryError.artifactHashMismatch(relative)
        }
        try onDerivedArtifactVerified(unresolved)
        return VerifiedArtifactData(url: unresolved, data: data)
    }

    private func derivedDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private func validatePostprocess(
        _ corrected: SegmentsDocument,
        against original: SegmentsDocument,
        conflicts: [PostprocessConflict],
        artifactName: String
    ) throws {
        func reject() throws -> Never {
            throw LibraryRepositoryError.artifactHashMismatch(artifactName)
        }

        guard corrected.schemaVersion == original.schemaVersion,
              SegmentsDocumentContract.isValid(corrected),
              corrected.numSpeakers == original.numSpeakers,
              corrected.source == original.source,
              corrected.segments.count == original.segments.count
        else {
            try reject()
        }

        var conflictsByIndex: [Int: PostprocessConflict] = [:]
        for conflict in conflicts {
            guard original.segments.indices.contains(conflict.segmentIndex),
                  conflictsByIndex[conflict.segmentIndex] == nil,
                  conflict.originalText
                    == original.segments[conflict.segmentIndex].text,
                  !conflict.candidateText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !conflict.reason
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try reject()
            }
            conflictsByIndex[conflict.segmentIndex] = conflict
        }

        for index in original.segments.indices {
            let before = original.segments[index]
            let after = corrected.segments[index]
            guard after.speaker == before.speaker,
                  after.startS == before.startS,
                  after.endS == before.endS,
                  after.language == before.language,
                  after.confidence == before.confidence,
                  !after.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try reject()
            }
            if conflictsByIndex[index] == nil {
                guard after.flags == before.flags else {
                    try reject()
                }
            } else {
                var expectedFlags = before.flags ?? []
                for flag in ["uncertain", "conflict"]
                    where !expectedFlags.contains(flag)
                {
                    expectedFlags.append(flag)
                }
                guard after.text == before.text,
                      after.flags == expectedFlags
                else {
                    try reject()
                }
            }
        }
    }

    private func validateTranslation(
        _ translation: TranslationDocument,
        against original: SegmentsDocument,
        provenance: ManifestPostprocess,
        sourceSegmentsSHA256: String,
        artifactName: String
    ) throws {
        func reject() throws -> Never {
            throw LibraryRepositoryError.artifactHashMismatch(artifactName)
        }

        guard provenance.mode == .translation,
              provenance.inputMode == .textOnly,
              provenance.targetLanguage == translation.targetLanguage,
              provenance.sourceSegmentsSHA256 == sourceSegmentsSHA256,
              translation.schemaVersion == MaccheroniSchema.version,
              translation.sourceSegmentsSHA256 == sourceSegmentsSHA256,
              translation.translations.count == original.segments.count,
              let batching = provenance.batching
        else {
            try reject()
        }

        let planningBudgetFitsHardLimit = batching.maximumOutputTokens.map {
            batching.outputTokenPlanningBudget <= $0
        } ?? true
        guard
              batching.maximumPromptUTF8Bytes > 0,
              batching.maximumSegmentsPerBatch > 0,
              batching.outputTokenPlanningBudget > 0,
              batching.outputTokensPerInputUTF8BytePermille > 0,
              batching.baseOutputTokenReserve >= 0,
              batching.perSegmentOutputTokenReserve >= 0,
              (batching.outputTokenLimitStatus == .configured)
                == (batching.maximumOutputTokens != nil),
              planningBudgetFitsHardLimit,
              batching.batchesPlanned == translation.batches.count
        else {
            try reject()
        }

        var indices = Set<Int>()
        for value in translation.translations {
            guard original.segments.indices.contains(value.segmentIndex),
                  indices.insert(value.segmentIndex).inserted,
                  !value.translatedText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                try reject()
            }
        }
        guard indices == Set(original.segments.indices) else { try reject() }

        let translationsByIndex = Dictionary(
            uniqueKeysWithValues: translation.translations.map {
                ($0.segmentIndex, $0)
            }
        )
        var batchedIndices: [Int] = []
        for (batchIndex, batch) in translation.batches.enumerated() {
            guard !batch.segmentIndices.isEmpty,
                  batch.segmentIndices.allSatisfy(original.segments.indices.contains)
            else {
                try reject()
            }
            let inputTextUTF8Bytes = batch.segmentIndices.reduce(0) {
                saturatingAdd($0, original.segments[$1].text.utf8.count)
            }
            let outputTextUTF8Bytes = try batch.segmentIndices.reduce(0) {
                guard let translated = translationsByIndex[$1] else {
                    try reject()
                }
                return saturatingAdd($0, translated.translatedText.utf8.count)
            }
            guard let estimatedOutputTokens = estimatedOutputTokens(
                      inputTextUTF8Bytes: inputTextUTF8Bytes,
                      segmentCount: batch.segmentIndices.count,
                      batching: batching
                  ),
              let acceptedOutputTokenUpperBound = outputTokenUpperBound(
                      textUTF8Bytes: batch.responseUTF8Bytes,
                      segmentCount: batch.segmentIndices.count,
                      batching: batching
                  )
            else {
                try reject()
            }
            guard batch.batchIndex == batchIndex,
                  batch.segmentIndices.count <= batching.maximumSegmentsPerBatch,
                  batch.promptUTF8Bytes > 0,
                  batch.promptUTF8Bytes <= batching.maximumPromptUTF8Bytes,
                  batch.inputTextUTF8Bytes == inputTextUTF8Bytes,
                  batch.estimatedOutputTokens == estimatedOutputTokens,
                  batch.estimatedOutputTokens <= batching.outputTokenPlanningBudget,
                  batch.outputTextUTF8Bytes == outputTextUTF8Bytes,
                  batch.responseUTF8Bytes >= batch.outputTextUTF8Bytes,
                  batch.acceptedOutputTokenUpperBound
                    == acceptedOutputTokenUpperBound,
                  batch.acceptedOutputTokenUpperBound
                    <= batching.outputTokenPlanningBudget
            else {
                try reject()
            }
            batchedIndices.append(contentsOf: batch.segmentIndices)
        }
        guard batchedIndices == Array(original.segments.indices) else {
            try reject()
        }
        guard batching.maximumObservedPromptUTF8Bytes
                == translation.batches.map(\.promptUTF8Bytes).max(),
              batching.maximumObservedInputTextUTF8Bytes
                == translation.batches.map(\.inputTextUTF8Bytes).max(),
              batching.maximumObservedEstimatedOutputTokens
                == translation.batches.map(\.estimatedOutputTokens).max(),
              batching.maximumObservedOutputTextUTF8Bytes
                == translation.batches.map(\.outputTextUTF8Bytes).max(),
              batching.maximumObservedResponseUTF8Bytes
                == translation.batches.map(\.responseUTF8Bytes).max(),
              batching.maximumObservedAcceptedOutputTokenUpperBound
                == translation.batches.map(\.acceptedOutputTokenUpperBound).max()
        else {
            try reject()
        }
    }

    private func estimatedOutputTokens(
        inputTextUTF8Bytes: Int,
        segmentCount: Int,
        batching: ManifestPostprocessBatching
    ) -> Int? {
        let (scaled, overflow) = inputTextUTF8Bytes.multipliedReportingOverflow(
            by: batching.outputTokensPerInputUTF8BytePermille
        )
        guard !overflow, scaled <= Int.max - 999 else { return nil }
        return outputTokenUpperBound(
            textUTF8Bytes: (scaled + 999) / 1_000,
            segmentCount: segmentCount,
            batching: batching
        )
    }

    private func outputTokenUpperBound(
        textUTF8Bytes: Int,
        segmentCount: Int,
        batching: ManifestPostprocessBatching
    ) -> Int? {
        let (segmentReserve, segmentOverflow) =
            segmentCount.multipliedReportingOverflow(
                by: batching.perSegmentOutputTokenReserve
            )
        guard !segmentOverflow else { return nil }
        let (withBase, baseOverflow) = textUTF8Bytes.addingReportingOverflow(
            batching.baseOutputTokenReserve
        )
        guard !baseOverflow else { return nil }
        let (total, totalOverflow) = withBase.addingReportingOverflow(segmentReserve)
        return totalOverflow ? nil : total
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private func requiredArtifact(
        kind: String,
        manifest: Manifest,
        runURL: URL
    ) throws -> VerifiedArtifactData {
        guard let artifact = manifest.artifacts.first(where: { $0.kind == kind }) else {
            throw LibraryRepositoryError.artifactMissing(kind)
        }
        let relative = artifact.path
        guard !(relative as NSString).isAbsolutePath,
              !relative.split(separator: "/").contains("..")
        else {
            throw LibraryRepositoryError.unsafeArtifactPath(relative)
        }
        let rootPath = runURL.standardizedFileURL.path + "/"
        let url = runURL.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(rootPath) else {
            throw LibraryRepositoryError.unsafeArtifactPath(relative)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LibraryRepositoryError.artifactMissing(relative)
        }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == artifact.sha256 else {
            throw LibraryRepositoryError.artifactHashMismatch(relative)
        }
        return VerifiedArtifactData(url: url, data: data)
    }
}

// MARK: - Failed and partial run diagnosis

/// What one finished run's own records say happened to it.
///
/// `partial` and `failed` are told apart by `manifest.status` alone. The chunk
/// status vocabulary has no partial value, so a chunk whose inference leaf
/// promoted only a recovered prefix is still recorded `succeeded`, and
/// `chunks_completed` can equal `chunks_planned` on a run that never covered
/// its input (`docs/engineering-constraint-policy.md`, the promotion block).
/// Nothing in this diagnosis reads a chunk count.
enum RunCompletionOutcome: Hashable, Sendable {
    case succeeded
    case partial
    case failed
    case canceled
    /// The run directory is on disk but its manifest cannot be read.
    case unreadable
}

/// The cause a failed or partial run is presented under.
///
/// Deliberately coarser than the engine's error codes: one case per sentence
/// the screen is able to say. It carries no raw value, so an engine identifier
/// cannot reach the screen by being printed.
enum RunFailureCause: Hashable, CaseIterable, Sendable {
    /// The decoder stopped producing new content and repeated itself to the
    /// end of its output budget.
    case repetitionLooping
    /// A limit outcome on a non-MOSS backend that recovery could not clear.
    case asrLimitExhausted
    /// The MOSS recovery tree was spent. Kept apart because the screen offers
    /// a different next step for it.
    case mossLimitExhausted
    case asrTimedOut
    case asrOutputUnusable
    case modelIdentityMismatch
    case diarizationRejectedTimeline
    case audioNotPreparable
    case mergeRejected
    case postprocessFailed
    case glossaryRejected
    case profileRejected
    case missingDependency
    case missingFile
    case integrityMismatch
    case unreadableRunRecord
    case canceled
    case unspecified
}

extension RunFailureCause {
    /// Classify one manifest failure.
    ///
    /// `failure.code` is the primary signal and always wins. A few codes bundle
    /// conditions the screen has to keep apart — a missing helper, a missing
    /// input file and a rejected timeline all arrive as `DIARIZATION_ERROR` —
    /// so those codes are sub-divided by markers taken from the engine's own
    /// English messages (`DiarizationError` in
    /// `Sources/MaccheroniDiarize/DiarizationAdapters.swift`, `ASRAdapterError`
    /// in `Sources/MaccheroniASR/ASRAdapters.swift`). Markers only ever narrow
    /// a code; they never override one.
    static func classify(code: String, message: String) -> RunFailureCause {
        switch code {
        // `ASR_REPETITION_DEGENERATION` is the name this code was written
        // under before the 2026-09-02 terminology rename to
        // `ASR_REPETITION_LOOPING`. A run's manifest is sealed when the run
        // ends and no stage rewrites it (PROJECT.md judgment rule 3), so every
        // run recorded before that day still carries the old spelling on disk
        // and always will. The alias is what keeps those runs saying what they
        // said: without it the screen falls through to `.unspecified`, loses
        // the sentence naming the cause, and loses the Stopped At row with it.
        case "ASR_REPETITION_LOOPING", "ASR_REPETITION_DEGENERATION":
            return .repetitionLooping
        case "ASR_LIMIT_EXHAUSTED": return .asrLimitExhausted
        case "MOSS_LIMIT_EXHAUSTED": return .mossLimitExhausted
        case "SOURCE_INTEGRITY_ERROR": return .integrityMismatch
        case "MERGE_ERROR": return .mergeRejected
        case "POSTPROCESS_ERROR": return .postprocessFailed
        case "GLOSSARY_ERROR": return .glossaryRejected
        case "CANCELED": return .canceled
        case "asr_timeout": return .asrTimedOut
        case "asr_model_identity_mismatch": return .modelIdentityMismatch
        case "asr_malformed_output", "asr_evidence_unavailable",
             "asr_coverage_shortfall", "invalid_eos_output",
             "limit_isolated", "backend_failed":
            return narrowed(message, fallback: .asrOutputUnusable)
        case "ASR_ERROR":
            return narrowed(message, fallback: .asrOutputUnusable)
        case "DIARIZATION_ERROR":
            return narrowed(message, fallback: .diarizationRejectedTimeline)
        case "PREPROCESS_ERROR", "VAD_ERROR", "CHUNK_PLAN_ERROR":
            return narrowed(message, fallback: .audioNotPreparable)
        case "PROFILE_ERROR", "USAGE_ERROR":
            return narrowed(message, fallback: .profileRejected)
        default:
            return narrowed(message, fallback: .unspecified)
        }
    }

    /// Markers, most specific first. Order matters: `required exact model
    /// snapshot is missing` and `input audio is missing` both contain the word
    /// missing, and they are different sentences on the screen.
    private static let markers: [(needle: String, cause: RunFailureCause)] = [
        ("model identity mismatch", .modelIdentityMismatch),
        ("did not prove the pinned model identity", .modelIdentityMismatch),
        ("input audio is missing", .missingFile),
        ("input audio cannot be read", .missingFile),
        ("no such file", .missingFile),
        ("is no longer available", .missingFile),
        ("executable is missing", .missingDependency),
        ("is missing or not executable", .missingDependency),
        ("runner is missing", .missingDependency),
        ("model snapshot is missing", .missingDependency),
        ("runtime is missing", .missingDependency),
        ("is not installed", .missingDependency),
        ("command-line engine is missing", .missingDependency),
        ("could not start", .missingDependency),
        ("integrity check", .integrityMismatch),
        ("hash mismatch", .integrityMismatch),
        ("hash changed", .integrityMismatch),
        ("sha256 mismatch", .integrityMismatch),
        ("limit outcome", .asrLimitExhausted),
    ]

    private static func narrowed(
        _ message: String,
        fallback: RunFailureCause
    ) -> RunFailureCause {
        let haystack = message.lowercased()
        for marker in markers where haystack.contains(marker.needle) {
            return marker.cause
        }
        return fallback
    }
}

/// How one pipeline stage of a finished run reads in the checklist.
enum RunStageStatus: Hashable, Sendable {
    case finished
    /// The stage produced output, but not for the whole planned input.
    case incomplete
    case failed
    case notReached
}

/// One source range that produced no transcript. `stopReason` is the engine's
/// own `stop_reason` string, kept so the range list is complete and
/// deliberately never rendered.
struct RunMissingRange: Decodable, Equatable, Sendable {
    var startS: Double
    var endS: Double
    var stopReason: String

    enum CodingKeys: String, CodingKey {
        case startS = "start_s"
        case endS = "end_s"
        case stopReason = "stop_reason"
    }
}

/// `primary/partial-coverage.json`, the run's own statement of what it
/// promoted and what it did not.
struct RunPartialCoverage: Decodable, Equatable, Sendable {
    var inputDurationS: Double
    var promotedDurationS: Double
    var missingDurationS: Double
    var missing: [RunMissingRange]

    enum CodingKeys: String, CodingKey {
        case missing
        case inputDurationS = "input_duration_s"
        case promotedDurationS = "promoted_duration_s"
        case missingDurationS = "missing_duration_s"
    }
}

/// How much of the input a run actually transcribed.
///
/// Every value here comes from `coverage` and `primary/partial-coverage.json`.
/// `chunks_planned` and `chunks_completed` are deliberately absent.
struct RunCoverageSummary: Equatable, Sendable {
    var inputDurationS: Double
    var processedDurationS: Double
    var truncated: Bool
    var isBackendTruncated: Bool
    var missingRanges: [RunMissingRange]
    var missingDurationS: Double?

    var coveredFraction: Double {
        guard inputDurationS > 0 else { return 0 }
        return min(1, max(0, processedDurationS / inputDurationS))
    }

    /// True when the run promoted some transcript but not for the whole input.
    var isShortOfInput: Bool {
        truncated || isBackendTruncated
            || processedDurationS < inputDurationS - 0.05
    }

    var promotedAnyAudio: Bool { processedDurationS > 0 }
}

/// The failure screen's whole input: what happened, where it stopped, how far
/// the checklist got, and how much audio was transcribed.
struct RunOutcome: Equatable, Sendable {
    var completion: RunCompletionOutcome
    var cause: RunFailureCause?
    var failedStage: PipelineStage?
    var stageStatuses: [PipelineStage: RunStageStatus]
    var coverage: RunCoverageSummary?
    /// The engine's own message, sanitized. English, diagnostic, secondary to
    /// the localized sentence the cause produces.
    var detail: String?

    var isFailureLike: Bool {
        completion == .failed || completion == .partial
            || completion == .unreadable
    }

    func status(of stage: PipelineStage) -> RunStageStatus {
        stageStatuses[stage] ?? .notReached
    }
}

extension RunOutcome {
    /// Stage order the checklist walks. `.preparing` is included so a run that
    /// never reached preprocessing has a row to fail on instead of marking a
    /// stage that did not run.
    static func stageOrder(includesPostprocess: Bool) -> [PipelineStage] {
        var stages: [PipelineStage] = [
            .preparing, .preprocessing, .diarization, .asr, .merge,
        ]
        if includesPostprocess { stages.append(.postprocess) }
        return stages
    }

    /// The artifact kind whose presence proves a stage finished.
    private static let completionEvidence: [(PipelineStage, String)] = [
        (.preprocessing, "preprocessed_audio"),
        (.diarization, "diarization_timeline"),
        (.asr, "primary_segments"),
        (.merge, "merged_segments"),
        (.postprocess, "postprocess_segments"),
    ]

    /// The stage a failure code names outright. `nil` means the code says
    /// nothing about the stage and the artifact evidence has to decide.
    private static func namedStage(for cause: RunFailureCause) -> PipelineStage? {
        switch cause {
        case .audioNotPreparable: .preprocessing
        case .diarizationRejectedTimeline: .diarization
        case .repetitionLooping, .asrLimitExhausted, .mossLimitExhausted,
             .asrTimedOut, .asrOutputUnusable, .modelIdentityMismatch:
            .asr
        case .mergeRejected: .merge
        case .postprocessFailed: .postprocess
        case .missingDependency, .missingFile, .integrityMismatch,
             .glossaryRejected, .profileRejected, .unreadableRunRecord,
             .canceled, .unspecified:
            nil
        }
    }

    /// Build the diagnosis from a run's own records.
    ///
    /// - Parameters:
    ///   - manifest: the run manifest, or `nil` when it is absent or unreadable.
    ///   - partialCoverage: `primary/partial-coverage.json` when it exists.
    ///   - runDirectoryExists: whether the run directory is still on disk.
    ///   - recordState: the library entry's state, used only when no manifest
    ///     was ever written.
    ///   - recordFailureMessage: the app-side error text for the same case.
    ///   - postprocessRequested: whether the checklist shows a post-processing
    ///     row.
    static func make(
        manifest: Manifest?,
        partialCoverage: RunPartialCoverage? = nil,
        runDirectoryExists: Bool,
        recordState: LibraryItemState,
        recordFailureMessage: String? = nil,
        postprocessRequested: Bool = false
    ) -> RunOutcome {
        let stages = stageOrder(includesPostprocess: postprocessRequested)
        guard let manifest else {
            return withoutManifest(
                runDirectoryExists: runDirectoryExists,
                recordState: recordState,
                recordFailureMessage: recordFailureMessage,
                stages: stages
            )
        }

        let kinds = Set(manifest.artifacts.map(\.kind))
        var completed: Set<PipelineStage> = [.preparing]
        for (stage, kind) in completionEvidence where kinds.contains(kind) {
            completed.insert(stage)
        }

        let coverage = RunCoverageSummary(
            inputDurationS: manifest.coverage.inputDurationS,
            processedDurationS: manifest.coverage.processedDurationS,
            truncated: manifest.coverage.truncated,
            isBackendTruncated: manifest.coverage.strategy == .backendTruncated,
            missingRanges: partialCoverage?.missing ?? [],
            missingDurationS: partialCoverage?.missingDurationS
        )

        let completion: RunCompletionOutcome = switch manifest.status {
        case .succeeded: .succeeded
        case .partial: .partial
        case .canceled: .canceled
        case .failed: .failed
        }

        guard completion != .succeeded else {
            var statuses: [PipelineStage: RunStageStatus] = [:]
            for stage in stages {
                statuses[stage] = completed.contains(stage) ? .finished : .notReached
            }
            return RunOutcome(
                completion: .succeeded,
                cause: nil,
                failedStage: nil,
                stageStatuses: statuses,
                coverage: coverage,
                detail: nil
            )
        }

        let cause: RunFailureCause? = manifest.failure.map {
            classify(completion: completion, failure: $0)
        }
        let failedStage = resolveFailedStage(
            cause: cause,
            completed: completed,
            stages: stages,
            completion: completion
        )
        let statuses = stageStatuses(
            stages: stages,
            completed: completed,
            failedStage: failedStage,
            completion: completion,
            coverage: coverage
        )
        return RunOutcome(
            completion: completion,
            cause: cause,
            failedStage: failedStage,
            stageStatuses: statuses,
            coverage: coverage,
            detail: sanitizedDetail(manifest.failure?.message)
        )
    }

    private static func classify(
        completion: RunCompletionOutcome,
        failure: Failure
    ) -> RunFailureCause {
        completion == .canceled
            ? .canceled
            : RunFailureCause.classify(code: failure.code, message: failure.message)
    }

    private static func resolveFailedStage(
        cause: RunFailureCause?,
        completed: Set<PipelineStage>,
        stages: [PipelineStage],
        completion: RunCompletionOutcome
    ) -> PipelineStage? {
        guard completion != .canceled else { return nil }
        if let cause, let named = namedStage(for: cause), stages.contains(named) {
            return named
        }
        return stages.first { !completed.contains($0) }
    }

    private static func stageStatuses(
        stages: [PipelineStage],
        completed: Set<PipelineStage>,
        failedStage: PipelineStage?,
        completion: RunCompletionOutcome,
        coverage: RunCoverageSummary?
    ) -> [PipelineStage: RunStageStatus] {
        var statuses: [PipelineStage: RunStageStatus] = [:]
        let failedIndex = failedStage.flatMap { stages.firstIndex(of: $0) }
        for (index, stage) in stages.enumerated() {
            if let failedIndex, index == failedIndex {
                statuses[stage] = completion == .partial ? .incomplete : .failed
            } else if completed.contains(stage) {
                let short = completion == .partial
                    && stage == .asr
                    && coverage?.isShortOfInput == true
                statuses[stage] = short ? .incomplete : .finished
            } else if let failedIndex, index < failedIndex {
                statuses[stage] = .finished
            } else {
                statuses[stage] = .notReached
            }
        }
        return statuses
    }

    private static func withoutManifest(
        runDirectoryExists: Bool,
        recordState: LibraryItemState,
        recordFailureMessage: String?,
        stages: [PipelineStage]
    ) -> RunOutcome {
        var statuses: [PipelineStage: RunStageStatus] = [:]
        for stage in stages { statuses[stage] = .notReached }
        // A run the operator stopped, or one the app was quit out from under,
        // has a known ending. Nothing here should invent a failure for it.
        guard recordState != .cancelled, recordState != .interrupted else {
            return RunOutcome(
                completion: .canceled,
                cause: nil,
                failedStage: nil,
                stageStatuses: statuses,
                coverage: nil,
                detail: nil
            )
        }
        // The engine never wrote a manifest, so the structure of the run
        // directory decides the cause. The app-side message is English only
        // when it comes from the engine, so it may narrow the cause but never
        // sets it on its own.
        let narrowed = recordFailureMessage
            .flatMap { message -> RunFailureCause? in
                guard !message.isEmpty else { return nil }
                let cause = RunFailureCause.classify(code: "", message: message)
                return cause == .unspecified ? nil : cause
            }
        statuses[.preparing] = .failed
        return RunOutcome(
            completion: runDirectoryExists ? .unreadable : .failed,
            cause: narrowed
                ?? (runDirectoryExists ? .unreadableRunRecord : .missingFile),
            failedStage: .preparing,
            stageStatuses: statuses,
            coverage: nil,
            detail: sanitizedDetail(recordFailureMessage)
        )
    }

    private static var runIDPattern: Regex<Substring> {
        /[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}/
    }

    private static var hexTokenPattern: Regex<Substring> {
        /\b[0-9a-f]{32,}\b/
    }

    private static var runAnnotationPattern: Regex<Substring> {
        /\ *\[run: [^\]]*\]/
    }

    /// Strip the identifiers the failure screen must never show: the run
    /// directory the engine appends to a thrown error, run IDs, and any
    /// SHA-256 or revision hex token.
    static func sanitizedDetail(_ message: String?) -> String? {
        guard let message else { return nil }
        var text = message.replacing(runAnnotationPattern, with: "")
        text = text.replacing(runIDPattern, with: "…")
        text = text.replacing(hexTokenPattern, with: "…")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension RunOutcome {
    /// Read a run directory's own account of its outcome. Reading only: it
    /// opens `manifest.json` and `primary/partial-coverage.json` and changes
    /// nothing in a preserved run.
    static func load(
        runURL: URL?,
        recordState: LibraryItemState,
        recordFailureMessage: String? = nil,
        postprocessRequested: Bool = false
    ) -> RunOutcome {
        guard let runURL else {
            return make(
                manifest: nil,
                runDirectoryExists: false,
                recordState: recordState,
                recordFailureMessage: recordFailureMessage,
                postprocessRequested: postprocessRequested
            )
        }
        return make(
            manifest: LibraryRepository.readManifest(at: runURL),
            partialCoverage: LibraryRepository.readPartialCoverage(at: runURL),
            runDirectoryExists: FileManager.default.fileExists(atPath: runURL.path),
            recordState: recordState,
            recordFailureMessage: recordFailureMessage,
            postprocessRequested: postprocessRequested
        )
    }
}

extension LibraryRepository {
    /// The same reading, inside this library's security-scoped access to its
    /// runs root.
    func runOutcome(
        at runURL: URL,
        recordState: LibraryItemState,
        recordFailureMessage: String? = nil,
        postprocessRequested: Bool = false
    ) -> RunOutcome {
        let access = (try? beginAccessingRunsRoot()) ?? nil
        defer { access?.end() }
        return RunOutcome.load(
            runURL: runURL,
            recordState: recordState,
            recordFailureMessage: recordFailureMessage,
            postprocessRequested: postprocessRequested
        )
    }

    static func readManifest(at runURL: URL) -> Manifest? {
        guard let data = try? Data(
            contentsOf: runURL.appendingPathComponent("manifest.json")
        ) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    static func readPartialCoverage(at runURL: URL) -> RunPartialCoverage? {
        guard let data = try? Data(
            contentsOf: runURL.appendingPathComponent("primary/partial-coverage.json")
        ) else { return nil }
        return try? JSONDecoder().decode(RunPartialCoverage.self, from: data)
    }
}
