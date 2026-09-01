@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import MaccheroniASR
import MaccheroniCore
import MaccheroniDiarize
import MaccheroniMerge
import MaccheroniPostprocess
import MaccheroniPreprocess
import MaccheroniStorage

private let cliResourcesBundle = PackagedResourceBundle.resolve(
    named: "Maccheroni_MaccheroniCLI"
) { Bundle.module }

public enum CLIError: Error, LocalizedError, Sendable {
    case usage(String)
    case profile(String)
    case postprocess(String)
    case glossary(String)
    case mossLimitExhausted(String)
    /// A limit outcome on a non-MOSS backend that recovery could not clear and
    /// that left no promotable prefix.  It is deliberately distinct from
    /// `mossLimitExhausted`, which names the MOSS recovery tree.
    case asrLimitExhausted(String)
    /// The decoder collapsed into repetition and neither recovery nor prefix
    /// promotion produced a usable result for the whole planned range.
    case asrRepetitionDegeneration(String)
    case run(String)
    case sourceIntegrity(RunIntegrityError)

    public var code: String {
        switch self {
        case .usage: "USAGE_ERROR"
        case .profile: "PROFILE_ERROR"
        case .postprocess: "POSTPROCESS_ERROR"
        case .glossary: "GLOSSARY_ERROR"
        case .mossLimitExhausted: "MOSS_LIMIT_EXHAUSTED"
        case .asrLimitExhausted: "ASR_LIMIT_EXHAUSTED"
        case .asrRepetitionDegeneration: "ASR_REPETITION_DEGENERATION"
        case .run: "RUN_ERROR"
        case .sourceIntegrity: "SOURCE_INTEGRITY_ERROR"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .usage(message), let .profile(message), let .postprocess(message),
             let .glossary(message), let .mossLimitExhausted(message),
             let .asrLimitExhausted(message),
             let .asrRepetitionDegeneration(message),
             let .run(message): message
        case let .sourceIntegrity(error): error.localizedDescription
        }
    }
}

public struct CLIASRInferencePolicy: Codable, Equatable, Sendable {
    public var source = "production-default"
    public var sampleRateHz: Int
    public var minimumInitialDurationS: Double
    public var preferredInitialDurationS: Double
    public var maximumInitialDurationS: Double
    public var minimumRecoveryDurationS: Double
    public var maximumRecoveryDepth: Int
    public var maximumTokens: Int
    public var contextHardCapTokens: Int?
    public var audioContextTokensPerSecond: Double?
    public var observedGeneratedTokensPerSecond: Double?

    public static func policy(for backend: SelectedASRBackend) -> Self {
        switch backend {
        case .moss:
            Self(
                sampleRateHz: 16_000,
                minimumInitialDurationS: 60,
                preferredInitialDurationS: 120,
                maximumInitialDurationS: 120,
                minimumRecoveryDurationS: 30,
                maximumRecoveryDepth: 3,
                maximumTokens: 5_120,
                contextHardCapTokens: 131_072,
                audioContextTokensPerSecond: 12.5,
                observedGeneratedTokensPerSecond: 7.7882
            )
        case .vibeVoice:
            // Derived in the VibeVoice section of
            // docs/engineering-constraint-policy.md.  The binding constraint is
            // repetition degeneration, not the token cap: no leaf longer than
            // 120 s has a clean record on the measured passages, and a 240 s
            // leaf collapsed on one of the two offsets it was measured at.
            // Depth 2 is the depth at which a 120 s parent reaches the 30 s
            // recovery floor.
            Self(
                sampleRateHz: 16_000,
                minimumInitialDurationS: 60,
                preferredInitialDurationS: 120,
                maximumInitialDurationS: 120,
                minimumRecoveryDurationS: 30,
                maximumRecoveryDepth: 2,
                maximumTokens: 5_120,
                contextHardCapTokens: nil,
                audioContextTokensPerSecond: 7.5,
                // Falsified at 7.61 by an accepted leaf in the 2026-09-01
                // full-file run: 22 segments in 31.87 s of rapid backchannel
                // generated 744 tokens.  Segment density, not audio seconds,
                // drives this.
                observedGeneratedTokensPerSecond: 23.34
            )
        case .qwen3:
            // D37 withdrew Qwen as a product fallback: the pinned backend
            // exposes no enforceable cap, terminal reason, or intra-chunk
            // timing, so no leaf on this path is promotable and no leaf
            // measurement exists to re-derive these bounds from.
            Self(
                sampleRateHz: 16_000,
                minimumInitialDurationS: 10 * 60,
                preferredInitialDurationS: 15 * 60,
                maximumInitialDurationS: 20 * 60,
                minimumRecoveryDurationS: 30,
                maximumRecoveryDepth: 0,
                maximumTokens: 5_120,
                contextHardCapTokens: nil,
                audioContextTokensPerSecond: nil,
                observedGeneratedTokensPerSecond: nil
            )
        }
    }

    static func resolvedPolicy(
        for backend: SelectedASRBackend,
        environment: [String: String]
    ) throws -> Self {
        var policy = policy(for: backend)
        let leafValue = environment["MACCHERONI_MOSS_EVAL_LEAF_SECONDS"]
        let tokenValue = environment["MACCHERONI_MOSS_EVAL_MAX_TOKENS"]
        guard leafValue != nil || tokenValue != nil else { return policy }
        guard backend == .moss else {
            throw CLIError.usage(
                "MOSS evaluation overrides require the MOSS backend"
            )
        }
        guard environment["MACCHERONI_ENABLE_BENCHMARK_OVERRIDES"] == "1" else {
            throw CLIError.usage(
                "MOSS evaluation overrides require explicit benchmark opt-in"
            )
        }
        if let leafValue {
            guard let leafSeconds = Double(leafValue),
                  [120.0, 240.0, 300.0].contains(leafSeconds)
            else {
                throw CLIError.usage(
                    "MOSS evaluation leaf seconds must be 120, 240, or 300"
                )
            }
            policy.minimumInitialDurationS = min(120, leafSeconds)
            policy.preferredInitialDurationS = leafSeconds
            policy.maximumInitialDurationS = leafSeconds
        }
        if let tokenValue {
            guard let maximumTokens = Int(tokenValue),
                  [1_024, 5_120].contains(maximumTokens)
            else {
                throw CLIError.usage(
                    "MOSS evaluation max tokens must be 1024 or 5120"
                )
            }
            policy.maximumTokens = maximumTokens
        }
        policy.source = "benchmark-evaluation"
        return policy
    }

    var planningConfiguration: InferenceLeafPlanningConfiguration {
        InferenceLeafPlanningConfiguration(
            sampleRateHz: sampleRateHz,
            preferredInitialDurationS: preferredInitialDurationS,
            minimumInitialDurationS: minimumInitialDurationS,
            maximumInitialDurationS: maximumInitialDurationS,
            minimumRecoveryDurationS: minimumRecoveryDurationS,
            maximumRecoveryDepth: maximumRecoveryDepth
        )
    }

    enum CodingKeys: String, CodingKey {
        case source
        case sampleRateHz = "sample_rate_hz"
        case minimumInitialDurationS = "minimum_initial_duration_s"
        case preferredInitialDurationS = "preferred_initial_duration_s"
        case maximumInitialDurationS = "maximum_initial_duration_s"
        case minimumRecoveryDurationS = "minimum_recovery_duration_s"
        case maximumRecoveryDepth = "maximum_recovery_depth"
        case maximumTokens = "maximum_tokens"
        case contextHardCapTokens = "context_hard_cap_tokens"
        case audioContextTokensPerSecond = "audio_context_tokens_per_second"
        case observedGeneratedTokensPerSecond = "observed_generated_tokens_per_second"
    }
}

public struct CLIProfileFile: Codable, Sendable {
    public var schemaVersion: String
    public var profiles: [CLIProfile]
    enum CodingKeys: String, CodingKey { case profiles; case schemaVersion = "schema_version" }
}

public struct CLIProfile: Codable, Sendable {
    public struct Diarization: Codable, Sendable { public var enabled: Bool; public var backend: String }
    public var name: String
    public var asrBackend: String
    public var languagePin: LanguagePin
    public var diarization: Diarization
    public var postprocess: String
    public var postprocessMode: PostprocessMode?
    public var targetLanguage: String?
    public var glossaryPath: String?
    enum CodingKeys: String, CodingKey {
        case name, diarization, postprocess
        case asrBackend = "asr_backend"
        case languagePin = "language_pin"
        case glossaryPath = "glossary_path"
        case postprocessMode = "postprocess_mode"
        case targetLanguage = "target_language"
    }
}

public struct CLIASRAttemptEvidence: Sendable {
    public var glossary: ManifestGlossary
    public var rawEvidence: Data
    public var runnerRecordEvidence: Data
    public var glossaryPayloadSHA256: String?
    public var glossaryPayloadEntryCount: Int
    public var metrics: ASRAttemptMetrics?
    public var language: ASRLanguageEvidence?
    public var helperFingerprint: ASRHelperFingerprint?
    public var inputSHA256: String?
    public var command: [String]

    public init(
        glossary: ManifestGlossary,
        rawEvidence: Data,
        runnerRecordEvidence: Data = Data(),
        glossaryPayloadSHA256: String? = nil,
        glossaryPayloadEntryCount: Int = 0,
        metrics: ASRAttemptMetrics? = nil,
        language: ASRLanguageEvidence? = nil,
        helperFingerprint: ASRHelperFingerprint? = nil,
        inputSHA256: String? = nil,
        command: [String] = []
    ) {
        self.glossary = glossary
        self.rawEvidence = rawEvidence
        self.runnerRecordEvidence = runnerRecordEvidence
        self.glossaryPayloadSHA256 = glossaryPayloadSHA256
        self.glossaryPayloadEntryCount = glossaryPayloadEntryCount
        self.metrics = metrics
        self.language = language
        self.helperFingerprint = helperFingerprint
        self.inputSHA256 = inputSHA256
        self.command = command
    }
}

public struct CLIASRExecution: Sendable {
    public var result: ASRResult
    public var evidence: CLIASRAttemptEvidence

    public init(
        result: ASRResult,
        glossary: ManifestGlossary,
        rawEvidence: Data
    ) {
        self.result = result
        evidence = CLIASRAttemptEvidence(
            glossary: glossary,
            rawEvidence: rawEvidence
        )
    }

    public init(result: ASRResult, evidence: CLIASRAttemptEvidence) {
        self.result = result
        self.evidence = evidence
    }
}

public struct CLIASRLimit: Sendable {
    public var stopReason: ASRAttemptStopReason
    public var evidence: CLIASRAttemptEvidence
    /// The leading valid transcript this limit outcome still holds, when the
    /// backend could recover one.  Promotion is the caller's decision.
    public var partialPrefix: ASRPartialPrefix?

    public init(
        stopReason: ASRAttemptStopReason,
        evidence: CLIASRAttemptEvidence,
        partialPrefix: ASRPartialPrefix? = nil
    ) {
        self.stopReason = stopReason
        self.evidence = evidence
        self.partialPrefix = partialPrefix
    }
}

public enum CLIASRAttemptOutcome: Sendable {
    case complete(CLIASRExecution)
    case limit(CLIASRLimit)
}

private struct ASRConstraintSnapshot: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var backend: String
    var model: ModelDescriptor
    var policy: CLIASRInferencePolicy
    var totalSamples: Int64
    var initialLeafCount: Int
    var overlapEnabled = false
    var previousTextContextEnabled = false
    var helperFingerprint: ASRHelperFingerprint?
    var mossContextPlan: MOSSContextPlan?
    var maximumAttemptCount: Int
    var sequentialConcurrency = 1
    var retainedPCMBytesUpperBound: Int64
    var preflightFailure: String?

    enum CodingKeys: String, CodingKey {
        case backend, model, policy
        case schemaVersion = "schema_version"
        case totalSamples = "total_samples"
        case initialLeafCount = "initial_leaf_count"
        case overlapEnabled = "overlap_enabled"
        case previousTextContextEnabled = "previous_text_context_enabled"
        case helperFingerprint = "helper_fingerprint"
        case mossContextPlan = "moss_context_plan"
        case maximumAttemptCount = "maximum_attempt_count"
        case sequentialConcurrency = "sequential_concurrency"
        case retainedPCMBytesUpperBound = "retained_pcm_bytes_upper_bound"
        case preflightFailure = "preflight_failure"
    }
}

private struct ASRAttemptRequestRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var attemptID: String
    var parentID: String?
    var rootChunkIndex: Int
    var depth: Int
    var startSample: Int64
    var endSample: Int64
    var sampleRateHz: Int
    var boundarySource: InferenceLeafBoundarySource
    var audioPath: String
    var audioSHA256: String
    var backend: String
    var model: ModelDescriptor
    var language: String
    var glossary: ManifestGlossary
    var maximumTokens: Int
    var promptTokens: Int?
    var audioTokens: Int?
    var contextUpperBoundTokens: Int?
    var helperFingerprint: ASRHelperFingerprint?

    enum CodingKeys: String, CodingKey {
        case backend, model, language, glossary
        case schemaVersion = "schema_version"
        case attemptID = "attempt_id"
        case parentID = "parent_id"
        case rootChunkIndex = "root_chunk_index"
        case depth
        case startSample = "start_sample"
        case endSample = "end_sample"
        case sampleRateHz = "sample_rate_hz"
        case boundarySource = "boundary_source"
        case audioPath = "audio_path"
        case audioSHA256 = "audio_sha256"
        case maximumTokens = "maximum_tokens"
        case promptTokens = "prompt_tokens"
        case audioTokens = "audio_tokens"
        case contextUpperBoundTokens = "context_upper_bound_tokens"
        case helperFingerprint = "helper_fingerprint"
    }
}

/// Attempt statuses double as the persisted failure identifier: an attempt
/// status and the manifest `failure.code` for the same error must be the same
/// string so evidence can be bucketed from either record alone.
private enum ASRAttemptStatus: String, Codable, Sendable {
    case eosComplete = "eos_complete"
    case limitIsolated = "limit_isolated"
    case limitExhausted = "limit_exhausted"
    case repetitionDegeneration = "repetition_degeneration"
    case partialPrefixPromoted = "partial_prefix_promoted"
    case invalidEOSOutput = "invalid_eos_output"
    case asrTimeout = "asr_timeout"
    case asrEvidenceUnavailable = "asr_evidence_unavailable"
    case asrMalformedOutput = "asr_malformed_output"
    case asrCoverageShortfall = "asr_coverage_shortfall"
    case asrModelIdentityMismatch = "asr_model_identity_mismatch"
    case backendFailed = "backend_failed"
    case canceled = "CANCELED"
}

private struct ASRAttemptOutcomeRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var attemptID: String
    var requestSHA256: String?
    var status: ASRAttemptStatus
    var stopReason: ASRAttemptStopReason?
    var canonicalPromoted: Bool
    var childAttemptIDs: [String]
    var runnerRecordPath: String?
    var runnerRecordSHA256: String?
    var backendRawPath: String?
    var backendRawSHA256: String?
    var resultPath: String?
    var resultSHA256: String?
    var glossary: ManifestGlossary?
    var glossaryPayloadSHA256: String?
    var glossaryPayloadEntryCount: Int?
    var metrics: ASRAttemptMetrics?
    var audioTokens: Int?
    var contextTokens: Int?
    var language: ASRLanguageEvidence?
    var helperFingerprint: ASRHelperFingerprint?
    var command: [String]?
    var errorCode: String?
    var errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case status, glossary, metrics, language, command
        case schemaVersion = "schema_version"
        case attemptID = "attempt_id"
        case requestSHA256 = "request_sha256"
        case stopReason = "stop_reason"
        case canonicalPromoted = "canonical_promoted"
        case childAttemptIDs = "child_attempt_ids"
        case runnerRecordPath = "runner_record_path"
        case runnerRecordSHA256 = "runner_record_sha256"
        case backendRawPath = "backend_raw_path"
        case backendRawSHA256 = "backend_raw_sha256"
        case resultPath = "result_path"
        case resultSHA256 = "result_sha256"
        case glossaryPayloadSHA256 = "glossary_payload_sha256"
        case glossaryPayloadEntryCount = "glossary_payload_entry_count"
        case audioTokens = "audio_tokens"
        case contextTokens = "context_tokens"
        case helperFingerprint = "helper_fingerprint"
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

private struct CompletedASRLeaf: Sendable {
    var attemptID: String
    var leaf: InferenceLeaf
    var execution: CLIASRExecution
    var resultSHA256: String
    /// The last sample this attempt actually produced transcript for.  It
    /// equals `leaf.endSample` for an end-of-sequence leaf and is smaller when
    /// only a recovered prefix was promoted.
    var coveredEndSample: Int64
    var stopReason: ASRAttemptStopReason

    var isPartial: Bool { coveredEndSample < leaf.endSample }
}

/// One leaf whose range no attempt could transcribe, after recovery was spent.
/// It ends the leaf, not the run: the caller records the range and keeps every
/// other leaf's transcript.
private struct UnrecoveredASRLeaf: Sendable {
    var attemptID: String
    var leaf: InferenceLeaf
    var stopReason: ASRAttemptStopReason
    var failure: CLIError
}

/// What one leaf and its recovery subtree produced.
private struct ASRLeafResult: Sendable {
    var completed: [CompletedASRLeaf] = []
    var unrecovered: [UnrecoveredASRLeaf] = []

    static func += (lhs: inout ASRLeafResult, rhs: ASRLeafResult) {
        lhs.completed += rhs.completed
        lhs.unrecovered += rhs.unrecovered
    }
}

/// A half-open source range that no attempt produced transcript for.
private struct MissingSourceRange: Codable, Sendable, Equatable {
    var startS: Double
    var endS: Double
    var attemptID: String
    var stopReason: ASRAttemptStopReason
    /// The typed failure this range would have produced had it ended the run.
    /// Carried so the manifest reports the real cause per backend instead of
    /// inferring one.
    var failureCode: String

    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case startS = "start_s"
        case endS = "end_s"
        case stopReason = "stop_reason"
        case failureCode = "failure_code"
    }
}

/// The explicit record of what a run promoted and what it did not, written
/// whenever any leaf promoted only a recovered prefix.  Judgment rule 2: the
/// missing ranges are named rather than folded into a single duration.
private struct PartialCoverageRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var inputDurationS: Double
    var promotedDurationS: Double
    var missingDurationS: Double
    var missing: [MissingSourceRange]
    var partialAttemptIDs: [String]

    enum CodingKeys: String, CodingKey {
        case missing
        case schemaVersion = "schema_version"
        case inputDurationS = "input_duration_s"
        case promotedDurationS = "promoted_duration_s"
        case missingDurationS = "missing_duration_s"
        case partialAttemptIDs = "partial_attempt_ids"
    }
}

private struct ASRRootIndexRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var rootChunkIndex: Int
    var rootAttemptID: String
    var eosLeafAttemptIDs: [String]
    var eosLeafResultSHA256: [String]
    /// Attempts whose recovered prefix was promoted.  They are listed apart
    /// from the end-of-sequence leaves because they do not cover their range.
    var partialPrefixAttemptIDs: [String] = []
    var partialPrefixResultSHA256: [String] = []

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rootChunkIndex = "root_chunk_index"
        case rootAttemptID = "root_attempt_id"
        case eosLeafAttemptIDs = "eos_leaf_attempt_ids"
        case eosLeafResultSHA256 = "eos_leaf_result_sha256"
        case partialPrefixAttemptIDs = "partial_prefix_attempt_ids"
        case partialPrefixResultSHA256 = "partial_prefix_result_sha256"
    }
}

private struct CanonicalPromotionRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var inputSHA256Before: String
    var inputSHA256AtPromotion: String
    var eosLeafAttemptIDs: [String]
    var eosLeafResultSHA256: [String]
    var partialPrefixAttemptIDs: [String] = []
    var canonicalArtifactSHA256: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case inputSHA256Before = "input_sha256_before"
        case inputSHA256AtPromotion = "input_sha256_at_promotion"
        case eosLeafAttemptIDs = "eos_leaf_attempt_ids"
        case eosLeafResultSHA256 = "eos_leaf_result_sha256"
        case partialPrefixAttemptIDs = "partial_prefix_attempt_ids"
        case canonicalArtifactSHA256 = "canonical_artifact_sha256"
    }
}

public struct CLIDependencies: Sendable {
    public var inputSHA256: @Sendable (URL) throws -> String
    public var inferencePolicy: @Sendable (
        SelectedASRBackend
    ) throws -> CLIASRInferencePolicy
    public var preprocess: @Sendable (URL, URL) throws -> PreprocessedAudio
    public var vad: @Sendable (URL) async throws -> VoiceActivityMap
    public var plan: @Sendable (
        VoiceActivityMap,
        CLIASRInferencePolicy,
        Int64
    ) throws -> [InferenceLeaf]
    public var expectedHelperFingerprint: @Sendable (
        SelectedASRBackend
    ) throws -> ASRHelperFingerprint?
    public var mossContextPlan: @Sendable (
        SelectedASRBackend,
        Int64,
        LanguagePin,
        Glossary?,
        Int
    ) async throws -> MOSSContextPlan?
    public var diarize: @Sendable (
        String,
        DiarizationRequest
    ) async throws -> DiarizationTimelineResult
    public var asr: @Sendable (
        SelectedASRBackend,
        ASRRequest,
        URL,
        Int
    ) async throws -> CLIASRAttemptOutcome
    public var postprocess: @Sendable (
        PostprocessBackendID,
        PostprocessRequest
    ) async throws -> PostprocessResult
    public var translate: @Sendable (
        PostprocessBackendID,
        TranslationRequest
    ) async throws -> TranslationResult
    public var proposeSpeakers: @Sendable (
        PostprocessBackendID,
        SpeakerProposalRequest
    ) async throws -> SpeakerProposalResult
    public var glossaryRevisionStoreRoot: @Sendable () -> URL
    public var postprocessDoctor: @Sendable (PostprocessBackendID) async -> [String]
    public var doctor: @Sendable (SelectedASRBackend, CLIProfile) async -> [String]

