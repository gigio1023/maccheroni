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
    /// Correction decisions for create-only derived results. Legacy source-run
    /// decisions remain in `conflictResolutions` and are deliberately not
    /// reused by a newly derived result at the same segment index.
    var derivedCorrectionResolutions: [DerivedCorrectionResolution]? = nil
    /// Review acknowledgements are scoped to one immutable result and the
    /// exact translated text that the operator accepted. Keeping this optional
    /// preserves decoding of library indexes written before acknowledgements
    /// existed.
    var translationReviewAcknowledgements: [TranslationReviewAcknowledgement]? = nil
    var failureMessage: String?
    /// The engine request this record's latest run or post-processing went
    /// through, while its scratch directory still exists: the runner names
    /// that directory after this value (`EngineRequestScratch`).
    ///
    /// Written when the request is launched and cleared when it succeeds,
    /// because a succeeded request discards its scratch. A failed, cancelled or
    /// interrupted request keeps both, so the record can say where the
    /// engine's own account of the failure is, and a move to the Trash can
    /// take it along. Optional so indexes written before it decode.
    var requestID: UUID? = nil
}

struct DerivedCorrectionResolution: Codable, Equatable, Sendable {
    var resultID: String
    var segmentIndex: Int
    var resolvedText: String

    enum CodingKeys: String, CodingKey {
        case resultID = "result_id"
        case segmentIndex = "segment_index"
        case resolvedText = "resolved_text"
    }
}

struct TranslationReviewAcknowledgement: Codable, Equatable, Sendable {
    var resultID: String
    var segmentIndex: Int
    var translatedText: String

    enum CodingKeys: String, CodingKey {
        case resultID = "result_id"
        case segmentIndex = "segment_index"
        case translatedText = "translated_text"
    }
}

/// How many of the segments a speaker-proposal set examined it proposed a
/// speaker for, and how many it declined.
///
/// Counted once, while the set's own artifact is being verified, and carried on
/// the summary from there. The reading surface cannot recount them: only the
/// current member of the family is loaded as a document, so a second proposal
/// set would have no numbers at all if these were derived at display time.
struct SpeakerProposalCounts: Equatable, Sendable {
    var proposed: Int
    var declined: Int

    /// Every unattributed segment the set looked at, proposed or declined.
    var examined: Int { proposed + declined }
}

struct DerivedResultSummary: Equatable, Identifiable, Sendable {
    var id: String
    var createdAt: Date
    /// Which text operation the set recorded. Meaningful only when `kind` is
    /// `.textPostprocess`; a speaker-proposal manifest carries `.correction`
    /// here for a structural reason in the derived contract and corrected no
    /// text. Read `kind` first.
    var operation: PostprocessMode
    /// What family of derived set this is. Defaulted so every reader that
    /// predates the speaker-proposal family keeps compiling and keeps seeing
    /// what it always saw.
    var kind: DerivedOperationKind = .textPostprocess
    var targetLanguage: String?
    var glossarySHA256: String?
    var directory: URL
    var isCurrent: Bool
    /// The set's own proposal and decline counts when `kind` is
    /// `.speakerProposal`, `nil` otherwise. Two proposal sets of one run carry
    /// the same name, so this and `createdAt` are what tell them apart.
    var speakerProposalCounts: SpeakerProposalCounts? = nil
}

