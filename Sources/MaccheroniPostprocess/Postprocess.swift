import Foundation
import MaccheroniCore

public enum PostprocessBackendID: String, Codable, CaseIterable, Sendable {
    case codex
    case local
}

public struct PostprocessBatchPolicy: Codable, Equatable, Sendable {
    public var maximumPromptUTF8Bytes: Int
    public var maximumSegmentsPerBatch: Int
    public var maximumOutputTokens: Int?
    public var outputTokenLimitStatus: PostprocessOutputTokenLimitStatus
    public var outputTokenPlanningBudget: Int
    public var outputTokensPerInputUTF8BytePermille: Int
    public var baseOutputTokenReserve: Int
    public var perSegmentOutputTokenReserve: Int

    public init(
        maximumPromptUTF8Bytes: Int,
        maximumSegmentsPerBatch: Int,
        maximumOutputTokens: Int?,
        outputTokenLimitStatus: PostprocessOutputTokenLimitStatus,
        outputTokenPlanningBudget: Int,
        outputTokensPerInputUTF8BytePermille: Int,
        baseOutputTokenReserve: Int,
        perSegmentOutputTokenReserve: Int
    ) {
        precondition(maximumPromptUTF8Bytes > 0)
        precondition(maximumSegmentsPerBatch > 0)
        precondition((maximumOutputTokens != nil) == (outputTokenLimitStatus == .configured))
        precondition(outputTokenPlanningBudget > 0)
        precondition(outputTokensPerInputUTF8BytePermille > 0)
        precondition(baseOutputTokenReserve >= 0)
        precondition(perSegmentOutputTokenReserve >= 0)
        precondition(maximumOutputTokens.map { outputTokenPlanningBudget <= $0 } ?? true)
        self.maximumPromptUTF8Bytes = maximumPromptUTF8Bytes
        self.maximumSegmentsPerBatch = maximumSegmentsPerBatch
        self.maximumOutputTokens = maximumOutputTokens
        self.outputTokenLimitStatus = outputTokenLimitStatus
        self.outputTokenPlanningBudget = outputTokenPlanningBudget
        self.outputTokensPerInputUTF8BytePermille =
            outputTokensPerInputUTF8BytePermille
        self.baseOutputTokenReserve = baseOutputTokenReserve
        self.perSegmentOutputTokenReserve = perSegmentOutputTokenReserve
    }

    public func estimatedOutputTokens(
        inputTextUTF8Bytes: Int,
        segmentCount: Int
    ) -> Int {
        guard inputTextUTF8Bytes >= 0, segmentCount >= 0 else { return .max }
        let (scaled, scaleOverflow) = inputTextUTF8Bytes.multipliedReportingOverflow(
            by: outputTokensPerInputUTF8BytePermille
        )
        guard !scaleOverflow, scaled <= Int.max - 999 else { return .max }
        let sourceEstimate = (scaled + 999) / 1_000
        return reservedTokenUpperBound(
            textUTF8Bytes: sourceEstimate,
            segmentCount: segmentCount
        )
    }

    public func acceptedOutputTokenUpperBound(
        responseUTF8Bytes: Int,
        segmentCount: Int
    ) -> Int {
        reservedTokenUpperBound(
            textUTF8Bytes: responseUTF8Bytes,
            segmentCount: segmentCount
        )
    }

    public func manifest(
        batchesPlanned: Int,
        maximumObservedPromptUTF8Bytes: Int,
        maximumObservedInputTextUTF8Bytes: Int,
        maximumObservedEstimatedOutputTokens: Int,
        maximumObservedOutputTextUTF8Bytes: Int,
        maximumObservedResponseUTF8Bytes: Int,
        maximumObservedAcceptedOutputTokenUpperBound: Int
    ) -> ManifestPostprocessBatching {
        ManifestPostprocessBatching(
            maximumPromptUTF8Bytes: maximumPromptUTF8Bytes,
            maximumSegmentsPerBatch: maximumSegmentsPerBatch,
            maximumOutputTokens: maximumOutputTokens,
            outputTokenLimitStatus: outputTokenLimitStatus,
            outputTokenPlanningBudget: outputTokenPlanningBudget,
            outputTokensPerInputUTF8BytePermille:
                outputTokensPerInputUTF8BytePermille,
            baseOutputTokenReserve: baseOutputTokenReserve,
            perSegmentOutputTokenReserve: perSegmentOutputTokenReserve,
            batchesPlanned: batchesPlanned,
            maximumObservedPromptUTF8Bytes: maximumObservedPromptUTF8Bytes,
            maximumObservedInputTextUTF8Bytes: maximumObservedInputTextUTF8Bytes,
            maximumObservedEstimatedOutputTokens:
                maximumObservedEstimatedOutputTokens,
            maximumObservedOutputTextUTF8Bytes: maximumObservedOutputTextUTF8Bytes,
            maximumObservedResponseUTF8Bytes: maximumObservedResponseUTF8Bytes,
            maximumObservedAcceptedOutputTokenUpperBound:
                maximumObservedAcceptedOutputTokenUpperBound
        )
    }

    private func reservedTokenUpperBound(
        textUTF8Bytes: Int,
        segmentCount: Int
    ) -> Int {
        guard textUTF8Bytes >= 0, segmentCount >= 0 else { return .max }
        let (segmentReserve, segmentOverflow) =
            segmentCount.multipliedReportingOverflow(by: perSegmentOutputTokenReserve)
        guard !segmentOverflow else { return .max }
        let (withBase, baseOverflow) = textUTF8Bytes.addingReportingOverflow(
            baseOutputTokenReserve
        )
        guard !baseOverflow else { return .max }
        let (total, totalOverflow) = withBase.addingReportingOverflow(segmentReserve)
        return totalOverflow ? .max : total
    }
}

public struct PostprocessRequest: Sendable {
    public var document: SegmentsDocument
    public var glossary: Glossary?

    public init(document: SegmentsDocument, glossary: Glossary? = nil) {
        self.document = document
        self.glossary = glossary
    }
}

public enum PostprocessDisposition: String, Codable, Equatable, Sendable {
    case apply
    case review
}

public struct PostprocessProposal: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    public var replacementText: String
    public var disposition: PostprocessDisposition
    public var reason: String

    public init(segmentIndex: Int, replacementText: String, disposition: PostprocessDisposition, reason: String) {
        self.segmentIndex = segmentIndex
        self.replacementText = replacementText
        self.disposition = disposition
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
        case replacementText = "replacement_text"
        case disposition, reason
    }
}

public struct PostprocessConflict: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    public var originalText: String
    public var candidateText: String
    public var reason: String

    public init(segmentIndex: Int, originalText: String, candidateText: String, reason: String) {
        self.segmentIndex = segmentIndex
        self.originalText = originalText
        self.candidateText = candidateText
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
        case originalText = "original_text"
        case candidateText = "candidate_text"
        case reason
    }
}

