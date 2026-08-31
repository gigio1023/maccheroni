@preconcurrency import AVFoundation
import CryptoKit
import Darwin
import Foundation
import MaccheroniCore

struct RuntimePayloadFile: Sendable {
    let relativePath: String
    let sha256: String
}

struct RuntimePayloadPin: Sendable {
    let files: [RuntimePayloadFile]
    let treeSHA256: String
}

private let community1HarnessRuntimePayload = RuntimePayloadPin(
    files: [
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
    ],
    treeSHA256: "74247105450a08414a71ef5d512a52b706a7c23ac61efdcef051f4e44fae237a"
)

/// Runtime properties that the profile registry and `maccheroni doctor` can inspect
/// without knowing a diarizer's implementation details.
public struct DiarizerCapabilities: Equatable, Sendable {
    public let processesWholeFile: Bool
    public let supportsSpeakerCountRange: Bool

    public init(processesWholeFile: Bool, supportsSpeakerCountRange: Bool) {
        self.processesWholeFile = processesWholeFile
        self.supportsSpeakerCountRange = supportsSpeakerCountRange
    }
}

/// A bounded terminal timestamp adjustment made while converting a backend's
/// raw timeline to the common contract. The raw JSON stays available unchanged
/// through `DiarizationTimelineResult.rawJSON` for manifest/artifact handling.
public struct DiarizationNormalizationWarning: Equatable, Sendable {
    public let segmentIndex: Int
    public let rawEndS: Double
    public let normalizedEndS: Double
    public let deltaS: Double

    public init(segmentIndex: Int, rawEndS: Double, normalizedEndS: Double, deltaS: Double) {
        self.segmentIndex = segmentIndex
        self.rawEndS = rawEndS
        self.normalizedEndS = normalizedEndS
        self.deltaS = deltaS
    }
}

/// Backend evidence kept separate from the normalized common `Timeline`.
/// `rawJSON` is the exact JSON byte range emitted by the backend, without a
/// decode/encode round trip.
public struct DiarizationTimelineResult: Sendable {
    public let timeline: Timeline
    public let rawJSON: Data
    public let normalizationWarnings: [DiarizationNormalizationWarning]

    public init(
        timeline: Timeline,
        rawJSON: Data,
        normalizationWarnings: [DiarizationNormalizationWarning]
    ) {
        self.timeline = timeline
        self.rawJSON = rawJSON
        self.normalizationWarnings = normalizationWarnings
    }
}

public enum DiarizationError: Error, Equatable, LocalizedError, Sendable {
    case inputMissing(String)
    case inputUnreadable(String)
    case invalidSpeakerCountHint(Int, Int)
    case unsupportedSpeakerCountHint
    case executableMissing(String)
    case modelMissing(String)
    case modelMismatch(expected: String, actual: String)
    case processFailed(exitCode: Int32, standardError: String)
    case timedOut(seconds: Double)
    case missingOutput
    case invalidJSON(String)
    case invalidOutput(String)
    case outputOutOfRange(segment: Int, startS: Double, endS: Double, durationS: Double)
    case truncatedCoverage(expectedDurationS: Double, reportedDurationS: Double)
    case coverageShortfall(expectedDurationS: Double, finalSegmentEndS: Double)
    case outputPathAlreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case let .inputMissing(path):
            return "input audio is missing: \(path)"
        case let .inputUnreadable(path):
            return "input audio cannot be read: \(path)"
        case let .invalidSpeakerCountHint(lower, upper):
            return "speaker count hint must be positive: \(lower)...\(upper)"
        case .unsupportedSpeakerCountHint:
            return "this diarizer does not support a speaker count hint"
        case let .executableMissing(path):
            return "diarization executable is missing or not executable: \(path)"
        case let .modelMissing(path):
            return "required exact model snapshot is missing: \(path)"
        case let .modelMismatch(expected, actual):
            return "model identity mismatch; expected \(expected), got \(actual)"
        case let .processFailed(exitCode, standardError):
            return "diarization process failed with exit \(exitCode): \(standardError)"
        case let .timedOut(seconds):
            return "diarization process exceeded \(seconds) seconds"
        case .missingOutput:
            return "diarization process finished without JSON output"
        case let .invalidJSON(message):
            return "diarization JSON is invalid: \(message)"
        case let .invalidOutput(message):
            return "diarization output is invalid: \(message)"
        case let .outputOutOfRange(segment, startS, endS, durationS):
            return "segment \(segment) [\(startS), \(endS)) is outside input duration \(durationS)"
        case let .truncatedCoverage(expected, reported):
            return "backend reports \(reported) seconds for \(expected)-second input"
        case let .coverageShortfall(expected, finalEnd):
            return "backend timeline ends at \(finalEnd) seconds for \(expected)-second input"
        case let .outputPathAlreadyExists(path):
            return "refusing to overwrite diarization output: \(path)"
        }
    }
}