/// A derived set the app found beside a run, verified as far as it could, and
/// could not read.
///
/// It exists so that such a set is *rejected* rather than silently ignored,
/// while the source run still opens. Before this, an unrecognised derived
/// family made the source run itself fail to open, which is the failure mode
/// the speaker-proposal layer was built against.
struct UnreadableDerivedSet: Equatable, Identifiable, Sendable {
    /// Kept as data with no sentence of its own. Wording this for a reader
    /// means a new localized string in all ten locales, and those resources
    /// belong to the reading-surface tasks rather than to the loader.
    enum Reason: Equatable, Sendable {
        /// The manifest names a derived family this build does not know. The
        /// associated value is the raw `operation.kind` string as written.
        case unrecognisedKind(String)
        /// A speaker-proposal set whose artifact contradicts the source run it
        /// names: a decline cause the acoustic record does not support, a
        /// top-ranked candidate the candidates do not rank first, a model
        /// answer attached to another segment, evidence the run never
        /// measured, or coverage the run does not have.
        ///
        /// The bytes are the ones the manifest hashed, so this is the artifact
        /// being false rather than damaged, and it is recorded rather than
        /// thrown: the source run is immutable and readable whatever a derived
        /// set beside it claims.
        case speakerProposalContradictsSourceRun
    }

    /// The derived directory name, which is also the derived ID it claims.
    var id: String
    var reason: Reason
}

struct LoadedRun: Equatable, Sendable {
    var manifest: Manifest
    var transcript: SegmentsDocument
    var conflicts: [MergeConflict]
    var segments: [TranscriptSegment]
    /// The run's own merged transcript, kept when `transcript` is not it.
    ///
    /// A translation writes translated text over every segment and a
    /// correction replaces the document wholesale, and both used to throw the
    /// decoded source away. Keeping it means the acoustic, source-language
    /// record stays in memory beside the layer that replaced it instead of
    /// being reachable only by re-reading the run. `nil` when `transcript`
    /// already is the merged document; read `effectiveSourceTranscript`.
    var sourceTranscript: SegmentsDocument? = nil
    var resultID: String? = nil
    var derivedResults: [DerivedResultSummary] = []
    /// D46's marked non-acoustic speaker proposal, when a derived set carries
    /// one. Selected independently of the text result: a proposal changes no
    /// text, so it must not displace a correction or a translation.
    var speakerProposal: SpeakerProposalDocument? = nil
    /// Derived sets found beside this run that this build cannot read. The run
    /// still loads; these are recorded rather than dropped.
    var unreadableDerivedSets: [UnreadableDerivedSet] = []
    var resultPostprocess: ManifestPostprocess? = nil
    var resultOperation: DerivedOperation? = nil

    var effectiveResultID: String { resultID ?? manifest.runID }

    /// The run's merged transcript, whichever layer is loaded on top of it.
    var effectiveSourceTranscript: SegmentsDocument { sourceTranscript ?? transcript }

    var effectivePostprocess: ManifestPostprocess? {
        resultPostprocess ?? manifest.postprocess
    }

    var isTranslation: Bool {
        effectivePostprocess?.mode == .translation
    }

    var requiresReview: Bool {
        !conflicts.isEmpty || transcript.segments.contains { segment in
            let flags = segment.flags ?? []
            return flags.contains("uncertain") || flags.contains("conflict")
        }
    }

    func requiresReview(for record: LibraryRecord) -> Bool {
        if isTranslation {
            return transcript.segments.enumerated().contains { index, segment in
                let flags = segment.flags ?? []
                guard flags.contains(where: {
                    $0.localizedCaseInsensitiveContains("uncertain")
                        || $0.localizedCaseInsensitiveContains("conflict")
                }) else { return false }
                return !isTranslationAcknowledged(
                    at: index,
                    text: segment.text,
                    record: record
                )
            }
        }
        return conflicts.contains {
            correctionResolution(at: $0.segmentIndex, record: record) == nil
        } || transcript.segments.enumerated().contains { index, segment in
            let flags = segment.flags ?? []
            return flags.contains(where: {
                $0.localizedCaseInsensitiveContains("uncertain")
                    || $0.localizedCaseInsensitiveContains("conflict")
            }) && correctionResolution(at: index, record: record) == nil
        }
    }

    func correctionResolution(
        at segmentIndex: Int,
        record: LibraryRecord
    ) -> String? {
        guard !isTranslation else { return nil }
        guard resultID != nil else {
            return record.conflictResolutions[segmentIndex]
        }
        return record.derivedCorrectionResolutions?.first {
            $0.resultID == effectiveResultID && $0.segmentIndex == segmentIndex
        }?.resolvedText
    }

