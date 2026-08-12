import CryptoKit
import Foundation

public enum DerivedGlossarySemantics: String, Codable, Equatable, Sendable {
    case currentProfile = "current-profile"
}

public struct DerivedSourceLineage: Codable, Equatable, Sendable {
    public var runID: String
    public var manifestSHA256: String
    public var segmentsPath: String
    public var segmentsSHA256: String

    public init(
        runID: String,
        manifestSHA256: String,
        segmentsPath: String,
        segmentsSHA256: String
    ) {
        self.runID = runID
        self.manifestSHA256 = manifestSHA256
        self.segmentsPath = segmentsPath
        self.segmentsSHA256 = segmentsSHA256
    }

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case manifestSHA256 = "manifest_sha256"
        case segmentsPath = "segments_path"
        case segmentsSHA256 = "segments_sha256"
    }
}

public struct DerivedOperation: Codable, Equatable, Sendable {
    public var profileName: String
    public var mode: PostprocessMode
    public var targetLanguage: String?
    public var glossarySemantics: DerivedGlossarySemantics
    public var glossarySHA256: String?
    public var glossaryItemCount: Int

    public init(
        profileName: String,
        mode: PostprocessMode,
        targetLanguage: String? = nil,
        glossarySemantics: DerivedGlossarySemantics,
        glossarySHA256: String? = nil,
        glossaryItemCount: Int
    ) {
        self.profileName = profileName
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.glossarySemantics = glossarySemantics
        self.glossarySHA256 = glossarySHA256
        self.glossaryItemCount = glossaryItemCount
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case profileName = "profile_name"
        case targetLanguage = "target_language"
        case glossarySemantics = "glossary_semantics"
        case glossarySHA256 = "glossary_sha256"
        case glossaryItemCount = "glossary_item_count"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileName, forKey: .profileName)
        try container.encode(mode, forKey: .mode)
        try container.encode(targetLanguage, forKey: .targetLanguage)
        try container.encode(glossarySemantics, forKey: .glossarySemantics)
        try container.encode(glossarySHA256, forKey: .glossarySHA256)
        try container.encode(glossaryItemCount, forKey: .glossaryItemCount)
    }
}

public struct DerivedManifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var derivedID: String
    public var status: RunStatus
    public var source: DerivedSourceLineage
    public var operation: DerivedOperation
    public var timing: RunTiming
    public var artifacts: [Artifact]
    public var failure: Failure?
    public var postprocess: ManifestPostprocess?

    public init(
        schemaVersion: String = MaccheroniSchema.version,
        derivedID: String,
        status: RunStatus,
        source: DerivedSourceLineage,
        operation: DerivedOperation,
        timing: RunTiming,
        artifacts: [Artifact],
        failure: Failure?,
        postprocess: ManifestPostprocess?
    ) {
        self.schemaVersion = schemaVersion
        self.derivedID = derivedID
        self.status = status
        self.source = source
        self.operation = operation
        self.timing = timing
        self.artifacts = artifacts
        self.failure = failure
        self.postprocess = postprocess
    }

    enum CodingKeys: String, CodingKey {
        case status, source, operation, timing, artifacts, failure, postprocess
        case schemaVersion = "schema_version"
        case derivedID = "derived_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(derivedID, forKey: .derivedID)
        try container.encode(status, forKey: .status)
        try container.encode(source, forKey: .source)
        try container.encode(operation, forKey: .operation)
        try container.encode(timing, forKey: .timing)
        try container.encode(artifacts, forKey: .artifacts)
        try container.encode(failure, forKey: .failure)
        try container.encode(postprocess, forKey: .postprocess)
    }
}

public struct VerifiedRunSource: Sendable {
    public var runURL: URL
    public var manifest: Manifest
    public var document: SegmentsDocument
    public var lineage: DerivedSourceLineage
    public var verifiedArtifacts: [Artifact]

    public init(
        runURL: URL,
        manifest: Manifest,
        document: SegmentsDocument,
        lineage: DerivedSourceLineage,
        verifiedArtifacts: [Artifact]
    ) {
        self.runURL = runURL
        self.manifest = manifest
        self.document = document
        self.lineage = lineage
        self.verifiedArtifacts = verifiedArtifacts
    }
}