public struct Community1DiarizerConfiguration: Sendable {
    public var executableURL: URL
    public var hfHomeURL: URL
    /// When set, `executableURL` is the pinned local harness and this exact
    /// Community-1 repository root is passed through `--cache-dir`.
    public var harnessModelRepositoryURL: URL?
    public var timeoutS: Double
    /// Community-1 reports frame-quantized boundaries. Values farther than this
    /// outside the input are treated as data loss rather than normalized.
    public var timestampRoundingToleranceS: Double
    public var environment: [String: String]
    public var validatesPinnedModel: Bool

    public init(
        executableURL: URL = Self.defaultExecutableURL,
        hfHomeURL: URL = Self.defaultHFHomeURL,
        harnessModelRepositoryURL: URL? = nil,
        timeoutS: Double = 3_600,
        timestampRoundingToleranceS: Double = 0.1,
        environment: [String: String] = [:],
        validatesPinnedModel: Bool = true
    ) {
        self.executableURL = executableURL
        self.hfHomeURL = hfHomeURL
        self.harnessModelRepositoryURL = harnessModelRepositoryURL
        self.timeoutS = timeoutS
        self.timestampRoundingToleranceS = timestampRoundingToleranceS
        self.environment = environment
        self.validatesPinnedModel = validatesPinnedModel
    }

    public static var defaultExecutableURL: URL {
        if let override = ProcessInfo.processInfo.environment["MACCHERONI_COMMUNITY1_EXECUTABLE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/speech")
    }

    public static var defaultHFHomeURL: URL {
        resolveHFHomeURL()
    }

    public static func resolveHFHomeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["MACCHERONI_HF_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library/Caches/Maccheroni/benchmarks/models/huggingface", isDirectory: true)
    }
}

public enum DiarizationWorkspace {
    public static func processCaptureRootURL(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL {
        temporaryDirectory.appendingPathComponent(
            "Maccheroni/diarization/process",
            isDirectory: true
        )
    }
}

public struct FluidAudioDiarizerConfiguration: Sendable {
    public var executableURL: URL
    public var modelsRootURL: URL
    public var outputRootURL: URL
    public var timeoutS: Double
    public var environment: [String: String]
    public var validatesPinnedModel: Bool

    public init(
        executableURL: URL = Self.defaultExecutableURL,
        modelsRootURL: URL = Self.defaultModelsRootURL,
        outputRootURL: URL = Self.defaultOutputRootURL,
        timeoutS: Double = 3_600,
        environment: [String: String] = [:],
        validatesPinnedModel: Bool = true
    ) {
        self.executableURL = executableURL
        self.modelsRootURL = modelsRootURL
        self.outputRootURL = outputRootURL
        self.timeoutS = timeoutS
        self.environment = environment
        self.validatesPinnedModel = validatesPinnedModel
    }

    public static var defaultExecutableURL: URL {
        if let override = ProcessInfo.processInfo.environment["MACCHERONI_FLUID_DIARIZATION_EXECUTABLE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/Maccheroni/benchmarks/swift-scratch/fluid-diarization-harness/arm64-apple-macosx/debug/MaccheroniFluidDiarizationHarness"
            )
    }

    public static var defaultModelsRootURL: URL {
        if let override = ProcessInfo.processInfo.environment["MACCHERONI_FLUID_DIARIZATION_MODELS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Caches/Maccheroni/benchmarks/models/fluid-audio/diarization-\(FluidAudioDiarizer.modelRevision)",
                isDirectory: true
            )
    }

