import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess

enum AppProfileID: String, Codable, CaseIterable, Identifiable, Sendable {
    case koreanITMeeting = "ko-it-meeting"
    case italianDialogue = "it-dialogue"
    case englishMeeting = "en-meeting"
    case automatic

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .koreanITMeeting: appLocalized("Korean IT Meeting")
        case .italianDialogue: appLocalized("Italian Dialogue")
        case .englishMeeting: appLocalized("English Meeting")
        case .automatic: appLocalized("Automatic")
        }
    }
}

enum PostprocessChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case local
    case none

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .codex: appLocalized("Codex")
        case .local: appLocalized("Local")
        case .none: appLocalized("None")
        }
    }

    var requestedModelID: String? {
        switch self {
        case .codex:
            CodexPostprocessBackend.modelName
        case .local:
            LocalPostprocessBackend.pinnedModel.hfModelID
        case .none:
            nil
        }
    }
}

enum PostprocessOperationChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case correction
    case translation

    var id: String { rawValue }
    var mode: PostprocessMode { PostprocessMode(rawValue: rawValue) ?? .correction }

    init(_ mode: PostprocessMode) {
        self = PostprocessOperationChoice(rawValue: mode.rawValue) ?? .correction
    }

    var title: LocalizedStringResource {
        switch self {
        case .correction: appLocalized("Correct")
        case .translation: appLocalized("Translate")
        }
    }
}

struct BenchmarkMetric: Codable, Equatable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var value: Double
    var display: String
}

struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    var id: AppProfileID
    var cliProfile: String
    var asrBackend: String
    var languagePin: String
    var diarizationBackend: String
    var languageCoverage: [String]
    var models: [ModelDescriptor]
    var benchmarkSource: String?
    var metrics: [BenchmarkMetric]
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case korean = "ko"
    case italian = "it"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case portuguese = "pt"
    case russian = "ru"
    case system

    var id: String { rawValue }

    static var translationTargets: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    var title: LocalizedStringResource {
        switch self {
        case .english: appLocalized("English")
        case .korean: appLocalized("Korean")
        case .italian: appLocalized("Italian")
        case .japanese: appLocalized("Japanese")
        case .simplifiedChinese: appLocalized("Chinese, Simplified")
        case .spanish: appLocalized("Spanish")
        case .french: appLocalized("French")
        case .german: appLocalized("German")
        case .portuguese: appLocalized("Portuguese")
        case .russian: appLocalized("Russian")
        case .system: appLocalized("Use System Language")
        }
    }
}

struct ProfileRegistryDocument: Codable, Equatable, Sendable {
    var schemaVersion: String
    var profiles: [AppProfile]

    enum CodingKeys: String, CodingKey {
        case profiles
        case schemaVersion = "schema_version"
    }
}

enum LibraryItemState: String, Codable, Sendable {
    case recorded
    case transcribing
    case done
    case hasConflicts = "has-conflicts"
    case failed
    case cancelled
    case interrupted

    var title: LocalizedStringResource {
        switch self {
        case .recorded: appLocalized("Recorded")
        case .transcribing: appLocalized("Transcribing")
        case .done: appLocalized("Done")
        case .hasConflicts: appLocalized("Has Conflicts")
        case .failed: appLocalized("Failed")
        case .cancelled: appLocalized("Cancelled")
        case .interrupted: appLocalized("Interrupted")
        }
    }

    func localizedTitle(locale: Locale? = nil) -> String {
        switch self {
        case .recorded: appString("Recorded", locale: locale)
        case .transcribing: appString("Transcribing", locale: locale)
        case .done: appString("Done", locale: locale)
        case .hasConflicts: appString("Has Conflicts", locale: locale)
        case .failed: appString("Failed", locale: locale)
        case .cancelled: appString("Cancelled", locale: locale)
        case .interrupted: appString("Interrupted", locale: locale)
        }
    }
}

enum LibrarySourceKind: String, Codable, Sendable {
    case importedFile = "imported-file"
    case appRecording = "app-recording"
}

struct LibraryRecord: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var displayName: String
    var sourceKind: LibrarySourceKind
    var sourceURL: URL
    var securityScopedBookmark: Data?
    var microphoneURL: URL?
    var systemAudioURL: URL?
    var runURL: URL?
    var profileID: AppProfileID
    var postprocess: PostprocessChoice
    var postprocessMode: PostprocessMode? = nil
    var translationTargetLanguage: String? = nil
    var durationS: Double
    var state: LibraryItemState
    var speakerNames: [String: String]
    var conflictResolutions: [Int: String]
    var failureMessage: String?
}

struct LoadedRun: Equatable, Sendable {
    var manifest: Manifest
    var transcript: SegmentsDocument
    var conflicts: [MergeConflict]
    var segments: [TranscriptSegment]

    var requiresReview: Bool {
        !conflicts.isEmpty || transcript.segments.contains { segment in
            let flags = segment.flags ?? []
            return flags.contains("uncertain") || flags.contains("conflict")
        }
    }
}

struct TranscriptSegmentID: Hashable, Sendable {
    var runID: String
    var index: Int
}

struct TranscriptSegment: Equatable, Identifiable, Sendable {
    var id: TranscriptSegmentID
    var index: Int
    var segment: Segment
    var conflict: MergeConflict?
}

enum AppSelection: Hashable, Sendable {
    case capture
    case record(UUID)
}

enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case segmentsJSON = "segments.json"
    case markdown = "markdown"
    case srt = "srt"

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .segmentsJSON: appLocalized("Segments JSON")
        case .markdown: appLocalized("Markdown")
        case .srt: appLocalized("SRT Subtitles")
        }
    }
}