public enum RunIntegrityError: Error, Equatable, Sendable, LocalizedError {
    case manifestMissing
    case manifestInvalid
    case runIDMismatch(expected: String, actual: String)
    case sourceRunNotComplete
    case duplicateArtifactPath(String)
    case unsafeArtifactPath(String)
    case artifactMissing(String)
    case artifactHashMismatch(String)
    case mergedSegmentsMissing
    case mergedSegmentsDuplicate
    case mergedSegmentsInvalid
    case mergedSegmentsSourceMismatch
    case sourceChangedDuringOperation

    public var errorDescription: String? {
        switch self {
        case .manifestMissing:
            "The source run manifest is missing."
        case .manifestInvalid:
            "The source run manifest is invalid."
        case let .runIDMismatch(expected, actual):
            "The source run ID does not match its directory (expected \(expected), got \(actual))."
        case .sourceRunNotComplete:
            "The source run is not a verified complete run."
        case let .duplicateArtifactPath(path):
            "The source run manifest repeats an artifact path: \(path)"
        case let .unsafeArtifactPath(path):
            "The source run manifest contains an unsafe artifact path: \(path)"
        case let .artifactMissing(path):
            "A source run artifact is missing: \(path)"
        case let .artifactHashMismatch(path):
            "A source run artifact failed its integrity check: \(path)"
        case .mergedSegmentsMissing:
            "The source run has no merged transcript artifact."
        case .mergedSegmentsDuplicate:
            "The source run has more than one merged transcript artifact."
        case .mergedSegmentsInvalid:
            "The source run merged transcript is invalid."
        case .mergedSegmentsSourceMismatch:
            "The source run merged transcript does not match the manifest input."
        case .sourceChangedDuringOperation:
            "The source run changed while the derived operation was running."
        }
    }
}

public enum RunIntegrityVerifier {
    public static func verifyCompletedRun(at runURL: URL) throws -> VerifiedRunSource {
        let runURL = runURL.standardizedFileURL
        let manifestURL = runURL.appendingPathComponent("manifest.json")
        guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
            throw RunIntegrityError.manifestMissing
        }
        let manifestData: Data
        let manifest: Manifest
        do {
            manifestData = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw RunIntegrityError.manifestInvalid
        }

        guard manifestIsSemanticallyValid(manifest) else {
            throw RunIntegrityError.manifestInvalid
        }
        guard manifest.runID == runURL.lastPathComponent else {
            throw RunIntegrityError.runIDMismatch(
                expected: runURL.lastPathComponent,
                actual: manifest.runID
            )
        }
        guard manifest.status == .succeeded,
              manifest.failure == nil,
              !manifest.coverage.truncated,
              abs(manifest.coverage.inputDurationS
                  - manifest.coverage.processedDurationS) <= 0.01,
              manifest.coverage.chunksPlanned
                  == manifest.coverage.chunksCompleted,
              manifest.chunkBoundaries.count
                  == manifest.coverage.chunksPlanned,
              manifest.chunkBoundaries.allSatisfy({ $0.status == .succeeded })
        else {
            throw RunIntegrityError.sourceRunNotComplete
        }

        let mergedArtifacts = manifest.artifacts.filter {
            $0.kind == "merged_segments"
        }
        guard !mergedArtifacts.isEmpty else {
            throw RunIntegrityError.mergedSegmentsMissing
        }
        guard mergedArtifacts.count == 1 else {
            throw RunIntegrityError.mergedSegmentsDuplicate
        }
        guard mergedArtifacts[0].path == "merged/segments.json" else {
            throw RunIntegrityError.mergedSegmentsInvalid
        }

        var paths = Set<String>()
        var artifactURLs: [String: URL] = [:]
        for artifact in manifest.artifacts {
            guard !artifact.kind.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
                  isLowercaseSHA256(artifact.sha256)
            else {
                throw RunIntegrityError.manifestInvalid
            }
            guard paths.insert(artifact.path).inserted else {
                throw RunIntegrityError.duplicateArtifactPath(artifact.path)
            }
            let artifactURL = try verifiedArtifactURL(
                artifact.path,
                runURL: runURL
            )
            guard try sha256(of: artifactURL) == artifact.sha256 else {
                throw RunIntegrityError.artifactHashMismatch(artifact.path)
            }
            artifactURLs[artifact.path] = artifactURL
        }