    public static let production = CLIDependencies(
        inputSHA256: { try AudioPreprocessor.sha256(of: $0) },
        inferencePolicy: {
            try CLIASRInferencePolicy.resolvedPolicy(
                for: $0,
                environment: ProcessInfo.processInfo.environment
            )
        },
        preprocess: { input, directory in try AudioPreprocessor().preprocess(inputURL: input, outputDirectory: directory, settings: .init(enhancement: .disabled)) },
        vad: { try await productionVADAdapter().detect(audioURL: $0) },
        plan: productionASRPlan,
        expectedHelperFingerprint: productionMossHelperFingerprint,
        mossContextPlan: { selected, samples, language, glossary, tokens in
            guard selected == .moss else { return nil }
            return try await MOSSContextPlanner.plan(
                sampleCount: samples,
                language: language,
                glossary: glossary,
                maximumTokens: tokens
            )
        },
        diarize: { name, request in
            switch name {
            case "community1":
                return try await Community1Diarizer(
                    configuration: productionCommunity1Configuration()
                ).diarizeWithEvidence(request)
            case "fluid":
                return try await FluidAudioDiarizer().diarizeWithEvidence(request)
            default: throw CLIError.profile("unknown diarization backend: \(name)")
            }
        },
        asr: { selected, request, outputRoot, maximumTokens in
            var runtime = ASRRuntime.local; runtime.outputRoot = outputRoot
            let outcome = try await PinnedASRAdapter(
                selected,
                runtime: runtime
            ).transcribeAttempt(request, maximumTokens: maximumTokens)
            switch outcome {
            case let .complete(record):
                return .complete(CLIASRExecution(
                    result: record.result,
                    evidence: CLIASRAttemptEvidence(
                        glossary: record.glossary,
                        rawEvidence: try Data(
                            contentsOf: record.backendRawArtifactURL
                        ),
                        runnerRecordEvidence: try Data(
                            contentsOf: record.outputURL
                        ),
                        glossaryPayloadSHA256: record.glossaryPayloadSHA256,
                        glossaryPayloadEntryCount: record.glossaryPayloadEntryCount,
                        metrics: record.metrics,
                        language: record.language,
                        helperFingerprint: record.helperFingerprint,
                        inputSHA256: record.inputSHA256,
                        command: record.command
                    )
                ))
            case let .limit(record):
                return .limit(CLIASRLimit(
                    stopReason: record.stopReason,
                    evidence: CLIASRAttemptEvidence(
                        glossary: record.glossary,
                        rawEvidence: try Data(
                            contentsOf: record.backendRawArtifactURL
                        ),
                        runnerRecordEvidence: try Data(
                            contentsOf: record.outputURL
                        ),
                        glossaryPayloadSHA256: record.glossaryPayloadSHA256,
                        glossaryPayloadEntryCount: record.glossaryPayloadEntryCount,
                        metrics: record.metrics,
                        language: record.language,
                        helperFingerprint: record.helperFingerprint,
                        inputSHA256: record.inputSHA256,
                        command: record.command
                    ),
                    partialPrefix: record.partialPrefix
                ))
            }
        },
        postprocess: productionPostprocess,
        translate: productionTranslation,
        proposeSpeakers: productionSpeakerProposal,
        glossaryRevisionStoreRoot: CLIApplication.defaultGlossaryRevisionStoreRoot,
        postprocessDoctor: productionPostprocessDoctorChecks,
        doctor: productionDoctorChecks
    )
}

struct CLIDoctorReport: Equatable, Sendable {
    var diagnosticValues: String
    var storage: StorageReport
    var isReady: Bool

    var diagnostics: String {
        ([diagnosticValues] + storage.textLines()).joined(separator: "\n")
    }
}

public struct CLIApplication: Sendable {
    public var dependencies: CLIDependencies
    public var now: @Sendable () -> Date
    public var runID: @Sendable (Date) -> String
    public var libraryStorageConfiguration: @Sendable () -> LibraryStorageConfiguration
    public var storageReport: @Sendable (
        CLIProfile,
        LibraryStorageConfiguration
    ) -> StorageReport
    public init(
        dependencies: CLIDependencies = .production,
        now: @escaping @Sendable () -> Date = Date.init,
        runID: @escaping @Sendable (Date) -> String = CLIApplication.defaultRunID,
        libraryStorageConfiguration: @escaping @Sendable () -> LibraryStorageConfiguration = CLIApplication.productionLibraryStorageConfiguration,
        storageReport: @escaping @Sendable (
            CLIProfile,
            LibraryStorageConfiguration
        ) -> StorageReport = CLIApplication.productionStorageReport
    ) {
        self.dependencies = dependencies
        self.now = now
        self.runID = runID
        self.libraryStorageConfiguration = libraryStorageConfiguration
        self.storageReport = storageReport
    }

