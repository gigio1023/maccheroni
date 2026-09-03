import CryptoKit
import Darwin
import Foundation
import MaccheroniCore

private let asrResourcesBundle = PackagedResourceBundle.resolve(
    named: "Maccheroni_MaccheroniASR"
) { Bundle.module }

public enum SelectedASRBackend: String, CaseIterable, Sendable {
    case vibeVoice = "vibevoice"
    case qwen3 = "qwen3"
    case moss

    public var descriptor: BackendDescriptor {
        switch self {
        case .vibeVoice:
            BackendDescriptor(name: "mlx-audio-vibevoice", version: "0.4.6")
        case .qwen3:
            BackendDescriptor(name: "speech-qwen3", version: "0.0.23")
        case .moss:
            BackendDescriptor(name: "speech-swift-moss", version: "37c99dd856cfacfe952b2e48ecdb3c9dedc77625")
        }
    }

    public var model: ModelDescriptor {
        switch self {
        case .vibeVoice:
            ModelDescriptor(
                role: .asr,
                hfModelID: "mlx-community/VibeVoice-ASR-8bit",
                revision: "725c72e54d6ef875472c27fbc50fab470a960940",
                quantization: "int8"
            )
        case .qwen3:
            ModelDescriptor(
                role: .asr,
                hfModelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
                revision: "e5450a26d1fd417c45fc9c405651ddc3180a27a6",
                quantization: "int8"
            )
        case .moss:
            ModelDescriptor(
                role: .asr,
                hfModelID: "aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8",
                revision: "90aa65287111a327db98eb83e325bd5332945edd",
                quantization: "int8-decoder+fp16-audio-vq-kv"
            )
        }
    }

    public var requiredInjectionMode: GlossaryInjectionMode {
        switch self {
        case .vibeVoice, .qwen3: .freeTextContext
        case .moss: .hotwordInstruction
        }
    }

    public static let koreanDefault = SelectedASRBackend.vibeVoice
    public static let koreanFallback: SelectedASRBackend? = nil
    public static let italianDefault = SelectedASRBackend.moss
    public static let italianFallback = SelectedASRBackend.vibeVoice
}

public struct ASRRuntime: Sendable {
    public var pythonExecutable: URL
    public var runnerURL: URL
    public var cacheRoot: URL
    public var outputRoot: URL
    public var timeout: TimeInterval

    public init(
        pythonExecutable: URL,
        runnerURL: URL,
        cacheRoot: URL,
        outputRoot: URL,
        timeout: TimeInterval = 900
    ) {
        self.pythonExecutable = pythonExecutable
        self.runnerURL = runnerURL
        self.cacheRoot = cacheRoot
        self.outputRoot = outputRoot
        self.timeout = timeout
    }

    public static var local: ASRRuntime {
        localRuntime(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    public static func resolveCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let configuredCache = environment["MACCHERONI_BENCHMARK_CACHE"],
           !configuredCache.isEmpty
        {
            return URL(fileURLWithPath: configuredCache, isDirectory: true)
        }
        return home.appendingPathComponent(
            "Library/Caches/Maccheroni/benchmarks",
            isDirectory: true
        )
    }

    static func localRuntime(environment: [String: String], home: URL) -> ASRRuntime {
        let resolvedCacheRoot = resolveCacheRoot(environment: environment, home: home)
        let bundledRunner = asrResourcesBundle.url(
            forResource: "maccheroni_asr_runner",
            withExtension: "py"
        )
        let runnerURL = environment["MACCHERONI_ASR_RUNNER"].map(URL.init(fileURLWithPath:))
            ?? bundledRunner
            ?? resolvedCacheRoot.appendingPathComponent("missing-maccheroni-asr-runner.py")
        let pythonURL = environment["MACCHERONI_ASR_PYTHON"].map(URL.init(fileURLWithPath:))
            ?? resolvedCacheRoot.appendingPathComponent("venvs/mlx-audio/bin/python")
        let outputRoot = environment["MACCHERONI_ASR_OUTPUT_ROOT"].map(URL.init(fileURLWithPath:))
            ?? resolvedCacheRoot.appendingPathComponent("asr-adapter-runs")
        return ASRRuntime(
            pythonExecutable: pythonURL,
            runnerURL: runnerURL,
            cacheRoot: resolvedCacheRoot,
            outputRoot: outputRoot
        )
    }
}

public enum ASRAdapterError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedInjectionMode(expected: GlossaryInjectionMode, actual: GlossaryInjectionMode)
    case invalidRequest(String)
    case runtimeMissing(String)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case backendFailed(code: String, message: String)
    case malformedOutput(String)
    case modelIdentityMismatch
    case coverageShortfall(String)
    case inferenceLimit(ASRAttemptStopReason)
    case invalidEOSOutput(String)
    case evidenceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedInjectionMode(expected, actual):
            "backend requires glossary mode \(expected.rawValue), got \(actual.rawValue)"
        case let .invalidRequest(message), let .runtimeMissing(message), let .launchFailed(message), let .malformedOutput(message), let .coverageShortfall(message):
            message
        case let .timedOut(seconds):
            "ASR subprocess exceeded \(seconds)s"
        case let .backendFailed(code, message):
            "ASR backend \(code): \(message)"
        case .modelIdentityMismatch:
            "ASR backend output did not prove the pinned model identity"
        case let .inferenceLimit(reason):
            "ASR inference stopped at \(reason.rawValue); output is incomplete"
        case let .invalidEOSOutput(message), let .evidenceUnavailable(message):
            message
        }
    }
}

/// A terminal decoder condition reported by a pinned ASR helper.  Limit
/// outcomes deliberately carry no transcript: callers must split and retry
/// the audio range rather than promote partial text.
public enum ASRAttemptStopReason: String, Codable, Equatable, Sendable {
    case endOfSequence
    case maximumTokens
    case contextLimit
    /// The decoder stopped producing new content and repeated one token or
    /// short phrase to the end of generation.  It is a limit outcome like the
    /// other two, but it is not the same event as a transcript that
    /// legitimately reached the output cap with real content, and the
    /// recovered prefix travels with it in `ASRLimitRecord.partialPrefix`.
    case repetitionLooping

    /// The value `repetitionLooping` carried before the 2026-09-02
    /// terminology audit renamed repetition degeneration to repetition
    /// looping.  Attempt artifacts sealed before that rename still hold it.
    static let legacyRepetitionLoopingRawValue = "repetitionDegeneration"

    /// D52: a renamed wire value keeps its legacy value accepted on read.  An
    /// attempt outcome sealed before the rename decodes to the current case,
    /// and judgment rule 3 keeps its bytes untouched: nothing here writes the
    /// legacy value back, because encoding still uses the raw value.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let value = ASRAttemptStopReason(rawValue: raw) {
            self = value
        } else if raw == ASRAttemptStopReason.legacyRepetitionLoopingRawValue {
            self = .repetitionLooping
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "unknown ASR attempt stop reason \"\(raw)\""
                )
            )
        }
    }

    /// Whether this reason closes an attempt without a complete transcript.
    public var isLimitOutcome: Bool { self != .endOfSequence }
}

/// The leading valid transcript a limit outcome still holds.  A collapsed
/// VibeVoice generation leaves the transcript array in the raw payload
/// unclosed, so the backend reports no segments even when most of the leaf
/// decoded correctly.  The prefix is never complete coverage: promoting it is
/// the caller's decision and is recorded as partial.
public struct ASRPartialPrefix: Equatable, Sendable {
    public var coverageS: Double
    public var rawText: String
    public var segments: [Segment]
    public var completeObjectCount: Int
    public var promotedObjectCount: Int
    public var degenerateObjectCount: Int
    public var repetitionRunThreshold: Int
    public var repetitionRunMaximum: Int
    public var tailRepetitionRun: Int
    public var terminalCollapse: Bool

    public init(
        coverageS: Double,
        rawText: String,
        segments: [Segment],
        completeObjectCount: Int,
        promotedObjectCount: Int,
        degenerateObjectCount: Int,
        repetitionRunThreshold: Int,
        repetitionRunMaximum: Int,
        tailRepetitionRun: Int,
        terminalCollapse: Bool
    ) {
        self.coverageS = coverageS
        self.rawText = rawText
        self.segments = segments
        self.completeObjectCount = completeObjectCount
        self.promotedObjectCount = promotedObjectCount
        self.degenerateObjectCount = degenerateObjectCount
        self.repetitionRunThreshold = repetitionRunThreshold
        self.repetitionRunMaximum = repetitionRunMaximum
        self.tailRepetitionRun = tailRepetitionRun
        self.terminalCollapse = terminalCollapse
    }
}