    public static var defaultOutputRootURL: URL {
        if let override = ProcessInfo.processInfo.environment["MACCHERONI_DIARIZATION_OUTPUT_CACHE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("Maccheroni/diarization", isDirectory: true)
    }
}

/// Default whole-file CoreML diarizer selected by the T7 benchmark verdict.
public struct Community1Diarizer: DiarizerBackend {
    public static let modelID = "aufklarer/Pyannote-Community-1-CoreML"
    public static let modelRevision = "a14e6c420d56e8472850649b016a486fd0acbe81"
    public static let modelQuantization = "coreml-fp32"

    public let configuration: Community1DiarizerConfiguration
    public let descriptor = BackendDescriptor(name: "speech-swift-cli", version: "0.0.23")
    public let model = ModelDescriptor(
        role: .diarization,
        hfModelID: Community1Diarizer.modelID,
        revision: Community1Diarizer.modelRevision,
        quantization: Community1Diarizer.modelQuantization
    )
    public let capabilities = DiarizerCapabilities(
        processesWholeFile: true,
        supportsSpeakerCountRange: true
    )
    private let harnessRuntimePayload: RuntimePayloadPin

    public init(configuration: Community1DiarizerConfiguration = .init()) {
        self.configuration = configuration
        self.harnessRuntimePayload = community1HarnessRuntimePayload
    }

    init(testing configuration: Community1DiarizerConfiguration, harnessRuntimePayload: RuntimePayloadPin) {
        self.configuration = configuration
        self.harnessRuntimePayload = harnessRuntimePayload
    }

    public func diarize(_ request: DiarizationRequest) async throws -> Timeline {
        try await diarizeWithEvidence(request).timeline
    }

    public func diarizeWithEvidence(_ request: DiarizationRequest) async throws -> DiarizationTimelineResult {
        try validateInput(request.audioURL)
        try validateSpeakerHint(request.speakerCountHint)
        try validateExecutable(configuration.executableURL)
        if let repositoryURL = configuration.harnessModelRepositoryURL {
            try validateCommunity1HarnessModel(
                at: repositoryURL,
                expected: harnessRuntimePayload
            )
        } else if configuration.validatesPinnedModel {
            try validateCommunity1Model(in: configuration.hfHomeURL)
        }

        let duration = try audioDuration(request.audioURL)
        var arguments: [String]
        if let repositoryURL = configuration.harnessModelRepositoryURL {
            arguments = [
                "diarize", request.audioURL.path,
                "--cache-dir", repositoryURL.path,
                "--json",
            ]
        } else {
            arguments = ["diarize", request.audioURL.path, "--engine", "community1", "--json"]
        }
        if let hint = request.speakerCountHint {
            if hint.lowerBound == hint.upperBound {
                arguments += ["--num-speakers", String(hint.lowerBound)]
            } else {
                arguments += ["--min-speakers", String(hint.lowerBound)]
                arguments += ["--max-speakers", String(hint.upperBound)]
            }
        }
        var environment = configuration.environment
        if configuration.harnessModelRepositoryURL == nil {
            environment["HF_HOME"] = configuration.hfHomeURL.path
        }
        let output = try runProcess(
            executableURL: configuration.executableURL,
            arguments: arguments,
            environment: environment,
            timeoutS: configuration.timeoutS
        )
        let decoded: JSONOutput<Community1Output> = try decodeJSONOutput(output)
        let normalized = try normalizedTimeline(
            decoded.value.segments.map { .init(speaker: $0.speaker, startS: $0.startS, endS: $0.endS, confidence: nil) },
            durationS: duration,
            terminalRoundingToleranceS: configuration.timestampRoundingToleranceS,
            requiresTerminalCoverage: false
        )
        return DiarizationTimelineResult(
            timeline: normalized.timeline,
            rawJSON: decoded.rawJSON,
            normalizationWarnings: normalized.warnings
        )
    }
}

/// Explicit offline CoreML fallback. It uses the benchmark's pinned harness,
/// which loads the exact local model tree with FluidAudio offline mode enabled.
public struct FluidAudioDiarizer: DiarizerBackend {
    public static let modelID = "FluidInference/speaker-diarization-coreml"
    public static let modelRevision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"
    public static let modelQuantization = "coreml-fp32+fp16"