    func isTranslationAcknowledged(
        at segmentIndex: Int,
        text: String,
        record: LibraryRecord
    ) -> Bool {
        record.translationReviewAcknowledgements?.contains {
            $0.resultID == effectiveResultID
                && $0.segmentIndex == segmentIndex
                && $0.translatedText == text
        } == true
    }
}

extension LibraryRecord {
    /// The name the reading surface shows for one global speaker ID: the
    /// reader's own name for it when one is set, and the roster's worded
    /// fallback otherwise, so an ID never reaches the screen as a bare digit.
    func displayName(forSpeaker speaker: String, locale: Locale? = nil) -> String {
        if let name = speakerNames[speaker], !name.isEmpty { return name }
        return SpeakerRoster.fallbackName(for: speaker, locale: locale)
    }
}

extension LoadedRun {
    /// The global speaker IDs this run resolved: what a proposal reason may
    /// legitimately refer to. `UNKNOWN` and `UNASSIGNED` are not speakers.
    var resolvedSpeakerIDs: Set<String> {
        Set(effectiveSourceTranscript.segments.map(\.speaker))
            .subtracting(UnattributedSpeaker.labels)
    }

    /// The speaker-proposal document with every speaker reference in its
    /// reasons rendered with the record's current display names.
    ///
    /// Computed at read time and never stored: the artifact keeps the
    /// merger's IDs, because a display name is assigned by the reader later,
    /// lives only on the library record, and can change after the proposal
    /// exists. Every ID-bearing field — `proposedSpeaker`,
    /// `topRankedCandidate`, the candidates — is left as the ID; only the
    /// sentences change. See `SpeakerReasonRendering`.
    func speakerProposal(
        renderedFor record: LibraryRecord,
        locale: Locale? = nil
    ) -> SpeakerProposalDocument? {
        guard let speakerProposal else { return nil }
        return SpeakerReasonRendering.render(
            speakerProposal,
            speakers: resolvedSpeakerIDs
        ) { record.displayName(forSpeaker: $0, locale: locale) }
    }
}

/// Renders the speaker references in a proposal reason with display names.
///
/// The proposal artifact names speakers by the merger's global speaker ID,
/// `0`, `1`, and so on, while the reading surface shows the reader's names
/// for them. The two cannot be reconciled in the artifact: names are assigned
/// after the proposal exists and change afterwards. So the artifact keeps the
/// IDs and this substitutes them when a sentence is read.
///
/// A bare ID is not a safe token — `1` is also a segment number, a count, and
/// half of `0.5` — so the only forms recognised are the ones the prompt asks
/// the model to write and the runner's own sentences use: the word `speaker`
/// (any case) or its Korean counterpart `화자`, followed by the exact ID of a
/// speaker this run resolved, and the Korean ordinal form `0번 화자` that the
/// first real run's Korean answers also wrote. A reference to an ID the run
/// does not know is left exactly as written. The one other form accepted is
/// the runner's pre-2026-09-04 tie sentence, `the acoustic candidates 0 and 1
/// hold equal overlap`, which sealed artifacts still carry and which named
/// the tied speakers as bare IDs (D52: a sealed artifact is read through its
/// legacy form, never rewritten).
enum SpeakerReasonRendering {
    /// `reason` with each recognised reference replaced by `displayName(id)`.
    static func render(
        _ reason: String,
        speakers: some Sequence<String>,
        displayName: (String) -> String
    ) -> String {
        guard let alternation = idAlternation(speakers), !reason.isEmpty else {
            return reason
        }
        var rendered = reason
        // The legacy tie clause first: its IDs are bare and only recognisable
        // by the sentence around them.
        rendered = replacing(
            pattern: "(?<=the acoustic candidates )(?:\(alternation))(?:, (?:\(alternation)))* and (?:\(alternation))(?= hold equal overlap)",
            in: rendered
        ) { clause in
            replacing(
                pattern: "(?<![\\p{N}A-Za-z_])(\(alternation))(?![\\p{N}A-Za-z_])",
                in: clause
            ) { displayName($0) }
        }
        // The Korean ordinal form puts the ID first: `0번 화자`.
        rendered = replacing(
            pattern: "(?<![\\p{N}A-Za-z_])(\(alternation))번[ \u{00A0}]*화자",
            in: rendered
        ) { displayName($0) }
        // Then the token form. The boundary after the ID excludes digits and
        // Latin letters, so `1` never matches inside `10` and `SPEAKER_0`
        // never inside `SPEAKER_00`, but lets a Korean particle follow
        // directly: `화자 0이` is how a Korean answer writes it.
        return replacing(
            pattern: "(?<![\\p{L}\\p{N}_])(?:(?i:speaker)|화자)[ \u{00A0}]*(\(alternation))(?![\\p{N}A-Za-z_])",
            in: rendered
        ) { displayName($0) }
    }