public struct PostprocessResult: Equatable, Sendable {
    public var document: SegmentsDocument
    public var conflicts: [PostprocessConflict]
    public var manifestPostprocess: ManifestPostprocess

    public init(document: SegmentsDocument, conflicts: [PostprocessConflict], manifestPostprocess: ManifestPostprocess) {
        self.document = document
        self.conflicts = conflicts
        self.manifestPostprocess = manifestPostprocess
    }
}

public struct TranslationRequest: Sendable {
    public var document: SegmentsDocument
    public var targetLanguage: String
    public var sourceSegmentsSHA256: String
    public var glossary: Glossary?

    public init(
        document: SegmentsDocument,
        targetLanguage: String,
        sourceSegmentsSHA256: String,
        glossary: Glossary? = nil
    ) {
        self.document = document
        self.targetLanguage = targetLanguage
        self.sourceSegmentsSHA256 = sourceSegmentsSHA256
        self.glossary = glossary
    }
}

public struct SegmentTranslation: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    public var translatedText: String

    public init(segmentIndex: Int, translatedText: String) {
        self.segmentIndex = segmentIndex
        self.translatedText = translatedText
    }

    enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
        case translatedText = "translated_text"
    }
}

public struct TranslationBatchRecord: Codable, Equatable, Sendable {
    public var batchIndex: Int
    public var segmentIndices: [Int]
    public var promptUTF8Bytes: Int
    public var inputTextUTF8Bytes: Int
    public var estimatedOutputTokens: Int
    public var outputTextUTF8Bytes: Int
    public var responseUTF8Bytes: Int
    public var acceptedOutputTokenUpperBound: Int

    public init(
        batchIndex: Int,
        segmentIndices: [Int],
        promptUTF8Bytes: Int,
        inputTextUTF8Bytes: Int,
        estimatedOutputTokens: Int,
        outputTextUTF8Bytes: Int,
        responseUTF8Bytes: Int,
        acceptedOutputTokenUpperBound: Int
    ) {
        self.batchIndex = batchIndex
        self.segmentIndices = segmentIndices
        self.promptUTF8Bytes = promptUTF8Bytes
        self.inputTextUTF8Bytes = inputTextUTF8Bytes
        self.estimatedOutputTokens = estimatedOutputTokens
        self.outputTextUTF8Bytes = outputTextUTF8Bytes
        self.responseUTF8Bytes = responseUTF8Bytes
        self.acceptedOutputTokenUpperBound = acceptedOutputTokenUpperBound
    }

    enum CodingKeys: String, CodingKey {
        case acceptedOutputTokenUpperBound = "accepted_output_token_upper_bound"
        case batchIndex = "batch_index"
        case estimatedOutputTokens = "estimated_output_tokens"
        case inputTextUTF8Bytes = "input_text_utf8_bytes"
        case outputTextUTF8Bytes = "output_text_utf8_bytes"
        case promptUTF8Bytes = "prompt_utf8_bytes"
        case responseUTF8Bytes = "response_utf8_bytes"
        case segmentIndices = "segment_indices"
    }
}

public struct TranslationDocument: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var targetLanguage: String
    public var sourceSegmentsSHA256: String
    public var batches: [TranslationBatchRecord]
    public var translations: [SegmentTranslation]

    public init(
        schemaVersion: String = MaccheroniSchema.version,
        targetLanguage: String,
        sourceSegmentsSHA256: String,
        batches: [TranslationBatchRecord],
        translations: [SegmentTranslation]
    ) {
        self.schemaVersion = schemaVersion
        self.targetLanguage = targetLanguage
        self.sourceSegmentsSHA256 = sourceSegmentsSHA256
        self.batches = batches
        self.translations = translations
    }

    enum CodingKeys: String, CodingKey {
        case batches, translations
        case schemaVersion = "schema_version"
        case sourceSegmentsSHA256 = "source_segments_sha256"
        case targetLanguage = "target_language"
    }
}

public struct TranslationResult: Equatable, Sendable {
    public var document: TranslationDocument
    public var manifestPostprocess: ManifestPostprocess

    public init(document: TranslationDocument, manifestPostprocess: ManifestPostprocess) {
        self.document = document
        self.manifestPostprocess = manifestPostprocess
    }
}

// MARK: - Marked non-acoustic speaker proposal

public enum SpeakerProposalDisposition: String, Codable, Equatable, Sendable {
    case propose
    case decline
}

/// One backend answer about one unattributed segment, before validation.
public struct SpeakerProposalDecision: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    /// Empty when `disposition` is `.decline`.
    public var proposedSpeaker: String
    public var disposition: SpeakerProposalDisposition
    public var reason: String

    public init(
        segmentIndex: Int,
        proposedSpeaker: String,
        disposition: SpeakerProposalDisposition,
        reason: String
    ) {
        self.segmentIndex = segmentIndex
        self.proposedSpeaker = proposedSpeaker
        self.disposition = disposition
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case disposition, reason
        case segmentIndex = "segment_index"
        case proposedSpeaker = "proposed_speaker"
    }
}

public struct SpeakerProposalBackendResponse: Equatable, Sendable {
    public var decisions: [SpeakerProposalDecision]
    public var responseUTF8Bytes: Int

    public init(decisions: [SpeakerProposalDecision], responseUTF8Bytes: Int) {
        self.decisions = decisions
        self.responseUTF8Bytes = responseUTF8Bytes
    }
}

/// Receives a bounded text-only prompt and returns speaker proposals only. It
/// never sees audio, and nothing it returns reaches a source run.
public protocol SpeakerProposalBackend: Sendable {
    var id: PostprocessBackendID { get }
    var manifestPostprocess: ManifestPostprocess { get }
    var model: ModelDescriptor? { get }
    var batchPolicy: PostprocessBatchPolicy { get }
    func proposeSpeakers(prompt: String) async throws -> SpeakerProposalBackendResponse
}

/// A speaker this layer proposes for a segment the source run left
/// unattributed, with the acoustic evidence that did not settle it.
///
/// `proposedSpeaker` is deliberately not called `speaker`: nothing in this
/// record is an assignment, and a reader who sees only this type should not be
/// able to mistake it for one.
public struct SpeakerProposal: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    public var proposedSpeaker: String
    public var reason: String
    public var acousticOutcome: String
    public var acousticTimelineCoverage: Double
    public var acousticCandidates: [SpeakerCandidateEvidence]

    public init(
        segmentIndex: Int,
        proposedSpeaker: String,
        reason: String,
        acousticOutcome: String,
        acousticTimelineCoverage: Double,
        acousticCandidates: [SpeakerCandidateEvidence]
    ) {
        self.segmentIndex = segmentIndex
        self.proposedSpeaker = proposedSpeaker
        self.reason = reason
        self.acousticOutcome = acousticOutcome
        self.acousticTimelineCoverage = acousticTimelineCoverage
        self.acousticCandidates = acousticCandidates
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case segmentIndex = "segment_index"
        case proposedSpeaker = "proposed_speaker"
        case acousticOutcome = "acoustic_outcome"
        case acousticTimelineCoverage = "acoustic_timeline_coverage"
        case acousticCandidates = "acoustic_candidates"
    }
}