enum PipelineStage: String, Codable, CaseIterable, Sendable {
    case preparing
    case preprocessing
    case diarization
    case asr
    case merge
    case postprocess
    case complete
    case cancelled
    case failed

    var title: LocalizedStringResource {
        switch self {
        case .preparing: appLocalized("Preparing")
        case .preprocessing: appLocalized("Preprocessing")
        case .diarization: appLocalized("Speaker Diarization")
        case .asr: appLocalized("Transcription")
        case .merge: appLocalized("Merging")
        case .postprocess: appLocalized("Post-processing")
        case .complete: appLocalized("Complete")
        case .cancelled: appLocalized("Cancelled")
        case .failed: appLocalized("Failed")
        }
    }
}

struct RunProgressSnapshot: Equatable, Sendable {
    var stage: PipelineStage
    var completedChunks: Int
    var plannedChunks: Int
    var elapsedS: Double
    var stageElapsedS: [PipelineStage: Double]
    var modelID: String?
    /// True while `modelID` is the requested post-processing model rather than
    /// the model the completed manifest reports. The run may still fall back to
    /// a different backend, so the label must not claim this model is in use.
    var modelIDIsProvisional: Bool
    var message: String?
    var runURL: URL?

    init(
        stage: PipelineStage,
        completedChunks: Int,
        plannedChunks: Int,
        elapsedS: Double,
        stageElapsedS: [PipelineStage: Double] = [:],
        modelID: String?,
        modelIDIsProvisional: Bool = false,
        message: String?,
        runURL: URL?
    ) {
        self.stage = stage
        self.completedChunks = completedChunks
        self.plannedChunks = plannedChunks
        self.elapsedS = elapsedS
        self.stageElapsedS = stageElapsedS
        self.modelID = modelID
        self.modelIDIsProvisional = modelIDIsProvisional
        self.message = message
        self.runURL = runURL
    }

    /// Label for `modelID`. A provisional value names the model the run was
    /// asked for, which the pipeline may still replace, so it is never labelled
    /// as the model currently in use.
    func modelLabel(locale: Locale? = nil) -> LocalizedStringResource {
        modelIDIsProvisional
            ? appLocalized("Planned Model", locale: locale)
            : appLocalized("Current Model", locale: locale)
    }

    struct ModelProjection: Equatable, Sendable {
        var modelID: String?
        var isProvisional: Bool

        static let unavailable = ModelProjection(modelID: nil, isProvisional: false)
    }

    static func modelProjection(
        for stage: PipelineStage,
        models: [ModelDescriptor],
        postprocess: ManifestPostprocess?,
        requestedPostprocessModelID: String? = nil
    ) -> ModelProjection {
        switch stage {
        case .preprocessing:
            return ModelProjection(
                modelID: models.first(where: { $0.role == .vad })?.hfModelID,
                isProvisional: false
            )
        case .diarization:
            return ModelProjection(
                modelID: models.first(where: { $0.role == .diarization })?.hfModelID,
                isProvisional: false
            )
        case .asr:
            return ModelProjection(
                modelID: models.first(where: { $0.role == .asr })?.hfModelID,
                isProvisional: false
            )
        case .postprocess:
            if let confirmed = postprocess?.modelID {
                return ModelProjection(modelID: confirmed, isProvisional: false)
            }
            return ModelProjection(
                modelID: requestedPostprocessModelID,
                isProvisional: requestedPostprocessModelID != nil
            )
        case .preparing, .merge, .complete, .cancelled, .failed:
            return .unavailable
        }
    }

    static func modelID(
        for stage: PipelineStage,
        models: [ModelDescriptor],
        postprocess: ManifestPostprocess?,
        requestedPostprocessModelID: String? = nil
    ) -> String? {
        modelProjection(
            for: stage,
            models: models,
            postprocess: postprocess,
            requestedPostprocessModelID: requestedPostprocessModelID
        ).modelID
    }
}

struct CaptureMeters: Equatable, Sendable {
    var microphone: Float
    var systemAudio: Float

    static let silent = CaptureMeters(microphone: 0, systemAudio: 0)
}

struct RecordingArtifacts: Equatable, Sendable {
    var directory: URL
    var microphoneURL: URL
    var systemAudioURL: URL
    var combinedURL: URL
    var startedAt: Date
    var stoppedAt: Date

    var durationS: Double { max(0, stoppedAt.timeIntervalSince(startedAt)) }
}

struct RecordingSessionMetadata: Equatable, Sendable {
    var directory: URL
    var microphoneURL: URL
    var systemAudioURL: URL
    var startedAt: Date
}

struct PreservedRecordingArtifacts: Equatable, Sendable {
    var directory: URL
    var microphoneURL: URL
    var systemAudioURL: URL
    var startedAt: Date
    var stoppedAt: Date

    var durationS: Double { max(0, stoppedAt.timeIntervalSince(startedAt)) }
}

struct TranscriptionRequest: Equatable, Sendable {
    var sourceURL: URL
    var outputRoot: URL
    var profile: AppProfile
    var postprocess: PostprocessChoice
    var postprocessMode: PostprocessMode = .correction
    var translationTargetLanguage: String? = nil
    var glossaryURL: URL?
}

@MainActor
protocol TranscriptionRunning: AnyObject {
    func run(
        _ request: TranscriptionRequest,
        progress: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL
    func cancel()
}

@MainActor
protocol RecordingControlling: AnyObject {
    var meters: CaptureMeters { get }
    func setMeterHandler(_ handler: (@MainActor (CaptureMeters) -> Void)?)
    func start(in outputRoot: URL) async throws -> RecordingSessionMetadata
    func stop() async throws -> RecordingArtifacts
    func cancel() async
}