    /// The document with every reason rendered and every ID field untouched.
    static func render(
        _ document: SpeakerProposalDocument,
        speakers: some Sequence<String>,
        displayName: (String) -> String
    ) -> SpeakerProposalDocument {
        var rendered = document
        for index in rendered.proposals.indices {
            rendered.proposals[index].reason = render(
                rendered.proposals[index].reason,
                speakers: speakers,
                displayName: displayName
            )
        }
        for index in rendered.declined.indices {
            rendered.declined[index].reason = render(
                rendered.declined[index].reason,
                speakers: speakers,
                displayName: displayName
            )
            if let answer = rendered.declined[index].modelAnswer {
                rendered.declined[index].modelAnswer?.reason = render(
                    answer.reason,
                    speakers: speakers,
                    displayName: displayName
                )
            }
        }
        return rendered
    }

    /// The known IDs as one alternation, longest first so that where one ID
    /// is a prefix of another the longer one is tried first. `nil` when there
    /// is nothing to recognise.
    private static func idAlternation(_ speakers: some Sequence<String>) -> String? {
        let ids = Set(speakers.filter { !$0.isEmpty })
            .sorted { ($0.count, $0) > ($1.count, $1) }
        guard !ids.isEmpty else { return nil }
        return ids.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    /// Every match of `pattern` in `text` replaced by `replacement` applied to
    /// its first capture group, or to the whole match when there is none.
    /// Built by hand rather than through a template so that a display name
    /// containing `$` or a backslash is inserted literally.
    private static func replacing(
        pattern: String,
        in text: String,
        with replacement: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let whole = NSRange(text.startIndex..., in: text)
        var output = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: whole) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let captured: String
            if match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                captured = String(text[range])
            } else {
                captured = String(text[matchRange])
            }
            output += text[cursor ..< matchRange.lowerBound]
            output += replacement(captured)
            cursor = matchRange.upperBound
        }
        output += text[cursor...]
        return output
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
    /// Names the engine's scratch directory for this request. Chosen by the
    /// caller so the library record can carry it before the engine starts;
    /// see `EngineRequestScratch`.
    var requestID: UUID = UUID()
}

struct ExistingRunPostprocessRequest: Equatable, Sendable {
    var sourceRunURL: URL
    var profile: AppProfile
    var postprocess: PostprocessChoice
    var operation: PostprocessMode
    var translationTargetLanguage: String?
    var glossarySemantics: DerivedGlossarySemantics = .currentProfile
    var glossaryURL: URL?
    /// See `TranscriptionRequest.requestID`.
    var requestID: UUID = UUID()
}