    public static func defaultRunID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(formatter.string(from: date))-\(suffix)"
    }

    public static func productionLibraryStorageConfiguration() -> LibraryStorageConfiguration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return LibraryStorageConfiguration(
            applicationSupportDirectory: home.appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            ),
            environment: ProcessInfo.processInfo.environment,
            preferences: .appDomain()
        )
    }

    public static func productionStorageReport(
        _ profile: CLIProfile,
        library: LibraryStorageConfiguration
    ) -> StorageReport {
        let roots = StorageRootInventory.current(
            library: library,
            profile: ConfiguredStorageProfile(
                diarizationBackend: profile.diarization.enabled
                    ? profile.diarization.backend
                    : nil,
                postprocessBackend: profile.postprocess,
                models: configuredModels(for: profile)
            )
        )
        return StorageReadinessReporter().report(roots: roots)
    }

    private static func configuredModels(for profile: CLIProfile) -> [ModelDescriptor] {
        var models = SelectedASRBackend(rawValue: profile.asrBackend).map { [$0.model] } ?? []
        if profile.diarization.enabled {
            switch profile.diarization.backend {
            case "community1": models.append(Community1Diarizer().model)
            case "fluid": models.append(FluidAudioDiarizer().model)
            default: break
            }
        }
        if profile.postprocess == PostprocessBackendID.local.rawValue {
            models.append(LocalPostprocessBackend.pinnedModel)
        }
        return models
    }

    public static func defaultGlossaryRevisionStoreRoot() -> URL {
        productionLibraryStorageConfiguration().root.appendingPathComponent(
            "Glossaries/Revisions",
            isDirectory: true
        )
    }

    public func execute(arguments: [String]) async throws -> String {
        let command = try CLICommand.parse(arguments)
        switch command {
        case let .run(audio, profile, profiles, outputRoot, glossary):
            return try await run(audio: audio, profileName: profile, profilesURL: profiles, outputRoot: outputRoot, glossaryURL: glossary)
        case let .postprocess(
            run,
            profile,
            profiles,
            glossary,
            glossarySemantics
        ):
            return try await postprocessExistingRun(
                runURL: run,
                profileName: profile,
                profilesURL: profiles,
                glossaryURL: glossary,
                glossarySemantics: glossarySemantics
            )
        case let .proposeSpeakers(run, profile, profiles):
            return try await proposeSpeakersForRun(
                runURL: run,
                profileName: profile,
                profilesURL: profiles
            )
        case let .doctor(profile, profiles):
            return try await doctor(profileName: profile, profilesURL: profiles)
        }
    }

    func executeProposeSpeakers(
        runPath: String,
        profileName: String,
        profilesPath: String? = nil
    ) async throws -> String {
        try await proposeSpeakersForRun(
            runURL: URL(fileURLWithPath: runPath, isDirectory: true),
            profileName: profileName,
            profilesURL: profilesPath.map(URL.init(fileURLWithPath:))
        )
    }

    func executePostprocess(
        runPath: String,
        profileName: String,
        profilesPath: String?,
        glossaryPath: String?,
        glossarySemantics: DerivedGlossarySemantics = .currentProfile
    ) async throws -> String {
        try await postprocessExistingRun(
            runURL: URL(fileURLWithPath: runPath, isDirectory: true),
            profileName: profileName,
            profilesURL: profilesPath.map(URL.init(fileURLWithPath:)),
            glossaryURL: glossaryPath.map(URL.init(fileURLWithPath:)),
            glossarySemantics: glossarySemantics
        )
    }

    func executeRun(
        audioPath: String,
        profileName: String,
        profilesPath: String?,
        outputRootPath: String?,
        glossaryPath: String?
    ) async throws -> String {
        try await run(
            audio: URL(fileURLWithPath: audioPath),
            profileName: profileName,
            profilesURL: profilesPath.map(URL.init(fileURLWithPath:)),
            outputRoot: outputRootPath.map(URL.init(fileURLWithPath:)),
            glossaryURL: glossaryPath.map(URL.init(fileURLWithPath:))
        )
    }

    func inspectDoctor(
        profileName: String?,
        profilesPath: String?
    ) async throws -> CLIDoctorReport {
        try await doctorReport(
            profileName: profileName,
            profilesURL: profilesPath.map(URL.init(fileURLWithPath:))
        )
    }

    private func postprocessExistingRun(
        runURL: URL,
        profileName: String,
        profilesURL: URL?,
        glossaryURL: URL?,
        glossarySemantics: DerivedGlossarySemantics
    ) async throws -> String {
        if glossarySemantics == .sourceRun, glossaryURL != nil {
            throw CLIError.usage(
                "--glossary cannot be combined with --glossary-semantics source-run"
            )
        }
        let resolution = try resolveProfile(
            name: profileName,
            profilesURL: profilesURL
        )
        let profile = resolution.profile
        guard let backend = PostprocessBackendID(rawValue: profile.postprocess) else {
            throw CLIError.profile(
                "existing-run postprocess requires a codex or local backend"
            )
        }
        let mode = profile.postprocessMode ?? .correction
        let source: VerifiedRunSource
        do {
            source = try RunIntegrityVerifier.verifyCompletedRun(at: runURL)
        } catch let error as RunIntegrityError {
            throw CLIError.sourceIntegrity(error)
        }
        let revisionStore = GlossaryRevisionStore(
            root: dependencies.glossaryRevisionStoreRoot()
        )
        let glossaryRevision: GlossaryRevision?
        switch glossarySemantics {
        case .currentProfile:
            glossaryRevision = try resolvedGlossaryRevision(
                cliURL: glossaryURL,
                profile: profile,
                profileDirectory: resolution.directory,
                store: revisionStore
            )
        case .sourceRun:
            glossaryRevision = try revisionStore.resolve(
                source.manifest.glossary
            )
        }
        let glossary = glossaryRevision?.glossary

        let started = now()
        let writer = try RunWriter(
            root: source.runURL.appendingPathComponent(
                "derived",
                isDirectory: true
            ),
            id: runID(started)
        )
        var artifacts: [Artifact] = []
        var provenance: ManifestPostprocess?
        let operation = DerivedOperation(
            profileName: profile.name,
            mode: mode,
            targetLanguage: mode == .translation ? profile.targetLanguage : nil,
            glossarySemantics: glossarySemantics,
            glossarySHA256: glossary?.sha256,
            glossaryItemCount: glossary?.entries.count ?? 0,
            sourceCoverage: source.coverage
        )

        func manifest(
            status: RunStatus,
            failure: Failure?
        ) -> DerivedManifest {
            let finished = now()
            return DerivedManifest(
                derivedID: writer.id,
                status: status,
                source: source.lineage,
                operation: operation,
                timing: RunTiming(
                    startedAt: ISO8601DateFormatter().string(from: started),
                    finishedAt: ISO8601DateFormatter().string(from: finished),
                    wallTimeS: max(0, finished.timeIntervalSince(started))
                ),
                artifacts: artifacts,
                failure: failure,
                postprocess: provenance
            )
        }

        try writer.write(
            manifest(
                status: .failed,
                failure: Failure(
                    code: "RUN_INCOMPLETE",
                    message: "derived postprocess initialized"
                )
            ),
            at: "manifest.json",
            replace: true
        )

        do {
            switch mode {
            case .correction:
                let result: PostprocessResult
                do {
                    result = try await dependencies.postprocess(
                        backend,
                        PostprocessRequest(
                            document: source.document,
                            glossary: glossary
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CLIError.postprocess(failureMessage(for: error))
                }
                try validate(
                    postprocess: result,
                    against: source.document,
                    glossary: glossary,
                    backend: backend
                )
                try writer.write(
                    result.document,
                    at: "postprocess/segments.json"
                )
                try writer.write(
                    result.conflicts,
                    at: "postprocess/conflicts.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "postprocess_segments",
                    relative: "postprocess/segments.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "postprocess_conflicts",
                    relative: "postprocess/conflicts.json"
                )
                provenance = result.manifestPostprocess
            case .translation:
                guard let targetLanguage = profile.targetLanguage else {
                    throw CLIError.profile(
                        "translation mode requires a valid target_language"
                    )
                }
                let result: TranslationResult
                do {
                    result = try await dependencies.translate(
                        backend,
                        TranslationRequest(
                            document: source.document,
                            targetLanguage: targetLanguage,
                            sourceSegmentsSHA256: source.lineage.segmentsSHA256,
                            glossary: glossary
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CLIError.postprocess(failureMessage(for: error))
                }
                try validate(
                    translation: result,
                    against: source.document,
                    sourceSegmentsSHA256: source.lineage.segmentsSHA256,
                    glossary: glossary,
                    backend: backend,
                    targetLanguage: targetLanguage
                )
                try writer.write(
                    result.document,
                    at: "postprocess/translation.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "postprocess_translation",
                    relative: "postprocess/translation.json"
                )
                provenance = result.manifestPostprocess
            }

            try writer.verify(artifacts: artifacts)
            let sourceAfter: VerifiedRunSource
            do {
                sourceAfter = try RunIntegrityVerifier.verifyCompletedRun(
                    at: source.runURL
                )
            } catch let error as RunIntegrityError {
                throw CLIError.sourceIntegrity(error)
            }
            guard sourceAfter.lineage == source.lineage else {
                throw CLIError.sourceIntegrity(.sourceChangedDuringOperation)
            }
            try writer.write(
                manifest(status: .succeeded, failure: nil),
                at: "manifest.json",
                replace: true
            )
            return writer.directory.path
        } catch {
            try? writer.addAllUntrackedArtifacts(
                &artifacts,
                kind: "preserved_partial_artifact"
            )
            artifacts = writer.rebuiltArtifacts(preservingKindsFrom: artifacts)
            let code: String
            if error is CancellationError {
                code = "CANCELED"
            } else if let cliError = error as? CLIError {
                code = cliError.code
            } else {
                code = "RUN_ERROR"
            }
            let message = error is CancellationError
                ? "derived postprocess was canceled"
                : failureMessage(for: error)
            try? writer.write(
                manifest(
                    status: error is CancellationError ? .canceled : .failed,
                    failure: Failure(code: code, message: message)
                ),
                at: "manifest.json",
                replace: true
            )
            throw error
        }
    }

    /// Create a derived run carrying a marked, non-acoustic speaker proposal
    /// for the segments the source run left unattributed.
    ///
    /// The source run is opened read-only, verified before and after, and never
    /// written to; the proposal lands in a fresh `derived/<id>/` set beside the
    /// correction and translation sets, under the same lineage contract.
    /// Judgment rule 4 permits this only as a marked proposal that carries the
    /// acoustic candidates beside it, so the acoustic evidence is read out of
    /// `merged/conflicts.json` and travels into the artifact with every record.
    private func proposeSpeakersForRun(
        runURL: URL,
        profileName: String,
        profilesURL: URL?
    ) async throws -> String {
        let resolution = try resolveProfile(
            name: profileName,
            profilesURL: profilesURL
        )
        let profile = resolution.profile
        guard let backend = PostprocessBackendID(rawValue: profile.postprocess) else {
            throw CLIError.profile(
                "a speaker proposal requires a codex or local backend"
            )
        }
        let source: VerifiedRunSource
        do {
            source = try RunIntegrityVerifier.verifyMergedRun(at: runURL)
        } catch let error as RunIntegrityError {
            throw CLIError.sourceIntegrity(error)
        }
        let evidence = try speakerEvidence(for: source)

        let started = now()
        let writer = try RunWriter(
            root: source.runURL.appendingPathComponent(
                "derived",
                isDirectory: true
            ),
            id: runID(started)
        )
        var artifacts: [Artifact] = []
        var provenance: ManifestPostprocess?
        let operation = DerivedOperation(
            profileName: profile.name,
            // `mode` describes a text operation and this one touches no text.
            // `kind` is the field that says what this derived run produced;
            // `ManifestPostprocess.mode` is non-optional, so a value has to be
            // written here either way.
            mode: .correction,
            targetLanguage: nil,
            glossarySemantics: .currentProfile,
            glossarySHA256: nil,
            glossaryItemCount: 0,
            kind: .speakerProposal,
            sourceCoverage: source.coverage
        )

        func manifest(status: RunStatus, failure: Failure?) -> DerivedManifest {
            let finished = now()
            return DerivedManifest(
                derivedID: writer.id,
                status: status,
                source: source.lineage,
                operation: operation,
                timing: RunTiming(
                    startedAt: ISO8601DateFormatter().string(from: started),
                    finishedAt: ISO8601DateFormatter().string(from: finished),
                    wallTimeS: max(0, finished.timeIntervalSince(started))
                ),
                artifacts: artifacts,
                failure: failure,
                postprocess: provenance
            )
        }

        try writer.write(
            manifest(
                status: .failed,
                failure: Failure(
                    code: "RUN_INCOMPLETE",
                    message: "derived speaker proposal initialized"
                )
            ),
            at: "manifest.json",
            replace: true
        )

        do {
            let result: SpeakerProposalResult
            do {
                result = try await dependencies.proposeSpeakers(
                    backend,
                    SpeakerProposalRequest(
                        document: source.document,
                        evidence: evidence,
                        sourceSegmentsSHA256: source.lineage.segmentsSHA256,
                        sourceCoverage: source.coverage
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw CLIError.postprocess(failureMessage(for: error))
            }
            try validate(
                speakerProposal: result,
                against: source.document,
                evidence: evidence,
                sourceSegmentsSHA256: source.lineage.segmentsSHA256,
                sourceCoverage: source.coverage,
                backend: backend
            )
            try writer.write(result.document, at: speakerProposalArtifactPath)
            try writer.addArtifact(
                &artifacts,
                kind: speakerProposalArtifactKind,
                relative: speakerProposalArtifactPath
            )
            provenance = result.manifestPostprocess

            try writer.verify(artifacts: artifacts)
            let sourceAfter: VerifiedRunSource
            do {
                sourceAfter = try RunIntegrityVerifier.verifyMergedRun(
                    at: source.runURL
                )
            } catch let error as RunIntegrityError {
                throw CLIError.sourceIntegrity(error)
            }
            guard sourceAfter.lineage == source.lineage else {
                throw CLIError.sourceIntegrity(.sourceChangedDuringOperation)
            }
            try writer.write(
                manifest(status: .succeeded, failure: nil),
                at: "manifest.json",
                replace: true
            )
            return """
            \(writer.directory.path)
            unattributed=\(evidence.count) \
            proposed=\(result.document.proposals.count) \
            declined=\(result.document.declined.count)
            source_coverage=\(source.coverage.complete ? "complete" : "partial") \
            processed_s=\(source.coverage.processedDurationS) \
            missing_s=\(source.coverage.missingDurationS)
            """
        } catch {
            try? writer.addAllUntrackedArtifacts(
                &artifacts,
                kind: "preserved_partial_artifact"
            )
            artifacts = writer.rebuiltArtifacts(preservingKindsFrom: artifacts)
            let code: String
            if error is CancellationError {
                code = "CANCELED"
            } else if let cliError = error as? CLIError {
                code = cliError.code
            } else {
                code = "RUN_ERROR"
            }
            let message = error is CancellationError
                ? "derived speaker proposal was canceled"
                : failureMessage(for: error)
            try? writer.write(
                manifest(
                    status: error is CancellationError ? .canceled : .failed,
                    failure: Failure(code: code, message: message)
                ),
                at: "manifest.json",
                replace: true
            )
            throw error
        }
    }

    /// Read the acoustic evidence P1 discloses on `merged/conflicts.json` and
    /// return exactly one record per unattributed segment.
    ///
    /// A segment that the merger left `UNASSIGNED` because no diarization
    /// timeline covered it raises no conflict at all, so it legitimately has no
    /// record. That case gets an explicit empty record rather than being
    /// dropped: a proposal must never appear beside silence about what the
    /// acoustics said.
    private func speakerEvidence(
        for source: VerifiedRunSource
    ) throws -> [SegmentSpeakerEvidence] {
        let unattributed = source.document.segments.indices.filter {
            UnattributedSpeaker.isUnattributed(
                source.document.segments[$0].speaker
            )
        }
        guard !unattributed.isEmpty else {
            throw CLIError.postprocess(
                "the source run left no segment unattributed, so there is nothing to propose a speaker for"
            )
        }
        guard let artifact = source.verifiedArtifacts.first(where: {
            $0.kind == "merged_conflicts"
        }) else {
            throw CLIError.sourceIntegrity(
                .requiredArtifactMissing(
                    kind: "merged_conflicts",
                    path: "merged/conflicts.json"
                )
            )
        }
        let url = source.runURL.appendingPathComponent(artifact.path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError.sourceIntegrity(.artifactMissing(artifact.path))
        }
        guard try RunIntegrityVerifier.sha256(of: url) == artifact.sha256 else {
            throw CLIError.sourceIntegrity(
                .artifactHashMismatch(artifact.path)
            )
        }
        let conflicts: [MergeConflict]
        do {
            conflicts = try JSONDecoder().decode([MergeConflict].self, from: data)
        } catch {
            throw CLIError.sourceIntegrity(.manifestInvalid)
        }

        // A segment can raise both an ambiguous-speaker and an
        // overlapping-speech record and both carry the same attribution. The
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
        return unattributed.map { index in
            guard let attribution = attributionByIndex[index] else {
                return SegmentSpeakerEvidence(
                    segmentIndex: index,
                    outcome: "no_acoustic_record",
                    candidates: [],
                    timelineCoverage: 0
                )
            }
            return SegmentSpeakerEvidence(
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
    }

    private func validate(
        speakerProposal result: SpeakerProposalResult,
        against original: SegmentsDocument,
        evidence: [SegmentSpeakerEvidence],
        sourceSegmentsSHA256: String,
        sourceCoverage: DerivedSourceCoverage,
        backend: PostprocessBackendID
    ) throws {
        let provenance = result.manifestPostprocess
        guard provenance.inputMode == .textOnly,
              provenance.glossarySHA256 == nil,
              provenance.targetLanguage == nil,
              provenance.sourceSegmentsSHA256 == sourceSegmentsSHA256,
              !provenance.modelID.isEmpty,
              let batching = provenance.batching,
              batching.batchesPlanned > 0
        else {
            throw CLIError.postprocess(
                "speaker proposal provenance does not match its text-only source"
            )
        }
        switch backend {
        case .codex:
            guard provenance.backend.name == "codex-app-server",
                  !provenance.backend.version.isEmpty,
                  provenance.modelID == CodexPostprocessBackend.modelName,
                  provenance.modelRevision == nil,
                  provenance.quantization == nil,
                  validates(
                    batching: batching,
                    against: CodexPostprocessBackend.defaultBatchPolicy
                  )
            else {
                throw CLIError.postprocess(
                    "Codex speaker proposal provenance is incomplete or fabricated"
                )
            }
        case .local:
            let pinned = LocalPostprocessBackend.pinnedModel
            guard provenance.backend == LocalPostprocessBackend.descriptor,
                  provenance.modelID == pinned.hfModelID,
                  provenance.modelRevision == pinned.revision,
                  provenance.quantization == pinned.quantization,
                  validates(
                    batching: batching,
                    against: LocalPostprocessBackend.defaultBatchPolicy
                  )
            else {
                throw CLIError.postprocess(
                    "local speaker proposal provenance does not match the pinned model"
                )
            }
        }

        let document = result.document
        guard document.schemaVersion == MaccheroniSchema.version,
              document.layer == SpeakerProposalDocument.layer,
              document.sourceSegmentsSHA256 == sourceSegmentsSHA256,
              document.sourceCoverage == sourceCoverage,
              document.unattributedSpeakers == UnattributedSpeaker.labels,
              document.batches.count == batching.batchesPlanned
        else {
            throw CLIError.postprocess(
                "speaker proposal artifact does not match its canonical source"
            )
        }

        let evidenceByIndex = Dictionary(
            uniqueKeysWithValues: evidence.map { ($0.segmentIndex, $0) }
        )
        let expected = Set(evidenceByIndex.keys)
        var seen = Set<Int>()
        let knownSpeakers = Set(original.segments.map(\.speaker))
            .subtracting(UnattributedSpeaker.labels)

        func check(
            segmentIndex: Int,
            reason: String,
            outcome: String,
            coverage: Double,
            candidates: [SpeakerCandidateEvidence]
        ) throws {
            guard expected.contains(segmentIndex),
                  seen.insert(segmentIndex).inserted,
                  !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let record = evidenceByIndex[segmentIndex],
                  record.outcome == outcome,
                  record.candidates == candidates,
                  record.timelineCoverage == coverage
            else {
                throw CLIError.postprocess(
                    "speaker proposal artifact has invalid segment coverage"
                )
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
            // The layering, restated against the artifact rather than trusted
            // from the proposer: a proposal never lands on a segment the
            // acoustics assigned, and never names a speaker the acoustics did
            // not put in play.
            guard UnattributedSpeaker.isUnattributed(
                original.segments[proposal.segmentIndex].speaker
            ) else {
                throw CLIError.postprocess(
                    "speaker proposal targets segment \(proposal.segmentIndex), which the acoustics already assigned"
                )
            }
            let allowed = proposal.acousticCandidates.isEmpty
                ? knownSpeakers
                : Set(proposal.acousticCandidates.map(\.speaker))
            guard allowed.contains(proposal.proposedSpeaker) else {
                throw CLIError.postprocess(
                    "speaker proposal for segment \(proposal.segmentIndex) names a speaker the acoustics did not offer"
                )
            }
        }
        for declination in document.declined {
            try check(
                segmentIndex: declination.segmentIndex,
                reason: declination.reason,
                outcome: declination.acousticOutcome,
                coverage: declination.acousticTimelineCoverage,
                candidates: declination.acousticCandidates
            )
        }
        guard seen == expected else {
            throw CLIError.postprocess(
                "speaker proposal artifact does not account for every unattributed segment"
            )
        }
    }

    private func run(
        audio: URL,
        profileName: String,
        profilesURL: URL?,
        outputRoot: URL?,
        glossaryURL: URL?
    ) async throws -> String {
        let library = libraryStorageConfiguration()
        if outputRoot == nil,
           !library.isRootConfigurationValid("library.runs")
        {
            throw CLIError.run("the configured run storage path is invalid")
        }
        let resolution = try resolveProfile(name: profileName, profilesURL: profilesURL)
        let profile = resolution.profile
        let selected = try selectedASR(profile.asrBackend)
        let postprocessBackend = PostprocessBackendID(rawValue: profile.postprocess)
        let postprocessMode = profile.postprocessMode ?? .correction
        let translationTargetLanguage = profile.targetLanguage
        let inputFileName = audio.lastPathComponent
        guard !inputFileName.isEmpty,
              !inputFileName.contains("/"),
              !inputFileName.contains("\\")
        else {
            throw CLIError.run("input basename is incompatible with the run schema")
        }
        let glossaryRevision = try resolvedGlossaryRevision(
            cliURL: glossaryURL,
            profile: profile,
            profileDirectory: resolution.directory,
            store: GlossaryRevisionStore(
                root: dependencies.glossaryRevisionStoreRoot()
            )
        )
        let glossary = glossaryRevision?.glossary
        let inputHash = try dependencies.inputSHA256(audio)
        let values = try audio.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        let inputFile = try AVAudioFile(forReading: audio)
        let duration = Double(inputFile.length) / inputFile.processingFormat.sampleRate
        guard duration > 0 else { throw CLIError.run("input duration is zero") }

        let root = outputRoot ?? library.runsURL
        let started = now()
        let writer = try RunWriter(root: root, id: runID(started))
        let source = SourceAudio(
            fileName: inputFileName,
            sha256: inputHash,
            durationS: duration
        )
        var models = [selected.model, SileroVADProvenance().model]
            + (profile.diarization.enabled
                ? [try diarizerModel(profile.diarization.backend)]
                : [])
        var artifacts: [Artifact] = []
        var chunks: [ChunkBoundary] = []
        var processedDuration = 0.0
        var currentChunkIndex: Int?
        var glossaryApplied = glossary != nil
        var fullTranscriptReady = false
        var coverageStrategyOverride: CoverageStrategy?
        /// Set only once the canonical transcript artifacts exist on disk.
        /// `partial` is a claim that some transcript was produced, so it may
        /// not be written from chunk bookkeeping alone.
        var canonicalArtifactsWritten = false
        var manifestPostprocess: ManifestPostprocess?

        func manifest(
            status: RunStatus,
            failure: Failure?,
            truncated: Bool,
            message: String?,
            glossaryOverride: ManifestGlossary? = nil
        ) -> Manifest {
            let finished = now()
            let strategy: CoverageStrategy
            if let coverageStrategyOverride {
                strategy = coverageStrategyOverride
            } else if chunks.isEmpty {
                strategy = status == .succeeded ? .full : .rejected
            } else {
                strategy = chunks.count == 1 ? .full : .chunked
            }
            return Manifest(
                runID: writer.id,
                status: status,
                input: InputAudio(
                    fileName: inputFileName,
                    sha256: inputHash,
                    sizeBytes: fileSize
                ),
                backend: selected.descriptor,
                models: models,
                glossary: glossaryOverride
                    ?? glossary?.manifest(
                        mode: selected.requiredInjectionMode,
                        applied: glossaryApplied
                            && chunks.contains { $0.status == .succeeded }
                    )
                    ?? .absent,
                preprocessing: PreprocessingSettings.default.manifestConfiguration(),
                coverage: Coverage(
                    inputDurationS: duration,
                    processedDurationS: processedDuration,
                    truncated: truncated,
                    strategy: strategy,
                    chunksPlanned: chunks.count,
                    chunksCompleted: chunks.filter { $0.status == .succeeded }.count,
                    message: message
                ),
                chunkBoundaries: chunks,
                timing: RunTiming(
                    startedAt: ISO8601DateFormatter().string(from: started),
                    finishedAt: ISO8601DateFormatter().string(from: finished),
                    wallTimeS: max(0, finished.timeIntervalSince(started))
                ),
                artifacts: artifacts,
                failure: failure,
                postprocess: manifestPostprocess
            )
        }

        func writeIncompleteManifest(_ message: String) throws {
            // Mid-run state index.  It carries the same rule as the final
            // manifest: `partial` claims a transcript exists, so a run killed
            // before promotion must not leave that claim behind.
            try writer.write(
                manifest(
                    status: canonicalArtifactsWritten ? .partial : .failed,
                    failure: Failure(code: "RUN_INCOMPLETE", message: message),
                    truncated: !fullTranscriptReady,
                    message: message
                ),
                at: "manifest.json",
                replace: true
            )
        }

        try writeIncompleteManifest("run initialized")
        do {
            let preprocessed = try dependencies.preprocess(
                audio,
                writer.directory.appendingPathComponent("preprocess", isDirectory: true)
            )
            try validate(
                preprocessed: preprocessed,
                inputHash: inputHash,
                sourceDurationS: duration
            )
            try writer.addArtifact(
                &artifacts,
                kind: "preprocessed_audio",
                relative: try writer.relative(preprocessed.artifactURL)
            )
            try writeIncompleteManifest("preprocessing completed")

            let map = try await dependencies.vad(preprocessed.artifactURL)
            try writer.write(map, at: "preprocess/vad.json")
            try writer.addArtifact(&artifacts, kind: "vad_map", relative: "preprocess/vad.json")

            let preprocessedFile = try AVAudioFile(
                forReading: preprocessed.artifactURL
            )
            let totalSamples = Int64(preprocessedFile.length)
            let policy = try dependencies.inferencePolicy(selected)
            let plannedLeaves = try dependencies.plan(
                map,
                policy,
                totalSamples
            )
            guard !plannedLeaves.isEmpty else {
                throw CLIError.run("Silero VAD produced no ASR inference plan")
            }
            try validate(
                inferencePlan: plannedLeaves,
                totalSamples: totalSamples,
                policy: policy
            )
            let planned = proposedChunks(
                from: plannedLeaves,
                sampleRateHz: policy.sampleRateHz
            )
            try validate(chunkPlan: planned, durationS: duration)
            chunks = planned.map {
                ChunkBoundary(
                    index: $0.index,
                    startS: $0.startS,
                    endS: $0.endS,
                    status: .planned
                )
            }
            try writer.write(planned, at: "preprocess/chunks.json")
            try writer.addArtifact(
                &artifacts,
                kind: "chunk_plan",
                relative: "preprocess/chunks.json"
            )
            let expectedHelperFingerprint = try dependencies
                .expectedHelperFingerprint(selected)
            if selected == .moss, expectedHelperFingerprint == nil {
                throw CLIError.run(
                    "MOSS release helper fingerprint is missing"
                )
            }
            // Recovery is now available to any backend whose policy declares
            // a depth, so the worst-case attempt tree and retained audio come
            // from the depth rather than from the backend identity.
            let nodesPerRoot = (1 << (policy.maximumRecoveryDepth + 1)) - 1
            let maximumAttemptCount = plannedLeaves.count * nodesPerRoot
            let retainedLayers = Int64(policy.maximumRecoveryDepth + 2)
            let retainedPCMBytesUpperBound = totalSamples
                * retainedLayers * 2
            let maximumRootSamples = plannedLeaves.map(\.sampleCount).max()
                ?? totalSamples
            let mossContextPlan: MOSSContextPlan?
            do {
                mossContextPlan = try await dependencies.mossContextPlan(
                    selected,
                    maximumRootSamples,
                    profile.languagePin,
                    glossary,
                    policy.maximumTokens
                )
                if selected == .moss {
                    guard let mossContextPlan,
                          mossContextPlan.helperFingerprintSHA256
                            == expectedHelperFingerprint?.sha256
                    else {
                        throw CLIError.run(
                            "MOSS prompt plan does not match the release helper"
                        )
                    }
                }
            } catch {
                try writer.write(
                    ASRConstraintSnapshot(
                        backend: selected.rawValue,
                        model: selected.model,
                        policy: policy,
                        totalSamples: totalSamples,
                        initialLeafCount: plannedLeaves.count,
                        helperFingerprint: expectedHelperFingerprint,
                        mossContextPlan: nil,
                        maximumAttemptCount: maximumAttemptCount,
                        retainedPCMBytesUpperBound: retainedPCMBytesUpperBound,
                        preflightFailure: failureMessage(for: error)
                    ),
                    at: "preprocess/asr-constraints.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "asr_constraint_snapshot",
                    relative: "preprocess/asr-constraints.json"
                )
                try writeIncompleteManifest("ASR context preflight rejected")
                throw error
            }
            try writer.write(
                ASRConstraintSnapshot(
                    backend: selected.rawValue,
                    model: selected.model,
                    policy: policy,
                    totalSamples: totalSamples,
                    initialLeafCount: plannedLeaves.count,
                    helperFingerprint: expectedHelperFingerprint,
                    mossContextPlan: mossContextPlan,
                    maximumAttemptCount: maximumAttemptCount,
                    retainedPCMBytesUpperBound: retainedPCMBytesUpperBound,
                    preflightFailure: nil
                ),
                at: "preprocess/asr-constraints.json"
            )
            try writer.addArtifact(
                &artifacts,
                kind: "asr_constraint_snapshot",
                relative: "preprocess/asr-constraints.json"
            )
            try writeIncompleteManifest("chunk plan completed")

            let timeline: Timeline
            if profile.diarization.enabled {
                let execution: DiarizationTimelineResult
                do {
                    execution = try await dependencies.diarize(
                        profile.diarization.backend,
                        DiarizationRequest(audioURL: preprocessed.artifactURL)
                    )
                } catch {
                    throw preservedRejectedTimeline(
                        error,
                        writer: writer,
                        artifacts: &artifacts
                    )
                }
                guard !execution.rawJSON.isEmpty else {
                    throw CLIError.run("diarization backend raw evidence is empty")
                }
                timeline = execution.timeline
                try writer.write(
                    execution.rawJSON,
                    at: "diarization/backend.raw.json"
                )
                try writer.write(
                    execution.normalizationWarnings.map(
                        DiarizationWarningRecord.init
                    ),
                    at: "diarization/normalization-warnings.json"
                )
                try writer.write(
                    execution.orderNormalizations.map(
                        DiarizationOrderRecord.init
                    ),
                    at: "diarization/order-normalizations.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "diarization_backend_raw",
                    relative: "diarization/backend.raw.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "diarization_normalization_warnings",
                    relative: "diarization/normalization-warnings.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "diarization_order_normalizations",
                    relative: "diarization/order-normalizations.json"
                )
            } else {
                timeline = Timeline(segments: [])
            }
            try writer.write(timeline.segments, at: "diarization/timeline.json")
            try writer.addArtifact(
                &artifacts,
                kind: "diarization_timeline",
                relative: "diarization/timeline.json"
            )
            try writeIncompleteManifest("diarization completed")

            var transcripts: [ChunkTranscript] = []
            var rawText: [String] = []
            var allEOSLeaves: [CompletedASRLeaf] = []
            var missingRanges: [MissingSourceRange] = []
            var partialAttemptIDs: [String] = []
            var unrecoveredLeaves: [UnrecoveredASRLeaf] = []
            for (rootIndex, rootLeaf) in plannedLeaves.enumerated() {
                let chunk = planned[rootIndex]
                currentChunkIndex = chunk.index
                let audioPath = "primary/chunks/\(chunk.index)/audio.wav"
                _ = try extractChunk(
                    from: preprocessed.artifactURL,
                    startSample: rootLeaf.startSample,
                    endSample: rootLeaf.endSample,
                    outputURL: writer.directory.appendingPathComponent(audioPath)
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "asr_chunk_audio",
                    relative: audioPath
                )
                let rootAttemptID = String(
                    format: "chunk-%04d-root",
                    rootIndex
                )
                let leafResult = try await processASRLeaf(
                    rootLeaf,
                    attemptID: rootAttemptID,
                    parentID: nil,
                    rootChunkIndex: rootIndex,
                    preprocessedURL: preprocessed.artifactURL,
                    activityMap: map,
                    policy: policy,
                    selected: selected,
                    language: profile.languagePin,
                    glossary: glossary,
                    expectedHelperFingerprint: expectedHelperFingerprint,
                    mossContextPlan: mossContextPlan,
                    writer: writer
                )
                try writer.addArtifactsRecursively(
                    &artifacts,
                    under: "primary/attempts",
                    kind: "asr_attempt_evidence"
                )
                let rawPath = "primary/chunks/\(chunk.index)/backend.raw"
                unrecoveredLeaves += leafResult.unrecovered
                let orderedLeaves = leafResult.completed.sorted {
                    $0.leaf.startSample < $1.leaf.startSample
                }
                guard !orderedLeaves.isEmpty else {
                    // Nothing in this chunk was transcribable.  Name every
                    // range it lost and keep going: later chunks are
                    // independent work.
                    missingRanges += leafResult.unrecovered.map {
                        MissingSourceRange(
                            startS: Double($0.leaf.startSample)
                                / Double(policy.sampleRateHz),
                            endS: Double($0.leaf.endSample)
                                / Double(policy.sampleRateHz),
                            attemptID: $0.attemptID,
                            stopReason: $0.stopReason,
                            failureCode: $0.failure.code
                        )
                    }
                    chunks[chunk.index].status = .failed
                    // The chunk still occupies its place in the timeline, with
                    // no segments.  Dropping it entirely would renumber the
                    // chunks after it and break their correspondence with the
                    // manifest boundaries.
                    transcripts.append(ChunkTranscript(
                        index: chunk.index,
                        startS: chunk.startS,
                        endS: chunk.endS,
                        primary: ASRHypothesis(
                            source: selected.rawValue,
                            result: ASRResult(
                                rawText: "",
                                segments: [],
                                glossaryApplied: false
                            )
                        )
                    ))
                    currentChunkIndex = nil
                    try writeIncompleteManifest(
                        "ASR chunk \(chunk.index) produced no promotable transcript"
                    )
                    continue
                }
                let leafCoverage = try validate(
                    completedLeaves: orderedLeaves,
                    unrecovered: leafResult.unrecovered,
                    covering: rootLeaf,
                    sampleRateHz: policy.sampleRateHz
                )
                missingRanges += leafCoverage.missing
                partialAttemptIDs += orderedLeaves
                    .filter(\.isPartial)
                    .map(\.attemptID)
                try writer.write(
                    ASRRootIndexRecord(
                        rootChunkIndex: rootIndex,
                        rootAttemptID: rootAttemptID,
                        eosLeafAttemptIDs: orderedLeaves
                            .filter { !$0.isPartial }
                            .map(\.attemptID),
                        eosLeafResultSHA256: orderedLeaves
                            .filter { !$0.isPartial }
                            .map(\.resultSHA256),
                        partialPrefixAttemptIDs: orderedLeaves
                            .filter(\.isPartial)
                            .map(\.attemptID),
                        partialPrefixResultSHA256: orderedLeaves
                            .filter(\.isPartial)
                            .map(\.resultSHA256)
                    ),
                    at: rawPath
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "asr_backend_raw",
                    relative: rawPath
                )
                let rootResult = ASRResult(
                    rawText: orderedLeaves.map(\.execution.result.rawText)
                        .joined(separator: "\n"),
                    segments: orderedLeaves
                        .flatMap(\.execution.result.segments)
                        .sorted {
                            if $0.startS != $1.startS {
                                return $0.startS < $1.startS
                            }
                            return $0.endS < $1.endS
                        },
                    glossaryApplied: glossary != nil
                        && orderedLeaves.allSatisfy {
                            $0.execution.result.glossaryApplied
                        }
                )
                transcripts.append(ChunkTranscript(
                    index: chunk.index,
                    startS: chunk.startS,
                    endS: chunk.endS,
                    primary: ASRHypothesis(
                        source: selected.rawValue,
                        result: rootResult
                    )
                ))
                rawText.append(rootResult.rawText)
                if glossary != nil {
                    glossaryApplied = glossaryApplied
                        && orderedLeaves.allSatisfy {
                            $0.execution.evidence.glossary.applied
                        }
                }
                allEOSLeaves += orderedLeaves
                chunks[chunk.index].status = .succeeded
                processedDuration += Double(leafCoverage.coveredSamples)
                    / Double(policy.sampleRateHz)
                currentChunkIndex = nil
                try writeIncompleteManifest("ASR chunk \(chunk.index) completed")
            }

            // A run that transcribed nothing has nothing to promote, so it
            // fails with the cause of its first lost range rather than
            // producing an empty canonical transcript.
            if allEOSLeaves.isEmpty {
                if let first = unrecoveredLeaves.first { throw first.failure }
                throw CLIError.run("ASR produced no promotable transcript")
            }
            guard try dependencies.inputSHA256(audio) == inputHash else {
                throw CLIError.run("original input hash changed before promotion")
            }
            let merged = try TimelineMerger().merge(
                chunks: transcripts,
                timeline: timeline,
                source: source
            )
            let primarySegments = transcripts.flatMap { $0.primary.segments }
                .sorted {
                    if $0.startS != $1.startS { return $0.startS < $1.startS }
                    return $0.endS < $1.endS
                }
            let primarySpeakerCount = Set(primarySegments.compactMap { segment -> String? in
                ["UNASSIGNED", "UNKNOWN"].contains(segment.speaker) ? nil : segment.speaker
            }).count
            try writer.write(rawText.joined(separator: "\n"), at: "primary/raw.txt")
            try writer.write(
                SegmentsDocument(
                    segments: primarySegments,
                    numSpeakers: primarySpeakerCount,
                    source: source
                ),
                at: "primary/segments.json"
            )
            try writer.write(merged.segmentsDocument, at: "merged/segments.json")
            try writer.write(merged.conflicts, at: "merged/conflicts.json")
            canonicalArtifactsWritten = true
            let canonicalPaths = [
                "primary/raw.txt",
                "primary/segments.json",
                "merged/segments.json",
                "merged/conflicts.json",
            ]
            var canonicalHashes: [String: String] = [:]
            for path in canonicalPaths {
                canonicalHashes[path] = try AudioPreprocessor.sha256(
                    of: writer.directory.appendingPathComponent(path)
                )
            }
            let inputHashAtPromotion = try dependencies.inputSHA256(audio)
            guard inputHashAtPromotion == inputHash else {
                throw CLIError.run("original input hash changed at promotion")
            }
            try writer.write(
                CanonicalPromotionRecord(
                    inputSHA256Before: inputHash,
                    inputSHA256AtPromotion: inputHashAtPromotion,
                    eosLeafAttemptIDs: allEOSLeaves
                        .filter { !$0.isPartial }
                        .map(\.attemptID),
                    eosLeafResultSHA256: allEOSLeaves
                        .filter { !$0.isPartial }
                        .map(\.resultSHA256),
                    partialPrefixAttemptIDs: partialAttemptIDs,
                    canonicalArtifactSHA256: canonicalHashes
                ),
                at: "primary/promotion.json"
            )
            for (kind, path) in [
                ("primary_raw", "primary/raw.txt"),
                ("primary_segments", "primary/segments.json"),
                ("merged_segments", "merged/segments.json"),
                ("merged_conflicts", "merged/conflicts.json"),
                ("canonical_promotion", "primary/promotion.json"),
            ] {
                try writer.addArtifact(&artifacts, kind: kind, relative: path)
            }

            if missingRanges.isEmpty {
                processedDuration = duration
                fullTranscriptReady = true
            } else {
                // Some planned audio produced no transcript.  The strategy
                // says so in the coverage record instead of leaving a short
                // processed duration to be noticed.
                coverageStrategyOverride = .backendTruncated
                try writer.write(
                    PartialCoverageRecord(
                        inputDurationS: duration,
                        promotedDurationS: processedDuration,
                        missingDurationS: missingRanges.reduce(0) {
                            $0 + ($1.endS - $1.startS)
                        },
                        missing: missingRanges,
                        partialAttemptIDs: partialAttemptIDs
                    ),
                    at: "primary/partial-coverage.json"
                )
                try writer.addArtifact(
                    &artifacts,
                    kind: "partial_coverage",
                    relative: "primary/partial-coverage.json"
                )
            }
            if let postprocessBackend {
                try writeIncompleteManifest("postprocess started")
                switch postprocessMode {
                case .correction:
                    let result: PostprocessResult
                    do {
                        result = try await dependencies.postprocess(
                            postprocessBackend,
                            PostprocessRequest(
                                document: merged.segmentsDocument,
                                glossary: glossary
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw CLIError.postprocess(failureMessage(for: error))
                    }
                    try validate(
                        postprocess: result,
                        against: merged.segmentsDocument,
                        glossary: glossary,
                        backend: postprocessBackend
                    )
                    try writer.write(
                        result.document,
                        at: "postprocess/segments.json"
                    )
                    try writer.write(
                        result.conflicts,
                        at: "postprocess/conflicts.json"
                    )
                    try writer.addArtifact(
                        &artifacts,
                        kind: "postprocess_segments",
                        relative: "postprocess/segments.json"
                    )
                    try writer.addArtifact(
                        &artifacts,
                        kind: "postprocess_conflicts",
                        relative: "postprocess/conflicts.json"
                    )
                    manifestPostprocess = result.manifestPostprocess
                case .translation:
                    guard let targetLanguage = translationTargetLanguage,
                          let sourceSegmentsSHA256 = canonicalHashes[
                            "merged/segments.json"
                          ]
                    else {
                        throw CLIError.postprocess(
                            "translation mode is missing its target or source hash"
                        )
                    }
                    let result: TranslationResult
                    do {
                        result = try await dependencies.translate(
                            postprocessBackend,
                            TranslationRequest(
                                document: merged.segmentsDocument,
                                targetLanguage: targetLanguage,
                                sourceSegmentsSHA256: sourceSegmentsSHA256,
                                glossary: glossary
                            )
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw CLIError.postprocess(failureMessage(for: error))
                    }
                    try validate(
                        translation: result,
                        against: merged.segmentsDocument,
                        sourceSegmentsSHA256: sourceSegmentsSHA256,
                        glossary: glossary,
                        backend: postprocessBackend,
                        targetLanguage: targetLanguage
                    )
                    try writer.write(
                        result.document,
                        at: "postprocess/translation.json"
                    )
                    try writer.addArtifact(
                        &artifacts,
                        kind: "postprocess_translation",
                        relative: "postprocess/translation.json"
                    )
                    manifestPostprocess = result.manifestPostprocess
                }
                if postprocessBackend == .local,
                   !models.contains(LocalPostprocessBackend.pinnedModel)
                {
                    models.append(LocalPostprocessBackend.pinnedModel)
                }
                for (path, sha256) in canonicalHashes {
                    guard try AudioPreprocessor.sha256(
                        of: writer.directory.appendingPathComponent(path)
                    ) == sha256 else {
                        throw CLIError.postprocess(
                            "postprocess changed canonical artifact bytes: \(path)"
                        )
                    }
                }
            }

            guard try dependencies.inputSHA256(audio) == inputHash else {
                throw CLIError.run("original input hash changed")
            }
            try writer.addAllUntrackedArtifacts(
                &artifacts,
                kind: "pipeline_evidence"
            )
            try writer.verify(artifacts: artifacts)
            let finalGlossary = glossary?.manifest(
                mode: selected.requiredInjectionMode,
                applied: glossaryApplied
            ) ?? .absent
            guard glossary == nil || glossaryApplied else {
                throw CLIError.glossary("one or more ASR chunks did not apply the glossary")
            }
            let partialCoverage = partialCoverageFailure(
                missing: missingRanges,
                inputDurationS: duration,
                promotedDurationS: processedDuration
            )
            try writer.write(
                manifest(
                    status: partialCoverage == nil ? .succeeded : .partial,
                    failure: partialCoverage,
                    truncated: partialCoverage != nil,
                    message: partialCoverage?.message,
                    glossaryOverride: finalGlossary
                ),
                at: "manifest.json",
                replace: true
            )
            return writer.directory.path
        } catch {
            try? writer.addArtifactsRecursively(
                &artifacts,
                under: "primary/attempts",
                kind: "asr_attempt_evidence"
            )
            try? writer.addAllUntrackedArtifacts(
                &artifacts,
                kind: "preserved_partial_artifact"
            )
            artifacts = writer.rebuiltArtifacts(preservingKindsFrom: artifacts)
            if let index = currentChunkIndex, chunks.indices.contains(index) {
                chunks[index].status = .failed
                for laterIndex in chunks.indices where laterIndex > index
                    && chunks[laterIndex].status == .planned
                {
                    chunks[laterIndex].status = .skipped
                }
            }
            if fullTranscriptReady {
                processedDuration = duration
            } else if canonicalArtifactsWritten {
                // A chunk that promoted only a recovered prefix is marked
                // succeeded but did not cover its whole range, so the chunk
                // boundaries are an upper bound on the processed duration
                // rather than the value itself.
                processedDuration = min(
                    processedDuration,
                    chunks
                        .filter { $0.status == .succeeded }
                        .reduce(0) { $0 + ($1.endS - $1.startS) }
                )
            } else if !(error is CancellationError) {
                // The run aborted before promotion, so no transcript exists
                // anywhere.  Reporting the audio it happened to reach as
                // processed would be a false claim, not a partial result.
                // A cancel is different: the policy requires completed outputs
                // to be preserved, and `canceled` already says the run stopped.
                processedDuration = 0
            }
            var code = failureCode(for: error)
            var message = failureMessage(for: error)
            if (try? dependencies.inputSHA256(audio)) != inputHash {
                code = "INPUT_MUTATED"
                message = "original input hash changed during the run"
            }
            let status: RunStatus
            switch code {
            case "INPUT_MUTATED":
                status = .failed
            case "CANCELED":
                status = .canceled
            default:
                // `partial` means some transcript was promoted, never that
                // some chunk bookkeeping succeeded before the abort.
                status = canonicalArtifactsWritten ? .partial : .failed
            }
            let failedManifest = manifest(
                status: status,
                failure: Failure(code: code, message: message),
                truncated: !fullTranscriptReady,
                message: message
            )
            do {
                try writer.write(failedManifest, at: "manifest.json", replace: true)
            } catch let manifestError {
                throw CLIError.run(
                    "\(message) [run: \(writer.directory.path); failure manifest: \(manifestError.localizedDescription)]"
                )
            }
            // Keep the typed cause on the way out: the manifest already
            // records it, and a caller that only sees the thrown error must
            // be able to tell a spent limit from a collapsed decoder.
            let annotated = "\(message) [run: \(writer.directory.path)]"
            switch code {
            case "MOSS_LIMIT_EXHAUSTED":
                throw CLIError.mossLimitExhausted(annotated)
            case "ASR_LIMIT_EXHAUSTED":
                throw CLIError.asrLimitExhausted(annotated)
            case "ASR_REPETITION_DEGENERATION":
                throw CLIError.asrRepetitionDegeneration(annotated)
            default:
                throw CLIError.run(annotated)
            }
        }
    }

    private func processASRLeaf(
        _ leaf: InferenceLeaf,
        attemptID: String,
        parentID: String?,
        rootChunkIndex: Int,
        preprocessedURL: URL,
        activityMap: VoiceActivityMap,
        policy: CLIASRInferencePolicy,
        selected: SelectedASRBackend,
        language: LanguagePin,
        glossary: Glossary?,
        expectedHelperFingerprint: ASRHelperFingerprint?,
        mossContextPlan: MOSSContextPlan?,
        writer: RunWriter
    ) async throws -> ASRLeafResult {
        do {
            return try await processPreparedASRLeaf(
                leaf,
                attemptID: attemptID,
                parentID: parentID,
                rootChunkIndex: rootChunkIndex,
                preprocessedURL: preprocessedURL,
                activityMap: activityMap,
                policy: policy,
                selected: selected,
                language: language,
                glossary: glossary,
                expectedHelperFingerprint: expectedHelperFingerprint,
                mossContextPlan: mossContextPlan,
                writer: writer
            )
        } catch {
            let base = "primary/attempts/\(attemptID)"
            let outcomePath = "\(base)/outcome.json"
            let outcomeURL = writer.directory.appendingPathComponent(
                outcomePath
            )
            if !FileManager.default.fileExists(atPath: outcomeURL.path) {
                let requestURL = writer.directory.appendingPathComponent(
                    "\(base)/request.json"
                )
                let requestSHA256 = FileManager.default.fileExists(
                    atPath: requestURL.path
                ) ? try? AudioPreprocessor.sha256(of: requestURL) : nil
                try writer.write(
                    ASRAttemptOutcomeRecord(
                        attemptID: attemptID,
                        requestSHA256: requestSHA256,
                        status: attemptStatus(for: error),
                        stopReason: nil,
                        canonicalPromoted: false,
                        childAttemptIDs: [],
                        runnerRecordPath: nil,
                        runnerRecordSHA256: nil,
                        backendRawPath: nil,
                        backendRawSHA256: nil,
                        resultPath: nil,
                        resultSHA256: nil,
                        glossary: glossary?.manifest(
                            mode: selected.requiredInjectionMode,
                            applied: false
                        ) ?? .absent,
                        glossaryPayloadSHA256: nil,
                        glossaryPayloadEntryCount: nil,
                        metrics: nil,
                        audioTokens: nil,
                        contextTokens: nil,
                        language: nil,
                        helperFingerprint: expectedHelperFingerprint,
                        command: nil,
                        errorCode: failureCode(for: error),
                        errorMessage: failureMessage(for: error)
                    ),
                    at: outcomePath
                )
            }
            throw error
        }
    }

    private func processPreparedASRLeaf(
        _ leaf: InferenceLeaf,
        attemptID: String,
        parentID: String?,
        rootChunkIndex: Int,
        preprocessedURL: URL,
        activityMap: VoiceActivityMap,
        policy: CLIASRInferencePolicy,
        selected: SelectedASRBackend,
        language: LanguagePin,
        glossary: Glossary?,
        expectedHelperFingerprint: ASRHelperFingerprint?,
        mossContextPlan: MOSSContextPlan?,
        writer: RunWriter
    ) async throws -> ASRLeafResult {
        let base = "primary/attempts/\(attemptID)"
        let audioPath = "\(base)/audio.wav"
        let audioURL = try extractChunk(
            from: preprocessedURL,
            startSample: leaf.startSample,
            endSample: leaf.endSample,
            outputURL: writer.directory.appendingPathComponent(audioPath)
        )
        let audioSHA256 = try AudioPreprocessor.sha256(of: audioURL)
        let attemptTokenPlan = try mossContextPlan?.attemptPlan(
            sampleCount: leaf.sampleCount
        )
        if selected == .moss, attemptTokenPlan == nil {
            throw CLIError.run("MOSS attempt has no prompt token plan")
        }
        let expectedGlossary = glossary?.manifest(
            mode: selected.requiredInjectionMode,
            applied: false
        ) ?? .absent
        let requestRecord = ASRAttemptRequestRecord(
            attemptID: attemptID,
            parentID: parentID,
            rootChunkIndex: rootChunkIndex,
            depth: leaf.depth,
            startSample: leaf.startSample,
            endSample: leaf.endSample,
            sampleRateHz: policy.sampleRateHz,
            boundarySource: leaf.boundarySource,
            audioPath: audioPath,
            audioSHA256: audioSHA256,
            backend: selected.rawValue,
            model: selected.model,
            language: languageValue(language),
            glossary: expectedGlossary,
            maximumTokens: policy.maximumTokens,
            promptTokens: attemptTokenPlan?.promptTokens,
            audioTokens: attemptTokenPlan?.audioTokens,
            contextUpperBoundTokens: attemptTokenPlan?
                .contextUpperBoundTokens,
            helperFingerprint: expectedHelperFingerprint
        )
        let requestPath = "\(base)/request.json"
        try writer.write(requestRecord, at: requestPath)
        let requestSHA256 = try AudioPreprocessor.sha256(
            of: writer.directory.appendingPathComponent(requestPath)
        )
        let request = ASRRequest(
            audioURL: audioURL,
            startS: Double(leaf.startSample) / Double(policy.sampleRateHz),
            endS: Double(leaf.endSample) / Double(policy.sampleRateHz),
            language: language,
            glossary: glossary,
            injectionMode: glossary == nil
                ? .none
                : selected.requiredInjectionMode
        )

        do {
            let attemptOutcome = try await dependencies.asr(
                selected,
                request,
                writer.directory.appendingPathComponent(
                    "\(base)/backend-records",
                    isDirectory: true
                ),
                policy.maximumTokens
            )
            switch attemptOutcome {
            case let .complete(execution):
            try validate(
                execution: execution,
                request: request,
                glossary: glossary,
                selected: selected
            )
            try validate(
                evidence: execution.evidence,
                audioSHA256: audioSHA256,
                language: language,
                glossary: glossary,
                selected: selected,
                policy: policy,
                expectedHelperFingerprint: expectedHelperFingerprint,
                attemptTokenPlan: attemptTokenPlan,
                mossContextPlan: mossContextPlan,
                request: request
            )
            let evidence = try persistAttemptEvidence(
                execution.evidence,
                base: base,
                writer: writer
            )
            let resultPath = "\(base)/result.json"
            try writer.write(execution.result, at: resultPath)
            let resultSHA256 = try AudioPreprocessor.sha256(
                of: writer.directory.appendingPathComponent(resultPath)
            )
            try writer.write(
                ASRAttemptOutcomeRecord(
                    attemptID: attemptID,
                    requestSHA256: requestSHA256,
                    status: .eosComplete,
                    stopReason: .endOfSequence,
                    canonicalPromoted: false,
                    childAttemptIDs: [],
                    runnerRecordPath: evidence.runnerPath,
                    runnerRecordSHA256: evidence.runnerSHA256,
                    backendRawPath: evidence.rawPath,
                    backendRawSHA256: evidence.rawSHA256,
                    resultPath: resultPath,
                    resultSHA256: resultSHA256,
                    glossary: execution.evidence.glossary,
                    glossaryPayloadSHA256: execution.evidence
                        .glossaryPayloadSHA256,
                    glossaryPayloadEntryCount: execution.evidence
                        .glossaryPayloadEntryCount,
                    metrics: execution.evidence.metrics,
                    audioTokens: attemptTokenPlan?.audioTokens,
                    contextTokens: execution.evidence.metrics.map {
                        $0.promptTokens + $0.generatedTokens
                    },
                    language: execution.evidence.language,
                    helperFingerprint: execution.evidence.helperFingerprint,
                    command: execution.evidence.command,
                    errorCode: nil,
                    errorMessage: nil
                ),
                at: "\(base)/outcome.json"
            )
            return ASRLeafResult(completed: [CompletedASRLeaf(
                attemptID: attemptID,
                leaf: leaf,
                execution: execution,
                resultSHA256: resultSHA256,
                coveredEndSample: leaf.endSample,
                stopReason: .endOfSequence
            )])

            case let .limit(limit):
            try validate(
                evidence: limit.evidence,
                audioSHA256: audioSHA256,
                language: language,
                glossary: glossary,
                selected: selected,
                policy: policy,
                expectedHelperFingerprint: expectedHelperFingerprint,
                attemptTokenPlan: attemptTokenPlan,
                mossContextPlan: mossContextPlan,
                request: request
            )
            let evidence = try persistAttemptEvidence(
                limit.evidence,
                base: base,
                writer: writer
            )
            guard limit.stopReason.isLimitOutcome else {
                try writer.write(
                    limitOutcomeRecord(
                        attemptID: attemptID,
                        requestSHA256: requestSHA256,
                        status: .limitExhausted,
                        stopReason: limit.stopReason,
                        childAttemptIDs: [],
                        evidence: limit.evidence,
                        evidencePaths: evidence,
                        attemptTokenPlan: attemptTokenPlan,
                        errorCode: "RUN_ERROR",
                        errorMessage: "backend emitted an unsupported limit outcome"
                    ),
                    at: "\(base)/outcome.json"
                )
                throw CLIError.run(
                    "backend emitted an unsupported limit outcome"
                )
            }

            let children: [InferenceLeaf]
            do {
                children = try InferenceLeafPlanner().splitForLimitRecovery(
                    leaf: leaf,
                    activityMap: activityMap,
                    configuration: policy.planningConfiguration
                )
            } catch {
                // Recovery is spent for this range.  Before failing the run,
                // promote whatever leading transcript the backend recovered:
                // a collapsed leaf commonly holds a correct prefix covering
                // most of its audio, and discarding it is total loss.
                if let promoted = try promotePartialPrefix(
                    limit,
                    leaf: leaf,
                    attemptID: attemptID,
                    requestSHA256: requestSHA256,
                    base: base,
                    request: request,
                    policy: policy,
                    glossary: glossary,
                    selected: selected,
                    evidencePaths: evidence,
                    attemptTokenPlan: attemptTokenPlan,
                    writer: writer
                ) {
                    return ASRLeafResult(completed: [promoted])
                }
                let exhausted = limitExhaustionFailure(
                    backend: selected,
                    stopReason: limit.stopReason,
                    leaf: leaf
                )
                try writer.write(
                    limitOutcomeRecord(
                        attemptID: attemptID,
                        requestSHA256: requestSHA256,
                        status: limit.stopReason == .repetitionDegeneration
                            ? .repetitionDegeneration
                            : .limitExhausted,
                        stopReason: limit.stopReason,
                        childAttemptIDs: [],
                        evidence: limit.evidence,
                        evidencePaths: evidence,
                        attemptTokenPlan: attemptTokenPlan,
                        errorCode: exhausted.code,
                        errorMessage: failureMessage(for: exhausted)
                    ),
                    at: "\(base)/outcome.json"
                )
                // This range is lost, and only this range.  Returning it as
                // unrecovered instead of throwing is what keeps every sibling
                // leaf and every other chunk: a run that loses one leaf must
                // not discard the transcript it already has.
                return ASRLeafResult(unrecovered: [UnrecoveredASRLeaf(
                    attemptID: attemptID,
                    leaf: leaf,
                    stopReason: limit.stopReason,
                    failure: exhausted
                )])
            }
            let childIDs = ["\(attemptID)-l", "\(attemptID)-r"]
            try writer.write(
                limitOutcomeRecord(
                    attemptID: attemptID,
                    requestSHA256: requestSHA256,
                    status: .limitIsolated,
                    stopReason: limit.stopReason,
                    childAttemptIDs: childIDs,
                    evidence: limit.evidence,
                    evidencePaths: evidence,
                    attemptTokenPlan: attemptTokenPlan,
                    errorCode: nil,
                    errorMessage: nil
                ),
                at: "\(base)/outcome.json"
            )
            var childResults = ASRLeafResult()
            var firstChildError: Error?
            for index in children.indices {
                do {
                    childResults += try await processASRLeaf(
                        children[index],
                        attemptID: childIDs[index],
                        parentID: attemptID,
                        rootChunkIndex: rootChunkIndex,
                        preprocessedURL: preprocessedURL,
                        activityMap: activityMap,
                        policy: policy,
                        selected: selected,
                        language: language,
                        glossary: glossary,
                        expectedHelperFingerprint: expectedHelperFingerprint,
                        mossContextPlan: mossContextPlan,
                        writer: writer
                    )
                } catch {
                    if firstChildError == nil { firstChildError = error }
                    if error is CancellationError {
                        for remainingIndex in children.indices
                            where remainingIndex > index
                        {
                            try writeUnstartedCanceledAttempt(
                                attemptID: childIDs[remainingIndex],
                                selected: selected,
                                glossary: glossary,
                                expectedHelperFingerprint:
                                    expectedHelperFingerprint,
                                writer: writer
                            )
                        }
                        break
                    }
                }
            }
            if let firstChildError { throw firstChildError }
            return childResults
            }
        } catch {
            let outcomePath = "\(base)/outcome.json"
            let outcomeURL = writer.directory.appendingPathComponent(outcomePath)
            if !FileManager.default.fileExists(atPath: outcomeURL.path) {
                let canceled = error is CancellationError
                try writer.write(
                    ASRAttemptOutcomeRecord(
                        attemptID: attemptID,
                        requestSHA256: requestSHA256,
                        status: canceled ? .canceled : attemptStatus(for: error),
                        stopReason: nil,
                        canonicalPromoted: false,
                        childAttemptIDs: [],
                        runnerRecordPath: nil,
                        runnerRecordSHA256: nil,
                        backendRawPath: nil,
                        backendRawSHA256: nil,
                        resultPath: nil,
                        resultSHA256: nil,
                        glossary: nil,
                        glossaryPayloadSHA256: nil,
                        glossaryPayloadEntryCount: nil,
                        metrics: nil,
                        audioTokens: attemptTokenPlan?.audioTokens,
                        contextTokens: nil,
                        language: nil,
                        helperFingerprint: nil,
                        command: nil,
                        errorCode: failureCode(for: error),
                        errorMessage: failureMessage(for: error)
                    ),
                    at: outcomePath
                )
            }
            throw error
        }
    }

    /// Name the failure a spent limit outcome becomes.  MOSS keeps its own
    /// code and message so its recovery tree reads exactly as before; every
    /// other backend gets a code that says which cause it was, because the
    /// failure screen cannot tell causes apart from `RUN_ERROR`.
    /// State partial coverage as a failure object on an otherwise finished
    /// run.  A run that promoted every recovered prefix it could still did
    /// not transcribe every planned second, and the manifest says which
    /// seconds and why rather than reporting the run as complete.
    private func partialCoverageFailure(
        missing: [MissingSourceRange],
        inputDurationS: Double,
        promotedDurationS: Double
    ) -> Failure? {
        guard !missing.isEmpty else { return nil }
        let degenerate = missing.contains { $0.stopReason == .repetitionDegeneration }
        // Prefer a degeneration cause when one is present, otherwise keep the
        // first recorded code so a MOSS run still reports MOSS_LIMIT_EXHAUSTED.
        let code = missing.first {
            $0.stopReason == .repetitionDegeneration
        }?.failureCode ?? missing[0].failureCode
        let ranges = missing
            .map { "[\(format(seconds: $0.startS)), \(format(seconds: $0.endS))) s" }
            .joined(separator: ", ")
        let message = """
        promoted \(format(seconds: promotedDurationS)) s of \
        \(format(seconds: inputDurationS)) s; \(missing.count) range(s) produced no \
        transcript after \(degenerate ? "repetition degeneration" : "a limit outcome") \
        exhausted recovery: \(ranges)
        """
        return Failure(code: code, message: message)
    }

    private func limitExhaustionFailure(
        backend: SelectedASRBackend,
        stopReason: ASRAttemptStopReason,
        leaf: InferenceLeaf
    ) -> CLIError {
        let range = "at depth \(leaf.depth) for samples [\(leaf.startSample), \(leaf.endSample))"
        if backend == .moss {
            return .mossLimitExhausted(
                "MOSS \(stopReason.rawValue) persisted \(range)"
            )
        }
        if stopReason == .repetitionDegeneration {
            return .asrRepetitionDegeneration(
                "\(backend.rawValue) repetition degeneration persisted \(range) with no promotable prefix"
            )
        }
        return .asrLimitExhausted(
            "\(backend.rawValue) \(stopReason.rawValue) persisted \(range)"
        )
    }

    /// Promote the leading valid transcript a spent limit outcome still holds.
    /// The promoted range is smaller than the leaf, so the caller records the
    /// remainder as missing rather than as processed.
    private func promotePartialPrefix(
        _ limit: CLIASRLimit,
        leaf: InferenceLeaf,
        attemptID: String,
        requestSHA256: String,
        base: String,
        request: ASRRequest,
        policy: CLIASRInferencePolicy,
        glossary: Glossary?,
        selected: SelectedASRBackend,
        evidencePaths: (
            runnerPath: String,
            runnerSHA256: String,
            rawPath: String,
            rawSHA256: String
        ),
        attemptTokenPlan: MOSSAttemptTokenPlan?,
        writer: RunWriter
    ) throws -> CompletedASRLeaf? {
        guard let prefix = limit.partialPrefix,
              prefix.promotedObjectCount > 0,
              !prefix.segments.isEmpty,
              !prefix.rawText.isEmpty,
              prefix.coverageS > 0
        else { return nil }
        let coveredEndSample = min(
            leaf.endSample,
            leaf.startSample
                + Int64((prefix.coverageS * Double(policy.sampleRateHz)).rounded(.down))
        )
        guard coveredEndSample > leaf.startSample else { return nil }
        let execution = CLIASRExecution(
            result: ASRResult(
                rawText: prefix.rawText,
                segments: prefix.segments,
                glossaryApplied: glossary != nil
            ),
            evidence: limit.evidence
        )
        try validate(
            execution: execution,
            request: request,
            glossary: glossary,
            selected: selected
        )
        let resultPath = "\(base)/result.json"
        try writer.write(execution.result, at: resultPath)
        let resultSHA256 = try AudioPreprocessor.sha256(
            of: writer.directory.appendingPathComponent(resultPath)
        )
        try writer.write(
            ASRAttemptOutcomeRecord(
                attemptID: attemptID,
                requestSHA256: requestSHA256,
                status: .partialPrefixPromoted,
                stopReason: limit.stopReason,
                canonicalPromoted: false,
                childAttemptIDs: [],
                runnerRecordPath: evidencePaths.runnerPath,
                runnerRecordSHA256: evidencePaths.runnerSHA256,
                backendRawPath: evidencePaths.rawPath,
                backendRawSHA256: evidencePaths.rawSHA256,
                resultPath: resultPath,
                resultSHA256: resultSHA256,
                glossary: limit.evidence.glossary,
                glossaryPayloadSHA256: limit.evidence.glossaryPayloadSHA256,
                glossaryPayloadEntryCount: limit.evidence
                    .glossaryPayloadEntryCount,
                metrics: limit.evidence.metrics,
                audioTokens: attemptTokenPlan?.audioTokens,
                contextTokens: limit.evidence.metrics.map {
                    $0.promptTokens + $0.generatedTokens
                },
                language: limit.evidence.language,
                helperFingerprint: limit.evidence.helperFingerprint,
                command: limit.evidence.command,
                errorCode: limit.stopReason == .repetitionDegeneration
                    ? CLIError.asrRepetitionDegeneration("").code
                    : CLIError.asrLimitExhausted("").code,
                errorMessage: partialPrefixMessage(
                    prefix,
                    stopReason: limit.stopReason,
                    leaf: leaf,
                    sampleRateHz: policy.sampleRateHz
                )
            ),
            at: "\(base)/outcome.json"
        )
        return CompletedASRLeaf(
            attemptID: attemptID,
            leaf: leaf,
            execution: execution,
            resultSHA256: resultSHA256,
            coveredEndSample: coveredEndSample,
            stopReason: limit.stopReason
        )
    }

    private func partialPrefixMessage(
        _ prefix: ASRPartialPrefix,
        stopReason: ASRAttemptStopReason,
        leaf: InferenceLeaf,
        sampleRateHz: Int
    ) -> String {
        let leafDuration = Double(leaf.sampleCount) / Double(sampleRateHz)
        return """
        promoted the valid transcript prefix after \(stopReason.rawValue): \
        \(format(seconds: prefix.coverageS)) s of \(format(seconds: leafDuration)) s, \
        \(prefix.promotedObjectCount) of \(prefix.completeObjectCount) recovered segments, \
        \(prefix.degenerateObjectCount) of them marked repetition_degenerate; \
        longest repeated run \(prefix.repetitionRunMaximum) inside the prefix and \
        \(prefix.tailRepetitionRun) in the discarded tail
        """
    }

    private func format(seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private func writeUnstartedCanceledAttempt(
        attemptID: String,
        selected: SelectedASRBackend,
        glossary: Glossary?,
        expectedHelperFingerprint: ASRHelperFingerprint?,
        writer: RunWriter
    ) throws {
        let outcomePath = "primary/attempts/\(attemptID)/outcome.json"
        let outcomeURL = writer.directory.appendingPathComponent(outcomePath)
        guard !FileManager.default.fileExists(atPath: outcomeURL.path) else {
            return
        }
        try writer.write(
            ASRAttemptOutcomeRecord(
                attemptID: attemptID,
                requestSHA256: nil,
                status: .canceled,
                stopReason: nil,
                canonicalPromoted: false,
                childAttemptIDs: [],
                runnerRecordPath: nil,
                runnerRecordSHA256: nil,
                backendRawPath: nil,
                backendRawSHA256: nil,
                resultPath: nil,
                resultSHA256: nil,
                glossary: glossary?.manifest(
                    mode: selected.requiredInjectionMode,
                    applied: false
                ) ?? .absent,
                glossaryPayloadSHA256: nil,
                glossaryPayloadEntryCount: nil,
                metrics: nil,
                audioTokens: nil,
                contextTokens: nil,
                language: nil,
                helperFingerprint: expectedHelperFingerprint,
                command: nil,
                errorCode: "CANCELED",
                errorMessage: "attempt was not started because a sibling was canceled"
            ),
            at: outcomePath
        )
    }

    private func persistAttemptEvidence(
        _ evidence: CLIASRAttemptEvidence,
        base: String,
        writer: RunWriter
    ) throws -> (
        runnerPath: String,
        runnerSHA256: String,
        rawPath: String,
        rawSHA256: String
    ) {
        guard !evidence.runnerRecordEvidence.isEmpty,
              !evidence.rawEvidence.isEmpty
        else {
            throw CLIError.run("ASR attempt evidence is incomplete")
        }
        let runnerPath = "\(base)/runner-record.json"
        let rawPath = "\(base)/backend.raw"
        try writer.write(evidence.runnerRecordEvidence, at: runnerPath)
        try writer.write(evidence.rawEvidence, at: rawPath)
        return (
            runnerPath,
            try AudioPreprocessor.sha256(
                of: writer.directory.appendingPathComponent(runnerPath)
            ),
            rawPath,
            try AudioPreprocessor.sha256(
                of: writer.directory.appendingPathComponent(rawPath)
            )
        )
    }

    private func limitOutcomeRecord(
        attemptID: String,
        requestSHA256: String,
        status: ASRAttemptStatus,
        stopReason: ASRAttemptStopReason,
        childAttemptIDs: [String],
        evidence: CLIASRAttemptEvidence,
        evidencePaths: (
            runnerPath: String,
            runnerSHA256: String,
            rawPath: String,
            rawSHA256: String
        ),
        attemptTokenPlan: MOSSAttemptTokenPlan?,
        errorCode: String?,
        errorMessage: String?
    ) -> ASRAttemptOutcomeRecord {
        ASRAttemptOutcomeRecord(
            attemptID: attemptID,
            requestSHA256: requestSHA256,
            status: status,
            stopReason: stopReason,
            canonicalPromoted: false,
            childAttemptIDs: childAttemptIDs,
            runnerRecordPath: evidencePaths.runnerPath,
            runnerRecordSHA256: evidencePaths.runnerSHA256,
            backendRawPath: evidencePaths.rawPath,
            backendRawSHA256: evidencePaths.rawSHA256,
            resultPath: nil,
            resultSHA256: nil,
            glossary: evidence.glossary,
            glossaryPayloadSHA256: evidence.glossaryPayloadSHA256,
            glossaryPayloadEntryCount: evidence.glossaryPayloadEntryCount,
            metrics: evidence.metrics,
            audioTokens: attemptTokenPlan?.audioTokens,
            contextTokens: evidence.metrics.map {
                $0.promptTokens + $0.generatedTokens
            },
            language: evidence.language,
            helperFingerprint: evidence.helperFingerprint,
            command: evidence.command,
            errorCode: errorMessage == nil ? nil : errorCode,
            errorMessage: errorMessage
        )
    }

    private func doctor(profileName: String?, profilesURL: URL?) async throws -> String {
        let report = try await doctorReport(
            profileName: profileName,
            profilesURL: profilesURL
        )
        guard report.isReady else {
            throw CLIError.run(report.diagnostics)
        }
        return report.diagnostics
    }

    private func doctorReport(
        profileName: String?,
        profilesURL: URL?
    ) async throws -> CLIDoctorReport {
        let profile = try resolveProfile(
            name: profileName ?? "ko-meeting",
            profilesURL: profilesURL
        ).profile
        let selected = try selectedASR(profile.asrBackend)
        let storage = storageReport(profile, libraryStorageConfiguration())
        let postprocessBackend = PostprocessBackendID(rawValue: profile.postprocess)
        var lines = [
            "profile=\(profile.name)",
            "language=\(languageValue(profile.languagePin))",
            "diarization_enabled=\(profile.diarization.enabled)",
            "diarization_backend=\(profile.diarization.backend)",
            "postprocess=\(profile.postprocess)",
            "check.storage=\(storage.isObservable)",
            modelLine(name: "asr_model", model: selected.model),
            modelLine(name: "vad_model", model: SileroVADProvenance().model),
        ]
        if profile.diarization.enabled {
            lines.append(modelLine(
                name: "diarization_model",
                model: try diarizerModel(profile.diarization.backend)
            ))
        }
        if let postprocessBackend {
            lines += await dependencies.postprocessDoctor(postprocessBackend)
        } else {
            lines.append("check.postprocess=true")
        }
        lines += await dependencies.doctor(selected, profile)
        let failed = lines.contains {
            $0.hasPrefix("check.") && $0.hasSuffix("=false")
        }
        return CLIDoctorReport(
            diagnosticValues: PrivacyBoundText.redactingFilePaths(
                in: lines.joined(separator: "\n")
            ),
            storage: storage,
            isReady: !failed
        )
    }

    private func resolveProfile(name: String, profilesURL: URL?) throws -> ResolvedProfile {
        let url = profilesURL ?? cliResourcesBundle.url(
            forResource: "default-profiles",
            withExtension: "json"
        )
        guard let url else { throw CLIError.profile("default profile resource is missing") }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError.profile("profile registry is unreadable: \(url.path)")
        }
        let file: CLIProfileFile
        do {
            file = try JSONDecoder().decode(CLIProfileFile.self, from: data)
        } catch {
            throw CLIError.profile("profile registry is invalid JSON: \(error.localizedDescription)")
        }
        guard file.schemaVersion == MaccheroniSchema.version else {
            throw CLIError.profile(
                "profile registry schema must be \(MaccheroniSchema.version)"
            )
        }
        guard !file.profiles.isEmpty else {
            throw CLIError.profile("profile registry has no profiles")
        }
        var names = Set<String>()
        for candidate in file.profiles {
            try validate(profile: candidate)
            guard names.insert(candidate.name).inserted else {
                throw CLIError.profile("duplicate profile: \(candidate.name)")
            }
        }
        guard let profile = file.profiles.first(where: { $0.name == name }) else {
            throw CLIError.profile("unknown profile: \(name)")
        }
        return ResolvedProfile(
            profile: profile,
            directory: url.deletingLastPathComponent()
        )
    }

    private func validate(profile: CLIProfile) throws {
        guard profile.name.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil else {
            throw CLIError.profile("invalid profile name: \(profile.name)")
        }
        _ = try selectedASR(profile.asrBackend)
        _ = try diarizerModel(profile.diarization.backend)
        guard ["none", "codex", "local"].contains(profile.postprocess) else {
            throw CLIError.profile(
                "unknown postprocess backend: \(profile.postprocess)"
            )
        }
        let mode = profile.postprocessMode ?? .correction
        if profile.postprocess == "none" {
            guard profile.targetLanguage == nil else {
                throw CLIError.profile(
                    "target_language requires an enabled postprocess backend"
                )
            }
        } else {
            switch mode {
            case .correction:
                guard profile.targetLanguage == nil else {
                    throw CLIError.profile(
                        "target_language is valid only for translation mode"
                    )
                }
            case .translation:
                guard let targetLanguage = profile.targetLanguage,
                      targetLanguage.range(
                        of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$",
                        options: .regularExpression
                      ) != nil
                else {
                    throw CLIError.profile(
                        "translation mode requires a valid target_language"
                    )
                }
            }
        }
        if let path = profile.glossaryPath,
           path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw CLIError.profile("glossary_path must not be empty")
        }
        if case let .fixed(identifier) = profile.languagePin {
            guard identifier.range(
                of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$",
                options: .regularExpression
            ) != nil else {
                throw CLIError.profile("invalid language pin: \(identifier)")
            }
        }
    }

    private func selectedASR(_ value: String) throws -> SelectedASRBackend {
        guard let result = SelectedASRBackend(rawValue: value) else {
            throw CLIError.profile("unknown ASR backend: \(value)")
        }
        return result
    }

    private func diarizerModel(_ value: String) throws -> ModelDescriptor {
        switch value {
        case "community1": Community1Diarizer().model
        case "fluid": FluidAudioDiarizer().model
        default: throw CLIError.profile("unknown diarization backend: \(value)")
        }
    }

    private func resolvedGlossaryRevision(
        cliURL: URL?,
        profile: CLIProfile,
        profileDirectory: URL,
        store: GlossaryRevisionStore
    ) throws -> GlossaryRevision? {
        let profileURL = profile.glossaryPath.map { path -> URL in
            return (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : profileDirectory.appendingPathComponent(path)
        }
        guard let url = cliURL ?? profileURL else { return nil }
        do {
            return try store.createRevision(from: Data(contentsOf: url))
        } catch let error as GlossaryRevisionError {
            throw error
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.glossary(
                "glossary is invalid or unreadable: \(url.path) (\(String(describing: error)))"
            )
        }
    }

    private func validate(
        execution: CLIASRExecution,
        request: ASRRequest,
        glossary: Glossary?,
        selected: SelectedASRBackend
    ) throws {
        guard !execution.evidence.rawEvidence.isEmpty else {
            throw CLIError.run("ASR backend raw evidence is empty")
        }
        guard !execution.result.rawText.isEmpty,
              !execution.result.segments.isEmpty
        else {
            throw CLIError.run("ASR output has no transcript segments")
        }
        var previousStart = -Double.infinity
        for segment in execution.result.segments {
            guard segment.speaker == "UNASSIGNED",
                  segment.startS >= request.startS - 0.01,
                  segment.endS <= request.endS + 0.01,
                  segment.endS > segment.startS,
                  segment.startS >= previousStart
            else {
                throw CLIError.run(
                    "ASR output violates the normalized global-time contract"
                )
            }
            previousStart = segment.startS
        }
        if let glossary {
            guard execution.evidence.glossary.provided,
                  execution.evidence.glossary.sha256 == glossary.sha256,
                  execution.evidence.glossary.itemCount == glossary.entries.count,
                  execution.evidence.glossary.injectionMode
                    == selected.requiredInjectionMode,
                  execution.evidence.glossary.applied,
                  execution.result.glossaryApplied
            else {
                throw CLIError.glossary(
                    "ASR output did not prove the exact glossary injection"
                )
            }
        } else {
            guard execution.evidence.glossary == .absent,
                  !execution.result.glossaryApplied
            else {
                throw CLIError.glossary(
                    "ASR output falsely reports glossary application"
                )
            }
        }
    }

    private func validate(
        evidence: CLIASRAttemptEvidence,
        audioSHA256: String,
        language: LanguagePin,
        glossary: Glossary?,
        selected: SelectedASRBackend,
        policy: CLIASRInferencePolicy,
        expectedHelperFingerprint: ASRHelperFingerprint?,
        attemptTokenPlan: MOSSAttemptTokenPlan?,
        mossContextPlan: MOSSContextPlan?,
        request: ASRRequest
    ) throws {
        guard !evidence.rawEvidence.isEmpty,
              !evidence.runnerRecordEvidence.isEmpty
        else {
            throw CLIError.run("ASR attempt evidence is incomplete")
        }
        if let inputSHA256 = evidence.inputSHA256,
           inputSHA256 != audioSHA256
        {
            throw CLIError.run("ASR attempt input hash does not match its WAV")
        }
        if let glossary {
            guard evidence.glossary.provided,
                  evidence.glossary.sha256 == glossary.sha256,
                  evidence.glossary.itemCount == glossary.entries.count,
                  evidence.glossary.injectionMode
                    == selected.requiredInjectionMode,
                  evidence.glossary.applied,
                  evidence.glossaryPayloadEntryCount
                    == glossary.entries.count,
                  let glossaryPayloadSHA256 = evidence
                    .glossaryPayloadSHA256,
                  isSHA256(glossaryPayloadSHA256)
            else {
                throw CLIError.glossary(
                    "ASR attempt did not prove the exact glossary transport"
                )
            }
        } else {
            guard evidence.glossary == .absent,
                  evidence.glossaryPayloadEntryCount == 0,
                  evidence.glossaryPayloadSHA256 == nil
            else {
                throw CLIError.glossary(
                    "ASR attempt falsely reports glossary transport"
                )
            }
        }

        guard selected == .moss else {
            if let metrics = evidence.metrics {
                guard metrics.maxTokens == policy.maximumTokens else {
                    throw CLIError.run("ASR attempt used a different token budget")
                }
            }
            return
        }
        guard let metrics = evidence.metrics,
              metrics.maxTokens == policy.maximumTokens,
              let contextHardCapTokens = metrics.contextHardCapTokens,
              let policyContextHardCapTokens = policy.contextHardCapTokens,
              contextHardCapTokens == policyContextHardCapTokens,
              let attemptTokenPlan,
              metrics.promptTokens == attemptTokenPlan.promptTokens,
              metrics.promptTokens + metrics.generatedTokens
                <= contextHardCapTokens,
              let languageEvidence = evidence.language,
              let mossContextPlan,
              languageEvidence.requested == languageValue(language),
              isSHA256(languageEvidence.instructionSHA256),
              languageEvidence.instructionSHA256
                == mossContextPlan.instructionSHA256,
              languageEvidence.promptGuidanceApplied
                == (languageValue(language) != "auto"),
              let expectedHelperFingerprint,
              evidence.helperFingerprint == expectedHelperFingerprint,
              expectedHelperFingerprint.sha256
                == mossContextPlan.helperFingerprintSHA256,
              isSHA256(expectedHelperFingerprint.sha256),
              evidence.inputSHA256 == audioSHA256,
              !evidence.command.isEmpty,
              commandValue("--audio", in: evidence.command)
                == request.audioURL.path,
              commandValue("--max-tokens", in: evidence.command)
                == String(policy.maximumTokens),
              commandValue("--language", in: evidence.command)
                == languageValue(language),
              (glossary == nil)
                == (commandValue("--glossary", in: evidence.command) == nil)
        else {
            throw CLIError.run(
                "MOSS attempt evidence does not match its constraint snapshot"
            )
        }
        if glossary != nil {
            guard evidence.glossaryPayloadSHA256
                    == languageEvidence.instructionSHA256
            else {
                throw CLIError.glossary(
                    "MOSS glossary and language instruction evidence disagree"
                )
            }
        }
    }

    /// Check that the promoted attempts tile their root exactly and report
    /// what they actually covered.  Leaf planning still has to cover every
    /// sample; a leaf that promoted only a recovered prefix contributes its
    /// covered range and names the remainder as missing.
    /// Check that every planned leaf of this root is accounted for, and report
    /// what was actually covered.  Planning still has to tile the root exactly;
    /// a leaf may now account for its range by promoting a prefix or by being
    /// recorded as unrecovered, and either way the gap is named rather than
    /// dropped.
    private func validate(
        completedLeaves: [CompletedASRLeaf],
        unrecovered: [UnrecoveredASRLeaf],
        covering root: InferenceLeaf,
        sampleRateHz: Int
    ) throws -> (coveredSamples: Int64, missing: [MissingSourceRange]) {
        guard !completedLeaves.isEmpty else {
            throw CLIError.run("ASR root produced no promotable leaves")
        }
        enum Accounted {
            case promoted(CompletedASRLeaf)
            case unrecovered(UnrecoveredASRLeaf)

            var leaf: InferenceLeaf {
                switch self {
                case let .promoted(value): value.leaf
                case let .unrecovered(value): value.leaf
                }
            }
        }
        let accounted = (completedLeaves.map(Accounted.promoted)
            + unrecovered.map(Accounted.unrecovered))
            .sorted { $0.leaf.startSample < $1.leaf.startSample }
        var cursor = root.startSample
        var coveredSamples: Int64 = 0
        var missing: [MissingSourceRange] = []
        for entry in accounted {
            let leaf = entry.leaf
            guard leaf.startSample == cursor,
                  leaf.endSample > leaf.startSample,
                  leaf.endSample <= root.endSample
            else {
                throw CLIError.run(
                    "attempt leaves do not exactly cover their root"
                )
            }
            switch entry {
            case let .promoted(completed):
                guard completed.coveredEndSample > leaf.startSample,
                      completed.coveredEndSample <= leaf.endSample,
                      !completed.resultSHA256.isEmpty
                else {
                    throw CLIError.run(
                        "attempt leaves do not exactly cover their root"
                    )
                }
                coveredSamples += completed.coveredEndSample - leaf.startSample
                if completed.coveredEndSample < leaf.endSample {
                    missing.append(MissingSourceRange(
                        startS: Double(completed.coveredEndSample)
                            / Double(sampleRateHz),
                        endS: Double(leaf.endSample) / Double(sampleRateHz),
                        attemptID: completed.attemptID,
                        stopReason: completed.stopReason,
                        failureCode: completed.stopReason == .repetitionDegeneration
                            ? CLIError.asrRepetitionDegeneration("").code
                            : CLIError.asrLimitExhausted("").code
                    ))
                }
            case let .unrecovered(entry):
                missing.append(MissingSourceRange(
                    startS: Double(leaf.startSample) / Double(sampleRateHz),
                    endS: Double(leaf.endSample) / Double(sampleRateHz),
                    attemptID: entry.attemptID,
                    stopReason: entry.stopReason,
                    failureCode: entry.failure.code
                ))
            }
            cursor = leaf.endSample
        }
        guard cursor == root.endSample else {
            throw CLIError.run(
                "attempt leaves do not exactly cover their root"
            )
        }
        return (coveredSamples, missing)
    }

    private func validate(
        postprocess result: PostprocessResult,
        against original: SegmentsDocument,
        glossary: Glossary?,
        backend: PostprocessBackendID
    ) throws {
        let provenance = result.manifestPostprocess
        guard provenance.inputMode == .textOnly,
              provenance.glossarySHA256 == glossary?.sha256,
              !provenance.modelID.isEmpty,
              provenance.mode == .correction,
              provenance.targetLanguage == nil,
              provenance.sourceSegmentsSHA256 == nil,
              let batching = provenance.batching,
              batching.batchesPlanned > 0
        else {
            throw CLIError.postprocess(
                "postprocess provenance does not match its text-only input"
            )
        }
        switch backend {
        case .codex:
            guard provenance.backend.name == "codex-app-server",
                  !provenance.backend.version.isEmpty,
                  provenance.modelID == CodexPostprocessBackend.modelName,
                  provenance.modelRevision == nil,
                  provenance.quantization == nil,
                  validates(
                    batching: batching,
                    against: CodexPostprocessBackend.defaultBatchPolicy
                  )
            else {
                throw CLIError.postprocess(
                    "Codex postprocess provenance is incomplete or fabricated"
                )
            }
        case .local:
            let pinned = LocalPostprocessBackend.pinnedModel
            guard provenance.backend == LocalPostprocessBackend.descriptor,
                  provenance.modelID == pinned.hfModelID,
                  provenance.modelRevision == pinned.revision,
                  provenance.quantization == pinned.quantization,
                  validates(
                    batching: batching,
                    against: LocalPostprocessBackend.defaultBatchPolicy
                  )
            else {
                throw CLIError.postprocess(
                    "local postprocess provenance does not match the pinned model"
                )
            }
        }

        let document = result.document
        guard SegmentsDocumentContract.isValid(document),
              document.schemaVersion == original.schemaVersion,
              document.numSpeakers == original.numSpeakers,
              document.source == original.source,
              document.segments.count == original.segments.count
        else {
            throw CLIError.postprocess(
                "postprocess output changed transcript structure or source provenance"
            )
        }

        var conflictsByIndex: [Int: PostprocessConflict] = [:]
        for conflict in result.conflicts {
            guard original.segments.indices.contains(conflict.segmentIndex),
                  conflictsByIndex[conflict.segmentIndex] == nil,
                  conflict.originalText
                    == original.segments[conflict.segmentIndex].text,
                  !conflict.candidateText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !conflict.reason
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIError.postprocess(
                    "postprocess conflict does not match its source segment"
                )
            }
            conflictsByIndex[conflict.segmentIndex] = conflict
        }

        for index in original.segments.indices {
            let before = original.segments[index]
            let after = document.segments[index]
            guard after.speaker == before.speaker,
                  after.startS == before.startS,
                  after.endS == before.endS,
                  after.language == before.language,
                  after.confidence == before.confidence,
                  !after.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIError.postprocess(
                    "postprocess output changed speaker, timing, or segment metadata"
                )
            }
            if conflictsByIndex[index] == nil {
                guard after.flags == before.flags else {
                    throw CLIError.postprocess(
                        "postprocess output changed flags without a review conflict"
                    )
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
                    throw CLIError.postprocess(
                        "review postprocess output must preserve text and add review flags"
                    )
                }
            }
        }
    }

    private func validate(
        translation result: TranslationResult,
        against original: SegmentsDocument,
        sourceSegmentsSHA256: String,
        glossary: Glossary?,
        backend: PostprocessBackendID,
        targetLanguage: String
    ) throws {
        let provenance = result.manifestPostprocess
        guard provenance.inputMode == .textOnly,
              provenance.glossarySHA256 == glossary?.sha256,
              provenance.mode == .translation,
              provenance.targetLanguage == targetLanguage,
              provenance.sourceSegmentsSHA256 == sourceSegmentsSHA256,
              !provenance.modelID.isEmpty,
              let batching = provenance.batching,
              batching.batchesPlanned > 0
        else {
            throw CLIError.postprocess(
                "translation provenance does not match its text-only source"
            )
        }
        switch backend {
        case .codex:
            guard provenance.backend.name == "codex-app-server",
                  !provenance.backend.version.isEmpty,
                  provenance.modelID == CodexPostprocessBackend.modelName,
                  provenance.modelRevision == nil,
                  provenance.quantization == nil,
                  validates(
                    batching: batching,
                    against: CodexPostprocessBackend.defaultBatchPolicy
                  )
            else {
                throw CLIError.postprocess(
                    "Codex translation provenance is incomplete or fabricated"
                )
            }
        case .local:
            let pinned = LocalPostprocessBackend.pinnedModel
            guard provenance.backend == LocalPostprocessBackend.descriptor,
                  provenance.modelID == pinned.hfModelID,
                  provenance.modelRevision == pinned.revision,
                  provenance.quantization == pinned.quantization,
                  validates(
                    batching: batching,
                    against: LocalPostprocessBackend.defaultBatchPolicy
                  )
            else {
                throw CLIError.postprocess(
                    "local translation provenance does not match the pinned model"
                )
            }
        }

        let document = result.document
        guard document.schemaVersion == MaccheroniSchema.version,
              document.targetLanguage == targetLanguage,
              document.sourceSegmentsSHA256 == sourceSegmentsSHA256,
              document.translations.count == original.segments.count,
              document.batches.count == batching.batchesPlanned
        else {
            throw CLIError.postprocess(
                "translation artifact does not match its canonical source"
            )
        }

        var translationIndices = Set<Int>()
        for translation in document.translations {
            guard original.segments.indices.contains(translation.segmentIndex),
                  translationIndices.insert(translation.segmentIndex).inserted,
                  !translation.translatedText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw CLIError.postprocess(
                    "translation artifact has invalid segment coverage"
                )
            }
        }
        guard translationIndices == Set(original.segments.indices) else {
            throw CLIError.postprocess(
                "translation artifact omitted one or more source segments"
            )
        }

        let translationsByIndex = Dictionary(
            uniqueKeysWithValues: document.translations.map {
                ($0.segmentIndex, $0)
            }
        )
        var batchedIndices: [Int] = []
        for (batchIndex, batch) in document.batches.enumerated() {
            guard !batch.segmentIndices.isEmpty,
                  batch.segmentIndices.allSatisfy(original.segments.indices.contains)
            else {
                throw CLIError.postprocess(
                    "translation batch refers to an invalid source segment"
                )
            }
            let inputTextUTF8Bytes = batch.segmentIndices.reduce(0) {
                saturatingAdd($0, original.segments[$1].text.utf8.count)
            }
            let outputTextUTF8Bytes = try batch.segmentIndices.reduce(0) {
                guard let translation = translationsByIndex[$1] else {
                    throw CLIError.postprocess(
                        "translation batch refers to a missing result"
                    )
                }
                return saturatingAdd($0, translation.translatedText.utf8.count)
            }
            let expectedEstimatedOutputTokens =
                estimatedOutputTokens(
                    inputTextUTF8Bytes: inputTextUTF8Bytes,
                    segmentCount: batch.segmentIndices.count,
                    batching: batching
                )
            let expectedAcceptedUpperBound = acceptedOutputTokenUpperBound(
                responseUTF8Bytes: batch.responseUTF8Bytes,
                segmentCount: batch.segmentIndices.count,
                batching: batching
            )
            guard batch.batchIndex == batchIndex,
                  batch.segmentIndices.count <= batching.maximumSegmentsPerBatch,
                  batch.promptUTF8Bytes > 0,
                  batch.promptUTF8Bytes <= batching.maximumPromptUTF8Bytes,
                  batch.inputTextUTF8Bytes == inputTextUTF8Bytes,
                  batch.estimatedOutputTokens == expectedEstimatedOutputTokens,
                  batch.estimatedOutputTokens <= batching.outputTokenPlanningBudget,
                  batch.outputTextUTF8Bytes == outputTextUTF8Bytes,
                  batch.responseUTF8Bytes >= batch.outputTextUTF8Bytes,
                  batch.acceptedOutputTokenUpperBound == expectedAcceptedUpperBound,
                  batch.acceptedOutputTokenUpperBound
                    <= batching.outputTokenPlanningBudget
            else {
                throw CLIError.postprocess(
                    "translation batch evidence exceeds its declared policy"
                )
            }
            batchedIndices.append(contentsOf: batch.segmentIndices)
        }
        guard batchedIndices == Array(original.segments.indices) else {
            throw CLIError.postprocess(
                "translation batches are not contiguous source coverage"
            )
        }
        guard batching.maximumObservedPromptUTF8Bytes
                == document.batches.map(\.promptUTF8Bytes).max(),
              batching.maximumObservedInputTextUTF8Bytes
                == document.batches.map(\.inputTextUTF8Bytes).max(),
              batching.maximumObservedEstimatedOutputTokens
                == document.batches.map(\.estimatedOutputTokens).max(),
              batching.maximumObservedOutputTextUTF8Bytes
                == document.batches.map(\.outputTextUTF8Bytes).max(),
              batching.maximumObservedResponseUTF8Bytes
                == document.batches.map(\.responseUTF8Bytes).max(),
              batching.maximumObservedAcceptedOutputTokenUpperBound
                == document.batches.map(\.acceptedOutputTokenUpperBound).max()
        else {
            throw CLIError.postprocess(
                "translation manifest does not match its batch evidence"
            )
        }
    }

    private func validates(
        batching: ManifestPostprocessBatching,
        against policy: PostprocessBatchPolicy
    ) -> Bool {
        guard batching.maximumPromptUTF8Bytes == policy.maximumPromptUTF8Bytes,
              batching.maximumSegmentsPerBatch == policy.maximumSegmentsPerBatch,
              batching.maximumOutputTokens == policy.maximumOutputTokens,
              batching.outputTokenLimitStatus == policy.outputTokenLimitStatus,
              batching.outputTokenPlanningBudget == policy.outputTokenPlanningBudget,
              batching.outputTokensPerInputUTF8BytePermille
                == policy.outputTokensPerInputUTF8BytePermille,
              batching.baseOutputTokenReserve == policy.baseOutputTokenReserve,
              batching.perSegmentOutputTokenReserve
                == policy.perSegmentOutputTokenReserve,
              batching.maximumObservedPromptUTF8Bytes > 0,
              batching.maximumObservedPromptUTF8Bytes
                <= policy.maximumPromptUTF8Bytes,
              batching.maximumObservedInputTextUTF8Bytes >= 0,
              batching.maximumObservedEstimatedOutputTokens > 0,
              batching.maximumObservedEstimatedOutputTokens
                <= policy.outputTokenPlanningBudget,
              batching.maximumObservedOutputTextUTF8Bytes >= 0,
              batching.maximumObservedResponseUTF8Bytes
                >= batching.maximumObservedOutputTextUTF8Bytes,
              batching.maximumObservedAcceptedOutputTokenUpperBound >= 0,
              batching.maximumObservedAcceptedOutputTokenUpperBound
                <= policy.outputTokenPlanningBudget
        else {
            return false
        }
        return true
    }

    private func estimatedOutputTokens(
        inputTextUTF8Bytes: Int,
        segmentCount: Int,
        batching: ManifestPostprocessBatching
    ) -> Int {
        let (scaled, scaleOverflow) = inputTextUTF8Bytes.multipliedReportingOverflow(
            by: batching.outputTokensPerInputUTF8BytePermille
        )
        guard !scaleOverflow, scaled <= Int.max - 999 else { return .max }
        let sourceEstimate = (scaled + 999) / 1_000
        return reservedOutputTokenUpperBound(
            textUTF8Bytes: sourceEstimate,
            segmentCount: segmentCount,
            batching: batching
        )
    }

    private func acceptedOutputTokenUpperBound(
        responseUTF8Bytes: Int,
        segmentCount: Int,
        batching: ManifestPostprocessBatching
    ) -> Int {
        reservedOutputTokenUpperBound(
            textUTF8Bytes: responseUTF8Bytes,
            segmentCount: segmentCount,
            batching: batching
        )
    }

    private func reservedOutputTokenUpperBound(
        textUTF8Bytes: Int,
        segmentCount: Int,
        batching: ManifestPostprocessBatching
    ) -> Int {
        let (segmentReserve, segmentOverflow) =
            segmentCount.multipliedReportingOverflow(
                by: batching.perSegmentOutputTokenReserve
            )
        guard !segmentOverflow else { return .max }
        let (withBase, baseOverflow) = textUTF8Bytes.addingReportingOverflow(
            batching.baseOutputTokenReserve
        )
        guard !baseOverflow else { return .max }
        let (total, totalOverflow) = withBase.addingReportingOverflow(segmentReserve)
        return totalOverflow ? .max : total
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private func validate(
        preprocessed: PreprocessedAudio,
        inputHash: String,
        sourceDurationS: Double
    ) throws {
        guard preprocessed.inputSHA256 == inputHash else {
            throw CLIError.run(
                "preprocessing provenance does not match the initial input hash"
            )
        }
        let actualHash = try AudioPreprocessor.sha256(
            of: preprocessed.artifactURL
        )
        let audio = try AVAudioFile(forReading: preprocessed.artifactURL)
        let actualDuration = Double(audio.length)
            / audio.processingFormat.sampleRate
        guard actualHash == preprocessed.artifactSHA256,
              abs(preprocessed.durationS - actualDuration) <= 0.01,
              abs(sourceDurationS - actualDuration) <= 0.01,
              abs(preprocessed.sampleRateHz - 16_000) < 0.5,
              abs(audio.processingFormat.sampleRate - 16_000) < 0.5,
              preprocessed.channels == 1,
              audio.processingFormat.channelCount == 1,
              preprocessed.settings == .default
        else {
            throw CLIError.run("preprocessing provenance is inconsistent")
        }
    }

    private func validate(
        inferencePlan: [InferenceLeaf],
        totalSamples: Int64,
        policy: CLIASRInferencePolicy
    ) throws {
        let maximumSamples = InferenceLeafPlanner.sampleIndex(
            seconds: policy.maximumInitialDurationS,
            sampleRateHz: policy.sampleRateHz
        )
        var cursor: Int64 = 0
        for leaf in inferencePlan {
            guard leaf.depth == 0,
                  leaf.startSample == cursor,
                  leaf.endSample > leaf.startSample,
                  leaf.endSample <= totalSamples,
                  leaf.sampleCount <= maximumSamples
            else {
                throw CLIError.run(
                    "ASR inference plan is non-contiguous or exceeds its backend limit"
                )
            }
            cursor = leaf.endSample
        }
        guard cursor == totalSamples else {
            throw CLIError.run(
                "ASR inference plan does not cover every input sample"
            )
        }
    }

    private func proposedChunks(
        from leaves: [InferenceLeaf],
        sampleRateHz: Int
    ) -> [ProposedChunk] {
        leaves.enumerated().map { index, leaf in
            ProposedChunk(
                index: index,
                startS: Double(leaf.startSample) / Double(sampleRateHz),
                endS: Double(leaf.endSample) / Double(sampleRateHz),
                boundarySource: leaf.boundarySource == .deterministicFallback
                    ? .deterministicFallback
                    : .silence
            )
        }
    }

    private func validate(chunkPlan: [ProposedChunk], durationS: Double) throws {
        var cursor = 0.0
        for (offset, chunk) in chunkPlan.enumerated() {
            guard chunk.index == offset,
                  chunk.startS.isFinite,
                  chunk.endS.isFinite,
                  chunk.endS > chunk.startS,
                  abs(chunk.startS - cursor) <= 0.000_001,
                  chunk.endS <= durationS + 0.01
            else {
                throw CLIError.run("chunk plan is non-contiguous or out of range")
            }
            cursor = chunk.endS
        }
        guard abs(cursor - durationS) <= 0.01 else {
            throw CLIError.run("chunk plan does not cover the full input")
        }
    }
}

private struct ResolvedProfile {
    var profile: CLIProfile
    var directory: URL
}

private struct DiarizationWarningRecord: Codable {
    var segmentIndex: Int
    var rawEndS: Double
    var normalizedEndS: Double
    var deltaS: Double

    init(_ warning: DiarizationNormalizationWarning) {
        segmentIndex = warning.segmentIndex
        rawEndS = warning.rawEndS
        normalizedEndS = warning.normalizedEndS
        deltaS = warning.deltaS
    }

    enum CodingKeys: String, CodingKey {
        case segmentIndex = "segment_index"
        case rawEndS = "raw_end_s"
        case normalizedEndS = "normalized_end_s"
        case deltaS = "delta_s"
    }
}

private struct DiarizationOrderRecord: Codable {
    var emittedIndex: Int
    var normalizedIndex: Int
    var speaker: String
    var startS: Double
    var endS: Double

    init(_ normalization: DiarizationOrderNormalization) {
        emittedIndex = normalization.emittedIndex
        normalizedIndex = normalization.normalizedIndex
        speaker = normalization.speaker
        startS = normalization.startS
        endS = normalization.endS
    }

    enum CodingKeys: String, CodingKey {
        case emittedIndex = "emitted_index"
        case normalizedIndex = "normalized_index"
        case speaker
        case startS = "start_s"
        case endS = "end_s"
    }
}

/// Where a derived run keeps its marked speaker proposal. It sits under its own
/// prefix rather than under `postprocess/`, because nothing here is a text
/// operation and a reader listing the set should be able to tell that from the
/// path alone.
private let speakerProposalArtifactPath = "speaker/proposals.json"
private let speakerProposalArtifactKind = "speaker_proposals"

/// Where a rejected backend timeline is kept inside the run directory, beside
/// the `diarization/backend.raw.json` an accepted one produces.
private let rejectedDiarizationArtifactPath =
    "diarization/rejected-backend.raw.json"
private let rejectedDiarizationArtifactKind =
    "diarization_rejected_backend_raw"

/// Copy a rejected diarization timeline into the run directory and rename the
/// failure after that copy.
///
/// `DiarizationError.rejectedOutput` already carries the exact bytes the
/// backend emitted, but it names them at a path the run does not own: either
/// `$TMPDIR/Maccheroni/diarization/rejected/`, which the OS sweeps on its own
/// schedule, or the FluidAudio harness's own output file. Either way a
/// rejection was diagnosable only for as long as something outside the run
/// directory happened to survive. The payload holds no transcript text — across
/// the 18 samples captured on 2026-09-01 its complete key set is `segments`,
/// `num_speakers`, `speaker`, `start`, `end` and `duration`, numeric apart from
/// the cluster label — so the run may keep it, though nothing here may be
/// committed.
///
/// Anything that is not a rejection, and any rejection whose bytes are already
/// gone or cannot be written, passes through unchanged: a diagnosis must not be
/// replaced by a filesystem complaint.
private func preservedRejectedTimeline(
    _ error: Error,
    writer: RunWriter,
    artifacts: inout [Artifact]
) -> Error {
    guard let rejection = error as? DiarizationError,
          case let .rejectedOutput(reason, rawOutputPath) = rejection,
          let rawJSON = try? Data(
              contentsOf: URL(fileURLWithPath: rawOutputPath)
          )
    else { return error }
    do {
        try writer.write(rawJSON, at: rejectedDiarizationArtifactPath)
        try writer.addArtifact(
            &artifacts,
            kind: rejectedDiarizationArtifactKind,
            relative: rejectedDiarizationArtifactPath
        )
    } catch {
        return rejection
    }
    return DiarizationError.rejectedOutput(
        reason: reason,
        rawOutputPath: rejectedDiarizationArtifactPath
    )
}

private enum CLICommand {
    case run(URL, String, URL?, URL?, URL?)
    case postprocess(
        URL,
        String,
        URL?,
        URL?,
        DerivedGlossarySemantics
    )
    case proposeSpeakers(URL, String, URL?)
    case doctor(String?, URL?)

    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else {
            throw CLIError.usage(
                "usage: maccheroni run <audio> --profile <name> | postprocess <run> --profile <name> | propose-speakers <run> --profile <name> | doctor [--profile <name>]"
            )
        }
        var values: [String: String] = [:]
        var positional: [String] = []
        var index = 1
        while index < arguments.count {
            let value = arguments[index]
            if value.hasPrefix("--") {
                guard index + 1 < arguments.count,
                      !arguments[index + 1].hasPrefix("--"),
                      values[value] == nil
                else {
                    throw CLIError.usage("invalid or duplicate option: \(value)")
                }
                values[value] = arguments[index + 1]
                index += 2
            } else {
                positional.append(value)
                index += 1
            }
        }

        let allowed: Set<String>
        switch command {
        case "run":
            allowed = ["--profile", "--profiles", "--output-root", "--glossary"]
        case "postprocess":
            allowed = [
                "--profile",
                "--profiles",
                "--glossary",
                "--glossary-semantics",
            ]
        case "propose-speakers":
            // No glossary options: a glossary is decode-time context for words,
            // and this operation proposes speakers rather than text.
            allowed = ["--profile", "--profiles"]
        case "doctor":
            allowed = ["--profile", "--profiles"]
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
        guard values.keys.allSatisfy(allowed.contains) else {
            throw CLIError.usage("unknown option")
        }

        if command == "run" {
            guard positional.count == 1, let profile = values["--profile"] else {
                throw CLIError.usage(
                    "usage: maccheroni run <audio> --profile <name>"
                )
            }
            return .run(
                URL(fileURLWithPath: positional[0]),
                profile,
                values["--profiles"].map(URL.init(fileURLWithPath:)),
                values["--output-root"].map(URL.init(fileURLWithPath:)),
                values["--glossary"].map(URL.init(fileURLWithPath:))
            )
        }
        if command == "postprocess" {
            guard positional.count == 1, let profile = values["--profile"] else {
                throw CLIError.usage(
                    "usage: maccheroni postprocess <run> --profile <name>"
                )
            }
            let glossarySemantics: DerivedGlossarySemantics
            if let rawValue = values["--glossary-semantics"] {
                guard let parsed = DerivedGlossarySemantics(rawValue: rawValue) else {
                    throw CLIError.usage(
                        "invalid glossary semantics: \(rawValue)"
                    )
                }
                glossarySemantics = parsed
            } else {
                glossarySemantics = .currentProfile
            }
            return .postprocess(
                URL(fileURLWithPath: positional[0], isDirectory: true),
                profile,
                values["--profiles"].map(URL.init(fileURLWithPath:)),
                values["--glossary"].map(URL.init(fileURLWithPath:)),
                glossarySemantics
            )
        }
        if command == "propose-speakers" {
            guard positional.count == 1, let profile = values["--profile"] else {
                throw CLIError.usage(
                    "usage: maccheroni propose-speakers <run> --profile <name>"
                )
            }
            return .proposeSpeakers(
                URL(fileURLWithPath: positional[0], isDirectory: true),
                profile,
                values["--profiles"].map(URL.init(fileURLWithPath:))
            )
        }
        guard positional.isEmpty else {
            throw CLIError.usage(
                "usage: maccheroni doctor [--profile <name>]"
            )
        }
        return .doctor(
            values["--profile"],
            values["--profiles"].map(URL.init(fileURLWithPath:))
        )
    }
}

private final class RunWriter: @unchecked Sendable {
    let directory: URL
    let id: String
    private let containmentRoot: String

    init(root: URL, id: String) throws {
        guard id.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
            options: .regularExpression
        ) != nil else {
            throw CLIError.run("invalid run ID")
        }
        self.id = id
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        directory = root.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CLIError.run("run directory exists: \(directory.path)")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        containmentRoot = RunWriter.containmentPath(of: directory) + "/"
    }

    func relative(_ url: URL) throws -> String {
        let path = RunWriter.containmentPath(of: url)
        guard path.hasPrefix(containmentRoot) else {
            throw CLIError.run("artifact is outside the run directory")
        }
        return String(path.dropFirst(containmentRoot.count))
    }

    func write<T: Encodable>(
        _ value: T,
        at relative: String,
        replace: Bool = false
    ) throws {
        try write(
            JSONEncoder.pretty.encode(value),
            at: relative,
            replace: replace
        )
    }

    func write(_ text: String, at relative: String) throws {
        try write(Data(text.utf8), at: relative)
    }

    func write(
        _ data: Data,
        at relative: String,
        replace: Bool = false
    ) throws {
        let target = try targetURL(for: relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard replace || !FileManager.default.fileExists(atPath: target.path) else {
            throw CLIError.run("refusing to overwrite \(relative)")
        }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString)-\(target.lastPathComponent)"
        )
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
            guard Darwin.rename(temporary.path, target.path) == 0 else {
                throw CLIError.run("atomic write failed: \(relative)")
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func addArtifact(
        _ artifacts: inout [Artifact],
        kind: String,
        relative: String
    ) throws {
        guard !artifacts.contains(where: { $0.path == relative }) else {
            throw CLIError.run("duplicate artifact path: \(relative)")
        }
        let url = try targetURL(for: relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw CLIError.run("artifact is missing: \(relative)")
        }
        artifacts.append(Artifact(
            kind: kind,
            path: relative,
            sha256: try AudioPreprocessor.sha256(of: url)
        ))
    }

    func addArtifactsRecursively(
        _ artifacts: inout [Artifact],
        under relativeRoot: String,
        kind: String
    ) throws {
        let root = try targetURL(for: relativeRoot)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let existing = Set(artifacts.map(\.path))
        for file in try regularFiles(under: root) {
            let path = try relative(file)
            guard !existing.contains(path),
                  !artifacts.contains(where: { $0.path == path })
            else { continue }
            try addArtifact(&artifacts, kind: kind, relative: path)
        }
    }

    func addAllUntrackedArtifacts(
        _ artifacts: inout [Artifact],
        kind: String
    ) throws {
        for file in try regularFiles(under: directory) {
            let path = try relative(file)
            guard path != "manifest.json",
                  !artifacts.contains(where: { $0.path == path })
            else { continue }
            try addArtifact(&artifacts, kind: kind, relative: path)
        }
    }

    func rebuiltArtifacts(
        preservingKindsFrom artifacts: [Artifact]
    ) -> [Artifact] {
        let kinds = Dictionary(
            artifacts.map { ($0.path, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let files = try? regularFiles(under: directory) else { return [] }
        return files.compactMap { file in
            guard let path = try? relative(file),
                  path != "manifest.json",
                  let sha256 = try? AudioPreprocessor.sha256(of: file)
            else { return nil }
            return Artifact(
                kind: kinds[path] ?? "preserved_partial_artifact",
                path: path,
                sha256: sha256
            )
        }
    }

    func verify(artifacts: [Artifact]) throws {
        let paths = artifacts.map(\.path)
        guard Set(paths).count == paths.count else {
            throw CLIError.run("manifest contains duplicate artifact paths")
        }
        for artifact in artifacts {
            let url = try targetURL(for: artifact.path)
            guard try AudioPreprocessor.sha256(of: url) == artifact.sha256 else {
                throw CLIError.run("artifact hash changed: \(artifact.path)")
            }
        }
        let actual = Set(try regularFiles(under: directory).map { try relative($0) })
            .subtracting(["manifest.json"])
        guard actual == Set(paths) else {
            let missing = actual.subtracting(paths).sorted()
            let stale = Set(paths).subtracting(actual).sorted()
            throw CLIError.run(
                "artifact manifest is incomplete; unlisted=\(missing), missing=\(stale)"
            )
        }
    }

    private func targetURL(for relative: String) throws -> URL {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.split(separator: "/", omittingEmptySubsequences: false)
                .contains("..")
        else {
            throw CLIError.run("invalid run-relative path: \(relative)")
        }
        let target = directory.appendingPathComponent(relative).standardized
        guard RunWriter.containmentPath(of: target).hasPrefix(containmentRoot) else {
            throw CLIError.run("run-relative path escaped the run directory")
        }
        return target
    }

    /// Normalizes a path so both sides of a containment check land in the same
    /// namespace.  `standardizedFileURL` folds `/private/tmp` to `/tmp` only for
    /// paths that already exist, so an existing run directory and a target file
    /// that has not been written yet normalize to different roots and a
    /// contained path is reported as an escape.  Resolving the deepest existing
    /// ancestor and re-appending the rest does not depend on what exists.
    private static func containmentPath(of url: URL) -> String {
        var existing = URL(fileURLWithPath: url.path).standardized
        var pending: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            pending.append(existing.lastPathComponent)
            existing = parent
        }
        var normalized = existing.resolvingSymlinksInPath()
        for component in pending.reversed() {
            normalized.appendPathComponent(component)
        }
        return normalized.path
    }

    private func regularFiles(under root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ) else { return [] }
        if !isDirectory.boolValue { return [root] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            throw CLIError.run("cannot enumerate run artifacts")
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Glossary {
    func manifest(
        mode: GlossaryInjectionMode,
        applied: Bool
    ) -> ManifestGlossary {
        ManifestGlossary(
            provided: true,
            sha256: sha256,
            itemCount: entries.count,
            injectionMode: mode,
            applied: applied
        )
    }
}

private func modelLine(name: String, model: ModelDescriptor) -> String {
    "\(name)=\(model.hfModelID)@\(model.revision) [\(model.quantization)]"
}

private func languageValue(_ language: LanguagePin) -> String {
    switch language {
    case .automatic: "auto"
    case let .fixed(value): value.lowercased()
    }
}

private func commandValue(_ flag: String, in command: [String]) -> String? {
    let matches = command.indices.compactMap { index -> String? in
        guard command[index] == flag,
              command.indices.contains(index + 1)
        else { return nil }
        return command[index + 1]
    }
    return matches.count == 1 ? matches[0] : nil
}

/// Adapter errors that earned their own persisted bucket.  Returning `nil`
/// keeps an error on the generic `backend_failed` / `ASR_ERROR` fallback, so
/// new adapter cases stay classified until they are given a stable name.
private func typedASRAttemptStatus(
    for error: ASRAdapterError
) -> ASRAttemptStatus? {
    switch error {
    case .invalidEOSOutput: return .invalidEOSOutput
    case .timedOut: return .asrTimeout
    case .evidenceUnavailable: return .asrEvidenceUnavailable
    case .malformedOutput: return .asrMalformedOutput
    case .coverageShortfall: return .asrCoverageShortfall
    case .modelIdentityMismatch: return .asrModelIdentityMismatch
    case .unsupportedInjectionMode, .invalidRequest, .runtimeMissing,
         .launchFailed, .backendFailed, .inferenceLimit:
        return nil
    }
}

private func failureCode(for error: Error) -> String {
    if let error = error as? CLIError { return error.code }
    if error is CancellationError { return "CANCELED" }
    if let error = error as? ASRAdapterError,
       let status = typedASRAttemptStatus(for: error)
    {
        return status.rawValue
    }
    return switch error {
    case is PreprocessError: "PREPROCESS_ERROR"
    case is VoiceActivityError: "VAD_ERROR"
    case is ChunkPlanningError, is InferenceLeafPlanningError:
        "CHUNK_PLAN_ERROR"
    case is DiarizationError: "DIARIZATION_ERROR"
    case is ASRAdapterError: "ASR_ERROR"
    case is TimelineMergeError: "MERGE_ERROR"
    case is GlossaryError: "GLOSSARY_ERROR"
    default: "RUN_ERROR"
    }
}

private func attemptStatus(for error: Error) -> ASRAttemptStatus {
    if error is CancellationError { return .canceled }
    if let error = error as? ASRAdapterError,
       let status = typedASRAttemptStatus(for: error)
    {
        return status
    }
    return .backendFailed
}

private func failureMessage(for error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription
    {
        return description
    }
    return String(describing: error)
}

private func productionASRPlan(
    _ activityMap: VoiceActivityMap,
    _ policy: CLIASRInferencePolicy,
    _ totalSamples: Int64
) throws -> [InferenceLeaf] {
    return try InferenceLeafPlanner().proposeInitialLeaves(
        totalSamples: totalSamples,
        activityMap: activityMap,
        configuration: policy.planningConfiguration
    )
}

private struct MossHelperFingerprintSidecar: Decodable {
    var contractVersion: String
    var sourceTreeSHA256: String
    var packageSwiftSHA256: String
    var packageResolvedSHA256: String
    var swiftVersion: String
    var swiftVersionSHA256: String
    var targetArchitecture: String
    var configuration: String
    var buildFlags: [String]
    var executableSHA256: String
    var metallibSHA256: String

    enum CodingKeys: String, CodingKey {
        case configuration
        case contractVersion = "contract_version"
        case sourceTreeSHA256 = "source_tree_sha256"
        case packageSwiftSHA256 = "package_swift_sha256"
        case packageResolvedSHA256 = "package_resolved_sha256"
        case swiftVersion = "swift_version"
        case swiftVersionSHA256 = "swift_version_sha256"
        case targetArchitecture = "target_architecture"
        case buildFlags = "build_flags"
        case executableSHA256 = "executable_sha256"
        case metallibSHA256 = "metallib_sha256"
    }
}

private func productionMossHelperFingerprint(
    _ selected: SelectedASRBackend
) throws -> ASRHelperFingerprint? {
    guard selected == .moss else { return nil }
    try verifyDevelopmentMossHarnessSourceIfAvailable()
    let releaseDirectory = ASRRuntime.local.cacheRoot.appendingPathComponent(
        "swift-scratch/moss-harness/arm64-apple-macosx/release",
        isDirectory: true
    )
    let executable = releaseDirectory.appendingPathComponent(
        "MaccheroniMossHarness"
    )
    let metallib = releaseDirectory.appendingPathComponent("mlx.metallib")
    let sidecarURL = releaseDirectory.appendingPathComponent(
        "MaccheroniMossHarness.fingerprint.json"
    )
    let data: Data
    let sidecar: MossHelperFingerprintSidecar
    do {
        data = try Data(contentsOf: sidecarURL)
        sidecar = try JSONDecoder().decode(
            MossHelperFingerprintSidecar.self,
            from: data
        )
    } catch {
        throw CLIError.run(
            "MOSS release helper fingerprint is unreadable: \(sidecarURL.path)"
        )
    }
    let expectedFlags = [
        "--configuration", "release", "--arch", "arm64",
        "--product", "MaccheroniMossHarness",
    ]
    let hashes = [
        sidecar.sourceTreeSHA256,
        sidecar.packageSwiftSHA256,
        sidecar.packageResolvedSHA256,
        sidecar.swiftVersionSHA256,
        sidecar.executableSHA256,
        sidecar.metallibSHA256,
    ]
    guard sidecar.contractVersion == "moss-harness-v2",
          sidecar.targetArchitecture == "arm64",
          sidecar.configuration == "release",
          sidecar.buildFlags == expectedFlags,
          hashes.allSatisfy(isSHA256),
          sha256(data: Data(sidecar.swiftVersion.utf8))
            == sidecar.swiftVersionSHA256,
          FileManager.default.isExecutableFile(atPath: executable.path),
          try AudioPreprocessor.sha256(of: executable)
            == sidecar.executableSHA256,
          try AudioPreprocessor.sha256(of: metallib)
            == sidecar.metallibSHA256
    else {
        throw CLIError.run(
            "MOSS release helper fingerprint does not match its executable"
        )
    }
    return ASRHelperFingerprint(
        path: sidecarURL.path,
        sha256: sha256(data: data),
        contractVersion: sidecar.contractVersion,
        sourceTreeSHA256: sidecar.sourceTreeSHA256,
        packageSwiftSHA256: sidecar.packageSwiftSHA256,
        packageResolvedSHA256: sidecar.packageResolvedSHA256,
        swiftVersion: sidecar.swiftVersion,
        swiftVersionSHA256: sidecar.swiftVersionSHA256,
        targetArchitecture: sidecar.targetArchitecture,
        configuration: sidecar.configuration,
        buildFlags: sidecar.buildFlags,
        executableSHA256: sidecar.executableSHA256,
        metallibSHA256: sidecar.metallibSHA256
    )
}

private func verifyDevelopmentMossHarnessSourceIfAvailable() throws {
    let sourceFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = sourceFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = repositoryRoot.appendingPathComponent(
        "Scripts/build-moss-harness.zsh"
    )
    guard FileManager.default.fileExists(atPath: script.path) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, "--verify"]
    let standardError = Pipe()
    process.standardOutput = Pipe()
    process.standardError = standardError
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        throw CLIError.run(
            "cannot verify the MOSS helper source fingerprint"
        )
    }
    guard process.terminationStatus == 0 else {
        let message = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "fingerprint mismatch"
        throw CLIError.run(
            "MOSS helper source fingerprint is stale: \(message)"
        )
    }
}

private func sha256(data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func isSHA256(_ value: String) -> Bool {
    value.count == 64 && value.unicodeScalars.allSatisfy {
        (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
    }
}

private func productionPostprocess(
    _ backend: PostprocessBackendID,
    _ request: PostprocessRequest
) async throws -> PostprocessResult {
    switch backend {
    case .codex:
        return try await TranscriptPostprocessor(
            backend: CodexPostprocessBackend()
        ).process(request)
    case .local:
        return try await TranscriptPostprocessor(
            backend: LocalPostprocessBackend()
        ).process(request)
    }
}

func productionCommunity1Configuration(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> Community1DiarizerConfiguration {
    let cacheRoot = ASRRuntime.resolveCacheRoot(
        environment: environment,
        home: home
    )
    return Community1DiarizerConfiguration(
        executableURL: cacheRoot.appendingPathComponent(
            "tools/offline-speech-runtime/bin/maccheroni-offline-speech-runtime"
        ),
        hfHomeURL: cacheRoot.appendingPathComponent(
            "models/huggingface",
            isDirectory: true
        ),
        harnessModelRepositoryURL: cacheRoot.appendingPathComponent(
            "qwen3-speech/models/aufklarer/Pyannote-Community-1-CoreML",
            isDirectory: true
        ),
        environment: [
            "HF_HUB_OFFLINE": "1",
            "QWEN3_CACHE_DIR": cacheRoot.path,
        ]
    )
}

func productionVADAdapter(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
) -> SpeechSileroVADAdapter {
    let cacheRoot = ASRRuntime.resolveCacheRoot(
        environment: environment,
        home: home
    )
    return SpeechSileroVADAdapter(
        executableURL: cacheRoot.appendingPathComponent(
            "tools/offline-speech-runtime/bin/maccheroni-offline-speech-runtime"
        ),
        modelCacheURL: cacheRoot.appendingPathComponent(
            "qwen3-speech/models/aufklarer/Silero-VAD-v6.2.1-CoreML/silero_vad.mlmodelc"
        ),
        revisionMarkerURL: cacheRoot.appendingPathComponent(
            "models/huggingface/hub/models--aufklarer--Silero-VAD-v6.2.1-CoreML/refs/main"
        ),
        harnessModelRepositoryURL: cacheRoot.appendingPathComponent(
            "qwen3-speech/models/aufklarer/Silero-VAD-v6.2.1-CoreML",
            isDirectory: true
        )
    )
}

struct RuntimePayloadFile: Sendable {
    var relativePath: String
    var sha256: String
}

struct RuntimePayloadEvidence: Sendable {
    var files: [(relativePath: String, isPinned: Bool)]
    var treeSHA256: String?
    var treeIsPinned: Bool
}

struct OfflineSpeechRuntimePin: Sendable {
    var speechRevision: String
    var packageManifestSHA256: String
    var packageResolvedSHA256: String
    var harnessSourceSHA256: String
    var executableSHA256: String?
    var swiftVersionMarker: String
}

struct OfflineSpeechRuntimeEvidence: Sendable {
    var executableIsUsable: Bool
    var executableMatchesSidecar: Bool
    var sidecarIsPinned: Bool

    var isPinned: Bool {
        executableIsUsable && executableMatchesSidecar && sidecarIsPinned
    }
}

private struct OfflineSpeechRuntimeProvenance: Decodable {
    var contractVersion: String
    var speechRevision: String
    var packageManifestSHA256: String
    var packageResolvedSHA256: String
    var harnessSourceSHA256: String
    var executableSHA256: String
    var swiftVersion: String

    enum CodingKeys: String, CodingKey {
        case contractVersion = "contract_version"
        case speechRevision = "speech_revision"
        case packageManifestSHA256 = "package_manifest_sha256"
        case packageResolvedSHA256 = "package_resolved_sha256"
        case harnessSourceSHA256 = "harness_source_sha256"
        case executableSHA256 = "executable_sha256"
        case swiftVersion = "swift_version"
    }
}

func offlineSpeechRuntimeEvidence(
    cacheRoot: URL,
    expected: OfflineSpeechRuntimePin
) -> OfflineSpeechRuntimeEvidence {
    let toolRoot = cacheRoot.appendingPathComponent(
        "tools/offline-speech-runtime",
        isDirectory: true
    )
    let executable = toolRoot.appendingPathComponent(
        "bin/maccheroni-offline-speech-runtime"
    )
    let sidecar = toolRoot.appendingPathComponent("provenance.json")
    let executableValues = try? executable.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    let executableSHA256 = try? AudioPreprocessor.sha256(of: executable)
    let executableIsUsable = FileManager.default.isExecutableFile(
        atPath: executable.path
    ) && executableValues?.isRegularFile == true
        && executableValues?.isSymbolicLink != true
        && (expected.executableSHA256 == nil
            || executableSHA256 == expected.executableSHA256)
    guard let sidecarValues = try? sidecar.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ), sidecarValues.isRegularFile == true,
        sidecarValues.isSymbolicLink != true,
        let data = try? Data(contentsOf: sidecar),
        let provenance = try? JSONDecoder().decode(
            OfflineSpeechRuntimeProvenance.self,
            from: data
        ) else {
        return OfflineSpeechRuntimeEvidence(
            executableIsUsable: executableIsUsable,
            executableMatchesSidecar: false,
            sidecarIsPinned: false
        )
    }
    let executableMatchesSidecar = provenance.executableSHA256
        == executableSHA256
    let sidecarIsPinned = provenance.contractVersion
        == "offline-speech-runtime-v1"
        && provenance.speechRevision == expected.speechRevision
        && provenance.packageManifestSHA256
            == expected.packageManifestSHA256
        && provenance.packageResolvedSHA256
            == expected.packageResolvedSHA256
        && provenance.harnessSourceSHA256
            == expected.harnessSourceSHA256
        && (expected.executableSHA256 == nil
            || provenance.executableSHA256 == expected.executableSHA256)
        && !provenance.swiftVersion.isEmpty
        && provenance.swiftVersion.contains(expected.swiftVersionMarker)
    return OfflineSpeechRuntimeEvidence(
        executableIsUsable: executableIsUsable,
        executableMatchesSidecar: executableMatchesSidecar,
        sidecarIsPinned: sidecarIsPinned
    )
}

private let sileroRuntimePayload = [
    RuntimePayloadFile(
        relativePath: "config.json",
        sha256: "459e764d58cdc13f3db6878adfdf8a29b5fd467ad1f4ef2161137cc115339c81"
    ),
    RuntimePayloadFile(
        relativePath: "silero_vad.mlmodelc/analytics/coremldata.bin",
        sha256: "b777c3751d72b7430eac7f8544769a3d918faf77c15db184fec30e44c56007a3"
    ),
    RuntimePayloadFile(
        relativePath: "silero_vad.mlmodelc/coremldata.bin",
        sha256: "f6fcd92c3132c9c718e5f54e0e770a8c8075beaa50a5b212a6287273b4ddae67"
    ),
    RuntimePayloadFile(
        relativePath: "silero_vad.mlmodelc/metadata.json",
        sha256: "1b953eb3818e7092deedd96e976c05354f77beb2ddc2976fe416af17e47f62d2"
    ),
    RuntimePayloadFile(
        relativePath: "silero_vad.mlmodelc/model.mil",
        sha256: "b0a1384c4a664697989d9eb9cfb166b4b85f151206aeefd1bfa391ef9e5ad08f"
    ),
    RuntimePayloadFile(
        relativePath: "silero_vad.mlmodelc/weights/weight.bin",
        sha256: "83210545de90c65195e8d6db1b349b7e5c31f989f48d0a908a8dc0e2f586e5f9"
    ),
]

private let community1RuntimePayload = [
    RuntimePayloadFile(
        relativePath: "config.json",
        sha256: "6bf96d3f361ad1b5bcfbcf2bdf70a2072d211fefd875700231e1f3b2fb69e713"
    ),
    RuntimePayloadFile(
        relativePath: "embedding.mlmodelc/analytics/coremldata.bin",
        sha256: "f4b5ad2e2ea815e334acaf162fa42e999ecd9881ecac4166ff43d6bc1d9322d6"
    ),
    RuntimePayloadFile(
        relativePath: "embedding.mlmodelc/coremldata.bin",
        sha256: "3ad7a2f309143107fc5394f34592ce80482bf6dbe6831e0588cff44cbaa609e5"
    ),
    RuntimePayloadFile(
        relativePath: "embedding.mlmodelc/model.mil",
        sha256: "66d248aad00b3e103151097a9bbba558402933c0cf31c010f66b086ac94d7aaf"
    ),
    RuntimePayloadFile(
        relativePath: "embedding.mlmodelc/weights/weight.bin",
        sha256: "1019c1bb4472abfe705da19db3b5d0764adcb2d59dabf766fef74f0963f810f2"
    ),
    RuntimePayloadFile(
        relativePath: "plda.safetensors",
        sha256: "aff6294b68b66adcbc1c2a402b1379ecfdd98d8d759dc2cca62b5380babea359"
    ),
    RuntimePayloadFile(
        relativePath: "segmentation.mlmodelc/analytics/coremldata.bin",
        sha256: "44d83274cec5ccfe4a959eca359a89e4fd757b1872962449f2206784fb2031e5"
    ),
    RuntimePayloadFile(
        relativePath: "segmentation.mlmodelc/coremldata.bin",
        sha256: "5385e1af87712e3027ac96915d3b85de9450681e73ef355dfadd4b274cc9ba58"
    ),
    RuntimePayloadFile(
        relativePath: "segmentation.mlmodelc/model.mil",
        sha256: "8c0956cbbce7bac956cb85176fde28353a0d4a1e623f5621b6277b3d256ad0e8"
    ),
    RuntimePayloadFile(
        relativePath: "segmentation.mlmodelc/weights/weight.bin",
        sha256: "d2c1c75adec19e64ea732808839b6b8da2968a8a26b8aa3e170ef283df44a6ca"
    ),
]

private let pinnedOfflineSpeechRuntime = OfflineSpeechRuntimePin(
    speechRevision: "c1aa219bc2284239ff6917d675a3e1978c840260",
    packageManifestSHA256:
        "5059f0c80bcec9cfc88bc56db8bc48504860ed556930f0225c817feb6607e5fd",
    packageResolvedSHA256:
        "e81c1d4f14185323abc782967b18a2342e36358b696b57be25a702718ab2330c",
    harnessSourceSHA256:
        "ba28b93e69c3b0ee6da9b19b328642a797355220f60a82eb87115496b6b8ff79",
    executableSHA256: nil,
    swiftVersionMarker: "Apple Swift version 6."
)

func runtimePayloadEvidence(
    at root: URL,
    expectedFiles: [RuntimePayloadFile],
    expectedTreeSHA256: String
) -> RuntimePayloadEvidence {
    do {
        var checks: [(relativePath: String, isPinned: Bool)] = []
        var hasher = SHA256()
        for expected in expectedFiles {
            let file = root.appendingPathComponent(expected.relativePath)
            guard let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true,
                values.isSymbolicLink != true,
                let actualSHA256 = try? AudioPreprocessor.sha256(of: file),
                actualSHA256 == expected.sha256 else {
                checks.append((expected.relativePath, false))
                continue
            }
            checks.append((expected.relativePath, true))
            let name = Data(expected.relativePath.utf8)
            var nameLength = UInt32(name.count).bigEndian
            withUnsafeBytes(of: &nameLength) {
                hasher.update(data: Data($0))
            }
            hasher.update(data: name)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
        }
        let allFilesPinned = checks.count == expectedFiles.count
            && checks.allSatisfy { $0.isPinned }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }
            .joined()
        return RuntimePayloadEvidence(
            files: checks,
            treeSHA256: digest,
            treeIsPinned: allFilesPinned && digest == expectedTreeSHA256
        )
    } catch {
        return RuntimePayloadEvidence(
            files: expectedFiles.map { ($0.relativePath, false) },
            treeSHA256: nil,
            treeIsPinned: false
        )
    }
}

private func productionTranslation(
    _ backend: PostprocessBackendID,
    _ request: TranslationRequest
) async throws -> TranslationResult {
    switch backend {
    case .codex:
        return try await TranscriptTranslator(
            backend: CodexPostprocessBackend()
        ).translate(request)
    case .local:
        return try await TranscriptTranslator(
            backend: LocalPostprocessBackend()
        ).translate(request)
    }
}

private func productionSpeakerProposal(
    _ backend: PostprocessBackendID,
    _ request: SpeakerProposalRequest
) async throws -> SpeakerProposalResult {
    switch backend {
    case .codex:
        return try await SpeakerProposer(
            backend: CodexPostprocessBackend()
        ).propose(request)
    case .local:
        return try await SpeakerProposer(
            backend: LocalPostprocessBackend()
        ).propose(request)
    }
}

private func productionPostprocessDoctorChecks(
    _ backend: PostprocessBackendID
) async -> [String] {
    switch backend {
    case .codex:
        let availability = await CodexPostprocessBackend.detectAvailability()
        return [
            "postprocess_backend=codex-app-server@\(availability.version)",
            "postprocess_model=\(CodexPostprocessBackend.modelName)",
            "postprocess_input_mode=text-only",
            "check.postprocess_installed=\(availability.isInstalled)",
            "check.postprocess_authentication_known=\(!availability.authenticationCheckFailed)",
            "check.postprocess_authenticated=\(availability.isAuthenticated)",
            "check.postprocess=\(availability.isAuthenticated)",
        ]
    case .local:
        let runtime = LocalPostprocessRuntime.local
        let requiredModelFiles = [
            "config.json",
            "model.safetensors.index.json",
            "model-00001-of-00003.safetensors",
            "model-00002-of-00003.safetensors",
            "model-00003-of-00003.safetensors",
            "tokenizer.json",
        ]
        let pythonReady = FileManager.default.isExecutableFile(
            atPath: runtime.pythonExecutableURL.path
        )
        let runnerReady = FileManager.default.isReadableFile(
            atPath: runtime.runnerURL.path
        )
        let modelReady = requiredModelFiles.allSatisfy {
            FileManager.default.isReadableFile(
                atPath: runtime.modelSnapshotURL.appendingPathComponent($0).path
            )
        }
        return [
            "postprocess_backend=\(LocalPostprocessBackend.descriptor.name)@\(LocalPostprocessBackend.descriptor.version)",
            modelLine(
                name: "postprocess_model",
                model: LocalPostprocessBackend.pinnedModel
            ),
            "postprocess_input_mode=text-only",
            "postprocess_python=\(runtime.pythonExecutableURL.path)",
            "postprocess_runner=\(runtime.runnerURL.path)",
            "postprocess_snapshot=\(runtime.modelSnapshotURL.path)",
            "check.postprocess_python=\(pythonReady)",
            "check.postprocess_runner=\(runnerReady)",
            "check.postprocess_model_cache=\(modelReady)",
            "check.postprocess=\(pythonReady && runnerReady && modelReady)",
        ]
    }
}

private func productionDoctorChecks(
    _ selected: SelectedASRBackend,
    _ profile: CLIProfile
) async -> [String] {
    let environment = ProcessInfo.processInfo.environment
    let benchmarkCacheRoot = ASRRuntime.resolveCacheRoot(
        environment: environment
    )
    let asrRuntime = ASRRuntime.local
    let afconvertIsExecutable = FileManager.default.isExecutableFile(
        atPath: "/usr/bin/afconvert"
    )
    let asrRunnerExists = FileManager.default.fileExists(
        atPath: asrRuntime.runnerURL.path
    )
    let asrLockExists = FileManager.default.fileExists(
        atPath: asrRuntime.runnerURL.deletingLastPathComponent()
            .appendingPathComponent("uv.lock").path
    )
    var lines = [
        "check.afconvert_executable=\(afconvertIsExecutable)",
        "check.asr_runner=\(asrRunnerExists)",
        "check.asr_lock=\(asrLockExists)",
    ]
    let vad = productionVADAdapter(environment: environment)
    do {
        let report = try await ASRDoctor.diagnose(selected, runtime: asrRuntime)
        lines.append("check.asr_doctor=\(report.ok)")
        lines.append("check.asr_model=\(report.model == selected.model)")
        let pythonIsPinned = report.python.hasPrefix("3.12.")
        lines.append("check.asr_python_3_12=\(pythonIsPinned)")
        for check in report.checks {
            let name = check.name.replacingOccurrences(
                of: "[^A-Za-z0-9_.-]",
                with: "_",
                options: .regularExpression
            )
            lines.append("check.asr.\(name)=\(check.ok)")
        }
    } catch {
        lines.append("check.asr_doctor=false")
        lines.append("asr_error=\(singleLine(failureMessage(for: error)))")
    }
    if selected == .moss {
        do {
            let fingerprint = try productionMossHelperFingerprint(.moss)
            lines.append(
                "moss_helper_contract=\(fingerprint?.contractVersion ?? "missing")"
            )
            lines.append("check.moss_release_helper=\(fingerprint != nil)")
        } catch {
            lines.append("check.moss_release_helper=false")
            lines.append(
                "moss_helper_error=\(singleLine(failureMessage(for: error)))"
            )
        }
    }

    lines.append(
        "check.vad_executable=\(FileManager.default.isExecutableFile(atPath: vad.executableURL.path))"
    )
    let runtime = offlineSpeechRuntimeEvidence(
        cacheRoot: benchmarkCacheRoot,
        expected: pinnedOfflineSpeechRuntime
    )
    lines.append(
        "offline_speech_runtime=soniqo/speech-swift@\(pinnedOfflineSpeechRuntime.speechRevision)"
    )
    lines.append(
        "check.offline_speech_runtime_executable=\(runtime.executableIsUsable)"
    )
    lines.append(
        "check.offline_speech_runtime_fingerprint=\(runtime.executableMatchesSidecar)"
    )
    lines.append(
        "check.offline_speech_runtime_sidecar=\(runtime.sidecarIsPinned)"
    )
    lines.append("check.offline_speech_runtime=\(runtime.isPinned)")
    let vadRepository = benchmarkCacheRoot.appendingPathComponent(
        "qwen3-speech/models/aufklarer/Silero-VAD-v6.2.1-CoreML",
        isDirectory: true
    )
    let vadPayload = runtimePayloadEvidence(
        at: vadRepository,
        expectedFiles: sileroRuntimePayload,
        expectedTreeSHA256:
            "edd772745342372800516b0da27556cf4aae1db386784620b2590183d94da346"
    )
    lines += runtimePayloadCheckLines(prefix: "vad", evidence: vadPayload)
    lines.append("check.vad_model_cache=\(vadPayload.treeIsPinned)")
    let vadSnapshot = benchmarkCacheRoot.appendingPathComponent(
        "models/huggingface/hub/models--aufklarer--Silero-VAD-v6.2.1-CoreML/snapshots/\(vad.provenance.model.revision)",
        isDirectory: true
    )
    lines.append(
        "check.vad_snapshot=\(FileManager.default.fileExists(atPath: vadSnapshot.path))"
    )
    lines.append(
        "check.vad_ref=\(exactRevisionReference(at: vad.revisionMarkerURL, expected: vad.provenance.model.revision))"
    )

    guard profile.diarization.enabled else {
        lines.append("check.diarization_disabled=true")
        return lines
    }
    switch profile.diarization.backend {
    case "community1":
        let configuration = productionCommunity1Configuration(
            environment: environment
        )
        let repository = configuration.hfHomeURL.appendingPathComponent(
            "hub/models--aufklarer--Pyannote-Community-1-CoreML",
            isDirectory: true
        )
        let snapshot = repository
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(
                Community1Diarizer.modelRevision,
                isDirectory: true
            )
        let referenceIsPinned = exactRevisionReference(
            at: repository.appendingPathComponent("refs/main"),
            expected: Community1Diarizer.modelRevision
        )
        lines.append(
            "check.diarization_executable=\(FileManager.default.isExecutableFile(atPath: configuration.executableURL.path))"
        )
        lines.append(
            "check.diarization_snapshot=\(FileManager.default.fileExists(atPath: snapshot.path))"
        )
        lines.append(
            "check.diarization_revision=\(referenceIsPinned)"
        )
        let runtimeRepository = benchmarkCacheRoot.appendingPathComponent(
            "qwen3-speech/models/aufklarer/Pyannote-Community-1-CoreML",
            isDirectory: true
        )
        let payload = runtimePayloadEvidence(
            at: runtimeRepository,
            expectedFiles: community1RuntimePayload,
            expectedTreeSHA256:
                "74247105450a08414a71ef5d512a52b706a7c23ac61efdcef051f4e44fae237a"
        )
        lines += runtimePayloadCheckLines(
            prefix: "diarization",
            evidence: payload
        )
        lines.append(
            "check.diarization_model_cache=\(payload.treeIsPinned)"
        )
    case "fluid":
        let configuration = FluidAudioDiarizerConfiguration()
        lines.append(
            "check.diarization_executable=\(FileManager.default.isExecutableFile(atPath: configuration.executableURL.path))"
        )
        lines.append(
            "check.diarization_model_cache=\(fluidModelTreeIsPinned(at: configuration.modelsRootURL))"
        )
    default:
        lines.append("check.diarization_backend=false")
    }
    return lines
}

private func exactRevisionReference(at url: URL, expected: String) -> Bool {
    guard expected.utf8.count == 40,
          let data = try? Data(contentsOf: url) else {
        return false
    }
    return data == Data(expected.utf8)
}

private func runtimePayloadCheckLines(
    prefix: String,
    evidence: RuntimePayloadEvidence
) -> [String] {
    let files = evidence.files.map { file in
        let name = file.relativePath.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
        return "check.\(prefix)_runtime_file.\(name)=\(file.isPinned)"
    }
    return files + [
        "check.\(prefix)_runtime_tree=\(evidence.treeIsPinned)",
    ]
}

private func fluidModelTreeIsPinned(at modelsRootURL: URL) -> Bool {
    let root = modelsRootURL.appendingPathComponent(
        "speaker-diarization",
        isDirectory: true
    )
    let requiredNames = [
        "Segmentation.mlmodelc",
        "FBank.mlmodelc",
        "Embedding.mlmodelc",
        "PldaRho.mlmodelc",
        "plda-parameters.json",
    ]
    do {
        var files: [URL] = []
        for name in requiredNames {
            let entry = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: entry.path,
                isDirectory: &isDirectory
            ) else { return false }
            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: entry,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { return false }
                for case let file as URL in enumerator {
                    if try file.resourceValues(
                        forKeys: [.isRegularFileKey]
                    ).isRegularFile == true {
                        files.append(file)
                    }
                }
            } else {
                files.append(entry)
            }
        }
        files.sort {
            $0.path.replacingOccurrences(of: root.path + "/", with: "")
                < $1.path.replacingOccurrences(of: root.path + "/", with: "")
        }
        guard files.count == 21 else { return false }
        var hasher = SHA256()
        for file in files {
            let relative = file.path.replacingOccurrences(
                of: root.path + "/",
                with: ""
            )
            let nameData = Data(relative.utf8)
            var length = UInt32(nameData.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: nameData)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while true {
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }
            .joined()
        return digest == "4ed93bd29ff9d4a3b25fe2e7ad01d8cfc31f1b2acad2165dccb0d2f6a7f189b5"
    } catch {
        return false
    }
}

private func singleLine(_ value: String) -> String {
    value.replacingOccurrences(of: "\n", with: " ")
}

private func extractChunk(
    from input: URL,
    startSample: Int64,
    endSample: Int64,
    outputURL: URL
) throws -> URL {
    let file = try AVAudioFile(forReading: input)
    let format = file.processingFormat
    let rate = format.sampleRate
    guard abs(rate - 16_000) < 0.5,
          format.channelCount == 1,
          startSample >= 0,
          endSample > startSample,
          endSample <= file.length
    else {
        throw CLIError.run("invalid 16 kHz mono sample range")
    }
    let start = AVAudioFramePosition(startSample)
    let end = AVAudioFramePosition(endSample)
    let frameCount = end - start
    guard frameCount > 0,
          end <= file.length,
          frameCount <= AVAudioFramePosition(UInt32.max)
    else {
        throw CLIError.run("chunk range is outside the preprocessed audio")
    }
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw CLIError.run("refusing to overwrite chunk audio")
    }
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let temporary = outputURL.deletingLastPathComponent().appendingPathComponent(
        ".\(UUID().uuidString).wav"
    )
    defer { try? FileManager.default.removeItem(at: temporary) }
    file.framePosition = start
    do {
        guard let pcm16 = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: rate,
            channels: 1,
            interleaved: true
        ) else {
            throw CLIError.run("cannot create the PCM16 chunk format")
        }
        let output = try AVAudioFile(
            forWriting: temporary,
            settings: pcm16.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var remaining = AVAudioFrameCount(frameCount)
        while remaining > 0 {
            let requested = min(remaining, 32_768)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: requested
            ) else {
                throw CLIError.run("cannot allocate a chunk audio buffer")
            }
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else {
                throw CLIError.run("chunk extraction reached EOF")
            }
            try output.write(from: buffer)
            remaining -= buffer.frameLength
        }
    }
    guard Darwin.rename(temporary.path, outputURL.path) == 0 else {
        throw CLIError.run("atomic chunk write failed")
    }
    let verification = try AVAudioFile(forReading: outputURL)
    let writtenDuration = Double(verification.length)
        / verification.processingFormat.sampleRate
    guard verification.processingFormat.channelCount == 1,
          abs(verification.processingFormat.sampleRate - 16_000) < 0.5,
          verification.fileFormat.commonFormat == .pcmFormatInt16,
          verification.length == frameCount,
          abs(
              writtenDuration
                - Double(endSample - startSample) / 16_000
          ) <= 0.000_001
    else {
        throw CLIError.run("physical chunk samples do not match their range")
    }
    return outputURL
}