/// An unattributed segment this layer looked at and did not propose a speaker
/// for, with why. Declining is a result, not a gap, so it is recorded with the
/// same evidence a proposal carries.
public struct SpeakerProposalDeclination: Codable, Equatable, Sendable {
    public var segmentIndex: Int
    public var reason: String
    public var acousticOutcome: String
    public var acousticTimelineCoverage: Double
    public var acousticCandidates: [SpeakerCandidateEvidence]

    public init(
        segmentIndex: Int,
        reason: String,
        acousticOutcome: String,
        acousticTimelineCoverage: Double,
        acousticCandidates: [SpeakerCandidateEvidence]
    ) {
        self.segmentIndex = segmentIndex
        self.reason = reason
        self.acousticOutcome = acousticOutcome
        self.acousticTimelineCoverage = acousticTimelineCoverage
        self.acousticCandidates = acousticCandidates
    }

    enum CodingKeys: String, CodingKey {
        case reason
        case segmentIndex = "segment_index"
        case acousticOutcome = "acoustic_outcome"
        case acousticTimelineCoverage = "acoustic_timeline_coverage"
        case acousticCandidates = "acoustic_candidates"
    }
}

/// The derived run's speaker-proposal artifact.
///
/// Every segment the source run left unattributed appears exactly once, in
/// `proposals` or in `declined`. That is what makes a run that proposed almost
/// nothing honest rather than empty: the file still says which segments were
/// examined and why each was left alone.
public struct SpeakerProposalDocument: Codable, Equatable, Sendable {
    public static let layer = "speaker-proposal"

    public var schemaVersion: String
    /// Always `speaker-proposal`. Present so the artifact names what it is
    /// without reference to the manifest that points at it.
    public var layer: String
    public var sourceSegmentsSHA256: String
    /// How much of the recording the source transcript covers. Carried here as
    /// well as in the derived manifest, because a reader looking at proposals
    /// must not have to open another file to learn that 30.56 s of the meeting
    /// has no transcript at all.
    public var sourceCoverage: DerivedSourceCoverage
    /// The speaker labels the source run uses for an unattributed segment.
    public var unattributedSpeakers: [String]
    public var proposals: [SpeakerProposal]
    public var declined: [SpeakerProposalDeclination]
    public var batches: [TranslationBatchRecord]

    public init(
        schemaVersion: String = MaccheroniSchema.version,
        layer: String = SpeakerProposalDocument.layer,
        sourceSegmentsSHA256: String,
        sourceCoverage: DerivedSourceCoverage,
        unattributedSpeakers: [String] = UnattributedSpeaker.labels,
        proposals: [SpeakerProposal],
        declined: [SpeakerProposalDeclination],
        batches: [TranslationBatchRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.layer = layer
        self.sourceSegmentsSHA256 = sourceSegmentsSHA256
        self.sourceCoverage = sourceCoverage
        self.unattributedSpeakers = unattributedSpeakers
        self.proposals = proposals
        self.declined = declined
        self.batches = batches
    }

    enum CodingKeys: String, CodingKey {
        case layer, proposals, declined, batches
        case schemaVersion = "schema_version"
        case sourceSegmentsSHA256 = "source_segments_sha256"
        case sourceCoverage = "source_coverage"
        case unattributedSpeakers = "unattributed_speakers"
    }
}

public struct SpeakerProposalRequest: Sendable {
    public var document: SegmentsDocument
    /// Exactly one entry per unattributed segment, from the source run's
    /// `merged/conflicts.json`.
    public var evidence: [SegmentSpeakerEvidence]
    public var sourceSegmentsSHA256: String
    public var sourceCoverage: DerivedSourceCoverage

    public init(
        document: SegmentsDocument,
        evidence: [SegmentSpeakerEvidence],
        sourceSegmentsSHA256: String,
        sourceCoverage: DerivedSourceCoverage
    ) {
        self.document = document
        self.evidence = evidence
        self.sourceSegmentsSHA256 = sourceSegmentsSHA256
        self.sourceCoverage = sourceCoverage
    }
}

public struct SpeakerProposalResult: Equatable, Sendable {
    public var document: SpeakerProposalDocument
    public var manifestPostprocess: ManifestPostprocess

    public init(
        document: SpeakerProposalDocument,
        manifestPostprocess: ManifestPostprocess
    ) {
        self.document = document
        self.manifestPostprocess = manifestPostprocess
    }
}

public struct PostprocessBackendResponse: Equatable, Sendable {
    public var proposals: [PostprocessProposal]
    public var responseUTF8Bytes: Int

    public init(proposals: [PostprocessProposal], responseUTF8Bytes: Int) {
        self.proposals = proposals
        self.responseUTF8Bytes = responseUTF8Bytes
    }
}

public struct TranslationBackendResponse: Equatable, Sendable {
    public var translations: [SegmentTranslation]
    public var responseUTF8Bytes: Int

    public init(translations: [SegmentTranslation], responseUTF8Bytes: Int) {
        self.translations = translations
        self.responseUTF8Bytes = responseUTF8Bytes
    }
}

/// Receives a bounded text-only prompt and returns proposed corrections.
public protocol PostprocessBackend: Sendable {
    var id: PostprocessBackendID { get }
    var manifestPostprocess: ManifestPostprocess { get }
    var model: ModelDescriptor? { get }
    var batchPolicy: PostprocessBatchPolicy { get }
    func propose(prompt: String) async throws -> PostprocessBackendResponse
}

/// Receives a bounded text-only prompt and returns translations only.
public protocol TranslationBackend: Sendable {
    var id: PostprocessBackendID { get }
    var manifestPostprocess: ManifestPostprocess { get }
    var model: ModelDescriptor? { get }
    var batchPolicy: PostprocessBatchPolicy { get }
    func translate(prompt: String) async throws -> TranslationBackendResponse
}

public enum PostprocessError: Error, Equatable, Sendable, LocalizedError {
    case duplicateSegmentIndex(Int)
    case segmentIndexOutOfRange(Int)
    case emptyReplacementText(Int)
    case duplicateTranslationIndex(Int)
    case emptyTranslationText(Int)
    case translationCoverageMismatch(expected: [Int], actual: [Int])
    case invalidTargetLanguage(String)
    case invalidSourceSegmentsSHA256
    case emptyDocument
    case batchPromptTooLarge(segmentIndex: Int, promptUTF8Bytes: Int, maximum: Int)
    case batchOutputBudgetTooLarge(
        segmentIndex: Int,
        inputTextUTF8Bytes: Int,
        estimatedOutputTokens: Int,
        maximum: Int
    )
    case backendOutputBudgetExceeded(upperBound: Int, maximum: Int)
    case noUnattributedSegments
    case speakerEvidenceMissing(Int)
    case speakerEvidenceForAttributedSegment(Int)
    case duplicateSpeakerEvidence(Int)
    case duplicateSpeakerDecision(Int)
    case speakerDecisionOutOfRange(Int)
    case speakerProposalOverridesAssignedSpeaker(segmentIndex: Int, speaker: String)
    case speakerProposalNotACandidate(segmentIndex: Int, speaker: String)
    case speakerDeclineNamesSpeaker(segmentIndex: Int, speaker: String)
    case emptySpeakerProposalReason(Int)
    case backendFailed(String)
    case missingOutput(String)
    case malformedOutput(String)
    case launchFailed(String)
    case authenticationRequired(String)

