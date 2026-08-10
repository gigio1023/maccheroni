import Foundation

public enum MaccheroniSchema {
    public static let version = "1.0.0"
}

public struct Segment: Codable, Equatable, Sendable {
    public var speaker: String
    public var startS: Double
    public var endS: Double
    public var text: String
    public var language: String?
    public var confidence: Double?
    public var flags: [String]?

    public init(
        speaker: String,
        startS: Double,
        endS: Double,
        text: String,
        language: String? = nil,
        confidence: Double? = nil,
        flags: [String]? = nil
    ) {
        self.speaker = speaker
        self.startS = startS
        self.endS = endS
        self.text = text
        self.language = language
        self.confidence = confidence
        self.flags = flags
    }

    enum CodingKeys: String, CodingKey {
        case speaker, text, language, confidence, flags
        case startS = "start_s"
        case endS = "end_s"
    }
}

public struct SourceAudio: Codable, Equatable, Sendable {
    public var fileName: String
    public var sha256: String
    public var durationS: Double

    public init(fileName: String, sha256: String, durationS: Double) {
        self.fileName = fileName
        self.sha256 = sha256
        self.durationS = durationS
    }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case sha256
        case durationS = "duration_s"
    }
}

public struct SegmentsDocument: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var segments: [Segment]
    public var numSpeakers: Int
    public var source: SourceAudio

    public init(
        schemaVersion: String = MaccheroniSchema.version,
        segments: [Segment],
        numSpeakers: Int,
        source: SourceAudio
    ) {
        self.schemaVersion = schemaVersion
        self.segments = segments
        self.numSpeakers = numSpeakers
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case segments, source
        case schemaVersion = "schema_version"
        case numSpeakers = "num_speakers"
    }
}

public struct TimelineSegment: Codable, Equatable, Sendable {
    public var speaker: String
    public var startS: Double
    public var endS: Double
    public var confidence: Double?

    public init(speaker: String, startS: Double, endS: Double, confidence: Double? = nil) {
        self.speaker = speaker
        self.startS = startS
        self.endS = endS
        self.confidence = confidence
    }

    enum CodingKeys: String, CodingKey {
        case speaker, confidence
        case startS = "start_s"
        case endS = "end_s"
    }
}

public struct Timeline: Codable, Equatable, Sendable {
    public var segments: [TimelineSegment]

    public init(segments: [TimelineSegment]) {
        self.segments = segments
    }
}

public struct BackendDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public enum PostprocessInputMode: String, Codable, Equatable, Sendable {
    case textOnly = "text-only"
}

public enum PostprocessMode: String, Codable, Equatable, Sendable {
    case correction
    case translation
}

public enum PostprocessOutputTokenLimitStatus: String, Codable, Equatable, Sendable {
    case configured
    case serviceManagedUnavailable = "service-managed-unavailable"
}

public struct ManifestPostprocessBatching: Codable, Equatable, Sendable {
    public var maximumPromptUTF8Bytes: Int
    public var maximumSegmentsPerBatch: Int
    public var maximumOutputTokens: Int?
    public var outputTokenLimitStatus: PostprocessOutputTokenLimitStatus
    public var outputTokenPlanningBudget: Int
    public var outputTokensPerInputUTF8BytePermille: Int
    public var baseOutputTokenReserve: Int
    public var perSegmentOutputTokenReserve: Int
    public var batchesPlanned: Int
    public var maximumObservedPromptUTF8Bytes: Int
    public var maximumObservedInputTextUTF8Bytes: Int
    public var maximumObservedEstimatedOutputTokens: Int
    public var maximumObservedOutputTextUTF8Bytes: Int
    public var maximumObservedResponseUTF8Bytes: Int
    public var maximumObservedAcceptedOutputTokenUpperBound: Int