        let mergedArtifact = mergedArtifacts[0]
        guard let mergedURL = artifactURLs[mergedArtifact.path] else {
            throw RunIntegrityError.artifactMissing(mergedArtifact.path)
        }
        let document: SegmentsDocument
        do {
            document = try JSONDecoder().decode(
                SegmentsDocument.self,
                from: Data(contentsOf: mergedURL)
            )
        } catch {
            throw RunIntegrityError.mergedSegmentsInvalid
        }
        guard document.schemaVersion == MaccheroniSchema.version,
              document.source.fileName == manifest.input.fileName,
              document.source.sha256 == manifest.input.sha256,
              isLowercaseSHA256(document.source.sha256),
              document.source.durationS.isFinite,
              document.source.durationS > 0,
              abs(document.source.durationS
                  - manifest.coverage.inputDurationS) <= 0.01,
              segmentsAreSemanticallyValid(document)
        else {
            throw RunIntegrityError.mergedSegmentsSourceMismatch
        }

        return VerifiedRunSource(
            runURL: runURL,
            manifest: manifest,
            document: document,
            lineage: DerivedSourceLineage(
                runID: manifest.runID,
                manifestSHA256: sha256(data: manifestData),
                segmentsPath: mergedArtifact.path,
                segmentsSHA256: mergedArtifact.sha256
            ),
            verifiedArtifacts: manifest.artifacts
        )
    }

    public static func sha256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RunIntegrityError.artifactMissing(url.lastPathComponent)
        }
        defer { try? handle.close() }
        var digest = SHA256()
        do {
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                guard !data.isEmpty else { break }
                digest.update(data: data)
            }
        } catch {
            throw RunIntegrityError.artifactMissing(url.lastPathComponent)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verifiedArtifactURL(
        _ relative: String,
        runURL: URL
    ) throws -> URL {
        guard !relative.isEmpty,
              !(relative as NSString).isAbsolutePath,
              !relative.contains("\\"),
              !relative.split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else {
            throw RunIntegrityError.unsafeArtifactPath(relative)
        }
        let unresolved = runURL.appendingPathComponent(relative)
            .standardizedFileURL
        let root = runURL.resolvingSymlinksInPath().standardizedFileURL
        let resolved = unresolved.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw RunIntegrityError.unsafeArtifactPath(relative)
        }
        let values: URLResourceValues
        do {
            values = try unresolved.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw RunIntegrityError.artifactMissing(relative)
        }
        guard values.isSymbolicLink != true else {
            throw RunIntegrityError.unsafeArtifactPath(relative)
        }
        guard values.isRegularFile == true else {
            throw RunIntegrityError.artifactMissing(relative)
        }
        return unresolved
    }

    private static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }

    private static func manifestIsSemanticallyValid(_ manifest: Manifest) -> Bool {
        guard manifest.schemaVersion == MaccheroniSchema.version,
              manifest.runID.range(
                  of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
                  options: .regularExpression
              ) != nil,
              !manifest.input.fileName.isEmpty,
              !manifest.input.fileName.contains("/"),
              !manifest.input.fileName.contains("\\"),
              isLowercaseSHA256(manifest.input.sha256),
              manifest.input.sizeBytes >= 0,
              !manifest.backend.name.isEmpty,
              !manifest.backend.version.isEmpty,
              !manifest.models.isEmpty,
              manifest.preprocessing.sampleRateHz > 0,
              manifest.preprocessing.channels > 0,
              manifest.coverage.inputDurationS.isFinite,
              manifest.coverage.inputDurationS > 0,
              manifest.coverage.processedDurationS.isFinite,
              manifest.coverage.processedDurationS >= 0,
              manifest.coverage.processedDurationS
                  <= manifest.coverage.inputDurationS + 0.01,
              manifest.coverage.chunksPlanned >= 0,
              manifest.coverage.chunksCompleted >= 0,
              manifest.coverage.chunksCompleted
                  <= manifest.coverage.chunksPlanned,
              manifest.timing.wallTimeS.isFinite,
              manifest.timing.wallTimeS >= 0,
              glossaryIsSemanticallyValid(manifest.glossary)
        else {
            return false
        }
        if let postprocess = manifest.postprocess {
            guard postprocessIsSemanticallyValid(postprocess) else {
                return false
            }
        }
        var previous: ChunkBoundary?
        for (expectedIndex, chunk) in manifest.chunkBoundaries.enumerated() {
            guard chunk.index == expectedIndex,
                  chunk.startS.isFinite,
                  chunk.endS.isFinite,
                  chunk.startS >= 0,
                  chunk.endS > chunk.startS,
                  chunk.endS <= manifest.coverage.inputDurationS + 0.01
            else {
                return false
            }
            if let previous,
               chunk.startS < previous.startS
                || (chunk.startS == previous.startS
                    && chunk.endS < previous.endS)
            {
                return false
            }
            previous = chunk
        }
        return true
    }

    private static func postprocessIsSemanticallyValid(
        _ postprocess: ManifestPostprocess
    ) -> Bool {
        guard !postprocess.backend.name.isEmpty,
              !postprocess.backend.version.isEmpty,
              !postprocess.modelID.isEmpty,
              postprocess.glossarySHA256.map(isLowercaseSHA256) ?? true,
              postprocess.sourceSegmentsSHA256.map(isLowercaseSHA256) ?? true
        else {
            return false
        }
        guard let batching = postprocess.batching else { return true }
        guard batching.maximumPromptUTF8Bytes > 0,
              batching.maximumSegmentsPerBatch > 0,
              batching.maximumOutputTokens.map({ $0 > 0 }) ?? true,
              batching.outputTokenPlanningBudget > 0,
              batching.outputTokensPerInputUTF8BytePermille > 0,
              batching.baseOutputTokenReserve >= 0,
              batching.perSegmentOutputTokenReserve >= 0,
              batching.batchesPlanned > 0,
              batching.maximumObservedPromptUTF8Bytes > 0,
              batching.maximumObservedInputTextUTF8Bytes >= 0,
              batching.maximumObservedEstimatedOutputTokens > 0,
              batching.maximumObservedOutputTextUTF8Bytes >= 0,
              batching.maximumObservedResponseUTF8Bytes > 0,
              batching.maximumObservedAcceptedOutputTokenUpperBound >= 0
        else {
            return false
        }

        let hardLimit = batching.maximumOutputTokens
        let hasConfiguredHardLimit =
            batching.outputTokenLimitStatus == .configured
        guard hasConfiguredHardLimit == (hardLimit != nil),
              hardLimit.map({ batching.outputTokenPlanningBudget <= $0 }) ?? true,
              batching.maximumObservedPromptUTF8Bytes
                  <= batching.maximumPromptUTF8Bytes,
              batching.maximumObservedEstimatedOutputTokens
                  <= batching.outputTokenPlanningBudget,
              batching.maximumObservedAcceptedOutputTokenUpperBound
                  <= batching.outputTokenPlanningBudget,
              batching.maximumObservedResponseUTF8Bytes
                  >= batching.maximumObservedOutputTextUTF8Bytes
        else {
            return false
        }
        return true
    }

    private static func glossaryIsSemanticallyValid(
        _ glossary: ManifestGlossary
    ) -> Bool {
        guard glossary.itemCount >= 0 else { return false }
        if glossary.provided {
            return glossary.itemCount > 0
                && glossary.sha256.map(isLowercaseSHA256) == true
                && glossary.injectionMode != .none
        }
        return glossary.sha256 == nil
            && glossary.itemCount == 0
            && glossary.injectionMode == .none
            && !glossary.applied
    }

    private static func segmentsAreSemanticallyValid(
        _ document: SegmentsDocument
    ) -> Bool {
        var previous: Segment?
        var speakers = Set<String>()
        for segment in document.segments {
            guard segment.startS.isFinite,
                  segment.endS.isFinite,
                  segment.endS > segment.startS,
                  segment.startS >= 0,
                  segment.endS <= document.source.durationS + 0.01,
                  !segment.speaker.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  !segment.text.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty
            else {
                return false
            }
            if let previous,
               segment.startS < previous.startS
                || (segment.startS == previous.startS
                    && segment.endS < previous.endS)
            {
                return false
            }
            if !["UNASSIGNED", "UNKNOWN"].contains(segment.speaker) {
                speakers.insert(segment.speaker)
            }
            previous = segment
        }
        return document.numSpeakers == speakers.count
    }
}
