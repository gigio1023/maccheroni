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

private let cliResourcesBundle = PackagedResourceBundle.resolve(
    named: "Maccheroni_MaccheroniCLI"
) { Bundle.module }

public enum CLIError: Error, LocalizedError, Sendable {
    case usage(String)
    case profile(String)
    case postprocess(String)
    case glossary(String)
    case mossLimitExhausted(String)
    case run(String)

    public var code: String {
        switch self {
        case .usage: "USAGE_ERROR"
        case .profile: "PROFILE_ERROR"
        case .postprocess: "POSTPROCESS_ERROR"
        case .glossary: "GLOSSARY_ERROR"
        case .mossLimitExhausted: "MOSS_LIMIT_EXHAUSTED"
        case .run: "RUN_ERROR"
        }
    }

    public var errorDescription: String? {
        switch self {
        case let .usage(message), let .profile(message), let .postprocess(message),
             let .glossary(message), let .mossLimitExhausted(message),
             let .run(message): message
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
        case .vibeVoice, .qwen3:
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

    public init(
        stopReason: ASRAttemptStopReason,
        evidence: CLIASRAttemptEvidence
    ) {
        self.stopReason = stopReason
        self.evidence = evidence
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
    case invalidEOSOutput = "invalid_eos_output"
    case asrTimeout = "asr_timeout"
    case asrMalformedOutput = "asr_malformed_output"
    case asrCoverageShortfall = "asr_coverage_shortfall"
    case asrModelIdentityMismatch = "asr_model_identity_mismatch"
    case backendFailed = "backend_failed"
    case canceled
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
}

private struct ASRRootIndexRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var rootChunkIndex: Int
    var rootAttemptID: String
    var eosLeafAttemptIDs: [String]
    var eosLeafResultSHA256: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rootChunkIndex = "root_chunk_index"
        case rootAttemptID = "root_attempt_id"
        case eosLeafAttemptIDs = "eos_leaf_attempt_ids"
        case eosLeafResultSHA256 = "eos_leaf_result_sha256"
    }
}

private struct CanonicalPromotionRecord: Codable, Sendable {
    var schemaVersion = "1.0.0"
    var inputSHA256Before: String
    var inputSHA256AtPromotion: String
    var eosLeafAttemptIDs: [String]
    var eosLeafResultSHA256: [String]
    var canonicalArtifactSHA256: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case inputSHA256Before = "input_sha256_before"
        case inputSHA256AtPromotion = "input_sha256_at_promotion"
        case eosLeafAttemptIDs = "eos_leaf_attempt_ids"
        case eosLeafResultSHA256 = "eos_leaf_result_sha256"
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
        vad: { try await SpeechSileroVADAdapter().detect(audioURL: $0) },
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
                return try await Community1Diarizer().diarizeWithEvidence(request)
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
                    )
                ))
            }
        },
        postprocess: productionPostprocess,
        translate: productionTranslation,
        postprocessDoctor: productionPostprocessDoctorChecks,
        doctor: productionDoctorChecks
    )
}

struct CLIDoctorReport: Equatable, Sendable {
    var diagnostics: String
    var isReady: Bool
}

public struct CLIApplication: Sendable {
    public var dependencies: CLIDependencies
    public var now: @Sendable () -> Date
    public var runID: @Sendable (Date) -> String
    public init(
        dependencies: CLIDependencies = .production,
        now: @escaping @Sendable () -> Date = Date.init,
        runID: @escaping @Sendable (Date) -> String = CLIApplication.defaultRunID
    ) {
        self.dependencies = dependencies; self.now = now; self.runID = runID
    }