    public var errorDescription: String? {
        switch self {
        case let .duplicateSegmentIndex(index): "multiple postprocess proposals target segment \(index)"
        case let .segmentIndexOutOfRange(index): "postprocess proposal targets nonexistent segment \(index)"
        case let .emptyReplacementText(index): "postprocess proposal for segment \(index) has empty replacement text"
        case let .duplicateTranslationIndex(index): "multiple translations target segment \(index)"
        case let .emptyTranslationText(index): "translation for segment \(index) has empty text"
        case let .translationCoverageMismatch(expected, actual):
            "translation indices do not match the source batch (expected \(expected), got \(actual))"
        case let .invalidTargetLanguage(value): "invalid translation target language: \(value)"
        case .invalidSourceSegmentsSHA256: "translation source segments hash is not a SHA-256 value"
        case .emptyDocument: "postprocessing requires at least one transcript segment"
        case let .batchPromptTooLarge(index, bytes, maximum):
            "segment \(index) needs a \(bytes)-byte prompt, above the \(maximum)-byte backend limit"
        case let .batchOutputBudgetTooLarge(index, bytes, estimate, maximum):
            "segment \(index) has \(bytes) input text bytes and needs an estimated \(estimate) output tokens, above the \(maximum)-token planning budget"
        case let .backendOutputBudgetExceeded(upperBound, maximum):
            "backend output needs a conservative \(upperBound)-token upper bound, above the \(maximum)-token planning budget"
        case .noUnattributedSegments:
            "the source run left no segment unattributed, so there is nothing to propose a speaker for"
        case let .speakerEvidenceMissing(index):
            "unattributed segment \(index) has no acoustic evidence record"
        case let .speakerEvidenceForAttributedSegment(index):
            "segment \(index) already has an acoustic speaker and takes no proposal"
        case let .duplicateSpeakerEvidence(index):
            "multiple acoustic evidence records describe segment \(index)"
        case let .duplicateSpeakerDecision(index):
            "multiple speaker decisions target segment \(index)"
        case let .speakerDecisionOutOfRange(index):
            "speaker decision targets segment \(index), which this batch did not ask about"
        case let .speakerProposalOverridesAssignedSpeaker(index, speaker):
            "speaker proposal \(speaker) targets segment \(index), which the acoustics already assigned"
        case let .speakerProposalNotACandidate(index, speaker):
            "speaker proposal \(speaker) for segment \(index) is not one of its acoustic candidates"
        case let .speakerDeclineNamesSpeaker(index, speaker):
            "declined segment \(index) still names speaker \(speaker)"
        case let .emptySpeakerProposalReason(index):
            "the speaker decision for segment \(index) gives no reason"
        case let .backendFailed(message), let .missingOutput(message), let .malformedOutput(message),
             let .launchFailed(message), let .authenticationRequired(message): message
        }
    }
}

public struct TranscriptPostprocessor: Sendable {
    public let backend: any PostprocessBackend

    public init(backend: any PostprocessBackend) {
        self.backend = backend
    }

    public func process(_ request: PostprocessRequest) async throws -> PostprocessResult {
        let batches = try TextBatchPlanner.plan(
            document: request.document,
            policy: backend.batchPolicy
        ) { segments in
            try PostprocessPrompt.make(for: request, segments: segments)
        }
        var proposals: [PostprocessProposal] = []
        var outputEvidence: [BatchOutputEvidence] = []
        for batch in batches {
            let response = try await backend.propose(prompt: batch.prompt)
            let batchProposals = response.proposals
            try validate(batchProposals, allowedIndices: Set(batch.segments.map(\.index)))
            outputEvidence.append(try validateOutputBudget(
                batchProposals,
                responseUTF8Bytes: response.responseUTF8Bytes,
                sourceSegmentCount: batch.segments.count
            ))
            proposals.append(contentsOf: batchProposals)
        }
        try validateUnique(proposals)

        var corrected = request.document
        var conflicts: [PostprocessConflict] = []
        for proposal in proposals {
            switch proposal.disposition {
            case .apply:
                corrected.segments[proposal.segmentIndex].text = proposal.replacementText
            case .review:
                let original = request.document.segments[proposal.segmentIndex].text
                corrected.segments[proposal.segmentIndex].flags = addingReviewFlags(
                    to: corrected.segments[proposal.segmentIndex].flags
                )
                conflicts.append(PostprocessConflict(
                    segmentIndex: proposal.segmentIndex,
                    originalText: original,
                    candidateText: proposal.replacementText,
                    reason: proposal.reason
                ))
            }
        }
        var provenance = backend.manifestPostprocess
        provenance.glossarySHA256 = request.glossary?.sha256
        provenance.mode = .correction
        provenance.targetLanguage = nil
        provenance.sourceSegmentsSHA256 = nil
        provenance.batching = backend.batchPolicy.manifest(
            batchesPlanned: batches.count,
            maximumObservedPromptUTF8Bytes:
                batches.map(\.promptUTF8Bytes).max() ?? 0,
            maximumObservedInputTextUTF8Bytes:
                batches.map(\.inputTextUTF8Bytes).max() ?? 0,
            maximumObservedEstimatedOutputTokens:
                batches.map(\.estimatedOutputTokens).max() ?? 0,
            maximumObservedOutputTextUTF8Bytes:
                outputEvidence.map(\.outputTextUTF8Bytes).max() ?? 0,
            maximumObservedResponseUTF8Bytes:
                outputEvidence.map(\.responseUTF8Bytes).max() ?? 0,
            maximumObservedAcceptedOutputTokenUpperBound:
                outputEvidence.map(\.acceptedOutputTokenUpperBound).max() ?? 0
        )
        return PostprocessResult(
            document: corrected,
            conflicts: conflicts,
            manifestPostprocess: provenance
        )
    }

    private func validate(
        _ proposals: [PostprocessProposal],
        allowedIndices: Set<Int>
    ) throws {
        var indices = Set<Int>()
        for proposal in proposals {
            guard allowedIndices.contains(proposal.segmentIndex) else {
                throw PostprocessError.segmentIndexOutOfRange(proposal.segmentIndex)
            }
            guard indices.insert(proposal.segmentIndex).inserted else {
                throw PostprocessError.duplicateSegmentIndex(proposal.segmentIndex)
            }
            guard !proposal.replacementText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PostprocessError.emptyReplacementText(proposal.segmentIndex)
            }
        }
    }