    public init(
        maximumPromptUTF8Bytes: Int,
        maximumSegmentsPerBatch: Int,
        maximumOutputTokens: Int?,
        outputTokenLimitStatus: PostprocessOutputTokenLimitStatus,
        outputTokenPlanningBudget: Int,
        outputTokensPerInputUTF8BytePermille: Int,
        baseOutputTokenReserve: Int,
        perSegmentOutputTokenReserve: Int,
        batchesPlanned: Int,
        maximumObservedPromptUTF8Bytes: Int,
        maximumObservedInputTextUTF8Bytes: Int,
        maximumObservedEstimatedOutputTokens: Int,
        maximumObservedOutputTextUTF8Bytes: Int,
        maximumObservedResponseUTF8Bytes: Int,
        maximumObservedAcceptedOutputTokenUpperBound: Int
    ) {
        self.maximumPromptUTF8Bytes = maximumPromptUTF8Bytes
        self.maximumSegmentsPerBatch = maximumSegmentsPerBatch
        self.maximumOutputTokens = maximumOutputTokens
        self.outputTokenLimitStatus = outputTokenLimitStatus
        self.outputTokenPlanningBudget = outputTokenPlanningBudget
        self.outputTokensPerInputUTF8BytePermille = outputTokensPerInputUTF8BytePermille
        self.baseOutputTokenReserve = baseOutputTokenReserve
        self.perSegmentOutputTokenReserve = perSegmentOutputTokenReserve
        self.batchesPlanned = batchesPlanned
        self.maximumObservedPromptUTF8Bytes = maximumObservedPromptUTF8Bytes
        self.maximumObservedInputTextUTF8Bytes = maximumObservedInputTextUTF8Bytes
        self.maximumObservedEstimatedOutputTokens = maximumObservedEstimatedOutputTokens
        self.maximumObservedOutputTextUTF8Bytes = maximumObservedOutputTextUTF8Bytes
        self.maximumObservedResponseUTF8Bytes = maximumObservedResponseUTF8Bytes
        self.maximumObservedAcceptedOutputTokenUpperBound =
            maximumObservedAcceptedOutputTokenUpperBound
    }

    enum CodingKeys: String, CodingKey {
        case baseOutputTokenReserve = "base_output_token_reserve"
        case batchesPlanned = "batches_planned"
        case maximumOutputTokens = "maximum_output_tokens"
        case maximumObservedEstimatedOutputTokens = "maximum_observed_estimated_output_tokens"
        case maximumObservedAcceptedOutputTokenUpperBound = "maximum_observed_accepted_output_token_upper_bound"
        case maximumObservedInputTextUTF8Bytes = "maximum_observed_input_text_utf8_bytes"
        case maximumObservedOutputTextUTF8Bytes = "maximum_observed_output_text_utf8_bytes"
        case maximumObservedPromptUTF8Bytes = "maximum_observed_prompt_utf8_bytes"
        case maximumObservedResponseUTF8Bytes = "maximum_observed_response_utf8_bytes"
        case maximumPromptUTF8Bytes = "maximum_prompt_utf8_bytes"
        case maximumSegmentsPerBatch = "maximum_segments_per_batch"
        case outputTokenLimitStatus = "output_token_limit_status"
        case outputTokenPlanningBudget = "output_token_planning_budget"
        case outputTokensPerInputUTF8BytePermille = "output_tokens_per_input_utf8_byte_permille"
        case perSegmentOutputTokenReserve = "per_segment_output_token_reserve"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maximumPromptUTF8Bytes, forKey: .maximumPromptUTF8Bytes)
        try container.encode(maximumSegmentsPerBatch, forKey: .maximumSegmentsPerBatch)
        if let maximumOutputTokens {
            try container.encode(maximumOutputTokens, forKey: .maximumOutputTokens)
        } else {
            try container.encodeNil(forKey: .maximumOutputTokens)
        }
        try container.encode(outputTokenLimitStatus, forKey: .outputTokenLimitStatus)
        try container.encode(outputTokenPlanningBudget, forKey: .outputTokenPlanningBudget)
        try container.encode(
            outputTokensPerInputUTF8BytePermille,
            forKey: .outputTokensPerInputUTF8BytePermille
        )
        try container.encode(baseOutputTokenReserve, forKey: .baseOutputTokenReserve)
        try container.encode(perSegmentOutputTokenReserve, forKey: .perSegmentOutputTokenReserve)
        try container.encode(batchesPlanned, forKey: .batchesPlanned)
        try container.encode(
            maximumObservedPromptUTF8Bytes,
            forKey: .maximumObservedPromptUTF8Bytes
        )
        try container.encode(
            maximumObservedInputTextUTF8Bytes,
            forKey: .maximumObservedInputTextUTF8Bytes
        )
        try container.encode(
            maximumObservedEstimatedOutputTokens,
            forKey: .maximumObservedEstimatedOutputTokens
        )
        try container.encode(
            maximumObservedOutputTextUTF8Bytes,
            forKey: .maximumObservedOutputTextUTF8Bytes
        )
        try container.encode(
            maximumObservedResponseUTF8Bytes,
            forKey: .maximumObservedResponseUTF8Bytes
        )
        try container.encode(
            maximumObservedAcceptedOutputTokenUpperBound,
            forKey: .maximumObservedAcceptedOutputTokenUpperBound
        )
    }
}