public struct ASRLimitRecord: Equatable, Sendable {
    public var stopReason: ASRAttemptStopReason
    public var partialPrefix: ASRPartialPrefix?
    public var glossary: ManifestGlossary
    public var glossaryPayloadSHA256: String?
    public var glossaryPayloadEntryCount: Int
    public var command: [String]
    public var outputURL: URL
    public var backendRawArtifactURL: URL
    public var backendRawArtifactSHA256: String
    public var inputSHA256: String
    public var metrics: ASRAttemptMetrics
    public var language: ASRLanguageEvidence
    public var helperFingerprint: ASRHelperFingerprint?

    public init(
        stopReason: ASRAttemptStopReason,
        partialPrefix: ASRPartialPrefix? = nil,
        glossary: ManifestGlossary,
        glossaryPayloadSHA256: String?,
        glossaryPayloadEntryCount: Int,
        command: [String],
        outputURL: URL,
        backendRawArtifactURL: URL,
        backendRawArtifactSHA256: String,
        inputSHA256: String,
        metrics: ASRAttemptMetrics,
        language: ASRLanguageEvidence,
        helperFingerprint: ASRHelperFingerprint?
    ) {
        self.stopReason = stopReason
        self.partialPrefix = partialPrefix
        self.glossary = glossary
        self.glossaryPayloadSHA256 = glossaryPayloadSHA256
        self.glossaryPayloadEntryCount = glossaryPayloadEntryCount
        self.command = command
        self.outputURL = outputURL
        self.backendRawArtifactURL = backendRawArtifactURL
        self.backendRawArtifactSHA256 = backendRawArtifactSHA256
        self.inputSHA256 = inputSHA256
        self.metrics = metrics
        self.language = language
        self.helperFingerprint = helperFingerprint
    }
}

public enum ASRAttemptOutcome: Equatable, Sendable {
    case complete(ASRExecutionRecord)
    case limit(ASRLimitRecord)
}

public struct ASRAttemptMetrics: Codable, Equatable, Sendable {
    public var preprocessingS: Double?
    public var audioEncoderS: Double?
    public var decoderPrefillS: Double?
    public var tokenDecodeS: Double?
    public var promptTokens: Int
    public var generatedTokens: Int
    public var maxTokens: Int
    public var contextHardCapTokens: Int?
    public var audioDurationS: Double
    public var totalS: Double
    public var modelLoadS: Double?
    public var runnerWallTimeS: Double
    public var peakRSSBytes: Int64?
    public var unavailable: [String: String]

    public init(
        preprocessingS: Double?,
        audioEncoderS: Double?,
        decoderPrefillS: Double?,
        tokenDecodeS: Double?,
        promptTokens: Int,
        generatedTokens: Int,
        maxTokens: Int,
        contextHardCapTokens: Int?,
        audioDurationS: Double,
        totalS: Double,
        modelLoadS: Double?,
        runnerWallTimeS: Double,
        peakRSSBytes: Int64?,
        unavailable: [String: String] = [:]
    ) {
        self.preprocessingS = preprocessingS
        self.audioEncoderS = audioEncoderS
        self.decoderPrefillS = decoderPrefillS
        self.tokenDecodeS = tokenDecodeS
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.maxTokens = maxTokens
        self.contextHardCapTokens = contextHardCapTokens
        self.audioDurationS = audioDurationS
        self.totalS = totalS
        self.modelLoadS = modelLoadS
        self.runnerWallTimeS = runnerWallTimeS
        self.peakRSSBytes = peakRSSBytes
        self.unavailable = unavailable
    }
}

public struct ASRLanguageEvidence: Codable, Equatable, Sendable {
    public var requested: String
    public var instructionSHA256: String
    public var promptGuidanceApplied: Bool

    public init(requested: String, instructionSHA256: String, promptGuidanceApplied: Bool) {
        self.requested = requested
        self.instructionSHA256 = instructionSHA256
        self.promptGuidanceApplied = promptGuidanceApplied
    }
}