    public let configuration: FluidAudioDiarizerConfiguration
    public let descriptor = BackendDescriptor(
        name: "fluid-audio-offline",
        version: "5390df9752c8fc583596018360c5fd70d6fa6c75"
    )
    public let model = ModelDescriptor(
        role: .diarization,
        hfModelID: FluidAudioDiarizer.modelID,
        revision: FluidAudioDiarizer.modelRevision,
        quantization: FluidAudioDiarizer.modelQuantization
    )
    public let capabilities = DiarizerCapabilities(
        processesWholeFile: true,
        supportsSpeakerCountRange: false
    )

    public init(configuration: FluidAudioDiarizerConfiguration = .init()) {
        self.configuration = configuration
    }

    public func diarize(_ request: DiarizationRequest) async throws -> Timeline {
        try await diarizeWithEvidence(request).timeline
    }

    public func diarizeWithEvidence(_ request: DiarizationRequest) async throws -> DiarizationTimelineResult {
        try validateInput(request.audioURL)
        if request.speakerCountHint != nil {
            throw DiarizationError.unsupportedSpeakerCountHint
        }
        try validateExecutable(configuration.executableURL)
        if configuration.validatesPinnedModel {
            try validateFluidAudioModel(at: configuration.modelsRootURL)
        }
        let duration = try audioDuration(request.audioURL)
        let outputURL = try freshFluidOutputURL(in: configuration.outputRootURL)
        _ = try runProcess(
            executableURL: configuration.executableURL,
            arguments: [
                "--audio", request.audioURL.path,
                "--models-root", configuration.modelsRootURL.path,
                "--output", outputURL.path,
            ],
            environment: configuration.environment,
            timeoutS: configuration.timeoutS
        )
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw DiarizationError.missingOutput
        }
        let payload: FluidAudioOutput
        do {
            payload = try JSONDecoder().decode(FluidAudioOutput.self, from: Data(contentsOf: outputURL))
        } catch {
            throw DiarizationError.invalidJSON(error.localizedDescription)
        }
        try validateFluidIdentity(payload.model)
        guard abs(payload.audio.durationS - duration) <= 0.01 else {
            throw DiarizationError.truncatedCoverage(
                expectedDurationS: duration,
                reportedDurationS: payload.audio.durationS
            )
        }
        let normalized = try normalizedTimeline(
            payload.segments.map {
                .init(
                    speaker: $0.speaker,
                    startS: $0.rawStartS ?? $0.startS,
                    endS: $0.rawEndS ?? $0.endS,
                    confidence: $0.qualityScore
                )
            },
            durationS: duration,
            terminalRoundingToleranceS: 0,
            requiresTerminalCoverage: false
        )
        return DiarizationTimelineResult(
            timeline: normalized.timeline,
            rawJSON: try Data(contentsOf: outputURL),
            normalizationWarnings: normalized.warnings
        )
    }
}

private struct Community1Output: Decodable {
    let segments: [Community1Segment]
}

private struct Community1Segment: Decodable {
    let speaker: String
    let startS: Double
    let endS: Double

    enum CodingKeys: String, CodingKey {
        case speaker
        case startS = "start"
        case endS = "end"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(String.self, forKey: .speaker) {
            speaker = value
        } else if let value = try? container.decode(Int.self, forKey: .speaker) {
            speaker = String(value)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: container.codingPath, debugDescription: "speaker must be a string or integer")
            )
        }
        startS = try container.decode(Double.self, forKey: .startS)
        endS = try container.decode(Double.self, forKey: .endS)
    }
}

private struct FluidAudioOutput: Decodable {
    struct Model: Decodable {
        let hfID: String
        let revision: String
        let quantization: String

        enum CodingKeys: String, CodingKey {
            case hfID = "hf_id"
            case revision, quantization
        }
    }

    struct Audio: Decodable {
        let durationS: Double

        enum CodingKeys: String, CodingKey {
            case durationS = "duration_s"
        }
    }

    struct Segment: Decodable {
        let speaker: String
        let startS: Double
        let endS: Double
        let rawStartS: Double?
        let rawEndS: Double?
        let qualityScore: Double?

        enum CodingKeys: String, CodingKey {
            case speaker
            case startS = "start_s"
            case endS = "end_s"
            case rawStartS = "raw_start_s"
            case rawEndS = "raw_end_s"
            case qualityScore = "quality_score"
        }
    }

    let model: Model
    let audio: Audio
    let segments: [Segment]
}

private struct RawTimelineSegment {
    let speaker: String
    let startS: Double
    let endS: Double
    let confidence: Double?
}