/// The engine's per-request scratch directory, `Requests/request-<id>/`,
/// holding the profile handed to the engine and its stdout and stderr.
///
/// A succeeded request discards it. A failed or cancelled request keeps it,
/// because `stderr.log` is the only complete record of what the engine said
/// and the failure message shown in the app is cut from it. Nothing pruned
/// it, so failed runs accumulated scratch for ever. The retention policy is
/// anchored on the run's own lifetime and declared here, in typed
/// configuration, the way `docs/engineering-constraint-policy.md` asks for
/// an execution-scope value:
///
/// - A directory named by a library record's `requestID` is *live*: it goes
///   to the Trash with the record, together with the audio and the run, and
///   is otherwise never touched.
/// - A directory no record names is an *orphan*: a superseded request whose
///   record went on to a newer one, a request whose record was removed while
///   its files were already gone, a scratch written before records carried
///   the link, or one the Finder put back after its record was dropped. It is
///   pruned once it is older than `orphanMaximumAge`, on one trigger — the
///   library load at launch — and every pruning is written to the library's
///   maintenance log, so nothing is dropped silently (judgment rule 2).
enum EngineRequestScratch {
    static let directoryPrefix = "request-"

    /// The single naming rule the runner writes with and the library reads
    /// with. Lower-case so the directory reads the same as the older ones.
    static func directoryName(for requestID: UUID) -> String {
        directoryPrefix + requestID.uuidString.lowercased()
    }

    /// Whether a directory under the requests root is one of the engine's.
    /// Only these are ever candidates for pruning.
    static func isScratchDirectoryName(_ name: String) -> Bool {
        name.hasPrefix(directoryPrefix) && name.count > directoryPrefix.count
    }

    /// How old an orphan may be before the library load prunes it: 30 days,
    /// measured from the directory's creation date against the clock at the
    /// time of the load. Exactly at the bound is kept; the rule is strict.
    ///
    /// Ledger, in the terms of the constraint policy:
    /// - `per_request_bytes`: two log files and one profile; observed under
    ///   1 KB for an engine that refused a request and under 200 B of stderr
    ///   for the real 20.7-minute run of 2026-09-01, whose engine stderr is
    ///   quiet. Headroom assumed: 1 MB per request.
    /// - `orphan_arrival_rate`: at most one per run that failed and was then
    ///   retried or removed; a run takes minutes, so an upper bound of 100
    ///   orphans a day is already absurd.
    /// - `retained_orphan_bytes <= orphan_arrival_rate * 30 d * per_request_bytes`
    ///   = 3,000 MB at that absurd rate, and a few MB at any real one.
    /// An age rather than a count, because an orphan's only remaining value
    /// is diagnostic and decays with time, not with how many other runs
    /// failed; a count bound would drop the newest evidence on the day it is
    /// most likely wanted.
    static let orphanMaximumAge: TimeInterval = 30 * 24 * 60 * 60
}

struct ExistingRunPostprocessProgress: Equatable, Sendable {
    var operation: PostprocessMode
    var elapsedS: Double
    var modelID: String?
    var message: String?
}

struct ActiveExistingRunPostprocess: Equatable, Sendable {
    var recordID: UUID
    var operation: PostprocessMode
    var progress: ExistingRunPostprocessProgress
}

@MainActor
protocol TranscriptionRunning: AnyObject {
    func run(
        _ request: TranscriptionRequest,
        progress: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL
    func postprocess(
        _ request: ExistingRunPostprocessRequest,
        progress: @escaping @MainActor (ExistingRunPostprocessProgress) -> Void
    ) async throws -> URL
    func cancel()
}

extension TranscriptionRunning {
    func postprocess(
        _: ExistingRunPostprocessRequest,
        progress _: @escaping @MainActor (ExistingRunPostprocessProgress) -> Void
    ) async throws -> URL {
        throw TranscriptionRunnerError.existingRunPostprocessUnavailable
    }
}

@MainActor
protocol RecordingControlling: AnyObject {
    var meters: CaptureMeters { get }
    func setMeterHandler(_ handler: (@MainActor (CaptureMeters) -> Void)?)
    func start(in outputRoot: URL) async throws -> RecordingSessionMetadata
    func stop() async throws -> RecordingArtifacts
    func cancel() async
}