public struct ASRHelperFingerprint: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
    public var contractVersion: String
    public var sourceTreeSHA256: String
    public var packageSwiftSHA256: String
    public var packageResolvedSHA256: String
    public var swiftVersion: String
    public var swiftVersionSHA256: String
    public var targetArchitecture: String
    public var configuration: String
    public var buildFlags: [String]
    public var executableSHA256: String
    public var metallibSHA256: String

    public init(
        path: String,
        sha256: String,
        contractVersion: String,
        sourceTreeSHA256: String,
        packageSwiftSHA256: String,
        packageResolvedSHA256: String,
        swiftVersion: String,
        swiftVersionSHA256: String,
        targetArchitecture: String,
        configuration: String,
        buildFlags: [String],
        executableSHA256: String,
        metallibSHA256: String
    ) {
        self.path = path
        self.sha256 = sha256
        self.contractVersion = contractVersion
        self.sourceTreeSHA256 = sourceTreeSHA256
        self.packageSwiftSHA256 = packageSwiftSHA256
        self.packageResolvedSHA256 = packageResolvedSHA256
        self.swiftVersion = swiftVersion
        self.swiftVersionSHA256 = swiftVersionSHA256
        self.targetArchitecture = targetArchitecture
        self.configuration = configuration
        self.buildFlags = buildFlags
        self.executableSHA256 = executableSHA256
        self.metallibSHA256 = metallibSHA256
    }

    enum CodingKeys: String, CodingKey {
        case path, sha256, configuration
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

public struct MOSSAttemptTokenPlan: Codable, Equatable, Sendable {
    public var audioTokens: Int
    public var audioSpanTokens: Int
    public var promptTokens: Int
    public var maximumTokens: Int
    public var contextUpperBoundTokens: Int
    public var contextHardCapTokens: Int

    public init(
        audioTokens: Int,
        audioSpanTokens: Int,
        promptTokens: Int,
        maximumTokens: Int,
        contextUpperBoundTokens: Int,
        contextHardCapTokens: Int
    ) {
        self.audioTokens = audioTokens
        self.audioSpanTokens = audioSpanTokens
        self.promptTokens = promptTokens
        self.maximumTokens = maximumTokens
        self.contextUpperBoundTokens = contextUpperBoundTokens
        self.contextHardCapTokens = contextHardCapTokens
    }

    enum CodingKeys: String, CodingKey {
        case audioTokens = "audio_tokens"
        case audioSpanTokens = "audio_span_tokens"
        case promptTokens = "prompt_tokens"
        case maximumTokens = "maximum_tokens"
        case contextUpperBoundTokens = "context_upper_bound_tokens"
        case contextHardCapTokens = "context_hard_cap_tokens"
    }
}

public struct MOSSContextPlan: Codable, Equatable, Sendable {
    public var backend: String
    public var model: ModelDescriptor
    public var sampleCount: Int64
    public var textTokens: Int
    public var audioTokens: Int
    public var audioSpanTokens: Int
    public var promptTokens: Int
    public var maximumTokens: Int
    public var contextUpperBoundTokens: Int
    public var contextHardCapTokens: Int
    public var audioTokensPerSecond: Double
    public var timeMarkerEverySeconds: Int
    public var timeMarkersEnabled: Bool
    public var language: String
    public var instructionSHA256: String
    public var glossarySHA256: String?
    public var glossaryPayloadSHA256: String?
    public var glossaryItemCount: Int
    public var helperFingerprintSHA256: String

    public init(
        backend: String,
        model: ModelDescriptor,
        sampleCount: Int64,
        textTokens: Int,
        audioTokens: Int,
        audioSpanTokens: Int,
        promptTokens: Int,
        maximumTokens: Int,
        contextUpperBoundTokens: Int,
        contextHardCapTokens: Int,
        audioTokensPerSecond: Double,
        timeMarkerEverySeconds: Int,
        timeMarkersEnabled: Bool,
        language: String,
        instructionSHA256: String,
        glossarySHA256: String?,
        glossaryPayloadSHA256: String?,
        glossaryItemCount: Int,
        helperFingerprintSHA256: String
    ) {
        self.backend = backend
        self.model = model
        self.sampleCount = sampleCount
        self.textTokens = textTokens
        self.audioTokens = audioTokens
        self.audioSpanTokens = audioSpanTokens
        self.promptTokens = promptTokens
        self.maximumTokens = maximumTokens
        self.contextUpperBoundTokens = contextUpperBoundTokens
        self.contextHardCapTokens = contextHardCapTokens
        self.audioTokensPerSecond = audioTokensPerSecond
        self.timeMarkerEverySeconds = timeMarkerEverySeconds
        self.timeMarkersEnabled = timeMarkersEnabled
        self.language = language
        self.instructionSHA256 = instructionSHA256
        self.glossarySHA256 = glossarySHA256
        self.glossaryPayloadSHA256 = glossaryPayloadSHA256
        self.glossaryItemCount = glossaryItemCount
        self.helperFingerprintSHA256 = helperFingerprintSHA256
    }

    public func attemptPlan(sampleCount: Int64) throws -> MOSSAttemptTokenPlan {
        guard sampleCount > 0,
              audioTokensPerSecond > 0,
              timeMarkerEverySeconds > 0,
              maximumTokens > 0,
              contextHardCapTokens > 0
        else {
            throw ASRAdapterError.invalidRequest(
                "MOSS context plan is invalid"
            )
        }
        let chunkSamples: Int64 = 480_000
        let strideSamples: Int64 = 1_280
        let fullChunks = sampleCount / chunkSamples
        let remainder = sampleCount % chunkSamples
        var audioTokens = Int(fullChunks * (chunkSamples / strideSamples))
        if remainder > 0 {
            audioTokens += Int((remainder - 1) / strideSamples + 1)
        }
        let markerDigits: Int
        if timeMarkersEnabled {
            let duration = Double(audioTokens) / audioTokensPerSecond
            markerDigits = stride(
                from: timeMarkerEverySeconds,
                through: Int(duration),
                by: timeMarkerEverySeconds
            ).reduce(0) { $0 + String($1).count }
        } else {
            markerDigits = 0
        }
        let audioSpanTokens = audioTokens + markerDigits
        let promptTokens = textTokens + audioSpanTokens
        let contextUpperBoundTokens = promptTokens + maximumTokens
        guard contextUpperBoundTokens <= contextHardCapTokens else {
            throw ASRAdapterError.invalidRequest(
                "MOSS prompt plus output budget exceeds the hard context cap"
            )
        }
        return MOSSAttemptTokenPlan(
            audioTokens: audioTokens,
            audioSpanTokens: audioSpanTokens,
            promptTokens: promptTokens,
            maximumTokens: maximumTokens,
            contextUpperBoundTokens: contextUpperBoundTokens,
            contextHardCapTokens: contextHardCapTokens
        )
    }

    enum CodingKeys: String, CodingKey {
        case backend, model, language
        case sampleCount = "sample_count"
        case textTokens = "text_tokens"
        case audioTokens = "audio_tokens"
        case audioSpanTokens = "audio_span_tokens"
        case promptTokens = "prompt_tokens"
        case maximumTokens = "maximum_tokens"
        case contextUpperBoundTokens = "context_upper_bound_tokens"
        case contextHardCapTokens = "context_hard_cap_tokens"
        case audioTokensPerSecond = "audio_tokens_per_second"
        case timeMarkerEverySeconds = "time_marker_every_seconds"
        case timeMarkersEnabled = "time_markers_enabled"
        case instructionSHA256 = "instruction_sha256"
        case glossarySHA256 = "glossary_sha256"
        case glossaryPayloadSHA256 = "glossary_payload_sha256"
        case glossaryItemCount = "glossary_item_count"
        case helperFingerprintSHA256 = "helper_fingerprint_sha256"
    }
}

public struct ASRExecutionRecord: Equatable, Sendable {
    public var result: ASRResult
    public var glossary: ManifestGlossary
    public var glossaryPayloadSHA256: String?
    public var glossaryPayloadEntryCount: Int
    public var coverage: Coverage
    public var command: [String]
    public var outputURL: URL
    public var backendRawArtifactURL: URL
    public var backendRawArtifactSHA256: String
    public var inputSHA256: String
    public var metrics: ASRAttemptMetrics?
    public var language: ASRLanguageEvidence?
    public var helperFingerprint: ASRHelperFingerprint?

    public init(
        result: ASRResult,
        glossary: ManifestGlossary,
        glossaryPayloadSHA256: String?,
        glossaryPayloadEntryCount: Int,
        coverage: Coverage,
        command: [String],
        outputURL: URL,
        backendRawArtifactURL: URL,
        backendRawArtifactSHA256: String,
        inputSHA256: String,
        metrics: ASRAttemptMetrics? = nil,
        language: ASRLanguageEvidence? = nil,
        helperFingerprint: ASRHelperFingerprint? = nil
    ) {
        self.result = result
        self.glossary = glossary
        self.glossaryPayloadSHA256 = glossaryPayloadSHA256
        self.glossaryPayloadEntryCount = glossaryPayloadEntryCount
        self.coverage = coverage
        self.command = command
        self.outputURL = outputURL
        self.backendRawArtifactURL = backendRawArtifactURL
        self.backendRawArtifactSHA256 = backendRawArtifactSHA256
        self.inputSHA256 = inputSHA256
        self.metrics = metrics
        self.language = language
        self.helperFingerprint = helperFingerprint
    }
}

public struct PinnedASRAdapter: ASRBackend, Sendable {
    public let selected: SelectedASRBackend
    public let runtime: ASRRuntime

    public init(_ selected: SelectedASRBackend, runtime: ASRRuntime = .local) {
        self.selected = selected
        self.runtime = runtime
    }

    public var descriptor: BackendDescriptor { selected.descriptor }
    public var model: ModelDescriptor { selected.model }

    public func transcribe(_ request: ASRRequest) async throws -> ASRResult {
        try await transcribeDetailed(request).result
    }

    public func transcribeDetailed(_ request: ASRRequest) async throws -> ASRExecutionRecord {
        switch try await transcribeAttempt(request) {
        case let .complete(record): return record
        case let .limit(record): throw ASRAdapterError.inferenceLimit(record.stopReason)
        }
    }

    public func transcribeAttempt(
        _ request: ASRRequest,
        maximumTokens: Int = 5_120
    ) async throws -> ASRAttemptOutcome {
        try validate(request)
        guard maximumTokens > 0 else {
            throw ASRAdapterError.invalidRequest("ASR maximum token budget must be positive")
        }
        let outputURL = try makeFreshOutputURL()
        let glossaryURL = try makeGlossaryFile(request.glossary, beside: outputURL)
        let arguments = runnerArguments(request: request, glossaryURL: glossaryURL, outputURL: outputURL, maximumTokens: maximumTokens)
        let processResult = try await runSubprocess(arguments)
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            if let error = decodeRunnerError(processResult.standardError) { throw error }
            if processResult.status != 0 {
                throw ASRAdapterError.backendFailed(
                    code: "subprocess_exit_\(processResult.status)",
                    message: "diagnostic unavailable"
                )
            }
            throw ASRAdapterError.malformedOutput("ASR subprocess did not create its protected output record")
        }
        let data: Data
        do {
            data = try Data(contentsOf: outputURL)
        } catch {
            throw ASRAdapterError.malformedOutput("ASR subprocess output is unreadable: \(error.localizedDescription)")
        }
        let document: RunnerDocument
        do {
            document = try JSONDecoder().decode(RunnerDocument.self, from: data)
        } catch {
            throw ASRAdapterError.malformedOutput("ASR subprocess output is not a valid record: \(error.localizedDescription)")
        }
        if document.outcome == .invalidEOSOutput {
            guard processResult.status != 0 else {
                throw ASRAdapterError.malformedOutput(
                    "MOSS invalid_eos_output record must exit nonzero"
                )
            }
            return try validate(
                document: document,
                request: request,
                outputURL: outputURL,
                maximumTokens: maximumTokens
            )
        }
        if document.outcome == .unverified {
            guard processResult.status != 0 else {
                throw ASRAdapterError.malformedOutput(
                    "ASR unverified evidence record must exit nonzero"
                )
            }
            return try validate(
                document: document,
                request: request,
                outputURL: outputURL,
                maximumTokens: maximumTokens
            )
        }
        guard processResult.status == 0 else {
            throw ASRAdapterError.backendFailed(
                code: "subprocess_exit_\(processResult.status)",
                message: "diagnostic unavailable"
            )
        }
        return try validate(document: document, request: request, outputURL: outputURL, maximumTokens: maximumTokens)
    }

    private func validate(_ request: ASRRequest) throws {
        guard request.startS >= 0, request.endS > request.startS else {
            throw ASRAdapterError.invalidRequest("ASR request must have a positive half-open range")
        }
        guard FileManager.default.fileExists(atPath: request.audioURL.path) else {
            throw ASRAdapterError.invalidRequest("ASR audio chunk is missing: \(request.audioURL.path)")
        }
        if request.glossary == nil {
            guard request.injectionMode == .none else {
                throw ASRAdapterError.invalidRequest("an injection mode requires a glossary")
            }
        } else if request.injectionMode != selected.requiredInjectionMode {
            throw ASRAdapterError.unsupportedInjectionMode(
                expected: selected.requiredInjectionMode,
                actual: request.injectionMode
            )
        }
        guard FileManager.default.isExecutableFile(atPath: runtime.pythonExecutable.path) else {
            throw ASRAdapterError.runtimeMissing("pinned Python executable is missing: \(runtime.pythonExecutable.path)")
        }
        guard FileManager.default.fileExists(atPath: runtime.runnerURL.path) else {
            throw ASRAdapterError.runtimeMissing("ASR runner is missing: \(runtime.runnerURL.path)")
        }
    }

    private func makeFreshOutputURL() throws -> URL {
        do {
            try FileManager.default.createDirectory(at: runtime.outputRoot, withIntermediateDirectories: true)
        } catch {
            throw ASRAdapterError.launchFailed("cannot create ASR output root: \(error.localizedDescription)")
        }
        let output = runtime.outputRoot.appendingPathComponent("asr-\(UUID().uuidString.lowercased()).json")
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ASRAdapterError.launchFailed("generated ASR output path already exists")
        }
        return output
    }

    private func makeGlossaryFile(_ glossary: Glossary?, beside outputURL: URL) throws -> URL? {
        guard let glossary else { return nil }
        let outputDirectory = outputURL.deletingLastPathComponent()
        let path = outputDirectory.appendingPathComponent("\(outputURL.deletingPathExtension().lastPathComponent)-glossary.txt")
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw ASRAdapterError.launchFailed("generated glossary evidence path already exists")
        }
        do {
            try Data((glossary.entries.joined(separator: "\n") + "\n").utf8).write(to: path, options: .withoutOverwriting)
            return path
        } catch {
            throw ASRAdapterError.launchFailed("cannot write glossary evidence file: \(error.localizedDescription)")
        }
    }

    private func runnerArguments(request: ASRRequest, glossaryURL: URL?, outputURL: URL, maximumTokens: Int) -> [String] {
        var arguments = [
            runtime.runnerURL.path, "run",
            "--backend", selected.rawValue,
            "--audio", request.audioURL.path,
            "--start-s", String(request.startS),
            "--end-s", String(request.endS),
            "--language", languageString(request.language),
            "--injection-mode", request.glossary == nil ? GlossaryInjectionMode.none.rawValue : request.injectionMode.rawValue,
            "--cache-root", runtime.cacheRoot.path,
            "--output", outputURL.path,
            "--timeout-seconds", String(runtime.timeout),
            "--max-tokens", String(maximumTokens),
        ]
        if let glossaryURL {
            arguments += ["--glossary", glossaryURL.path]
            if let glossary = request.glossary {
                arguments += ["--glossary-sha256", glossary.sha256]
            }
        }
        return arguments
    }

    private func languageString(_ pin: LanguagePin) -> String {
        switch pin {
        case .automatic: "auto"
        case let .fixed(identifier): identifier.lowercased()
        }
    }

    private func runSubprocess(_ arguments: [String]) async throws -> ProcessResult {
        let executable = runtime.pythonExecutable
        let timeout = runtime.timeout
        let cacheRoot = runtime.cacheRoot
        return try await Task.detached(priority: .userInitiated) {
            try runProcessSynchronously(
                executable: executable,
                arguments: arguments,
                cacheRoot: cacheRoot,
                timeout: timeout
            )
        }.value
    }

    func decodeRunnerError(_ standardError: String) -> ASRAdapterError? {
        guard let line = standardError.split(separator: "\n").last,
              let data = String(line).data(using: .utf8),
              let error = try? JSONDecoder().decode(RunnerErrorDocument.self, from: data)
        else { return nil }
        guard runnerDiagnosticCodeIsAllowed(error.error.code) else { return nil }
        return .backendFailed(
            code: error.error.code,
            message: promotableRunnerDiagnostic(
                code: error.error.code,
                message: error.error.message
            ) ?? "diagnostic unavailable"
        )
    }

    /// Normalize backend segments onto the run timeline.  The backend's own
    /// speaker label never becomes the segment speaker, and a segment the
    /// runner measured as repetition looping is marked rather than
    /// silently kept or silently dropped.
    private func normalized(
        segments: [RunnerDocument.RunnerSegment],
        request: ASRRequest
    ) throws -> [Segment] {
        let requestedLanguage: String?
        switch request.language {
        case .automatic: requestedLanguage = nil
        case let .fixed(value): requestedLanguage = value
        }
        return try segments.enumerated().map { index, segment in
            guard segment.startS >= request.startS - 0.01,
                  segment.endS <= request.endS + 0.01,
                  segment.endS > segment.startS,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ASRAdapterError.coverageShortfall("invalid normalized segment \(index)") }
            var flags: [String] = []
            if !segment.speaker.isEmpty { flags.append("backend_speaker_evidence") }
            if segment.degenerate == true { flags.append("repetition_looping") }
            return Segment(
                speaker: "UNASSIGNED",
                startS: segment.startS,
                endS: segment.endS,
                text: segment.text,
                language: requestedLanguage,
                flags: flags.isEmpty ? nil : flags
            )
        }
    }

    /// Validate the recovered prefix a limit outcome carries.  The prefix is
    /// evidence, not a result: it must stay inside the requested range, stay
    /// ordered, and state a covered duration that its own segments support.
    private func validate(
        partialPrefix: RunnerDocument.RunnerPartialPrefix?,
        request: ASRRequest,
        expectedDuration: Double,
        stopReason: ASRAttemptStopReason
    ) throws -> ASRPartialPrefix? {
        guard let partialPrefix else {
            guard stopReason != .repetitionLooping else {
                throw ASRAdapterError.malformedOutput(
                    "ASR repetition-looping outcome carries no recovery evidence"
                )
            }
            return nil
        }
        guard partialPrefix.terminalCollapse
                == (stopReason == .repetitionLooping),
              partialPrefix.repetitionRunThreshold > 1,
              partialPrefix.promotedObjectCount >= 0,
              partialPrefix.promotedObjectCount <= partialPrefix.validatedObjectCount,
              partialPrefix.validatedObjectCount <= partialPrefix.completeObjectCount,
              partialPrefix.promotedObjectCount == partialPrefix.segments.count,
              partialPrefix.coverageS.isFinite,
              partialPrefix.coverageS >= 0,
              partialPrefix.coverageS <= expectedDuration + 0.01,
              partialPrefix.repetitionRunMaximum >= 0,
              partialPrefix.tailRepetitionRun >= 0
        else {
            throw ASRAdapterError.malformedOutput(
                "ASR partial prefix evidence is inconsistent"
            )
        }
        let segments = try normalized(
            segments: partialPrefix.segments,
            request: request
        )
        var previousEnd = request.startS - 0.01
        for segment in segments {
            guard segment.startS >= previousEnd - 0.01 else {
                throw ASRAdapterError.malformedOutput(
                    "ASR partial prefix segments are not ordered"
                )
            }
            previousEnd = segment.endS
        }
        if let last = segments.last {
            guard abs((last.endS - request.startS) - partialPrefix.coverageS) <= 0.01,
                  !partialPrefix.rawText.isEmpty
            else {
                throw ASRAdapterError.malformedOutput(
                    "ASR partial prefix coverage does not match its segments"
                )
            }
        } else {
            guard partialPrefix.coverageS == 0, partialPrefix.rawText.isEmpty else {
                throw ASRAdapterError.malformedOutput(
                    "ASR partial prefix coverage does not match its segments"
                )
            }
        }
        return ASRPartialPrefix(
            coverageS: partialPrefix.coverageS,
            rawText: partialPrefix.rawText,
            segments: segments,
            completeObjectCount: partialPrefix.completeObjectCount,
            promotedObjectCount: partialPrefix.promotedObjectCount,
            degenerateObjectCount: partialPrefix.degenerateObjectCount,
            repetitionRunThreshold: partialPrefix.repetitionRunThreshold,
            repetitionRunMaximum: partialPrefix.repetitionRunMaximum,
            tailRepetitionRun: partialPrefix.tailRepetitionRun,
            terminalCollapse: partialPrefix.terminalCollapse
        )
    }

    private func validate(
        document: RunnerDocument,
        request: ASRRequest,
        outputURL: URL,
        maximumTokens: Int
    ) throws -> ASRAttemptOutcome {
        guard document.backend == selected.rawValue,
              document.model == model
        else { throw ASRAdapterError.modelIdentityMismatch }
        let expectedDuration = request.endS - request.startS
        guard document.input.sha256Before == document.input.sha256After,
              document.input.sha256Before.isSHA256,
              sha256(of: request.audioURL) == document.input.sha256Before
        else { throw ASRAdapterError.coverageShortfall("ASR backend mutated the audio input") }
        let artifactURL = URL(fileURLWithPath: document.backendRawArtifact.path)
        guard FileManager.default.fileExists(atPath: artifactURL.path),
              document.backendRawArtifact.sha256.isSHA256,
              sha256(of: artifactURL) == document.backendRawArtifact.sha256
        else { throw ASRAdapterError.malformedOutput("ASR backend raw artifact is missing or changed") }
        let expectedMode = request.glossary == nil ? GlossaryInjectionMode.none : request.injectionMode
        guard document.glossary.injectionMode == expectedMode else {
            throw ASRAdapterError.malformedOutput("ASR output recorded an unexpected glossary injection mode")
        }
        if let glossary = request.glossary {
            guard document.glossary.provided,
                  document.glossary.sha256 == glossary.sha256,
                  document.glossary.itemCount == glossary.entries.count,
                  document.glossary.applied,
                  document.glossary.payloadEntryCount == glossary.entries.count,
                  let payloadSHA = document.glossary.payloadSHA256,
                  payloadSHA.isSHA256
            else { throw ASRAdapterError.malformedOutput("ASR output does not prove real glossary transport") }
            if selected == .moss, document.glossary.instructionSHA256 != document.language.instructionSHA256 {
                throw ASRAdapterError.malformedOutput("MOSS glossary and language instruction evidence disagree")
            }
        } else if document.glossary.provided
            || document.glossary.sha256 != nil
            || document.glossary.applied
            || document.glossary.itemCount != 0
            || document.glossary.payloadSHA256 != nil
            || document.glossary.payloadEntryCount != 0
        {
            throw ASRAdapterError.malformedOutput(
                "ASR output falsely reports glossary transport"
            )
        }
        let expectedLanguage = languageString(request.language)
        let expectsPromptGuidance = selected == .moss && expectedLanguage != "auto"
        guard document.language.requested == expectedLanguage,
              document.language.instructionSHA256.isSHA256,
              document.language.promptGuidanceApplied == expectsPromptGuidance
        else { throw ASRAdapterError.malformedOutput("ASR output does not prove the requested language guidance") }
        guard document.metrics.requestedMaxTokens == maximumTokens,
              document.metrics.hasTruthfulAvailability(document.metricsUnavailable),
              document.metrics.hasValidValues,
              document.runnerWallTimeS.isFinite,
              document.runnerWallTimeS >= 0,
              abs(document.metrics.audioDurationS - expectedDuration) <= 0.01
        else { throw ASRAdapterError.malformedOutput("ASR metrics are invalid") }
        let manifestGlossary = ManifestGlossary(
            provided: document.glossary.provided,
            sha256: document.glossary.sha256,
            itemCount: document.glossary.itemCount,
            injectionMode: document.glossary.injectionMode,
            applied: document.glossary.applied
        )
        let fingerprint = document.helperFingerprint?.publicValue
        if selected == .moss, fingerprint == nil {
            throw ASRAdapterError.malformedOutput("MOSS output has no validated helper fingerprint")
        }
        if document.outcome == .unverified {
            guard document.terminalEvidence == .unavailable,
                  document.stopReason == nil,
                  document.failure?.code == "evidence_unavailable",
                  let message = document.failure?.message,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  document.coverage.truncated,
                  abs(document.coverage.inputDurationS - expectedDuration) <= 0.01,
                  document.coverage.processedDurationS == 0,
                  document.segments.isEmpty
            else {
                throw ASRAdapterError.malformedOutput(
                    "ASR unverified evidence record is inconsistent"
                )
            }
            if selected == .qwen3, document.timingGranularity == .chunk {
                throw ASRAdapterError.evidenceUnavailable(
                    "Qwen output cannot be promoted without terminal and intra-chunk timing evidence"
                )
            }
            throw ASRAdapterError.evidenceUnavailable(
                "ASR output cannot be promoted without terminal evidence"
            )
        }
        guard document.terminalEvidence == .observed else {
            throw ASRAdapterError.evidenceUnavailable(
                "ASR output cannot be promoted without terminal evidence"
            )
        }
        guard document.timingGranularity == .segment else {
            let message = selected == .qwen3
                ? "Qwen output has no intra-chunk timestamp evidence"
                : "ASR output has no segment-level timestamp evidence"
            throw ASRAdapterError.evidenceUnavailable(message)
        }
        guard let metrics = document.metrics.publicValue(
            runnerWallTimeS: document.runnerWallTimeS,
            unavailable: document.metricsUnavailable
        ), metrics.maxTokens == maximumTokens
        else { throw ASRAdapterError.malformedOutput("ASR measured metrics are incomplete") }
        if let contextHardCapTokens = metrics.contextHardCapTokens,
           contextHardCapTokens < metrics.maxTokens
        {
            throw ASRAdapterError.malformedOutput("ASR context cap evidence is invalid")
        }
        if selected == .moss, metrics.contextHardCapTokens != 131_072 {
            throw ASRAdapterError.malformedOutput("MOSS context hard cap evidence is invalid")
        }
        if document.outcome == .invalidEOSOutput {
            guard selected == .moss,
                  document.stopReason == .endOfSequence,
                  document.failure?.code == "invalid_eos_output",
                  document.coverage.truncated,
                  abs(document.coverage.inputDurationS - expectedDuration) <= 0.01,
                  document.coverage.processedDurationS == 0,
                  document.rawText.isEmpty,
                  document.segments.isEmpty,
                  fingerprint != nil
            else {
                throw ASRAdapterError.malformedOutput(
                    "MOSS invalid_eos_output record contains promotable or inconsistent output"
                )
            }
            let message = document.failure?.message
                == "MOSS EOS output has no validated segments"
                ? "MOSS EOS output has no validated segments"
                : "diagnostic unavailable"
            throw ASRAdapterError.invalidEOSOutput(message)
        }
        if document.outcome == .limit {
            guard let stop = document.stopReason,
                  stop.isLimitOutcome,
                  document.coverage.truncated,
                  abs(document.coverage.inputDurationS - expectedDuration) <= 0.01,
                  document.coverage.processedDurationS == 0,
                  document.rawText.isEmpty,
                  document.segments.isEmpty,
                  selected != .moss || fingerprint != nil
            else { throw ASRAdapterError.malformedOutput("ASR limit output contains promotable partial content") }
            guard stop != .repetitionLooping || selected == .vibeVoice else {
                throw ASRAdapterError.malformedOutput(
                    "only the VibeVoice path detects repetition looping"
                )
            }
            let partialPrefix = try validate(
                partialPrefix: document.partialPrefix,
                request: request,
                expectedDuration: expectedDuration,
                stopReason: stop
            )
            return .limit(ASRLimitRecord(
                stopReason: stop,
                partialPrefix: partialPrefix,
                glossary: manifestGlossary,
                glossaryPayloadSHA256: document.glossary.payloadSHA256,
                glossaryPayloadEntryCount: document.glossary.payloadEntryCount,
                command: document.command,
                outputURL: outputURL,
                backendRawArtifactURL: artifactURL,
                backendRawArtifactSHA256: document.backendRawArtifact.sha256,
                inputSHA256: document.input.sha256Before,
                metrics: metrics,
                language: document.language.publicValue,
                helperFingerprint: fingerprint
            ))
        }
        guard document.outcome == .complete, document.stopReason == .endOfSequence,
              !document.coverage.truncated,
              abs(document.coverage.inputDurationS - expectedDuration) <= 0.01,
              abs(document.coverage.processedDurationS - expectedDuration) <= 0.01
        else { throw ASRAdapterError.coverageShortfall("ASR output does not cover the requested chunk") }
        guard !document.rawText.isEmpty, !document.segments.isEmpty else {
            throw ASRAdapterError.malformedOutput("ASR output has no raw transcript or segments")
        }
        let segments = try normalized(
            segments: document.segments,
            request: request
        )
        let coverage = Coverage(
            inputDurationS: document.coverage.inputDurationS,
            processedDurationS: document.coverage.processedDurationS,
            truncated: document.coverage.truncated,
            strategy: .full,
            chunksPlanned: 1,
            chunksCompleted: 1
        )
        return .complete(ASRExecutionRecord(
            result: ASRResult(rawText: document.rawText, segments: segments, glossaryApplied: manifestGlossary.applied),
            glossary: manifestGlossary,
            glossaryPayloadSHA256: document.glossary.payloadSHA256,
            glossaryPayloadEntryCount: document.glossary.payloadEntryCount,
            coverage: coverage,
            command: document.command,
            outputURL: outputURL,
            backendRawArtifactURL: artifactURL,
            backendRawArtifactSHA256: document.backendRawArtifact.sha256,
            inputSHA256: document.input.sha256Before,
            metrics: metrics,
            language: document.language.publicValue,
            helperFingerprint: fingerprint
        ))
    }
}

