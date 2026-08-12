import CryptoKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess

enum LibraryRepositoryError: Error, LocalizedError {
    case unsafeArtifactPath(String)
    case artifactMissing(String)
    case artifactHashMismatch(String)
    case derivedManifestInvalid(String)
    case derivedLineageMismatch(String)
    case originalUnavailable

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
        }
    }
}

private struct VerifiedDerivedResult {
    var directory: URL
    var manifest: DerivedManifest
    var finishedAt: Date
    var loaded: LoadedRun
}

private struct VerifiedArtifactData {
    var url: URL
    var data: Data
}

enum LibraryStorageSettings {
    static let recordingsDirectoryKey = "maccheroni.storage.recordingsDirectory"
    static let runsDirectoryKey = "maccheroni.storage.runsDirectory"
    static let localPostprocessModelKey = "maccheroni.postprocess.localModel"
    static let libraryRootEnvironmentKey = "MACCHERONI_LIBRARY_ROOT"

    static func defaultLibraryRoot(
        applicationSupportDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("Maccheroni", isDirectory: true)
            .standardizedFileURL
    }

    static func normalizedDirectoryURL(storedPath: String?) -> URL? {
        guard let storedPath,
              !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (storedPath as NSString).isAbsolutePath
        else {
            return nil
        }
        return URL(fileURLWithPath: storedPath, isDirectory: true).standardizedFileURL
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
        }
    )
}

struct LibraryRepository: Sendable {
    let root: URL
    let runsRoot: URL
    let recordingsRoot: URL
    private let bookmarkAccess: LibraryBookmarkAccess
    private let onDerivedArtifactVerified: @Sendable (URL) throws -> Void

    var indexURL: URL { root.appendingPathComponent("library.json") }
    var requestsRoot: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    var glossariesRoot: URL { root.appendingPathComponent("Glossaries", isDirectory: true) }

    init(
        root: URL,
        runsRoot: URL? = nil,
        recordingsRoot: URL? = nil,
        bookmarkAccess: LibraryBookmarkAccess = .system,
        onDerivedArtifactVerified: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        let standardizedRoot = root.standardizedFileURL
        self.root = standardizedRoot
        self.runsRoot = (runsRoot
            ?? standardizedRoot.appendingPathComponent("Runs", isDirectory: true))
            .standardizedFileURL
        self.recordingsRoot = (recordingsRoot
            ?? standardizedRoot.appendingPathComponent("Recordings", isDirectory: true))
            .standardizedFileURL
        self.bookmarkAccess = bookmarkAccess
        self.onDerivedArtifactVerified = onDerivedArtifactVerified
    }

    static var local: LibraryRepository {
        resolve(
            applicationSupportDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true),
            environment: ProcessInfo.processInfo.environment,
            recordingsPath: UserDefaults.standard.string(
                forKey: LibraryStorageSettings.recordingsDirectoryKey
            ),
            runsPath: UserDefaults.standard.string(forKey: LibraryStorageSettings.runsDirectoryKey)
        )
    }

    static func resolve(
        applicationSupportDirectory: URL,
        environment: [String: String],
        recordingsPath: String?,
        runsPath: String?
    ) -> LibraryRepository {
        let defaultRoot = LibraryStorageSettings.defaultLibraryRoot(
            applicationSupportDirectory: applicationSupportDirectory
        )
        if let overriddenRoot = LibraryStorageSettings.environmentLibraryRoot(
            environment: environment
        ) {
            return LibraryRepository(root: overriddenRoot)
        }
        return LibraryRepository(
            root: defaultRoot,
            runsRoot: LibraryStorageSettings.normalizedDirectoryURL(storedPath: runsPath),
            recordingsRoot: LibraryStorageSettings.normalizedDirectoryURL(storedPath: recordingsPath)
        )
    }

    func prepareDirectories() throws {
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

    func bookmark(for url: URL) throws -> Data {
        try bookmarkAccess.create(url)
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
            segments: segments
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

        let verifiedSource = try RunIntegrityVerifier.verifyCompletedRun(at: sourceRunURL)
        var results: [VerifiedDerivedResult] = []
        for directory in directories {
            if let result = try loadVerifiedDerivedResult(
                at: directory,
                source: verifiedSource,
                canonicalConflicts: canonicalConflicts
            ) {
                results.append(result)
            }
        }
        results.sort {
            if $0.finishedAt == $1.finishedAt { return $0.manifest.derivedID > $1.manifest.derivedID }
            return $0.finishedAt > $1.finishedAt
        }
        guard let freshest = results.first else { return sourceResult }

        let summaries = results.map { result in
            DerivedResultSummary(
                id: result.manifest.derivedID,
                createdAt: result.finishedAt,
                operation: result.manifest.operation.mode,
                targetLanguage: result.manifest.operation.targetLanguage,
                glossarySHA256: result.manifest.operation.glossarySHA256,
                directory: result.directory,
                isCurrent: result.manifest.derivedID == freshest.manifest.derivedID
            )
        }
        var loaded = freshest.loaded
        loaded.derivedResults = summaries
        return loaded
    }

    private func loadVerifiedDerivedResult(
        at directory: URL,
        source: VerifiedRunSource,
        canonicalConflicts: [MergeConflict]
    ) throws -> VerifiedDerivedResult? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifest: DerivedManifest
        do {
            manifest = try JSONDecoder().decode(
                DerivedManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw LibraryRepositoryError.derivedManifestInvalid(directory.lastPathComponent)
        }
        guard manifest.derivedID == directory.lastPathComponent,
              manifest.schemaVersion == MaccheroniSchema.version
        else {
            throw LibraryRepositoryError.derivedManifestInvalid(directory.lastPathComponent)
        }
        guard manifest.status == .succeeded, manifest.failure == nil else { return nil }
        let sourceHashMatches = manifest.operation.mode == .translation
            ? postprocessSourceHash(manifest) == source.lineage.segmentsSHA256
            : postprocessSourceHash(manifest) == nil
        let glossaryIsConsistent = manifest.operation.glossarySHA256 == nil
            ? manifest.operation.glossaryItemCount == 0
            : manifest.operation.glossaryItemCount > 0
        // Switch rather than compare, so a new semantics case cannot be
        // accepted here without a deliberate decision.
        let glossarySemanticsIsLoadable: Bool
        switch manifest.operation.glossarySemantics {
        case .currentProfile, .sourceRun:
            glossarySemanticsIsLoadable = true
        }
        guard manifest.source == source.lineage,
              manifest.source.segmentsPath == "merged/segments.json",
              !manifest.operation.profileName
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              glossarySemanticsIsLoadable,
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

        var document = source.document
        var conflicts = canonicalConflicts
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
        guard let finishedAt = derivedDate(manifest.timing.finishedAt) else {
            throw LibraryRepositoryError.derivedManifestInvalid(manifest.derivedID)
        }
        return VerifiedDerivedResult(
            directory: directory,
            manifest: manifest,
            finishedAt: finishedAt,
            loaded: LoadedRun(
                manifest: source.manifest,
                transcript: document,
                conflicts: conflicts,
                segments: segments,
                resultID: manifest.derivedID,
                resultPostprocess: postprocess,
                resultOperation: manifest.operation
            )
        )
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