private struct NormalizedTimeline {
    let timeline: Timeline
    let warnings: [DiarizationNormalizationWarning]
}

private func validateInput(_ audioURL: URL) throws {
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
        throw DiarizationError.inputMissing(audioURL.path)
    }
}

private func validateSpeakerHint(_ hint: ClosedRange<Int>?) throws {
    guard let hint else { return }
    guard hint.lowerBound > 0, hint.upperBound > 0 else {
        throw DiarizationError.invalidSpeakerCountHint(hint.lowerBound, hint.upperBound)
    }
}

private func validateExecutable(_ executableURL: URL) throws {
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw DiarizationError.executableMissing(executableURL.path)
    }
}

private func validateCommunity1Model(in hfHomeURL: URL) throws {
    let repository = hfHomeURL
        .appendingPathComponent("hub/models--aufklarer--Pyannote-Community-1-CoreML", isDirectory: true)
    let snapshot = repository
        .appendingPathComponent("snapshots", isDirectory: true)
        .appendingPathComponent(Community1Diarizer.modelRevision, isDirectory: true)
    guard FileManager.default.fileExists(atPath: snapshot.path) else {
        throw DiarizationError.modelMissing(snapshot.path)
    }
    let reference = repository.appendingPathComponent("refs/main")
    guard let value = try? String(contentsOf: reference, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else {
        throw DiarizationError.modelMissing(reference.path)
    }
    guard value == Community1Diarizer.modelRevision else {
        throw DiarizationError.modelMismatch(
            expected: "\(Community1Diarizer.modelID)@\(Community1Diarizer.modelRevision)",
            actual: "\(Community1Diarizer.modelID)@\(value)"
        )
    }
}

private func validateCommunity1HarnessModel(
    at repositoryURL: URL,
    expected: RuntimePayloadPin
) throws {
    var treeHasher = SHA256()
    for expectedFile in expected.files {
        let file = repositoryURL.appendingPathComponent(expectedFile.relativePath)
        let values: URLResourceValues
        do {
            values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw DiarizationError.modelMissing(file.path)
        }
        guard values.isRegularFile == true,
                values.isSymbolicLink != true else {
            throw DiarizationError.modelMissing(file.path)
        }

        let name = Data(expectedFile.relativePath.utf8)
        var nameLength = UInt32(name.count).bigEndian
        withUnsafeBytes(of: &nameLength) {
            treeHasher.update(data: Data($0))
        }
        treeHasher.update(data: name)

        var fileHasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            fileHasher.update(data: data)
            treeHasher.update(data: data)
        }
        guard hexDigest(fileHasher.finalize()) == expectedFile.sha256 else {
            throw community1PayloadMismatch()
        }
    }
    guard hexDigest(treeHasher.finalize()) == expected.treeSHA256 else {
        throw community1PayloadMismatch()
    }
}

private func community1PayloadMismatch() -> DiarizationError {
    .modelMismatch(
        expected: "\(Community1Diarizer.modelID)@\(Community1Diarizer.modelRevision)",
        actual: "local runtime payload"
    )
}

private func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func validateFluidAudioModel(at modelsRootURL: URL) throws {
    let modelDirectory = modelsRootURL.appendingPathComponent("speaker-diarization", isDirectory: true)
    guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
        throw DiarizationError.modelMissing(modelDirectory.path)
    }
    for name in ["Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json"] {
        let required = modelDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: required.path) else {
            throw DiarizationError.modelMissing(required.path)
        }
    }
    let evidence = try fluidModelTreeEvidence(at: modelDirectory)
    guard evidence.fileCount == 21 else {
        throw DiarizationError.modelMismatch(
            expected: "FluidAudio pinned model tree with 21 files",
            actual: "FluidAudio model tree with \(evidence.fileCount) files"
        )
    }
    guard evidence.sha256 == "4ed93bd29ff9d4a3b25fe2e7ad01d8cfc31f1b2acad2165dccb0d2f6a7f189b5" else {
        throw DiarizationError.modelMismatch(
            expected: "FluidInference/speaker-diarization-coreml@\(FluidAudioDiarizer.modelRevision) tree 4ed93bd29ff9d4a3b25fe2e7ad01d8cfc31f1b2acad2165dccb0d2f6a7f189b5",
            actual: evidence.sha256
        )
    }
}