public struct ASRDoctorReport: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        public var ok: Bool
        public var version: String?
        public var path: String?
        public var message: String?
    }

    public var backend: String
    public var python: String
    public var pythonExecutable: String
    public var model: ModelDescriptor
    public var checks: [Check]
    public var ok: Bool

    enum CodingKeys: String, CodingKey {
        case backend, python, model, checks, ok
        case pythonExecutable = "python_executable"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decode(String.self, forKey: .backend)
        python = try container.decode(String.self, forKey: .python)
        pythonExecutable = try container.decode(String.self, forKey: .pythonExecutable)
        let runnerModel = try container.decode(RunnerDocument.RunnerModel.self, forKey: .model)
        model = ModelDescriptor(
            role: .asr,
            hfModelID: runnerModel.hfModelID,
            revision: runnerModel.revision,
            quantization: runnerModel.quantization
        )
        checks = try container.decode([Check].self, forKey: .checks)
        ok = try container.decode(Bool.self, forKey: .ok)
    }
}

public enum ASRDoctor {
    public static func diagnose(
        _ selected: SelectedASRBackend,
        runtime: ASRRuntime = .local
    ) async throws -> ASRDoctorReport {
        guard FileManager.default.isExecutableFile(atPath: runtime.pythonExecutable.path) else {
            throw ASRAdapterError.runtimeMissing("pinned Python executable is missing: \(runtime.pythonExecutable.path)")
        }
        let adapter = PinnedASRAdapter(selected, runtime: runtime)
        let process = try await adapter.runDoctor()
        guard process.status == 0 else {
            throw adapter.decodeRunnerError(process.standardError)
                ?? ASRAdapterError.backendFailed(
                    code: "doctor_exit_\(process.status)",
                    message: "diagnostic unavailable"
                )
        }
        guard let data = process.standardOutput.data(using: .utf8) else {
            throw ASRAdapterError.malformedOutput("doctor emitted non-UTF-8 output")
        }
        do {
            return try JSONDecoder().decode(ASRDoctorReport.self, from: data)
        } catch {
            throw ASRAdapterError.malformedOutput("doctor output is malformed: \(error.localizedDescription)")
        }
    }
}

