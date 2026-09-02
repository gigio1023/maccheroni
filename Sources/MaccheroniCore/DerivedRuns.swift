import CryptoKit
import Foundation

public enum DerivedGlossarySemantics: String, Codable, Equatable, Sendable {
    case currentProfile = "current-profile"
    case sourceRun = "source-run"
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

/// How much of the source run's input its transcript actually covers.
///
/// A derived run over an incomplete transcript must record which range is
/// missing. A bare "incomplete" flag is not enough for that: a reader
/// deciding whether to trust a speaker proposal needs to know it was made over
/// 1212.52 s of 1243.08 s with 30.56 s missing, and which range went missing.
/// So the durations and the source run's own coverage message travel with the
/// flag, in the derived manifest and again in the derived artifact.
public struct DerivedSourceCoverage: Codable, Equatable, Sendable {
    public var complete: Bool
    public var inputDurationS: Double
    public var processedDurationS: Double
    /// `inputDurationS - processedDurationS`, never negative.
    public var missingDurationS: Double
    /// The source run's coverage message, which names the lost ranges when
    /// there are any.
    public var message: String?

    public init(
        complete: Bool,
        inputDurationS: Double,
        processedDurationS: Double,
        message: String?
    ) {
        self.complete = complete
        self.inputDurationS = inputDurationS
        self.processedDurationS = processedDurationS
        missingDurationS = max(0, inputDurationS - processedDurationS)
        self.message = message
    }

    public init(coverage: Coverage, complete: Bool) {
        self.init(
            complete: complete,
            inputDurationS: coverage.inputDurationS,
            processedDurationS: coverage.processedDurationS,
            message: coverage.message
        )
    }

    enum CodingKeys: String, CodingKey {
        case complete, message
        case inputDurationS = "input_duration_s"
        case processedDurationS = "processed_duration_s"
        case missingDurationS = "missing_duration_s"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        complete = try container.decode(Bool.self, forKey: .complete)
        inputDurationS = try container.decode(Double.self, forKey: .inputDurationS)
        processedDurationS = try container.decode(
            Double.self,
            forKey: .processedDurationS
        )
        // Recomputed rather than trusted, so the difference and the durations
        // can never disagree in a file someone edited.
        missingDurationS = max(0, inputDurationS - processedDurationS)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

/// What family of derived run this is.
///
/// `mode` says which *text* operation ran, and every derived run that existed
/// before 2026-09-02 was one of those two. A speaker proposal is not a text
/// operation at all, so it needs its own discriminator rather than a third
/// `PostprocessMode`: `ManifestPostprocess.mode` is non-optional, so every
/// derived manifest carries a `mode` whether or not text was touched. Read
/// `kind` to decide what a derived run produced; read `mode` only after `kind`
/// says a text operation ran.
public enum DerivedOperationKind: String, Codable, Equatable, Sendable {
    /// Correction or translation of the source transcript's text. `mode` is
    /// meaningful.
    case textPostprocess = "text-postprocess"
    /// A marked, non-acoustic speaker proposal over segments the source run
    /// left unattributed. `mode` carries no meaning here.
    case speakerProposal = "speaker-proposal"
}

public struct DerivedOperation: Codable, Equatable, Sendable {
    public var profileName: String
    /// Which text operation ran. Meaningful only when `kind` is
    /// `.textPostprocess`; see `DerivedOperationKind`.
    public var mode: PostprocessMode
    public var targetLanguage: String?
    public var glossarySemantics: DerivedGlossarySemantics
    public var glossarySHA256: String?
    public var glossaryItemCount: Int
    /// Absent in manifests written before 2026-09-02, which were all text
    /// operations, so a missing value decodes as `.textPostprocess`.
    public var kind: DerivedOperationKind
    /// How much of the source run's input its transcript covers. Absent only in
    /// manifests written before 2026-09-02, every one of which came from a
    /// completed run.
    public var sourceCoverage: DerivedSourceCoverage?
    /// Whether the source run's ASR coverage was complete. A projection of
    /// `sourceCoverage`, so the flag and the durations can never disagree.
    public var sourceCoverageComplete: Bool {
        sourceCoverage?.complete ?? true
    }