    public static func defaultRunID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "\(formatter.string(from: date))-\(suffix)"
    }

    public func execute(arguments: [String]) async throws -> String {
        let command = try CLICommand.parse(arguments)
        switch command {
        case let .run(audio, profile, profiles, outputRoot, glossary):
            return try await run(audio: audio, profileName: profile, profilesURL: profiles, outputRoot: outputRoot, glossaryURL: glossary)
        case let .doctor(profile, profiles):
            return try await doctor(profileName: profile, profilesURL: profiles)
        }
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

    private func run(
        audio: URL,
        profileName: String,
        profilesURL: URL?,
        outputRoot: URL?,
        glossaryURL: URL?
    ) async throws -> String {
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
        let glossary = try resolvedGlossary(
            cliURL: glossaryURL,
            profile: profile,
            profileDirectory: resolution.directory
        )
        let inputHash = try dependencies.inputSHA256(audio)
        let values = try audio.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = values.fileSize ?? 0
        let inputFile = try AVAudioFile(forReading: audio)
        let duration = Double(inputFile.length) / inputFile.processingFormat.sampleRate
        guard duration > 0 else { throw CLIError.run("input duration is zero") }

        let root = outputRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Maccheroni/Runs", isDirectory: true)
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
            if chunks.isEmpty {
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
            let completed = chunks.contains { $0.status == .succeeded }
            try writer.write(
                manifest(
                    status: completed ? .partial : .failed,
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
            let nodesPerRoot = selected == .moss
                ? (1 << (policy.maximumRecoveryDepth + 1)) - 1
                : 1
            let maximumAttemptCount = plannedLeaves.count * nodesPerRoot
            let retainedLayers = Int64(
                selected == .moss
                    ? policy.maximumRecoveryDepth + 2
                    : 2
            )
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
                let execution = try await dependencies.diarize(
                    profile.diarization.backend,
                    DiarizationRequest(audioURL: preprocessed.artifactURL)
                )
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
                let completedLeaves = try await processASRLeaf(
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
                let orderedLeaves = completedLeaves.sorted {
                    $0.leaf.startSample < $1.leaf.startSample
                }
                try validate(
                    completedLeaves: orderedLeaves,
                    covering: rootLeaf
                )
                try writer.write(
                    ASRRootIndexRecord(
                        rootChunkIndex: rootIndex,
                        rootAttemptID: rootAttemptID,
                        eosLeafAttemptIDs: orderedLeaves.map(\.attemptID),
                        eosLeafResultSHA256: orderedLeaves.map(\.resultSHA256)
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
                processedDuration += chunk.endS - chunk.startS
                currentChunkIndex = nil
                try writeIncompleteManifest("ASR chunk \(chunk.index) completed")
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
                    eosLeafAttemptIDs: allEOSLeaves.map(\.attemptID),
                    eosLeafResultSHA256: allEOSLeaves.map(\.resultSHA256),
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

            processedDuration = duration
            fullTranscriptReady = true
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
            try writer.write(
                manifest(
                    status: .succeeded,
                    failure: nil,
                    truncated: false,
                    message: nil,
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
            } else {
                processedDuration = chunks
                    .filter { $0.status == .succeeded }
                    .reduce(0) { $0 + ($1.endS - $1.startS) }
            }
            var code = failureCode(for: error)
            var message = failureMessage(for: error)
            if (try? dependencies.inputSHA256(audio)) != inputHash {
                code = "INPUT_MUTATED"
                message = "original input hash changed during the run"
            }
            let status: RunStatus = code == "INPUT_MUTATED"
                ? .failed
                : (chunks.contains { $0.status == .succeeded } ? .partial : .failed)
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
            if code == "MOSS_LIMIT_EXHAUSTED" {
                throw CLIError.mossLimitExhausted(
                    "\(message) [run: \(writer.directory.path)]"
                )
            }
            throw CLIError.run("\(message) [run: \(writer.directory.path)]")
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
    ) async throws -> [CompletedASRLeaf] {
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
    ) async throws -> [CompletedASRLeaf] {
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
            return [CompletedASRLeaf(
                attemptID: attemptID,
                leaf: leaf,
                execution: execution,
                resultSHA256: resultSHA256
            )]

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
            guard selected == .moss,
                  limit.stopReason == .maximumTokens
                    || limit.stopReason == .contextLimit
            else {
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
                let message = "MOSS \(limit.stopReason.rawValue) persisted at depth \(leaf.depth) for samples [\(leaf.startSample), \(leaf.endSample))"
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
                        errorMessage: message
                    ),
                    at: "\(base)/outcome.json"
                )
                throw CLIError.mossLimitExhausted(message)
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
                    errorMessage: nil
                ),
                at: "\(base)/outcome.json"
            )
            var completed: [CompletedASRLeaf] = []
            var firstChildError: Error?
            for index in children.indices {
                do {
                    completed += try await processASRLeaf(
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
            return completed
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
            errorCode: errorMessage == nil ? nil : "MOSS_LIMIT_EXHAUSTED",
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
        let freeBytes = ((try? FileManager.default.attributesOfFileSystem(
            forPath: FileManager.default.homeDirectoryForCurrentUser.path
        )[.systemFreeSize]) as? NSNumber)?.int64Value ?? -1
        let postprocessBackend = PostprocessBackendID(rawValue: profile.postprocess)
        var lines = [
            "profile=\(profile.name)",
            "language=\(languageValue(profile.languagePin))",
            "diarization_enabled=\(profile.diarization.enabled)",
            "diarization_backend=\(profile.diarization.backend)",
            "postprocess=\(profile.postprocess)",
            "disk_available_bytes=\(freeBytes)",
            "check.disk=\(freeBytes > 0)",
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
            diagnostics: lines.joined(separator: "\n"),
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

    private func resolvedGlossary(
        cliURL: URL?,
        profile: CLIProfile,
        profileDirectory: URL
    ) throws -> Glossary? {
        let profileURL = profile.glossaryPath.map { path -> URL in
            return (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : profileDirectory.appendingPathComponent(path)
        }
        guard let url = cliURL ?? profileURL else { return nil }
        do {
            let glossary = try Glossary.parse(data: Data(contentsOf: url))
            guard !glossary.entries.isEmpty else {
                throw CLIError.glossary("glossary has no entries: \(url.path)")
            }
            return glossary
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
              metrics.contextHardCapTokens == policy.contextHardCapTokens,
              let attemptTokenPlan,
              metrics.promptTokens == attemptTokenPlan.promptTokens,
              metrics.promptTokens + metrics.generatedTokens
                <= metrics.contextHardCapTokens,
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

    private func validate(
        completedLeaves: [CompletedASRLeaf],
        covering root: InferenceLeaf
    ) throws {
        guard !completedLeaves.isEmpty else {
            throw CLIError.run("ASR root produced no EOS leaves")
        }
        var cursor = root.startSample
        for completed in completedLeaves {
            guard completed.leaf.startSample == cursor,
                  completed.leaf.endSample > completed.leaf.startSample,
                  completed.leaf.endSample <= root.endSample,
                  !completed.resultSHA256.isEmpty
            else {
                throw CLIError.run(
                    "EOS attempt leaves do not exactly cover their root"
                )
            }
            cursor = completed.leaf.endSample
        }
        guard cursor == root.endSample else {
            throw CLIError.run(
                "EOS attempt leaves do not exactly cover their root"
            )
        }
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
                  provenance.backend.version != "unavailable",
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
        guard document.schemaVersion == original.schemaVersion,
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
                  provenance.backend.version != "unavailable",
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

private enum CLICommand {
    case run(URL, String, URL?, URL?, URL?)
    case doctor(String?, URL?)

    static func parse(_ arguments: [String]) throws -> CLICommand {
        guard let command = arguments.first else {
            throw CLIError.usage(
                "usage: maccheroni run <audio> --profile <name> | doctor [--profile <name>]"
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
    }

    func relative(_ url: URL) throws -> String {
        let base = directory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else {
            throw CLIError.run("artifact is outside the run directory")
        }
        return String(path.dropFirst(base.count))
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
        let target = directory.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            throw CLIError.run("run-relative path escaped the run directory")
        }
        return target
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

    let vad = SpeechSileroVADAdapter()
    let vadRevision = try? String(
        contentsOf: vad.revisionMarkerURL,
        encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    lines.append(
        "check.vad_executable=\(FileManager.default.isExecutableFile(atPath: vad.executableURL.path))"
    )
    lines.append(
        "check.vad_model_cache=\(FileManager.default.fileExists(atPath: vad.modelCacheURL.path))"
    )
    lines.append(
        "check.vad_revision=\(vadRevision == vad.provenance.model.revision)"
    )

    guard profile.diarization.enabled else {
        lines.append("check.diarization_disabled=true")
        return lines
    }
    switch profile.diarization.backend {
    case "community1":
        let configuration = Community1DiarizerConfiguration()
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
        let reference = try? String(
            contentsOf: repository.appendingPathComponent("refs/main"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(
            "check.diarization_executable=\(FileManager.default.isExecutableFile(atPath: configuration.executableURL.path))"
        )
        lines.append(
            "check.diarization_model_cache=\(FileManager.default.fileExists(atPath: snapshot.path))"
        )
        lines.append(
            "check.diarization_revision=\(reference == Community1Diarizer.modelRevision)"
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