public struct ManifestPostprocess: Codable, Equatable, Sendable {
    public var backend: BackendDescriptor
    public var modelID: String
    public var modelRevision: String?
    public var quantization: String?
    public var inputMode: PostprocessInputMode
    public var glossarySHA256: String?
    public var mode: PostprocessMode
    public var targetLanguage: String?
    public var sourceSegmentsSHA256: String?
    public var batching: ManifestPostprocessBatching?

    public init(
        backend: BackendDescriptor,
        modelID: String,
        modelRevision: String? = nil,
        quantization: String? = nil,
        inputMode: PostprocessInputMode = .textOnly,
        glossarySHA256: String? = nil,
        mode: PostprocessMode = .correction,
        targetLanguage: String? = nil,
        sourceSegmentsSHA256: String? = nil,
        batching: ManifestPostprocessBatching? = nil
    ) {
        self.backend = backend
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.quantization = quantization
        self.inputMode = inputMode
        self.glossarySHA256 = glossarySHA256
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.sourceSegmentsSHA256 = sourceSegmentsSHA256
        self.batching = batching
    }

    enum CodingKeys: String, CodingKey {
        case backend, batching, mode, quantization
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case inputMode = "input_mode"
        case glossarySHA256 = "glossary_sha256"
        case sourceSegmentsSHA256 = "source_segments_sha256"
        case targetLanguage = "target_language"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backend = try container.decode(BackendDescriptor.self, forKey: .backend)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
        inputMode = try container.decode(PostprocessInputMode.self, forKey: .inputMode)
        glossarySHA256 = try container.decodeIfPresent(String.self, forKey: .glossarySHA256)
        mode = try container.decodeIfPresent(PostprocessMode.self, forKey: .mode) ?? .correction
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage)
        sourceSegmentsSHA256 = try container.decodeIfPresent(String.self, forKey: .sourceSegmentsSHA256)
        batching = try container.decodeIfPresent(ManifestPostprocessBatching.self, forKey: .batching)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(backend, forKey: .backend)
        try container.encode(modelID, forKey: .modelID)
        if let modelRevision {
            try container.encode(modelRevision, forKey: .modelRevision)
        } else {
            try container.encodeNil(forKey: .modelRevision)
        }
        if let quantization {
            try container.encode(quantization, forKey: .quantization)
        } else {
            try container.encodeNil(forKey: .quantization)
        }
        try container.encode(inputMode, forKey: .inputMode)
        if let glossarySHA256 {
            try container.encode(glossarySHA256, forKey: .glossarySHA256)
        } else {
            try container.encodeNil(forKey: .glossarySHA256)
        }
        try container.encode(mode, forKey: .mode)
        if let targetLanguage {
            try container.encode(targetLanguage, forKey: .targetLanguage)
        } else {
            try container.encodeNil(forKey: .targetLanguage)
        }
        if let sourceSegmentsSHA256 {
            try container.encode(sourceSegmentsSHA256, forKey: .sourceSegmentsSHA256)
        } else {
            try container.encodeNil(forKey: .sourceSegmentsSHA256)
        }
        if let batching {
            try container.encode(batching, forKey: .batching)
        } else {
            try container.encodeNil(forKey: .batching)
        }
    }
}

public enum ModelRole: String, Codable, Sendable {
    case asr
    case diarization
    case alignment
    case vad
    case enhancement
    case postprocess
}

public struct ModelDescriptor: Codable, Equatable, Sendable {
    public var role: ModelRole
    public var hfModelID: String
    public var revision: String
    public var quantization: String

    public init(role: ModelRole, hfModelID: String, revision: String, quantization: String) {
        self.role = role
        self.hfModelID = hfModelID
        self.revision = revision
        self.quantization = quantization
    }