    private func validateUnique(_ proposals: [PostprocessProposal]) throws {
        var indices = Set<Int>()
        for proposal in proposals where !indices.insert(proposal.segmentIndex).inserted {
            throw PostprocessError.duplicateSegmentIndex(proposal.segmentIndex)
        }
    }

    private func validateOutputBudget(
        _ proposals: [PostprocessProposal],
        responseUTF8Bytes: Int,
        sourceSegmentCount: Int
    ) throws -> BatchOutputEvidence {
        let outputTextUTF8Bytes = proposals.reduce(into: 0) { total, proposal in
            total = saturatingAdd(total, proposal.replacementText.utf8.count)
            total = saturatingAdd(total, proposal.reason.utf8.count)
        }
        guard responseUTF8Bytes >= outputTextUTF8Bytes else {
            throw PostprocessError.malformedOutput(
                "backend response byte evidence is smaller than its decoded text"
            )
        }
        let upperBound = backend.batchPolicy.acceptedOutputTokenUpperBound(
            responseUTF8Bytes: responseUTF8Bytes,
            segmentCount: sourceSegmentCount
        )
        guard upperBound <= backend.batchPolicy.outputTokenPlanningBudget else {
            throw PostprocessError.backendOutputBudgetExceeded(
                upperBound: upperBound,
                maximum: backend.batchPolicy.outputTokenPlanningBudget
            )
        }
        return BatchOutputEvidence(
            outputTextUTF8Bytes: outputTextUTF8Bytes,
            responseUTF8Bytes: responseUTF8Bytes,
            acceptedOutputTokenUpperBound: upperBound
        )
    }

    private func addingReviewFlags(to flags: [String]?) -> [String] {
        var result = flags ?? []
        for value in ["uncertain", "conflict"] where !result.contains(value) {
            result.append(value)
        }
        return result
    }
}

public struct TranscriptTranslator: Sendable {
    public let backend: any TranslationBackend

    public init(backend: any TranslationBackend) {
        self.backend = backend
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        let targetLanguage = try normalizedTargetLanguage(request.targetLanguage)
        guard isSHA256(request.sourceSegmentsSHA256) else {
            throw PostprocessError.invalidSourceSegmentsSHA256
        }
        let batches = try TextBatchPlanner.plan(
            document: request.document,
            policy: backend.batchPolicy
        ) { segments in
            try TranslationPrompt.make(
                for: request,
                targetLanguage: targetLanguage,
                segments: segments
            )
        }

        var translations: [SegmentTranslation] = []
        var records: [TranslationBatchRecord] = []
        for (batchIndex, batch) in batches.enumerated() {
            let expected = batch.segments.map(\.index)
            let response = try await backend.translate(prompt: batch.prompt)
            let output = response.translations
            try validate(output, expectedIndices: expected)
            let outputTextUTF8Bytes = output.reduce(0) {
                saturatingAdd($0, $1.translatedText.utf8.count)
            }
            guard response.responseUTF8Bytes >= outputTextUTF8Bytes else {
                throw PostprocessError.malformedOutput(
                    "backend response byte evidence is smaller than its decoded text"
                )
            }
            let acceptedOutputTokenUpperBound =
                backend.batchPolicy.acceptedOutputTokenUpperBound(
                    responseUTF8Bytes: response.responseUTF8Bytes,
                    segmentCount: output.count
                )
            guard acceptedOutputTokenUpperBound
                    <= backend.batchPolicy.outputTokenPlanningBudget
            else {
                throw PostprocessError.backendOutputBudgetExceeded(
                    upperBound: acceptedOutputTokenUpperBound,
                    maximum: backend.batchPolicy.outputTokenPlanningBudget
                )
            }
            translations.append(contentsOf: output)
            records.append(TranslationBatchRecord(
                batchIndex: batchIndex,
                segmentIndices: expected,
                promptUTF8Bytes: batch.promptUTF8Bytes,
                inputTextUTF8Bytes: batch.inputTextUTF8Bytes,
                estimatedOutputTokens: batch.estimatedOutputTokens,
                outputTextUTF8Bytes: outputTextUTF8Bytes,
                responseUTF8Bytes: response.responseUTF8Bytes,
                acceptedOutputTokenUpperBound: acceptedOutputTokenUpperBound
            ))
        }
        translations.sort { $0.segmentIndex < $1.segmentIndex }

        var provenance = backend.manifestPostprocess
        provenance.glossarySHA256 = request.glossary?.sha256
        provenance.mode = .translation
        provenance.targetLanguage = targetLanguage
        provenance.sourceSegmentsSHA256 = request.sourceSegmentsSHA256
        provenance.batching = backend.batchPolicy.manifest(
            batchesPlanned: batches.count,
            maximumObservedPromptUTF8Bytes:
                batches.map(\.promptUTF8Bytes).max() ?? 0,
            maximumObservedInputTextUTF8Bytes:
                batches.map(\.inputTextUTF8Bytes).max() ?? 0,
            maximumObservedEstimatedOutputTokens:
                batches.map(\.estimatedOutputTokens).max() ?? 0,
            maximumObservedOutputTextUTF8Bytes:
                records.map(\.outputTextUTF8Bytes).max() ?? 0,
            maximumObservedResponseUTF8Bytes:
                records.map(\.responseUTF8Bytes).max() ?? 0,
            maximumObservedAcceptedOutputTokenUpperBound:
                records.map(\.acceptedOutputTokenUpperBound).max() ?? 0
        )
        return TranslationResult(
            document: TranslationDocument(
                targetLanguage: targetLanguage,
                sourceSegmentsSHA256: request.sourceSegmentsSHA256,
                batches: records,
                translations: translations
            ),
            manifestPostprocess: provenance
        )
    }

    private func validate(
        _ translations: [SegmentTranslation],
        expectedIndices: [Int]
    ) throws {
        var indices = Set<Int>()
        for translation in translations {
            guard indices.insert(translation.segmentIndex).inserted else {
                throw PostprocessError.duplicateTranslationIndex(translation.segmentIndex)
            }
            guard !translation.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PostprocessError.emptyTranslationText(translation.segmentIndex)
            }
        }
        let actual = indices.sorted()
        guard actual == expectedIndices.sorted() else {
            throw PostprocessError.translationCoverageMismatch(
                expected: expectedIndices.sorted(),
                actual: actual
            )
        }
    }

    private func normalizedTargetLanguage(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              trimmed.range(
                of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$",
                options: .regularExpression
              ) != nil
        else {
            throw PostprocessError.invalidTargetLanguage(value)
        }
        return trimmed
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }
}

/// Proposes a speaker for segments the source run left unattributed, and for
/// nothing else.
///
/// The layering is enforced here rather than trusted: a decision about a
/// segment that already carries an acoustic speaker is rejected as a contract
/// violation, not merged. Judgment rule 4 permits this proposal only in a
/// derived run, marked, beside the acoustic candidates, and this type produces
/// exactly that and never touches the source document.
public struct SpeakerProposer: Sendable {
    public let backend: any SpeakerProposalBackend