    public init(
        profileName: String,
        mode: PostprocessMode,
        targetLanguage: String? = nil,
        glossarySemantics: DerivedGlossarySemantics,
        glossarySHA256: String? = nil,
        glossaryItemCount: Int,
        kind: DerivedOperationKind = .textPostprocess,
        sourceCoverage: DerivedSourceCoverage? = nil
    ) {
        self.profileName = profileName
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.glossarySemantics = glossarySemantics
        self.glossarySHA256 = glossarySHA256
        self.glossaryItemCount = glossaryItemCount
        self.kind = kind
        self.sourceCoverage = sourceCoverage
    }

    enum CodingKeys: String, CodingKey {
        case mode, kind
        case profileName = "profile_name"
        case targetLanguage = "target_language"
        case glossarySemantics = "glossary_semantics"
        case glossarySHA256 = "glossary_sha256"
        case glossaryItemCount = "glossary_item_count"
        case sourceCoverage = "source_coverage"
        case sourceCoverageComplete = "source_coverage_complete"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileName = try container.decode(String.self, forKey: .profileName)
        mode = try container.decode(PostprocessMode.self, forKey: .mode)
        targetLanguage = try container.decodeIfPresent(
            String.self,
            forKey: .targetLanguage
        )
        glossarySemantics = try container.decode(
            DerivedGlossarySemantics.self,
            forKey: .glossarySemantics
        )
        glossarySHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .glossarySHA256
        )
        glossaryItemCount = try container.decode(
            Int.self,
            forKey: .glossaryItemCount
        )
        kind = try container.decodeIfPresent(
            DerivedOperationKind.self,
            forKey: .kind
        ) ?? .textPostprocess
        sourceCoverage = try container.decodeIfPresent(
            DerivedSourceCoverage.self,
            forKey: .sourceCoverage
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profileName, forKey: .profileName)
        try container.encode(mode, forKey: .mode)
        try container.encode(targetLanguage, forKey: .targetLanguage)
        try container.encode(glossarySemantics, forKey: .glossarySemantics)
        try container.encode(glossarySHA256, forKey: .glossarySHA256)
        try container.encode(glossaryItemCount, forKey: .glossaryItemCount)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(sourceCoverage, forKey: .sourceCoverage)
        // Written even when `source_coverage` is, and read back through it, so
        // a reader skimming the manifest cannot miss an incomplete source.
        try container.encode(sourceCoverageComplete, forKey: .sourceCoverageComplete)
    }
}

/// One global speaker that overlapped an unattributed segment, with how much of
/// the segment it held.
///
/// This mirrors `MaccheroniMerge.SpeakerCandidate` field for field, including
/// its JSON keys, because it carries exactly those numbers onwards. It is
/// declared here rather than imported because `MaccheroniPostprocess` does not
/// depend on `MaccheroniMerge`, and because a derived artifact should not make
/// its reader link the merger to decode it.
public struct SpeakerCandidateEvidence: Codable, Equatable, Sendable {
    public var speaker: String
    /// Union of that speaker's turns clipped to the segment, in seconds.
    public var overlapS: Double
    /// That speaker's fraction of the segment's total clipped overlap time.
    /// Shares over all candidates sum to 1.
    public var share: Double

    public init(speaker: String, overlapS: Double, share: Double) {
        self.speaker = speaker
        self.overlapS = overlapS
        self.share = share
    }

    enum CodingKeys: String, CodingKey {
        case speaker, share
        case overlapS = "overlap_s"
    }
}

/// What the acoustics said about one segment: which speakers were candidates,
/// for how long each, how much of the interval the timeline covered, and why
/// no speaker was named. This is the disclosure P1 added to
/// `merged/conflicts.json`, restated as the input a non-acoustic proposer reads
/// and as the evidence that travels beside every proposal it makes.
public struct SegmentSpeakerEvidence: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    /// One of `MaccheroniMerge.SpeakerAttributionOutcome`'s raw values, carried
    /// as text so this contract does not fix the merger's enum.
    public var outcome: String
    /// Ordered by descending overlap, ties by ascending speaker ID. Empty only
    /// when no diarization turn overlapped the segment at all.
    public var candidates: [SpeakerCandidateEvidence]
    /// Union of every clipped turn over the segment's duration, in `0...1`.
    public var timelineCoverage: Double

    public init(
        segmentIndex: Int,
        outcome: String,
        candidates: [SpeakerCandidateEvidence],
        timelineCoverage: Double
    ) {
        self.segmentIndex = segmentIndex
        self.outcome = outcome
        self.candidates = candidates
        self.timelineCoverage = timelineCoverage
    }