public enum MOSSContextPlanner {
    public static func plan(
        sampleCount: Int64,
        language: LanguagePin,
        glossary: Glossary?,
        maximumTokens: Int = 5_120,
        runtime: ASRRuntime = .local
    ) async throws -> MOSSContextPlan {
        guard sampleCount > 0 else {
            throw ASRAdapterError.invalidRequest(
                "MOSS prompt planning requires a positive sample count"
            )
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "maccheroni-moss-plan-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        var arguments = [
            runtime.runnerURL.path,
            "plan-moss",
            "--sample-count", String(sampleCount),
            "--language", languageString(language),
            "--cache-root", runtime.cacheRoot.path,
            "--max-tokens", String(maximumTokens),
        ]
        if let glossary {
            let glossaryURL = temporaryDirectory.appendingPathComponent(
                "glossary.txt"
            )
            try Data(
                (glossary.entries.joined(separator: "\n") + "\n").utf8
            ).write(to: glossaryURL, options: .withoutOverwriting)
            arguments += [
                "--glossary", glossaryURL.path,
                "--glossary-sha256", glossary.sha256,
            ]
        }
        let process = try await Task.detached(priority: .userInitiated) {
            try runProcessSynchronously(
                executable: runtime.pythonExecutable,
                arguments: arguments,
                cacheRoot: runtime.cacheRoot,
                timeout: min(runtime.timeout, 60)
            )
        }.value
        guard process.status == 0 else {
            throw PinnedASRAdapter(.moss, runtime: runtime)
                .decodeRunnerError(process.standardError)
                ?? ASRAdapterError.backendFailed(
                    code: "prompt_plan_exit_\(process.status)",
                    message: "diagnostic unavailable"
                )
        }
        guard let data = process.standardOutput.data(using: .utf8) else {
            throw ASRAdapterError.malformedOutput(
                "MOSS prompt planner emitted non-UTF-8 output"
            )
        }
        let plan: MOSSContextPlan
        do {
            plan = try JSONDecoder().decode(MOSSContextPlan.self, from: data)
        } catch {
            throw ASRAdapterError.malformedOutput(
                "MOSS prompt planner output is malformed: \(error.localizedDescription)"
            )
        }
        let expectedLanguage = languageString(language)
        let expectedGlossaryPayloadSHA256 = glossary.map {
            sha256Data(Data(($0.entries.joined(separator: "\n") + "\n").utf8))
        }
        guard plan.backend == "moss",
              plan.model == SelectedASRBackend.moss.model,
              plan.sampleCount == sampleCount,
              plan.maximumTokens == maximumTokens,
              plan.contextHardCapTokens == 131_072,
              plan.contextUpperBoundTokens
                == plan.promptTokens + maximumTokens,
              plan.contextUpperBoundTokens <= plan.contextHardCapTokens,
              plan.audioTokens > 0,
              plan.audioSpanTokens >= plan.audioTokens,
              plan.promptTokens == plan.textTokens + plan.audioSpanTokens,
              plan.audioTokensPerSecond == 12.5,
              plan.timeMarkerEverySeconds == 5,
              plan.timeMarkersEnabled,
              plan.language == expectedLanguage,
              plan.instructionSHA256.isSHA256,
              plan.helperFingerprintSHA256.isSHA256,
              plan.glossarySHA256 == glossary?.sha256,
              plan.glossaryPayloadSHA256
                == expectedGlossaryPayloadSHA256,
              plan.glossaryItemCount == (glossary?.entries.count ?? 0),
              try plan.attemptPlan(sampleCount: sampleCount).promptTokens
                == plan.promptTokens
        else {
            throw ASRAdapterError.malformedOutput(
                "MOSS prompt planner evidence is inconsistent"
            )
        }
        return plan
    }