private func fluidModelTreeEvidence(at root: URL) throws -> (sha256: String, fileCount: Int) {
    let requiredNames = [
        "Segmentation.mlmodelc",
        "FBank.mlmodelc",
        "Embedding.mlmodelc",
        "PldaRho.mlmodelc",
        "plda-parameters.json",
    ]
    var files: [URL] = []
    for name in requiredNames {
        let entry = root.appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory) else {
            throw DiarizationError.modelMissing(entry.path)
        }
        if isDirectory.boolValue {
            guard let enumerator = FileManager.default.enumerator(
                at: entry,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                throw DiarizationError.modelMissing(entry.path)
            }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true { files.append(file) }
            }
        } else {
            files.append(entry)
        }
    }
    files.sort { lhs, rhs in
        lhs.path.replacingOccurrences(of: root.path + "/", with: "")
            < rhs.path.replacingOccurrences(of: root.path + "/", with: "")
    }
    var hasher = SHA256()
    for file in files {
        let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
        let nameData = Data(relative.utf8)
        var length = UInt32(nameData.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
        hasher.update(data: nameData)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
    }
    return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), files.count)
}

private func validateFluidIdentity(_ model: FluidAudioOutput.Model) throws {
    guard model.hfID == FluidAudioDiarizer.modelID else {
        throw DiarizationError.modelMismatch(
            expected: FluidAudioDiarizer.modelID,
            actual: model.hfID
        )
    }
    guard model.revision == FluidAudioDiarizer.modelRevision else {
        throw DiarizationError.modelMismatch(
            expected: FluidAudioDiarizer.modelRevision,
            actual: model.revision
        )
    }
    let normalized = model.quantization.lowercased()
    guard normalized.contains("float32"), normalized.contains("float16") else {
        throw DiarizationError.modelMismatch(
            expected: FluidAudioDiarizer.modelQuantization,
            actual: model.quantization
        )
    }
}

private func audioDuration(_ audioURL: URL) throws -> Double {
    do {
        let audio = try AVAudioFile(forReading: audioURL)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else {
            throw DiarizationError.inputUnreadable(audioURL.path)
        }
        return duration
    } catch let error as DiarizationError {
        throw error
    } catch {
        throw DiarizationError.inputUnreadable(audioURL.path)
    }
}

private func normalizedTimeline(
    _ rawSegments: [RawTimelineSegment],
    durationS: Double,
    terminalRoundingToleranceS: Double,
    requiresTerminalCoverage: Bool
) throws -> NormalizedTimeline {
    guard durationS.isFinite, durationS > 0, terminalRoundingToleranceS >= 0 else {
        throw DiarizationError.invalidOutput("invalid input duration or timestamp tolerance")
    }
    guard !rawSegments.isEmpty else {
        throw DiarizationError.invalidOutput("timeline has no segments")
    }
    var normalized: [TimelineSegment] = []
    normalized.reserveCapacity(rawSegments.count)
    var warnings: [DiarizationNormalizationWarning] = []
    for (index, segment) in rawSegments.enumerated() {
        guard !segment.speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiarizationError.invalidOutput("segment \(index) has no speaker")
        }
        guard segment.startS.isFinite, segment.endS.isFinite, segment.endS > segment.startS else {
            throw DiarizationError.invalidOutput("segment \(index) has invalid interval")
        }
        if index > 0 {
            let previous = rawSegments[index - 1]
            guard segment.startS > previous.startS || (
                segment.startS == previous.startS && segment.endS >= previous.endS
            ) else {
                throw DiarizationError.invalidOutput("segment \(index) is not ordered after segment \(index - 1)")
            }
        }
        guard segment.startS >= 0 else {
            throw DiarizationError.outputOutOfRange(
                segment: index,
                startS: segment.startS,
                endS: segment.endS,
                durationS: durationS
            )
        }
        var end = segment.endS
        if segment.endS > durationS {
            let delta = segment.endS - durationS
            guard index == rawSegments.indices.last, delta <= terminalRoundingToleranceS else {
                throw DiarizationError.outputOutOfRange(
                    segment: index,
                    startS: segment.startS,
                    endS: segment.endS,
                    durationS: durationS
                )
            }
            end = durationS
            warnings.append(DiarizationNormalizationWarning(
                segmentIndex: index,
                rawEndS: segment.endS,
                normalizedEndS: end,
                deltaS: delta
            ))
        }
        if let confidence = segment.confidence, !confidence.isFinite || !(0...1).contains(confidence) {
            throw DiarizationError.invalidOutput("segment \(index) has invalid confidence")
        }
        let start = segment.startS
        guard end > start else {
            throw DiarizationError.outputOutOfRange(
                segment: index,
                startS: segment.startS,
                endS: segment.endS,
                durationS: durationS
            )
        }
        normalized.append(TimelineSegment(
            speaker: segment.speaker,
            startS: start,
            endS: end,
            confidence: segment.confidence
        ))
    }
    if requiresTerminalCoverage, let finalEnd = normalized.last?.endS, finalEnd < durationS - 0.01 {
        throw DiarizationError.coverageShortfall(
            expectedDurationS: durationS,
            finalSegmentEndS: finalEnd
        )
    }
    return NormalizedTimeline(timeline: Timeline(segments: normalized), warnings: warnings)
}