    enum CodingKeys: String, CodingKey {
        case role, revision, quantization
        case hfModelID = "hf_model_id"
    }
}

public enum GlossaryInjectionMode: String, Codable, Sendable {
    case none
    case freeTextContext = "free_text_context"
    case hotwordInstruction = "hotword_instruction"
    case ctcVocabulary = "ctc_vocabulary"
}

public struct ManifestGlossary: Codable, Equatable, Sendable {
    public var provided: Bool
    public var sha256: String?
    public var itemCount: Int
    public var injectionMode: GlossaryInjectionMode
    public var applied: Bool

    public init(
        provided: Bool,
        sha256: String?,
        itemCount: Int,
        injectionMode: GlossaryInjectionMode,
        applied: Bool
    ) {
        self.provided = provided
        self.sha256 = sha256
        self.itemCount = itemCount
        self.injectionMode = injectionMode
        self.applied = applied
    }

    public static let absent = ManifestGlossary(
        provided: false,
        sha256: nil,
        itemCount: 0,
        injectionMode: .none,
        applied: false
    )

    enum CodingKeys: String, CodingKey {
        case provided, sha256, applied
        case itemCount = "item_count"
        case injectionMode = "injection_mode"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provided, forKey: .provided)
        if let sha256 {
            try container.encode(sha256, forKey: .sha256)
        } else {
            try container.encodeNil(forKey: .sha256)
        }
        try container.encode(itemCount, forKey: .itemCount)
        try container.encode(injectionMode, forKey: .injectionMode)
        try container.encode(applied, forKey: .applied)
    }
}

public struct ProcessingSwitch: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var backend: String?

    public init(enabled: Bool, backend: String?) {
        self.enabled = enabled
        self.backend = backend
    }

    enum CodingKeys: String, CodingKey {
        case enabled, backend
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        if let backend {
            try container.encode(backend, forKey: .backend)
        } else {
            try container.encodeNil(forKey: .backend)
        }
    }
}

public struct PreprocessingConfiguration: Codable, Equatable, Sendable {
    public var sampleRateHz: Int
    public var channels: Int
    public var peakNormalization: Bool
    public var vad: ProcessingSwitch
    public var enhancement: ProcessingSwitch

    public init(
        sampleRateHz: Int,
        channels: Int,
        peakNormalization: Bool,
        vad: ProcessingSwitch,
        enhancement: ProcessingSwitch
    ) {
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.peakNormalization = peakNormalization
        self.vad = vad
        self.enhancement = enhancement
    }

    enum CodingKeys: String, CodingKey {
        case channels, vad, enhancement
        case sampleRateHz = "sample_rate_hz"
        case peakNormalization = "peak_normalization"
    }
}

public enum CoverageStrategy: String, Codable, Sendable {
    case full
    case chunked
    case rejected
    case backendTruncated = "backend_truncated"
}

public struct Coverage: Codable, Equatable, Sendable {
    public var inputDurationS: Double
    public var processedDurationS: Double
    public var truncated: Bool
    public var strategy: CoverageStrategy
    public var chunksPlanned: Int
    public var chunksCompleted: Int
    public var message: String?

    public init(
        inputDurationS: Double,
        processedDurationS: Double,
        truncated: Bool,
        strategy: CoverageStrategy,
        chunksPlanned: Int,
        chunksCompleted: Int,
        message: String? = nil
    ) {
        self.inputDurationS = inputDurationS
        self.processedDurationS = processedDurationS
        self.truncated = truncated
        self.strategy = strategy
        self.chunksPlanned = chunksPlanned
        self.chunksCompleted = chunksCompleted
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case truncated, strategy, message
        case inputDurationS = "input_duration_s"
        case processedDurationS = "processed_duration_s"
        case chunksPlanned = "chunks_planned"
        case chunksCompleted = "chunks_completed"
    }
}

public enum ChunkStatus: String, Codable, Sendable {
    case planned
    case succeeded
    case failed
    case skipped
}

public struct ChunkBoundary: Codable, Equatable, Sendable {
    public var index: Int
    public var startS: Double
    public var endS: Double
    public var status: ChunkStatus

    public init(index: Int, startS: Double, endS: Double, status: ChunkStatus) {
        self.index = index
        self.startS = startS
        self.endS = endS
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case index, status
        case startS = "start_s"
        case endS = "end_s"
    }
}

