import CryptoKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess

enum LibraryRepositoryError: Error, LocalizedError {
    case unsafeArtifactPath(String)
    case artifactMissing(String)
    case artifactHashMismatch(String)
    case originalUnavailable

    var errorDescription: String? {
        switch self {
        case let .unsafeArtifactPath(path):
            appString("The run contains an unsafe artifact path: \(path)")
        case let .artifactMissing(path):
            appString("A run artifact is missing: \(path)")
        case let .artifactHashMismatch(path):
            appString("A run artifact failed its integrity check: \(path)")
        case .originalUnavailable:
            appString("The original audio is not available.")
        }
    }
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

    var indexURL: URL { root.appendingPathComponent("library.json") }
    var requestsRoot: URL { root.appendingPathComponent("Requests", isDirectory: true) }
    var glossariesRoot: URL { root.appendingPathComponent("Glossaries", isDirectory: true) }

    init(
        root: URL,
        runsRoot: URL? = nil,
        recordingsRoot: URL? = nil,
        bookmarkAccess: LibraryBookmarkAccess = .system
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
        var transcript = try JSONDecoder().decode(
            SegmentsDocument.self,
            from: Data(contentsOf: segmentsArtifact)
        )
        var mergedTranscript: SegmentsDocument?
        if postprocessMode == .correction {
            let merged = try JSONDecoder().decode(
                SegmentsDocument.self,
                from: Data(contentsOf: mergedSegmentsArtifact)
            )
            mergedTranscript = merged
        }
        var conflicts = try JSONDecoder().decode(
            [MergeConflict].self,
            from: Data(contentsOf: conflictsArtifact)
        )
        if postprocessMode == .correction {
            let postprocessConflictsArtifact = try requiredArtifact(
                kind: "postprocess_conflicts",
                manifest: manifest,
                runURL: runURL
            )
            let postprocessConflicts = try JSONDecoder().decode(
                [PostprocessConflict].self,
                from: Data(contentsOf: postprocessConflictsArtifact)
            )
            guard let mergedTranscript else {
                throw LibraryRepositoryError.artifactMissing("merged_segments")
            }
            try validatePostprocess(
                transcript,
                against: mergedTranscript,
                conflicts: postprocessConflicts,
                artifactName: segmentsArtifact.lastPathComponent
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
                from: Data(contentsOf: translationArtifact)
            )
            try validateTranslation(
                translation,
                against: transcript,
                provenance: provenance,
                sourceSegmentsSHA256: mergedArtifact.sha256,
                artifactName: translationArtifact.lastPathComponent
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
        return LoadedRun(
            manifest: manifest,
            transcript: transcript,
            conflicts: conflicts,
            segments: segments
        )
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
    ) throws -> URL {
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
        let digest = SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == artifact.sha256 else {
            throw LibraryRepositoryError.artifactHashMismatch(relative)
        }
        return url
    }
}