    private static func languageString(_ pin: LanguagePin) -> String {
        switch pin {
        case .automatic: "auto"
        case let .fixed(value): value.lowercased()
        }
    }
}

private extension PinnedASRAdapter {
    func runDoctor() async throws -> ProcessResult {
        try await runSubprocess([runtime.runnerURL.path, "doctor", "--backend", selected.rawValue, "--cache-root", runtime.cacheRoot.path])
    }
}

private struct ProcessResult: Sendable {
    var status: Int32
    var standardOutput: String
    var standardError: String
}

private let maximumCapturedStandardErrorBytes = 16_384

private func runnerDiagnosticCodeIsAllowed(_ code: String) -> Bool {
    switch code {
    case "backend_failed", "backend_import_failed", "backend_inference_failed",
         "backend_load_failed", "context_preflight", "coverage_shortfall",
         "dependency_invalid", "dependency_missing", "duration_limit", "environment_missing",
         "environment_version", "glossary_invalid", "glossary_not_applied",
         "harness_contract_mismatch", "harness_fingerprint_malformed",
         "harness_fingerprint_stale", "injection_mode", "input_mutated",
         "malformed_output", "model_unpinned", "output_alias", "request_invalid",
         "runtime_missing":
        true
    default:
        false
    }
}

private func promotableRunnerDiagnostic(code: String, message: String) -> String? {
    let exactMessages: [String: Set<String>] = [
        "dependency_invalid": [
            "VibeVoice tokenizer is missing required offline Qwen control tokens",
        ],
        "dependency_missing": [
            "VibeVoice tokenizer failed its offline semantic probe",
        ],
        "duration_limit": [
            "VibeVoice has a verified 59-minute limit; split this chunk before launch",
        ],
        "environment_missing": [
            "mlx-audio is not installed in the pinned uv environment",
        ],
        "glossary_invalid": [
            "a glossary injection mode requires nonempty glossary entries",
            "absent glossary must not carry an original SHA-256",
            "adapter must provide the original 64-character glossary SHA-256",
            "glossary contains NUL",
            "glossary has no usable entries",
            "planner requires the original 64-character glossary SHA-256",
        ],
        "glossary_not_applied": [
            "MOSS did not confirm the exact glossary payload",
            "MOSS did not retain hotword instruction evidence",
        ],
        "harness_fingerprint_malformed": [
            "MOSS harness fingerprint lacks the required v2 release evidence",
        ],
        "harness_fingerprint_stale": [
            "MOSS harness binary or metallib no longer matches its fingerprint",
        ],
        "injection_mode": [
            "glossary entries require a decode-time injection mode",
        ],
        "input_mutated": [
            "audio input changed during ASR; backend artifacts were preserved for inspection",
        ],
        "malformed_output": [
            "ASR subprocess output did not prove a safe diagnostic",
            "MOSS did not create its output JSON",
            "MOSS output is malformed",
            "Qwen emitted an empty transcript",
            "Qwen must emit exactly one Result line per chunk",
            "VibeVoice JSON has no segments",
            "VibeVoice JSON has no transcript text field",
            "VibeVoice JSON is malformed",
            "VibeVoice produced no JSON output",
            "backend returned no normalized segments",
        ],
        "model_unpinned": [
            "MOSS output does not prove the selected model identity",
            "MOSS processor token-rate configuration differs from the pinned contract",
            "MOSS processor token-rate configuration is invalid",
            "MOSS tokenizer digits do not match the time-marker contract",
            "MOSS tokenizer is missing required special tokens",
            "MOSS prompt planner requires the pinned tokenizer and processor",
            "model identity is incomplete",
        ],
        "output_alias": [
            "output must not alias audio or glossary input",
        ],
        "request_invalid": [
            "--max-tokens must be in 1...131072",
            "ASR range must be a positive half-open interval",
            "MOSS language must be auto or a BCP-47 language tag",
            "MOSS sample count must be positive",
        ],
        "runtime_missing": [
            "MOSS prompt tokenizer is unavailable or invalid",
        ],
    ]
    if exactMessages[code]?.contains(message) == true { return message }

    let patterns: [String: [String]] = [
        "backend_failed": [#"Qwen backend exited with status -?[0-9]+"#],
        "backend_import_failed": [#"VibeVoice dependency import failed \([A-Za-z_][A-Za-z0-9_]{0,63}\)"#],
        "backend_inference_failed": [#"VibeVoice inference failed \([A-Za-z_][A-Za-z0-9_]{0,63}\)"#],
        "backend_load_failed": [#"VibeVoice model load failed \([A-Za-z_][A-Za-z0-9_]{0,63}\)"#],
        "context_preflight": [#"MOSS prompt plus output budget requires [0-9]+ tokens, exceeding 131072"#],
        "coverage_shortfall": [
            #"backend returned out-of-range output"#,
            #"chunk duration [0-9]+\.[0-9]{3}s does not match request range [0-9]+\.[0-9]{3}s"#,
            #"MOSS metrics audio duration differs from input chunk"#,
            #"MOSS reported a duration different from the input chunk"#,
            #"segment [0-9]+ is outside chunk duration"#,
        ],
        "dependency_missing": [#"VibeVoice dependency check [A-Za-z0-9_]+ failed"#],
        "environment_version": [#"requires mlx-audio [0-9]+\.[0-9]+\.[0-9]+, found [0-9A-Za-z.+-]+"#],
        "glossary_invalid": [#"invalid glossary entry at line [0-9]+"#],
        "injection_mode": [#"(vibevoice|qwen3|moss) requires (free_text_context|hotword_instruction), got (none|free_text_context|hotword_instruction)"#],
        "malformed_output": [
            #"MOSS metrics field (preprocessing_s|audio_encoder_s|decoder_prefill_s|token_decode_s|total_s|model_load_s|audio_duration_s|prompt_tokens|generated_tokens|max_tokens|context_hard_cap_tokens|peak_rss_bytes) is invalid"#,
            #"segment [0-9]+ has (empty text|invalid timestamps)"#,
            #"VibeVoice (prompt_tokens|generation_tokens) evidence is invalid"#,
            #"VibeVoice segment [0-9]+ is not an object"#,
        ],
        "model_unpinned": [#"model revision is not a 40-character SHA: [0-9a-f]{0,64}"#],
    ]
    guard let allowed = patterns[code] else { return nil }
    return allowed.contains { pattern in
        message.range(
            of: "^(?:\(pattern))$",
            options: .regularExpression
        ) != nil
    } ? message : nil
}

private func capturedStandardError(at url: URL) -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    if size > UInt64(maximumCapturedStandardErrorBytes) {
        try? handle.seek(toOffset: size - UInt64(maximumCapturedStandardErrorBytes))
    } else {
        try? handle.seek(toOffset: 0)
    }
    return String(
        decoding: (try? handle.readToEnd()) ?? Data(),
        as: UTF8.self
    )
}

private func runProcessSynchronously(
    executable: URL,
    arguments: [String],
    cacheRoot: URL,
    timeout: TimeInterval
) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["HF_HUB_OFFLINE"] = "1"
    environment["HF_HOME"] = cacheRoot.appendingPathComponent("models/huggingface").path
    process.environment = environment
    let temporaryDirectory = FileManager.default.temporaryDirectory
    let stdoutURL = temporaryDirectory.appendingPathComponent("maccheroni-asr-stdout-\(UUID().uuidString)")
    let stderrURL = temporaryDirectory.appendingPathComponent("maccheroni-asr-stderr-\(UUID().uuidString)")
    let privateFileAttributes: [FileAttributeKey: Any] = [
        .posixPermissions: NSNumber(value: 0o600),
    ]
    guard FileManager.default.createFile(
        atPath: stdoutURL.path,
        contents: nil,
        attributes: privateFileAttributes
    ), FileManager.default.createFile(
        atPath: stderrURL.path,
        contents: nil,
        attributes: privateFileAttributes
    ) else {
        throw ASRAdapterError.launchFailed(
            "cannot create ASR subprocess capture files"
        )
    }
    let stdout: FileHandle
    let stderr: FileHandle
    do {
        stdout = try FileHandle(forWritingTo: stdoutURL)
        stderr = try FileHandle(forWritingTo: stderrURL)
    } catch {
        throw ASRAdapterError.launchFailed("cannot create ASR subprocess capture files: \(error.localizedDescription)")
    }
    var capturesClosed = false
    func closeCaptures() {
        guard !capturesClosed else { return }
        capturesClosed = true
        try? stdout.close()
        try? stderr.close()
    }
    defer {
        closeCaptures()
        try? FileManager.default.removeItem(at: stdoutURL)
        try? FileManager.default.removeItem(at: stderrURL)
    }
    process.standardOutput = stdout
    process.standardError = stderr
    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        throw ASRAdapterError.launchFailed("cannot launch ASR runner: \(error.localizedDescription)")
    }
    if finished.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 1) == .timedOut {
            _ = kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 1)
        }
        throw ASRAdapterError.timedOut(timeout)
    }
    closeCaptures()
    return ProcessResult(
        status: process.terminationStatus,
        standardOutput: String(data: (try? Data(contentsOf: stdoutURL)) ?? Data(), encoding: .utf8) ?? "",
        standardError: capturedStandardError(at: stderrURL)
    )
}

private func sha256(of url: URL) -> String? {
    guard let stream = InputStream(url: url) else { return nil }
    stream.open()
    defer { stream.close() }
    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { return nil }
        if count == 0 { break }
        digest.update(data: Data(buffer.prefix(count)))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func sha256Data(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private extension String {
    var isSHA256: Bool {
        count == 64 && unicodeScalars.allSatisfy { (48...57).contains($0.value) || (97...102).contains($0.value) }
    }
}

private struct RunnerErrorDocument: Decodable {
    struct Detail: Decodable { var code: String; var message: String }
    var error: Detail
}

private struct RunnerDocument: Decodable {
    struct RunnerFailure: Decodable {
        var code: String
        var message: String
    }

    struct RunnerModel: Decodable, Equatable {
        var hfModelID: String
        var revision: String
        var quantization: String

        enum CodingKeys: String, CodingKey {
            case hfModelID = "hf_model_id"
            case revision, quantization
        }
    }

    struct RunnerSegment: Decodable {
        var startS: Double
        var endS: Double
        var text: String
        var speaker: String
        var degenerate: Bool?

        enum CodingKeys: String, CodingKey {
            case startS = "start_s"
            case endS = "end_s"
            case text, speaker, degenerate
        }
    }

    struct RunnerPartialPrefix: Decodable {
        var completeObjectCount: Int
        var validatedObjectCount: Int
        var promotedObjectCount: Int
        var degenerateObjectCount: Int
        var coverageS: Double
        var repetitionRunThreshold: Int
        var repetitionRunMaximum: Int
        var tailRepetitionRun: Int
        var terminalCollapse: Bool
        var rawText: String
        var segments: [RunnerSegment]

        enum CodingKeys: String, CodingKey {
            case segments
            case completeObjectCount = "complete_object_count"
            case validatedObjectCount = "validated_object_count"
            case promotedObjectCount = "promoted_object_count"
            case degenerateObjectCount = "degenerate_object_count"
            case coverageS = "coverage_s"
            case repetitionRunThreshold = "repetition_run_threshold"
            case repetitionRunMaximum = "repetition_run_maximum"
            case tailRepetitionRun = "tail_repetition_run"
            case terminalCollapse = "terminal_collapse"
            case rawText = "raw_text"
        }
    }

    struct RunnerGlossary: Decodable {
        var provided: Bool
        var sha256: String?
        var itemCount: Int
        var injectionMode: GlossaryInjectionMode
        var applied: Bool
        var payloadSHA256: String?
        var payloadEntryCount: Int
        var instructionSHA256: String

        enum CodingKeys: String, CodingKey {
            case provided, sha256, applied
            case itemCount = "item_count"
            case injectionMode = "injection_mode"
            case payloadSHA256 = "payload_sha256"
            case payloadEntryCount = "payload_entry_count"
            case instructionSHA256 = "instruction_sha256"
        }
    }

    struct RunnerCoverage: Decodable {
        var inputDurationS: Double
        var processedDurationS: Double
        var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case inputDurationS = "input_duration_s"
            case processedDurationS = "processed_duration_s"
            case truncated
        }
    }

    struct RunnerInput: Decodable {
        var sha256Before: String
        var sha256After: String

        enum CodingKeys: String, CodingKey {
            case sha256Before = "sha256_before"
            case sha256After = "sha256_after"
        }
    }

    struct RunnerArtifact: Decodable {
        var path: String
        var sha256: String
    }

    struct RunnerLanguage: Decodable {
        var requested: String
        var instructionSHA256: String
        var promptGuidanceApplied: Bool
        enum CodingKeys: String, CodingKey {
            case requested
            case instructionSHA256 = "instruction_sha256"
            case promptGuidanceApplied = "prompt_guidance_applied"
        }
        var publicValue: ASRLanguageEvidence {
            .init(requested: requested, instructionSHA256: instructionSHA256, promptGuidanceApplied: promptGuidanceApplied)
        }
    }

    struct RunnerMetrics: Decodable {
        var preprocessingS: Double?
        var audioEncoderS: Double?
        var decoderPrefillS: Double?
        var tokenDecodeS: Double?
        var totalS: Double?
        var modelLoadS: Double?
        var audioDurationS: Double
        var promptTokens: Int?
        var generatedTokens: Int?
        var requestedMaxTokens: Int
        var maxTokens: Int?
        var contextHardCapTokens: Int?
        var peakRSSBytes: Int64?
        enum CodingKeys: String, CodingKey {
            case preprocessingS = "preprocessing_s"
            case audioEncoderS = "audio_encoder_s"
            case decoderPrefillS = "decoder_prefill_s"
            case tokenDecodeS = "token_decode_s"
            case totalS = "total_s"
            case modelLoadS = "model_load_s"
            case audioDurationS = "audio_duration_s"
            case promptTokens = "prompt_tokens"
            case generatedTokens = "generated_tokens"
            case requestedMaxTokens = "requested_max_tokens"
            case maxTokens = "max_tokens"
            case contextHardCapTokens = "context_hard_cap_tokens"
            case peakRSSBytes = "peak_rss_bytes"
        }

        var hasValidValues: Bool {
            let floatingPointValues = [
                preprocessingS, audioEncoderS, decoderPrefillS, tokenDecodeS,
                totalS, modelLoadS,
            ].compactMap { $0 }
            let integerValues = [
                promptTokens, generatedTokens, maxTokens,
                contextHardCapTokens,
            ].compactMap { $0 }
            return requestedMaxTokens > 0
                && audioDurationS.isFinite
                && audioDurationS >= 0
                && floatingPointValues.allSatisfy { $0.isFinite && $0 >= 0 }
                && integerValues.allSatisfy { $0 >= 0 }
                && (peakRSSBytes.map { $0 >= 0 } ?? true)
        }

        func hasTruthfulAvailability(_ unavailable: [String: String]) -> Bool {
            var absentFields = Set<String>()
            if preprocessingS == nil { absentFields.insert("preprocessing_s") }
            if audioEncoderS == nil { absentFields.insert("audio_encoder_s") }
            if decoderPrefillS == nil { absentFields.insert("decoder_prefill_s") }
            if tokenDecodeS == nil { absentFields.insert("token_decode_s") }
            if totalS == nil { absentFields.insert("total_s") }
            if modelLoadS == nil { absentFields.insert("model_load_s") }
            if promptTokens == nil { absentFields.insert("prompt_tokens") }
            if generatedTokens == nil { absentFields.insert("generated_tokens") }
            if maxTokens == nil { absentFields.insert("max_tokens") }
            if contextHardCapTokens == nil {
                absentFields.insert("context_hard_cap_tokens")
            }
            if peakRSSBytes == nil { absentFields.insert("peak_rss_bytes") }
            return Set(unavailable.keys) == absentFields
                && unavailable.values.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }

        func publicValue(
            runnerWallTimeS: Double,
            unavailable: [String: String]
        ) -> ASRAttemptMetrics? {
            guard let promptTokens,
                  let generatedTokens,
                  let maxTokens,
                  let totalS
            else { return nil }
            return .init(
                preprocessingS: preprocessingS,
                audioEncoderS: audioEncoderS,
                decoderPrefillS: decoderPrefillS,
                tokenDecodeS: tokenDecodeS,
                promptTokens: promptTokens,
                generatedTokens: generatedTokens,
                maxTokens: maxTokens,
                contextHardCapTokens: contextHardCapTokens,
                audioDurationS: audioDurationS,
                totalS: totalS,
                modelLoadS: modelLoadS,
                runnerWallTimeS: runnerWallTimeS,
                peakRSSBytes: peakRSSBytes,
                unavailable: unavailable
            )
        }
    }

    enum TerminalEvidence: String, Decodable {
        case observed, unavailable
    }

    enum TimingGranularity: String, Decodable {
        case segment, chunk
    }

    struct RunnerFingerprint: Decodable {
        var path: String
        var sha256: String
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
            case path, sha256
            case contractVersion = "contract_version"
            case sourceTreeSHA256 = "source_tree_sha256"
            case packageSwiftSHA256 = "package_swift_sha256"
            case packageResolvedSHA256 = "package_resolved_sha256"
            case swiftVersion = "swift_version"
            case swiftVersionSHA256 = "swift_version_sha256"
            case targetArchitecture = "target_architecture"
            case configuration
            case buildFlags = "build_flags"
            case executableSHA256 = "executable_sha256"
            case metallibSHA256 = "metallib_sha256"
        }
        var publicValue: ASRHelperFingerprint? {
            guard sha256.isSHA256, sourceTreeSHA256.isSHA256, packageSwiftSHA256.isSHA256,
                  packageResolvedSHA256.isSHA256, swiftVersionSHA256.isSHA256,
                  executableSHA256.isSHA256, metallibSHA256.isSHA256,
                  sha256Data(Data(swiftVersion.utf8)) == swiftVersionSHA256,
                  contractVersion == "moss-harness-v2", targetArchitecture == "arm64",
                  configuration == "release", buildFlags == ["--configuration", "release", "--arch", "arm64", "--product", "MaccheroniMossHarness"]
            else { return nil }
            return .init(path: path, sha256: sha256, contractVersion: contractVersion, sourceTreeSHA256: sourceTreeSHA256, packageSwiftSHA256: packageSwiftSHA256, packageResolvedSHA256: packageResolvedSHA256, swiftVersion: swiftVersion, swiftVersionSHA256: swiftVersionSHA256, targetArchitecture: targetArchitecture, configuration: configuration, buildFlags: buildFlags, executableSHA256: executableSHA256, metallibSHA256: metallibSHA256)
        }
    }

    var backend: String
    var model: RunnerModel
    var rawText: String
    var segments: [RunnerSegment]
    var glossary: RunnerGlossary
    var coverage: RunnerCoverage
    var command: [String]
    var input: RunnerInput
    var backendRawArtifact: RunnerArtifact
    var outcome: Outcome
    var stopReason: ASRAttemptStopReason?
    var terminalEvidence: TerminalEvidence
    var timingGranularity: TimingGranularity
    var language: RunnerLanguage
    var metrics: RunnerMetrics
    var metricsUnavailable: [String: String]
    var helperFingerprint: RunnerFingerprint?
    var runnerWallTimeS: Double
    var failure: RunnerFailure?
    var partialPrefix: RunnerPartialPrefix?

    enum Outcome: String, Decodable {
        case complete, limit, unverified
        case invalidEOSOutput = "invalid_eos_output"
    }

    enum CodingKeys: String, CodingKey {
        case backend, model, segments, glossary, coverage, command, input, outcome, language, metrics, failure
        case rawText = "raw_text"
        case backendRawArtifact = "backend_raw_artifact"
        case stopReason = "stop_reason"
        case terminalEvidence = "terminal_evidence"
        case timingGranularity = "timing_granularity"
        case helperFingerprint = "helper_fingerprint"
        case runnerWallTimeS = "runner_wall_time_s"
        case metricsUnavailable = "metrics_unavailable"
        case partialPrefix = "partial_prefix"
    }
}

private extension RunnerDocument.RunnerModel {
    static func == (lhs: RunnerDocument.RunnerModel, rhs: ModelDescriptor) -> Bool {
        lhs.hfModelID == rhs.hfModelID && lhs.revision == rhs.revision && lhs.quantization == rhs.quantization
    }
}