    enum CodingKeys: String, CodingKey {
        case outcome, candidates
        case segmentIndex = "segment_index"
        case timelineCoverage = "timeline_coverage"
    }
}

/// The speaker labels a merged transcript uses when it declines to name a
/// speaker. A derived proposal may only cover segments carrying one of these.
public enum UnattributedSpeaker {
    public static let labels: [String] = ["UNASSIGNED", "UNKNOWN"]

    public static func isUnattributed(_ speaker: String) -> Bool {
        labels.contains(speaker)
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
    /// How much of the input this run's transcript covers. Always complete for
    /// a source accepted by `verifyCompletedRun`; only `verifyMergedRun` can
    /// return an incomplete one.
    public var coverage: DerivedSourceCoverage

    public var coverageIsComplete: Bool { coverage.complete }

    public init(
        runURL: URL,
        manifest: Manifest,
        document: SegmentsDocument,
        lineage: DerivedSourceLineage,
        verifiedArtifacts: [Artifact],
        coverage: DerivedSourceCoverage
    ) {
        self.runURL = runURL
        self.manifest = manifest
        self.document = document
        self.lineage = lineage
        self.verifiedArtifacts = verifiedArtifacts
        self.coverage = coverage
    }
}

public enum RunArtifactContract {
    /// Contract tolerance for source-relative time ranges.
    public static let timeToleranceS = 0.01
}

public enum SegmentsDocumentContract {
    public static func decode(_ data: Data) throws -> SegmentsDocument {
        guard hasCanonicalJSONShape(data) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "segments document does not match segments.schema.json"
            ))
        }
        let document = try JSONDecoder().decode(SegmentsDocument.self, from: data)
        guard isValid(document) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "segments document violates segments.schema.json"
            ))
        }
        return document
    }

    public static func isValid(_ document: SegmentsDocument) -> Bool {
        guard document.schemaVersion == MaccheroniSchema.version,
              document.numSpeakers >= 0,
              !document.source.fileName.isEmpty,
              !document.source.fileName.contains("/"),
              !document.source.fileName.contains("\\"),
              RunIntegrityVerifier.isLowercaseSHA256(document.source.sha256),
              document.source.durationS.isFinite,
              document.source.durationS > 0
        else {
            return false
        }

        var previous: Segment?
        var speakers = Set<String>()
        for segment in document.segments {
            guard segment.startS.isFinite,
                  segment.endS.isFinite,
                  segment.endS > segment.startS,
                  segment.startS >= 0,
                  segment.endS <= document.source.durationS
                    + RunArtifactContract.timeToleranceS,
                  !segment.speaker.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  !segment.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty,
                  segment.language.map(isLanguageTag) ?? true,
                  segment.confidence.map({
                    $0.isFinite && (0 ... 1).contains($0)
                  }) ?? true,
                  flagsAreValid(segment.flags)
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

    private static func isLanguageTag(_ value: String) -> Bool {
        fullMatch(
            value,
            of: "^[A-Za-z]{2,3}([_-][A-Za-z0-9]{2,8})*$",
            options: .regularExpression
        )
    }

    private static func flagsAreValid(_ flags: [String]?) -> Bool {
        guard let flags else { return true }
        guard Set(flags).count == flags.count else { return false }
        return flags.allSatisfy {
            fullMatch(
                $0,
                of: "^[a-z][a-z0-9_-]*$",
                options: .regularExpression
            )
        }
    }

    private static func fullMatch(
        _ value: String,
        of pattern: String,
        options: String.CompareOptions
    ) -> Bool {
        value.range(of: pattern, options: options) == value.startIndex ..< value.endIndex
    }

    private static func hasCanonicalJSONShape(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any],
              Set(document.keys) == [
                "schema_version", "segments", "num_speakers", "source",
              ],
              let segments = document["segments"] as? [Any],
              let source = document["source"] as? [String: Any],
              Set(source.keys) == ["file_name", "sha256", "duration_s"]
        else {
            return false
        }
        let requiredSegmentKeys: Set<String> = [
            "speaker", "start_s", "end_s", "text",
        ]
        let allowedSegmentKeys = requiredSegmentKeys.union([
            "language", "confidence", "flags",
        ])
        return segments.allSatisfy { value in
            guard let segment = value as? [String: Any] else { return false }
            let keys = Set(segment.keys)
            return requiredSegmentKeys.isSubset(of: keys)
                && keys.isSubset(of: allowedSegmentKeys)
        }
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
    case requiredArtifactMissing(kind: String, path: String)
    case artifactInventoryMismatch(unlisted: [String], missing: [String])
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
        case let .requiredArtifactMissing(kind, path):
            "The source run is missing required artifact \(kind) at \(path)."
        case let .artifactInventoryMismatch(unlisted, missing):
            "The source run artifact inventory is incomplete (unlisted: \(unlisted), missing: \(missing))."
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
        try verifyCompletedRun(at: runURL, onArtifactVerified: nil)
    }

    static func verifyCompletedRun(
        at runURL: URL,
        onArtifactVerified: ((Artifact, URL) throws -> Void)?
    ) throws -> VerifiedRunSource {
        try verify(
            at: runURL,
            requiringCompleteCoverage: true,
            onArtifactVerified: onArtifactVerified
        )
    }

    /// Verify a run that finished its merge, whether or not ASR covered the
    /// whole input.
    ///
    /// Every integrity check `verifyCompletedRun` performs still runs: the
    /// manifest is semantically valid, its run ID matches the directory, every
    /// listed artifact exists and matches its hash, the directory holds nothing
    /// the manifest does not list, the required artifact set is present, and
    /// `merged/segments.json` decodes and agrees with the manifest's input. The
    /// one gate this drops is coverage completeness, so a run that reported
    /// `partial` with a named lost range is accepted and reported through
    /// `VerifiedRunSource.coverageIsComplete`.
    ///
    /// Correction and translation keep the stricter gate: they rewrite or
    /// mirror every segment, so a transcript with a hole in it would silently
    /// produce a set that claims coverage it does not have. A speaker proposal
    /// makes a per-segment claim about segments that exist, which a partial
    /// transcript can still support as long as the reader is told it is
    /// partial.
    public static func verifyMergedRun(at runURL: URL) throws -> VerifiedRunSource {
        try verify(
            at: runURL,
            requiringCompleteCoverage: false,
            onArtifactVerified: nil
        )
    }

    private static func verify(
        at runURL: URL,
        requiringCompleteCoverage: Bool,
        onArtifactVerified: ((Artifact, URL) throws -> Void)?
    ) throws -> VerifiedRunSource {
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
        let coverageIsComplete = manifest.status == .succeeded
            && manifest.failure == nil
            && !manifest.coverage.truncated
            && successfulCoverageIsComplete(manifest)
        guard successfulGlossaryIsValid(manifest.glossary) else {
            throw RunIntegrityError.sourceRunNotComplete
        }
        if requiringCompleteCoverage {
            guard coverageIsComplete else {
                throw RunIntegrityError.sourceRunNotComplete
            }
        } else {
            // A run that failed outright, or that a user canceled, never
            // reached a merge worth deriving from. Only a completed run and a
            // run that promoted what it could are sources.
            guard manifest.status == .succeeded || manifest.status == .partial,
                  manifest.coverage.processedDurationS > 0
            else {
                throw RunIntegrityError.sourceRunNotComplete
            }
        }

        try requireSuccessfulArtifactSet(manifest)

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
        var artifactData: [String: Data] = [:]
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
            let data: Data
            do {
                data = try Data(contentsOf: artifactURL)
            } catch {
                throw RunIntegrityError.artifactMissing(artifact.path)
            }
            guard sha256(data: data) == artifact.sha256 else {
                throw RunIntegrityError.artifactHashMismatch(artifact.path)
            }
            try onArtifactVerified?(artifact, artifactURL)
            artifactData[artifact.path] = data
        }

        let actualPaths = try regularSourceArtifactPaths(in: runURL)
        let unlisted = actualPaths.subtracting(paths).sorted()
        let missing = paths.subtracting(actualPaths).sorted()
        guard unlisted.isEmpty, missing.isEmpty else {
            throw RunIntegrityError.artifactInventoryMismatch(
                unlisted: unlisted,
                missing: missing
            )
        }

        let mergedArtifact = mergedArtifacts[0]
        guard let mergedData = artifactData[mergedArtifact.path] else {
            throw RunIntegrityError.artifactMissing(mergedArtifact.path)
        }
        let document: SegmentsDocument
        do {
            document = try SegmentsDocumentContract.decode(mergedData)
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
                  - manifest.coverage.inputDurationS)
                <= RunArtifactContract.timeToleranceS,
              SegmentsDocumentContract.isValid(document)
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
            verifiedArtifacts: manifest.artifacts,
            coverage: DerivedSourceCoverage(
                coverage: manifest.coverage,
                complete: coverageIsComplete
            )
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

    static func isLowercaseSHA256(_ value: String) -> Bool {
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
                  <= manifest.coverage.inputDurationS
                    + RunArtifactContract.timeToleranceS,
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
                  chunk.endS <= manifest.coverage.inputDurationS
                    + RunArtifactContract.timeToleranceS
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

    private static func successfulCoverageIsComplete(_ manifest: Manifest) -> Bool {
        let coverage = manifest.coverage
        let boundaries = manifest.chunkBoundaries
        guard coverage.strategy == .full || coverage.strategy == .chunked,
              coverage.chunksPlanned > 0,
              coverage.chunksPlanned == coverage.chunksCompleted,
              boundaries.count == coverage.chunksPlanned,
              boundaries.allSatisfy({ $0.status == .succeeded }),
              let first = boundaries.first,
              let last = boundaries.last,
              abs(first.startS) <= RunArtifactContract.timeToleranceS,
              abs(last.endS - coverage.inputDurationS)
                <= RunArtifactContract.timeToleranceS,
              abs(last.endS - coverage.processedDurationS)
                <= RunArtifactContract.timeToleranceS,
              (coverage.strategy == .full ? boundaries.count == 1 : boundaries.count > 1)
        else {
            return false
        }
        for (previous, current) in zip(boundaries, boundaries.dropFirst()) {
            guard abs(current.startS - previous.endS)
                    <= RunArtifactContract.timeToleranceS
            else {
                return false
            }
        }
        let coveredDuration = boundaries.reduce(0) {
            $0 + ($1.endS - $1.startS)
        }
        return abs(coveredDuration - coverage.processedDurationS)
            <= RunArtifactContract.timeToleranceS
    }

    private static func successfulGlossaryIsValid(
        _ glossary: ManifestGlossary
    ) -> Bool {
        glossaryIsSemanticallyValid(glossary)
            && (!glossary.provided || glossary.applied)
    }

    private static func requireSuccessfulArtifactSet(_ manifest: Manifest) throws {
        var required = [
            "primary_raw": "primary/raw.txt",
            "primary_segments": "primary/segments.json",
            "diarization_timeline": "diarization/timeline.json",
            "merged_segments": "merged/segments.json",
            "merged_conflicts": "merged/conflicts.json",
        ]
        switch manifest.postprocess?.mode {
        case .correction:
            required["postprocess_segments"] = "postprocess/segments.json"
            required["postprocess_conflicts"] = "postprocess/conflicts.json"
        case .translation:
            required["postprocess_translation"] = "postprocess/translation.json"
        case nil:
            break
        }
        for (kind, path) in required {
            let matches = manifest.artifacts.filter { $0.kind == kind }
            guard matches.count == 1, matches[0].path == path else {
                throw RunIntegrityError.requiredArtifactMissing(
                    kind: kind,
                    path: path
                )
            }
        }
    }

    private static func regularSourceArtifactPaths(in runURL: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(
            at: runURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: nil
        ) else {
            throw RunIntegrityError.manifestInvalid
        }
        let rootPrefix = runURL.standardizedFileURL.path + "/"
        var paths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(rootPrefix) else {
                throw RunIntegrityError.unsafeArtifactPath(url.path)
            }
            let relative = String(standardized.path.dropFirst(rootPrefix.count))
            let values = try standardized.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if relative == "derived" {
                guard values.isDirectory == true,
                      values.isSymbolicLink != true
                else {
                    throw RunIntegrityError.unsafeArtifactPath(relative)
                }
                enumerator.skipDescendants()
                continue
            }
            if relative.hasPrefix("derived/") { continue }
            guard values.isSymbolicLink != true else {
                if manifestExcludedPath(relative) { continue }
                throw RunIntegrityError.unsafeArtifactPath(relative)
            }
            guard values.isRegularFile == true,
                  !manifestExcludedPath(relative)
            else {
                continue
            }
            paths.insert(relative)
        }
        return paths
    }

    private static func manifestExcludedPath(_ relative: String) -> Bool {
        relative == "manifest.json"
            || relative.split(separator: "/").last == ".DS_Store"
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

}