    public init(backend: any SpeakerProposalBackend) {
        self.backend = backend
    }

    public func propose(
        _ request: SpeakerProposalRequest
    ) async throws -> SpeakerProposalResult {
        guard !request.document.segments.isEmpty else {
            throw PostprocessError.emptyDocument
        }
        guard isSHA256(request.sourceSegmentsSHA256) else {
            throw PostprocessError.invalidSourceSegmentsSHA256
        }

        let segments = request.document.segments
        let unattributed = segments.indices.filter {
            UnattributedSpeaker.isUnattributed(segments[$0].speaker)
        }
        guard !unattributed.isEmpty else {
            throw PostprocessError.noUnattributedSegments
        }
        let targets = Set(unattributed)
        let knownSpeakers = Set(segments.map(\.speaker))
            .subtracting(UnattributedSpeaker.labels)
            .sorted()

        var evidenceByIndex: [Int: SegmentSpeakerEvidence] = [:]
        for record in request.evidence {
            guard segments.indices.contains(record.segmentIndex),
                  targets.contains(record.segmentIndex)
            else {
                throw PostprocessError.speakerEvidenceForAttributedSegment(
                    record.segmentIndex
                )
            }
            guard evidenceByIndex[record.segmentIndex] == nil else {
                throw PostprocessError.duplicateSpeakerEvidence(record.segmentIndex)
            }
            evidenceByIndex[record.segmentIndex] = record
        }
        for index in unattributed where evidenceByIndex[index] == nil {
            throw PostprocessError.speakerEvidenceMissing(index)
        }

        let batches = try TextBatchPlanner.plan(
            document: request.document,
            policy: backend.batchPolicy
        ) { batchSegments in
            try SpeakerProposalPrompt.make(
                segments: batchSegments,
                document: request.document,
                targets: targets,
                evidence: evidenceByIndex,
                knownSpeakers: knownSpeakers
            )
        }

        var decisions: [Int: SpeakerProposalDecision] = [:]
        var records: [TranslationBatchRecord] = []
        var batchIndex = 0
        for batch in batches {
            let batchTargets = batch.segments.map(\.index).filter(targets.contains)
            // A batch that asks about nothing is not sent. The model is not
            // billed for context it cannot answer about, and an empty answer
            // from it would be indistinguishable from a decline.
            guard !batchTargets.isEmpty else { continue }
            let response = try await backend.proposeSpeakers(prompt: batch.prompt)
            let allowed = Set(batchTargets)
            var batchDecisions: [SpeakerProposalDecision] = []
            for decision in response.decisions {
                guard allowed.contains(decision.segmentIndex) else {
                    // A decision about an acoustically assigned segment is the
                    // layering going wrong, so it is named as that rather than
                    // as an out-of-range index.
                    if segments.indices.contains(decision.segmentIndex),
                       !targets.contains(decision.segmentIndex),
                       decision.disposition == .propose
                    {
                        throw PostprocessError
                            .speakerProposalOverridesAssignedSpeaker(
                                segmentIndex: decision.segmentIndex,
                                speaker: decision.proposedSpeaker
                            )
                    }
                    throw PostprocessError.speakerDecisionOutOfRange(
                        decision.segmentIndex
                    )
                }
                guard decisions[decision.segmentIndex] == nil,
                      !batchDecisions.contains(where: {
                          $0.segmentIndex == decision.segmentIndex
                      })
                else {
                    throw PostprocessError.duplicateSpeakerDecision(
                        decision.segmentIndex
                    )
                }
                try validate(
                    decision,
                    evidence: evidenceByIndex[decision.segmentIndex],
                    knownSpeakers: knownSpeakers
                )
                batchDecisions.append(decision)
            }
            let outputTextUTF8Bytes = batchDecisions.reduce(0) {
                saturatingAdd(
                    saturatingAdd($0, $1.proposedSpeaker.utf8.count),
                    $1.reason.utf8.count
                )
            }
            guard response.responseUTF8Bytes >= outputTextUTF8Bytes else {
                throw PostprocessError.malformedOutput(
                    "backend response byte evidence is smaller than its decoded text"
                )
            }
            let acceptedOutputTokenUpperBound =
                backend.batchPolicy.acceptedOutputTokenUpperBound(
                    responseUTF8Bytes: response.responseUTF8Bytes,
                    segmentCount: batchDecisions.count
                )
            guard acceptedOutputTokenUpperBound
                    <= backend.batchPolicy.outputTokenPlanningBudget
            else {
                throw PostprocessError.backendOutputBudgetExceeded(
                    upperBound: acceptedOutputTokenUpperBound,
                    maximum: backend.batchPolicy.outputTokenPlanningBudget
                )
            }
            for decision in batchDecisions {
                decisions[decision.segmentIndex] = decision
            }
            records.append(TranslationBatchRecord(
                batchIndex: batchIndex,
                segmentIndices: batchTargets,
                promptUTF8Bytes: batch.promptUTF8Bytes,
                inputTextUTF8Bytes: batch.inputTextUTF8Bytes,
                estimatedOutputTokens: batch.estimatedOutputTokens,
                outputTextUTF8Bytes: outputTextUTF8Bytes,
                responseUTF8Bytes: response.responseUTF8Bytes,
                acceptedOutputTokenUpperBound: acceptedOutputTokenUpperBound
            ))
            batchIndex += 1
        }

        var proposals: [SpeakerProposal] = []
        var declined: [SpeakerProposalDeclination] = []
        for index in unattributed {
            // Force-unwrapping is safe: every unattributed index was checked
            // against `evidenceByIndex` above.
            let evidence = evidenceByIndex[index]!
            guard let decision = decisions[index],
                  decision.disposition == .propose
            else {
                declined.append(SpeakerProposalDeclination(
                    segmentIndex: index,
                    reason: decisions[index]?.reason
                        ?? "the proposer returned no decision for this segment",
                    acousticOutcome: evidence.outcome,
                    acousticTimelineCoverage: evidence.timelineCoverage,
                    acousticCandidates: evidence.candidates
                ))
                continue
            }
            proposals.append(SpeakerProposal(
                segmentIndex: index,
                proposedSpeaker: decision.proposedSpeaker,
                reason: decision.reason,
                acousticOutcome: evidence.outcome,
                acousticTimelineCoverage: evidence.timelineCoverage,
                acousticCandidates: evidence.candidates
            ))
        }

        var provenance = backend.manifestPostprocess
        provenance.glossarySHA256 = nil
        provenance.mode = .correction
        provenance.targetLanguage = nil
        provenance.sourceSegmentsSHA256 = request.sourceSegmentsSHA256
        provenance.batching = backend.batchPolicy.manifest(
            batchesPlanned: records.count,
            maximumObservedPromptUTF8Bytes:
                records.map(\.promptUTF8Bytes).max() ?? 0,
            maximumObservedInputTextUTF8Bytes:
                records.map(\.inputTextUTF8Bytes).max() ?? 0,
            maximumObservedEstimatedOutputTokens:
                records.map(\.estimatedOutputTokens).max() ?? 0,
            maximumObservedOutputTextUTF8Bytes:
                records.map(\.outputTextUTF8Bytes).max() ?? 0,
            maximumObservedResponseUTF8Bytes:
                records.map(\.responseUTF8Bytes).max() ?? 0,
            maximumObservedAcceptedOutputTokenUpperBound:
                records.map(\.acceptedOutputTokenUpperBound).max() ?? 0
        )
        return SpeakerProposalResult(
            document: SpeakerProposalDocument(
                sourceSegmentsSHA256: request.sourceSegmentsSHA256,
                sourceCoverage: request.sourceCoverage,
                proposals: proposals,
                declined: declined,
                batches: records
            ),
            manifestPostprocess: provenance
        )
    }