private func freshFluidOutputURL(in root: URL) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let output = root.appendingPathComponent("fluid-diarization-\(UUID().uuidString.lowercased()).json")
    guard !FileManager.default.fileExists(atPath: output.path) else {
        throw DiarizationError.outputPathAlreadyExists(output.path)
    }
    return output
}

private func runProcess(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeoutS: Double
) throws -> Data {
    guard timeoutS > 0, timeoutS.isFinite else {
        throw DiarizationError.invalidOutput("timeout must be a positive finite duration")
    }
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment { mergedEnvironment[key] = value }
    process.environment = mergedEnvironment
    let outputDirectory = DiarizationWorkspace.processCaptureRootURL()
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let outputURL = outputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).stdout")
    let errorURL = outputDirectory.appendingPathComponent("\(UUID().uuidString.lowercased()).stderr")
    guard !FileManager.default.fileExists(atPath: outputURL.path), !FileManager.default.fileExists(atPath: errorURL.path) else {
        throw DiarizationError.outputPathAlreadyExists(outputDirectory.path)
    }
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    else {
        throw DiarizationError.invalidOutput("could not create fresh process capture files")
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: errorURL.path)
    let standardOutput: FileHandle
    let standardError: FileHandle
    do {
        standardOutput = try FileHandle(forWritingTo: outputURL)
        standardError = try FileHandle(forWritingTo: errorURL)
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: errorURL)
        throw DiarizationError.invalidOutput("could not open fresh process capture files")
    }
    var capturesClosed = false
    func closeCaptures() throws {
        guard !capturesClosed else { return }
        try standardOutput.close()
        try standardError.close()
        capturesClosed = true
    }
    defer {
        try? closeCaptures()
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: errorURL)
    }
    process.standardOutput = standardOutput
    process.standardError = standardError
    do {
        try process.run()
    } catch {
        throw DiarizationError.executableMissing(executableURL.path)
    }
    let deadline = Date().addingTimeInterval(timeoutS)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        process.terminate()
        let termGraceDeadline = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < termGraceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            let killGraceDeadline = Date().addingTimeInterval(0.2)
            while process.isRunning, Date() < killGraceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw DiarizationError.timedOut(seconds: timeoutS)
    }
    try closeCaptures()
    let output = try Data(contentsOf: outputURL)
    guard process.terminationStatus == 0 else {
        throw DiarizationError.processFailed(
            exitCode: process.terminationStatus,
            standardError: "diagnostic unavailable"
        )
    }
    return output
}

private struct JSONOutput<T> {
    let value: T
    let rawJSON: Data
}

private func decodeJSONOutput<T: Decodable>(_ output: Data) throws -> JSONOutput<T> {
    guard !output.isEmpty, let text = String(data: output, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DiarizationError.missingOutput
    }
    let starts = output.indices.filter { output[$0] == UInt8(ascii: "{") }
    guard !starts.isEmpty else {
        throw DiarizationError.invalidJSON("no JSON object in standard output")
    }
    for start in starts {
        let rawJSON = Data(output[start...])
        do {
            return JSONOutput(value: try JSONDecoder().decode(T.self, from: rawJSON), rawJSON: rawJSON)
        } catch {
            continue
        }
    }
    throw DiarizationError.invalidJSON("no decodable JSON object in standard output")
}