public struct RunTiming: Codable, Equatable, Sendable {
    public var startedAt: String
    public var finishedAt: String
    public var wallTimeS: Double

    public init(startedAt: String, finishedAt: String, wallTimeS: Double) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.wallTimeS = wallTimeS
    }

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case wallTimeS = "wall_time_s"
    }
}

public struct Artifact: Codable, Equatable, Sendable {
    public var kind: String
    public var path: String
    public var sha256: String

    public init(kind: String, path: String, sha256: String) {
        self.kind = kind
        self.path = path
        self.sha256 = sha256
    }
}

public struct Failure: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RunStatus: String, Codable, Sendable {
    case succeeded
    case partial
    case failed
    case canceled
}

public struct Manifest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var runID: String
    public var status: RunStatus
    public var input: InputAudio
    public var backend: BackendDescriptor
    public var models: [ModelDescriptor]
    public var glossary: ManifestGlossary
    public var preprocessing: PreprocessingConfiguration
    public var coverage: Coverage
    public var chunkBoundaries: [ChunkBoundary]
    public var timing: RunTiming
    public var peakMemoryBytes: Int?
    public var artifacts: [Artifact]
    public var failure: Failure?
    public var postprocess: ManifestPostprocess?

    public init(
        schemaVersion: String = MaccheroniSchema.version,
        runID: String,
        status: RunStatus,
        input: InputAudio,
        backend: BackendDescriptor,
        models: [ModelDescriptor],
        glossary: ManifestGlossary,
        preprocessing: PreprocessingConfiguration,
        coverage: Coverage,
        chunkBoundaries: [ChunkBoundary],
        timing: RunTiming,
        peakMemoryBytes: Int? = nil,
        artifacts: [Artifact],
        failure: Failure?,
        postprocess: ManifestPostprocess? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.status = status
        self.input = input
        self.backend = backend
        self.models = models
        self.glossary = glossary
        self.preprocessing = preprocessing
        self.coverage = coverage
        self.chunkBoundaries = chunkBoundaries
        self.timing = timing
        self.peakMemoryBytes = peakMemoryBytes
        self.artifacts = artifacts
        self.failure = failure
        self.postprocess = postprocess
    }

    enum CodingKeys: String, CodingKey {
        case status, input, backend, models, glossary, preprocessing, coverage, timing, artifacts, failure, postprocess
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case chunkBoundaries = "chunk_boundaries"
        case peakMemoryBytes = "peak_memory_bytes"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runID, forKey: .runID)
        try container.encode(status, forKey: .status)
        try container.encode(input, forKey: .input)
        try container.encode(backend, forKey: .backend)
        try container.encode(models, forKey: .models)
        try container.encode(glossary, forKey: .glossary)
        try container.encode(preprocessing, forKey: .preprocessing)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(chunkBoundaries, forKey: .chunkBoundaries)
        try container.encode(timing, forKey: .timing)
        if let peakMemoryBytes {
            try container.encode(peakMemoryBytes, forKey: .peakMemoryBytes)
        }
        try container.encode(artifacts, forKey: .artifacts)
        if let failure {
            try container.encode(failure, forKey: .failure)
        } else {
            try container.encodeNil(forKey: .failure)
        }
        if let postprocess {
            try container.encode(postprocess, forKey: .postprocess)
        }
    }
}

public struct InputAudio: Codable, Equatable, Sendable {
    public var fileName: String
    public var sha256: String
    public var sizeBytes: Int

    public init(fileName: String, sha256: String, sizeBytes: Int) {
        self.fileName = fileName
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    enum CodingKeys: String, CodingKey {
        case fileName = "file_name"
        case sha256
        case sizeBytes = "size_bytes"
    }
}

public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var language: String?
    public var asrModel: ModelDescriptor
    public var diarizationModel: ModelDescriptor?

    public init(name: String, language: String? = nil, asrModel: ModelDescriptor, diarizationModel: ModelDescriptor? = nil) {
        self.name = name
        self.language = language
        self.asrModel = asrModel
        self.diarizationModel = diarizationModel
    }

    enum CodingKeys: String, CodingKey {
        case name, language
        case asrModel = "asr_model"
        case diarizationModel = "diarization_model"
    }
}