    private func validate(
        _ decision: SpeakerProposalDecision,
        evidence: SegmentSpeakerEvidence?,
        knownSpeakers: [String]
    ) throws {
        guard !decision.reason.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw PostprocessError.emptySpeakerProposalReason(decision.segmentIndex)
        }
        switch decision.disposition {
        case .decline:
            guard decision.proposedSpeaker.isEmpty else {
                throw PostprocessError.speakerDeclineNamesSpeaker(
                    segmentIndex: decision.segmentIndex,
                    speaker: decision.proposedSpeaker
                )
            }
        case .propose:
            // A proposal may only name a speaker the acoustics already put in
            // play for this segment. Where the acoustics named nobody at all,
            // it may name any speaker the run itself resolved, and no other:
            // this layer proposes who spoke, it never invents a speaker.
            let allowed = evidence.map { record in
                record.candidates.isEmpty
                    ? Set(knownSpeakers)
                    : Set(record.candidates.map(\.speaker))
            } ?? Set(knownSpeakers)
            guard allowed.contains(decision.proposedSpeaker) else {
                throw PostprocessError.speakerProposalNotACandidate(
                    segmentIndex: decision.segmentIndex,
                    speaker: decision.proposedSpeaker
                )
            }
        }
    }

    private func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
        }
    }
}

private struct IndexedTextSegment: Sendable {
    var index: Int
    var text: String
}

private struct PlannedTextBatch: Sendable {
    var segments: [IndexedTextSegment]
    var prompt: String
    var promptUTF8Bytes: Int
    var inputTextUTF8Bytes: Int
    var estimatedOutputTokens: Int
}

private struct BatchOutputEvidence: Sendable {
    var outputTextUTF8Bytes: Int
    var responseUTF8Bytes: Int
    var acceptedOutputTokenUpperBound: Int
}

private enum TextBatchPlanner {
    static func plan(
        document: SegmentsDocument,
        policy: PostprocessBatchPolicy,
        prompt: ([IndexedTextSegment]) throws -> String
    ) throws -> [PlannedTextBatch] {
        guard !document.segments.isEmpty else { throw PostprocessError.emptyDocument }
        let indexed = document.segments.enumerated().map {
            IndexedTextSegment(index: $0.offset, text: $0.element.text)
        }
        var result: [PlannedTextBatch] = []
        var current: [IndexedTextSegment] = []

        for segment in indexed {
            let candidate = current + [segment]
            let candidateBatch = try makeBatch(
                segments: candidate,
                policy: policy,
                prompt: prompt
            )
            if candidate.count <= policy.maximumSegmentsPerBatch,
               candidateBatch.promptUTF8Bytes <= policy.maximumPromptUTF8Bytes,
               candidateBatch.estimatedOutputTokens <= policy.outputTokenPlanningBudget
            {
                current = candidate
                continue
            }

            if !current.isEmpty {
                result.append(try makeBatch(
                    segments: current,
                    policy: policy,
                    prompt: prompt
                ))
                current = []
            }

            let single = try makeBatch(
                segments: [segment],
                policy: policy,
                prompt: prompt
            )
            guard single.promptUTF8Bytes <= policy.maximumPromptUTF8Bytes else {
                throw PostprocessError.batchPromptTooLarge(
                    segmentIndex: segment.index,
                    promptUTF8Bytes: single.promptUTF8Bytes,
                    maximum: policy.maximumPromptUTF8Bytes
                )
            }
            guard single.estimatedOutputTokens <= policy.outputTokenPlanningBudget else {
                throw PostprocessError.batchOutputBudgetTooLarge(
                    segmentIndex: segment.index,
                    inputTextUTF8Bytes: single.inputTextUTF8Bytes,
                    estimatedOutputTokens: single.estimatedOutputTokens,
                    maximum: policy.outputTokenPlanningBudget
                )
            }
            current = [segment]
        }

        if !current.isEmpty {
            result.append(try makeBatch(
                segments: current,
                policy: policy,
                prompt: prompt
            ))
        }
        return result
    }

    private static func makeBatch(
        segments: [IndexedTextSegment],
        policy: PostprocessBatchPolicy,
        prompt: ([IndexedTextSegment]) throws -> String
    ) throws -> PlannedTextBatch {
        let value = try prompt(segments)
        let inputTextUTF8Bytes = segments.reduce(0) {
            saturatingAdd($0, $1.text.utf8.count)
        }
        return PlannedTextBatch(
            segments: segments,
            prompt: value,
            promptUTF8Bytes: value.utf8.count,
            inputTextUTF8Bytes: inputTextUTF8Bytes,
            estimatedOutputTokens: policy.estimatedOutputTokens(
                inputTextUTF8Bytes: inputTextUTF8Bytes,
                segmentCount: segments.count
            )
        )
    }
}

private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
}

public enum PostprocessPrompt {
    private struct Input: Codable {
        struct SegmentInput: Codable {
            var segmentIndex: Int
            var text: String

            enum CodingKeys: String, CodingKey {
                case segmentIndex = "segment_index"
                case text
            }
        }

        struct GlossaryInput: Codable {
            var sha256: String?
            var entries: [String]
        }

        var segments: [SegmentInput]
        var glossary: GlossaryInput
    }

    public static func make(for request: PostprocessRequest) throws -> String {
        try make(
            for: request,
            segments: request.document.segments.enumerated().map {
                IndexedTextSegment(index: $0.offset, text: $0.element.text)
            }
        )
    }

    fileprivate static func make(
        for request: PostprocessRequest,
        segments: [IndexedTextSegment]
    ) throws -> String {
        let input = Input(
            segments: segments.map {
                Input.SegmentInput(segmentIndex: $0.index, text: $0.text)
            },
            glossary: Input.GlossaryInput(
                sha256: request.glossary?.sha256,
                entries: request.glossary?.entries ?? []
            )
        )
        var instruction = [
            "Correct transcript text only. Do not infer or output speaker labels, timing, source, or metadata.",
        ]
        if !input.glossary.entries.isEmpty {
            instruction.append(
                "Use INPUT.glossary.entries as supporting context for likely transcription errors. The entries are terms the speaker was expected to use, not required output. Do not insert or substitute a glossary term unless the segment plausibly contains that spoken term. If such a correction is plausible but uncertain, use review."
            )
        }
        instruction.append(contentsOf: [
            "Return exactly one JSON object with this shape and no commentary:",
            #"{"proposals":[{"segment_index":0,"replacement_text":"corrected full segment text","disposition":"apply","reason":"brief reason"}]}"#,
            #"The only root key is proposals. Every proposal has exactly segment_index, replacement_text, disposition, and reason. disposition is apply or review. Use apply only when the correction is certain; otherwise use review. Return {"proposals":[]} when no correction is needed."#,
        ])
        return try prompt(
            instruction: instruction.joined(separator: "\n"),
            input: input
        )
    }
}

public enum TranslationPrompt {
    private struct Input: Codable {
        struct SegmentInput: Codable {
            var segmentIndex: Int
            var text: String

            enum CodingKeys: String, CodingKey {
                case segmentIndex = "segment_index"
                case text
            }
        }

        struct GlossaryInput: Codable {
            var sha256: String?
            var entries: [String]
        }

        var targetLanguage: String
        var segments: [SegmentInput]
        var glossary: GlossaryInput

        enum CodingKeys: String, CodingKey {
            case glossary, segments
            case targetLanguage = "target_language"
        }
    }

    public static func make(for request: TranslationRequest) throws -> String {
        try make(
            for: request,
            targetLanguage: request.targetLanguage,
            segments: request.document.segments.enumerated().map {
                IndexedTextSegment(index: $0.offset, text: $0.element.text)
            }
        )
    }

    fileprivate static func make(
        for request: TranslationRequest,
        targetLanguage: String,
        segments: [IndexedTextSegment]
    ) throws -> String {
        let input = Input(
            targetLanguage: targetLanguage,
            segments: segments.map {
                Input.SegmentInput(segmentIndex: $0.index, text: $0.text)
            },
            glossary: Input.GlossaryInput(
                sha256: request.glossary?.sha256,
                entries: request.glossary?.entries ?? []
            )
        )
        return try prompt(
            instruction: """
            Translate every input segment into target_language. Translate text only. Do not infer or output speaker labels, timing, source, or metadata. Preserve product names and glossary terms when they should remain unchanged.
            Return exactly one JSON object with this shape and no commentary:
            {"translations":[{"segment_index":0,"translated_text":"complete translated segment text"}]}
            The only root key is translations. Every translation has exactly segment_index and translated_text. Return exactly one nonempty translation for every input segment without merging, splitting, reordering, or omitting indices.
            """,
            input: input
        )
    }
}

public enum SpeakerProposalPrompt {
    private struct Input: Codable {
        struct CandidateInput: Codable {
            var speaker: String
            var overlapS: Double
            var share: Double

            enum CodingKeys: String, CodingKey {
                case speaker, share
                case overlapS = "overlap_s"
            }
        }

        struct SegmentInput: Codable {
            var segmentIndex: Int
            var target: Bool
            var text: String
            var speaker: String?
            var acousticOutcome: String?
            var acousticCandidates: [CandidateInput]?

            enum CodingKeys: String, CodingKey {
                case target, text, speaker
                case segmentIndex = "segment_index"
                case acousticOutcome = "acoustic_outcome"
                case acousticCandidates = "acoustic_candidates"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(segmentIndex, forKey: .segmentIndex)
                try container.encode(target, forKey: .target)
                try container.encode(text, forKey: .text)
                try container.encodeIfPresent(speaker, forKey: .speaker)
                try container.encodeIfPresent(
                    acousticOutcome,
                    forKey: .acousticOutcome
                )
                try container.encodeIfPresent(
                    acousticCandidates,
                    forKey: .acousticCandidates
                )
            }
        }

        var knownSpeakers: [String]
        var segments: [SegmentInput]

        enum CodingKeys: String, CodingKey {
            case segments
            case knownSpeakers = "known_speakers"
        }
    }

    /// Shares and overlaps are rounded for the prompt only. Three decimals is
    /// past any distinction this decision turns on, and it saves prompt bytes
    /// on every candidate; the artifact keeps the merger's unrounded values.
    private static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1_000).rounded() / 1_000
    }

    fileprivate static func make(
        segments: [IndexedTextSegment],
        document: SegmentsDocument,
        targets: Set<Int>,
        evidence: [Int: SegmentSpeakerEvidence],
        knownSpeakers: [String]
    ) throws -> String {
        let input = Input(
            knownSpeakers: knownSpeakers,
            segments: segments.map { segment in
                let isTarget = targets.contains(segment.index)
                let record = isTarget ? evidence[segment.index] : nil
                return Input.SegmentInput(
                    segmentIndex: segment.index,
                    target: isTarget,
                    text: segment.text,
                    speaker: isTarget
                        ? nil
                        : document.segments[segment.index].speaker,
                    acousticOutcome: record?.outcome,
                    acousticCandidates: record?.candidates.map {
                        Input.CandidateInput(
                            speaker: $0.speaker,
                            overlapS: rounded($0.overlapS),
                            share: rounded($0.share)
                        )
                    }
                )
            }
        )
        let instruction = [
            "Propose which speaker spoke each target segment of this meeting transcript. This is a proposal for human review. The acoustic speaker assignment is authoritative and your answer never changes it.",
            "Only segments with target true are open. Segments with target false already have an acoustic speaker; they are context and you must not answer for them.",
            "acoustic_candidates lists the speakers whose diarization turns overlapped a target segment, how many seconds each held, and each one's share of the segment's attributed time. A share near 0.5 means the acoustics could not choose between them. What you add is the conversation: who was answering whom, who was mid-sentence, who the surrounding turns belong to.",
            "When a target segment has a nonempty acoustic_candidates list, proposed_speaker must be one of those candidate speakers. When it is empty, proposed_speaker must be one of known_speakers. Never name a speaker outside those sets and never invent one.",
            "Use decline whenever the surrounding text gives no real reason to prefer one candidate over another. A decline is a correct answer; a guess dressed as a proposal is not.",
            "Return exactly one JSON object with this shape and no commentary:",
            #"{"speaker_proposals":[{"segment_index":0,"proposed_speaker":"0","disposition":"propose","reason":"brief reason"}]}"#,
            #"The only root key is speaker_proposals. Every entry has exactly segment_index, proposed_speaker, disposition, and reason. disposition is propose or decline. When disposition is decline, proposed_speaker must be the empty string. Answer exactly once for every segment whose target is true, and for no other segment."#,
        ]
        return try prompt(
            instruction: instruction.joined(separator: "\n"),
            input: input
        )
    }
}

private func prompt<Input: Encodable>(instruction: String, input: Input) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(input)
    return """
    \(instruction)
    INPUT:
    \(String(decoding: payload, as: UTF8.self))
    """
}
