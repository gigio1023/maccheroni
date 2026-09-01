import Accessibility
import AppKit
import AVFoundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    @Bindable var model: MaccheroniAppModel
    let record: LibraryRecord
    let run: LoadedRun
    /// D46's marked speaker proposal, when the record has one. Defaulted
    /// because the library repository cannot load a speaker-proposal derived
    /// run yet — it rejects the artifact set and the source run then fails to
    /// open at all — so today this is always `nil` in the running app and the
    /// layer reports itself as not produced.
    var proposal: SpeakerProposalDocument?
    /// Collapsed by default. Provenance is a reference, not the first thing a
    /// reader needs, and the panel used to open onto run IDs and hashes.
    @State private var isInspectorPresented = false
    @State private var editingSpeaker: SpeakerEdit?
    @State private var speakerDraft = ""
    @State private var reviewing: TranscriptSegment?
    @State private var exportDocument: TranscriptDataDocument?
    @State private var exportType = UTType.json
    @State private var exportFilename = "transcript"
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var postprocessAction: ExistingRunAction?
    @State private var selectedSegmentIDs: Set<TranscriptSegmentID> = []
    @State private var copyFeedback: TranscriptCopyFeedback?
    @State private var copyFeedbackGeneration = 0
    @State private var selectedLayer: TranscriptDisplayLayer?
    @State private var searchText = ""
    @State private var focusedSegmentIndex: Int?
    @State private var playback = TranscriptPlaybackController()

    private var isTranslation: Bool {
        run.isTranslation
    }

    private var proposalLayer: TranscriptProposalLayer? {
        proposal.map(TranscriptProposalLayer.init(document:))
    }

    private var layerOptions: [TranscriptLayerOption] {
        TranscriptLayerCatalog.options(run: run, record: record, proposal: proposal)
    }

    private var displayLayer: TranscriptDisplayLayer {
        guard let selectedLayer,
              layerOptions.contains(where: { $0.layer == selectedLayer && $0.isAvailable })
        else {
            return TranscriptLayerCatalog.defaultLayer(
                run: run,
                record: record,
                proposal: proposal
            )
        }
        return selectedLayer
    }

    private var roster: SpeakerRoster {
        SpeakerRoster(segments: run.transcript.segments)
    }

    private var visibleSegments: [TranscriptSegment] {
        TranscriptSearch.filter(
            run.segments,
            query: searchText,
            text: { text(for: $0) },
            speaker: { displaySpeaker($0.segment.speaker) }
        )
    }

    private var reviewQueue: [Int] {
        visibleSegments.filter { needsReview($0) }.map(\.index)
    }

    /// Why unnamed rows carry no evidence, when that is true of them as a
    /// group. `nil` when every unnamed segment has its candidates.
    private var evidenceGap: TranscriptEvidenceGap? {
        let unnamed = run.segments.filter { !SpeakerRoster.isAttributed($0.segment.speaker) }
        guard !unnamed.isEmpty else { return nil }
        if isTranslation { return .notLoadedWithTranslation }
        let layer = displayLayer == .proposed ? proposalLayer : nil
        let anyMissing = unnamed.contains { item in
            item.conflict?.speakerAttribution == nil
                && layer?.inlineEvidence(at: item.index) == nil
        }
        return anyMissing ? .someSegmentsHaveNoRecord : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            segmentList
        }
        .navigationTitle(record.displayName)
        .onCopyCommand {
            guard !run.segments.isEmpty else { return [] }
            do {
                let payload = try TranscriptCopyCommand(
                    clipboard: SystemTranscriptClipboard.shared
                ).payload(
                    run: run,
                    record: record,
                    selectedSegmentIDs: selectedSegmentIDs,
                    layer: displayLayer
                )
                showCopyFeedback(
                    TranscriptCopyFeedback(
                        message: payload.confirmation.message(),
                        isError: false
                    )
                )
                return [NSItemProvider(object: payload.text as NSString)]
            } catch {
                showCopyFeedback(
                    TranscriptCopyFeedback(
                        message: appString("The transcript could not be copied."),
                        isError: true
                    )
                )
                return []
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: copyTranscript) {
                    Label(copyButtonTitle, systemImage: "doc.on.doc")
                }
                .disabled(run.segments.isEmpty)
                .help(copyButtonTitle)
                Menu(appLocalized("Export"), systemImage: "square.and.arrow.up") {
                    ForEach(TranscriptExportFormat.allCases) { format in
                        Button {
                            prepareExport(format)
                        } label: {
                            Text(format.title)
                        }
                    }
                }
                Menu(appLocalized("Post-processing"), systemImage: "wand.and.stars") {
                    Button {
                        postprocessAction = ExistingRunAction(operation: .correction)
                    } label: {
                        Text(PostprocessOperationChoice.correction.title)
                    }
                    Button {
                        postprocessAction = ExistingRunAction(operation: .translation)
                    } label: {
                        Text(PostprocessOperationChoice.translation.title)
                    }
                }
                .disabled(!model.canPostprocess(record))
                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label(appLocalized("Run Inspector"), systemImage: "sidebar.trailing")
                }
                .help(appLocalized("Show or hide how this run was produced."))
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            RunInspector(record: record, run: run)
        }
        .popover(item: $editingSpeaker) { edit in
            SpeakerRenamePopover(
                originalSpeaker: edit.speaker,
                name: $speakerDraft,
                save: {
                    model.renameSpeaker(edit.speaker, to: speakerDraft)
                    editingSpeaker = nil
                },
                cancel: { editingSpeaker = nil }
            )
        }
        .sheet(item: $reviewing) { item in
            SegmentReviewSheet(
                item: item,
                target: TranscriptReviewTarget(item: item),
                displayedText: text(for: item),
                speakerName: { displaySpeaker($0) },
                speakerColor: { roster.color(for: $0) },
                currentResolution: isTranslation
                    ? (isResolved(item) ? item.segment.text : nil)
                    : run.correctionResolution(at: item.index, record: record),
                isTranslation: isTranslation,
                choose: { text in
                    if isTranslation {
                        model.acknowledgeTranslation(at: item.index, text: text)
                    } else {
                        model.resolveConflict(at: item.index, with: text)
                    }
                    reviewing = nil
                },
                rename: {
                    let speaker = item.segment.speaker
                    reviewing = nil
                    guard SpeakerRoster.isAttributed(speaker) else { return }
                    editingSpeaker = SpeakerEdit(speaker: speaker)
                    speakerDraft = displaySpeaker(speaker)
                },
                cancel: { reviewing = nil }
            )
        }
        .sheet(item: $postprocessAction) { action in
            ExistingRunPostprocessSheet(
                model: model,
                operation: action.operation,
                start: { backend, targetLanguage in
                    model.postprocessSelectedRun(
                        operation: action.operation,
                        backend: backend,
                        targetLanguage: targetLanguage
                    )
                    postprocessAction = nil
                },
                cancel: { postprocessAction = nil }
            )
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert(appLocalized("Transcript Could Not Be Exported"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(appLocalized("OK"), role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onChange(of: run.effectiveResultID) {
            selectedSegmentIDs.removeAll()
            copyFeedback = nil
            selectedLayer = nil
            focusedSegmentIndex = nil
        }
        .onDisappear { playback.stop() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            TranscriptHeaderBar(
                title: record.displayName,
                summary: summaryLine,
                layerOptions: layerOptions,
                selectedLayer: displayLayer,
                selectLayer: { selectedLayer = $0 },
                searchText: $searchText,
                matchCount: searchText.isEmpty ? nil : visibleSegments.count,
                reviewQueue: reviewQueue,
                focusedSegmentIndex: focusedSegmentIndex,
                step: { step($0) },
                evidenceGap: evidenceGap,
                playback: playback,
                totalDurationS: max(record.durationS, run.manifest.coverage.inputDurationS),
                togglePlayback: {
                    model.stopPlayback()
                    playback.togglePlayPause(record: record)
                },
                seek: { playback.seek(to: $0, record: record) }
            )
            if displayLayer == .proposed, let proposalLayer {
                ProposalLayerNotice(layer: proposalLayer)
            }
            if let copyFeedback {
                Label(
                    copyFeedback.message,
                    systemImage: copyFeedback.isError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(AppTheme.Typography.meta)
                .foregroundStyle(copyFeedback.isError ? Color.red : Color.secondary)
                .transition(.opacity)
            }
            postprocessStatus
        }
        // The same measure and centring as the segment column below, so a
        // control and the thing it controls share one left edge. Full-bleed
        // chrome over a centred column put 261 points between the layer bar and
        // the first segment it switches, and a reader crosses that on every
        // pass down the page.
        .frame(maxWidth: 860, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.screen)
        .padding(.vertical, AppTheme.Spacing.large)
        .frame(maxWidth: .infinity)
    }

    private var summaryLine: String {
        let unattributed = run.transcript.segments.count {
            !SpeakerRoster.isAttributed($0.speaker)
        }
        return appString(
            "\(run.transcript.segments.count) segments · \(run.transcript.numSpeakers) speakers · \(unattributed) without a speaker · \(unresolvedConflictCount) to review"
        )
    }

    @ViewBuilder
    private var postprocessStatus: some View {
        if let active = model.activeExistingRunPostprocess,
           active.recordID == record.id
        {
            HStack(spacing: AppTheme.Spacing.small) {
                ProgressView().controlSize(.small)
                Text(PostprocessOperationChoice(active.operation).title)
                if let modelID = active.progress.modelID {
                    Text(verbatim: modelID).foregroundStyle(.secondary)
                }
                Button(appLocalized("Cancel"), role: .cancel) {
                    model.cancelTranscription()
                }
            }
            .font(AppTheme.Typography.meta)
        } else if let failure = model.existingRunPostprocessFailure(for: record.id) {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    // MARK: - List

    private var segmentList: some View {
        // Bound once here: `roster` and `visibleSegments` are computed
        // properties, and reading them from a per-row closure rebuilt the
        // roster 248 times per pass on the measured run.
        let roster = self.roster
        let visibleSegments = self.visibleSegments
        return ScrollViewReader { proxy in
            ScrollView {
                TranscriptSegmentColumn(
                    segments: visibleSegments,
                    roster: roster,
                    displayName: { displaySpeaker($0) },
                    text: { text(for: $0) },
                    needsReview: { needsReview($0) },
                    isReviewable: { isReviewable($0) },
                    focusedSegmentIndex: focusedSegmentIndex,
                    playingSegmentIndex: playback.playingSegmentIndex(in: visibleSegments),
                    selectedSegmentIDs: selectedSegmentIDs,
                    evidenceIsLoaded: !isTranslation,
                    proposalLayer: displayLayer == .proposed ? proposalLayer : nil,
                    play: { item in
                        model.stopPlayback()
                        playback.play(from: item.segment.startS, record: record)
                        focusedSegmentIndex = item.index
                    },
                    select: { toggleSelection(of: $0.id) },
                    rename: { item in
                        editingSpeaker = SpeakerEdit(speaker: item.segment.speaker)
                        speakerDraft = displaySpeaker(item.segment.speaker)
                    },
                    review: { item in
                        focusedSegmentIndex = item.index
                        reviewing = item
                    }
                )
            }
            .onChange(of: focusedSegmentIndex) { _, index in
                guard let index,
                      let item = visibleSegments.first(where: { $0.index == index })
                else { return }
                withAnimation { proxy.scrollTo(item.id, anchor: .center) }
            }
        }
    }

    // MARK: - Derived state

    private func text(for item: TranscriptSegment) -> String {
        TranscriptLayerCatalog.text(
            displayLayer,
            for: item,
            run: run,
            record: record
        )
    }

    private var unresolvedConflictCount: Int {
        run.segments.count { needsReview($0) }
    }

    /// A segment the reader has not signed off yet. The rule is the one the
    /// library already uses to decide `hasConflicts`, kept in one place.
    private func needsReview(_ item: TranscriptSegment) -> Bool {
        guard !isResolved(item) else { return false }
        if item.conflict != nil { return true }
        return TranscriptFlagVocabulary.marksUncertainty(item.segment.flags ?? [])
    }

    /// Whether the review sheet has anything to offer. A translation
    /// acknowledgement and a correction both need the sheet; so does a speaker
    /// conflict, which shows evidence rather than alternatives.
    private func isReviewable(_ item: TranscriptSegment) -> Bool {
        item.conflict != nil
            || TranscriptFlagVocabulary.marksUncertainty(item.segment.flags ?? [])
    }

    private func isResolved(_ item: TranscriptSegment) -> Bool {
        if isTranslation {
            return run.isTranslationAcknowledged(
                at: item.index,
                text: item.segment.text,
                record: record
            )
        }
        return run.correctionResolution(at: item.index, record: record) != nil
    }

    private func displaySpeaker(_ raw: String) -> String {
        if let name = record.speakerNames[raw], !name.isEmpty { return name }
        return SpeakerRoster.fallbackName(for: raw)
    }

    private func step(_ direction: Int) {
        guard let next = TranscriptReviewQueue.step(
            from: focusedSegmentIndex,
            in: reviewQueue,
            direction: direction
        ) else { return }
        focusedSegmentIndex = next
    }

    private var copyButtonTitle: LocalizedStringResource {
        selectedSegmentIDs.isEmpty
            ? appLocalized("Copy Transcript")
            : appLocalized("Copy Selection")
    }

    private func toggleSelection(of id: TranscriptSegmentID) {
        if selectedSegmentIDs.contains(id) {
            selectedSegmentIDs.remove(id)
        } else {
            selectedSegmentIDs.insert(id)
        }
        copyFeedback = nil
    }

    private func copyTranscript() {
        do {
            let confirmation = try TranscriptCopyCommand(
                clipboard: SystemTranscriptClipboard.shared
            ).perform(
                run: run,
                record: record,
                selectedSegmentIDs: selectedSegmentIDs,
                layer: displayLayer
            )
            showCopyFeedback(
                TranscriptCopyFeedback(
                    message: confirmation.message(),
                    isError: false
                )
            )
        } catch {
            showCopyFeedback(
                TranscriptCopyFeedback(
                    message: appString("The transcript could not be copied."),
                    isError: true
                )
            )
        }
    }

    private func showCopyFeedback(_ feedback: TranscriptCopyFeedback) {
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        withAnimation { copyFeedback = feedback }
        AccessibilityNotification.Announcement(feedback.message).post()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard generation == copyFeedbackGeneration else { return }
            withAnimation { copyFeedback = nil }
        }
    }

    private func prepareExport(_ format: TranscriptExportFormat) {
        do {
            let data = try TranscriptExporter.data(format: format, run: run, record: record)
            exportDocument = TranscriptDataDocument(data: data)
            exportType = contentType(for: format)
            exportFilename = TranscriptExporter.suggestedFilename(format: format, record: record)
            isExporting = true
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func contentType(for format: TranscriptExportFormat) -> UTType {
        switch format {
        case .segmentsJSON: .json
        case .markdown: .init(filenameExtension: "md") ?? .plainText
        case .srt: .init(filenameExtension: "srt") ?? .plainText
        }
    }
}

// MARK: - Speakers

/// Who the run's speakers are and which colour each one gets. The index comes
/// from the run's sorted roster rather than from a hash of the label: a hash
/// seats two speakers of a two-speaker recording on the same colour about one
/// time in seven, and this surface has nothing else to tell them apart with.
struct SpeakerRoster: Equatable, Sendable {
    /// Attribution refused: the merger looked and would not name a speaker.
    static let unnamed = "UNKNOWN"
    /// Not yet attributed: merge has not run for this segment.
    static let unattributed = "UNASSIGNED"

    private let indexBySpeaker: [String: Int]

    init(segments: [Segment]) {
        let named = Set(segments.map(\.speaker)).filter { Self.isAttributed($0) }
        indexBySpeaker = Dictionary(
            uniqueKeysWithValues: named.sorted().enumerated().map { ($1, $0) }
        )
    }

    /// Defers to `MaccheroniCore.UnattributedSpeaker`, which is where the
    /// derived-run contract fixes these labels. Two lists of the same fact
    /// would eventually disagree.
    static func isAttributed(_ speaker: String) -> Bool {
        !speaker.isEmpty && !UnattributedSpeaker.isUnattributed(speaker)
    }

    func index(of speaker: String) -> Int? {
        indexBySpeaker[speaker]
    }

    func color(for speaker: String) -> Color {
        AppTheme.Palette.speaker(atRosterIndex: indexBySpeaker[speaker])
    }

    /// The name shown when the reader has not renamed the speaker. Raw
    /// `UNKNOWN` and `UNASSIGNED` never reach the reading surface, and a bare
    /// global-namespace ID reads as a stray digit next to a real name, so it is
    /// worded. The ID itself is kept in the wording, because that is what the
    /// artifacts and the exports say.
    static func fallbackName(for speaker: String, locale: Locale? = nil) -> String {
        switch speaker {
        case unnamed: appString("Speaker not named", locale: locale)
        case unattributed: appString("Speaker not attributed yet", locale: locale)
        default: appString("Speaker \(speaker)", locale: locale)
        }
    }
}

/// What the acoustic evidence said about one segment's speaker, ready to
/// render. Every number here was computed by the merger and disclosed on the
/// conflict record; nothing is inferred.
struct SegmentAttributionSummary: Equatable, Sendable {
    var speaker: String
    /// `nil` when no evidence reached this surface at all, which is a
    /// different fact from any outcome the merger can report.
    var outcome: SpeakerAttributionOutcome?
    var candidates: [SpeakerCandidate]
    var timelineCoverage: Double?
    /// The bar this run applied. Absent when the evidence arrived by a route
    /// that does not carry it, in which case the sentences below name no
    /// number rather than inventing one.
    var thresholds: SpeakerAttributionThresholds?
    /// False when the loaded result cannot carry the evidence — a translation
    /// result drops the merge conflicts on load. Absent evidence and unloaded
    /// evidence are different facts and must not read the same: the first says
    /// the acoustics were silent, the second says we are not looking at them.
    var evidenceIsLoaded: Bool

    init(item: TranscriptSegment, evidenceIsLoaded: Bool = true) {
        self.init(
            speaker: item.segment.speaker,
            attribution: item.conflict?.speakerAttribution,
            evidenceIsLoaded: evidenceIsLoaded
        )
    }

    init(
        speaker: String,
        attribution: SpeakerAttribution?,
        evidenceIsLoaded: Bool = true
    ) {
        self.speaker = speaker
        outcome = attribution?.outcome
        candidates = attribution?.candidates ?? []
        timelineCoverage = attribution?.timelineCoverage
        thresholds = attribution?.thresholds
        self.evidenceIsLoaded = evidenceIsLoaded
    }

    init(
        speaker: String,
        outcome: SpeakerAttributionOutcome?,
        candidates: [SpeakerCandidate],
        timelineCoverage: Double?,
        thresholds: SpeakerAttributionThresholds? = nil,
        evidenceIsLoaded: Bool = true
    ) {
        self.speaker = speaker
        self.outcome = outcome
        self.candidates = candidates
        self.timelineCoverage = timelineCoverage
        self.thresholds = thresholds
        self.evidenceIsLoaded = evidenceIsLoaded
    }

    var isAttributed: Bool { SpeakerRoster.isAttributed(speaker) }

    var hasEvidence: Bool { outcome != nil }

    /// The winning speaker's share, shown beside an attributed name only when
    /// somebody else was also talking. On the measured run 183 segments are in
    /// that state; printing the full evidence block on all of them would bury
    /// the 110 that have no speaker at all.
    var contestedTopShare: Double? {
        guard isAttributed, candidates.count > 1 else { return nil }
        return candidates.first(where: { $0.speaker == speaker })?.share
            ?? candidates.first?.share
    }

    /// One sentence saying why no speaker was named, in the reader's language.
    /// One case per return site the merger distinguishes.
    func reason(locale: Locale? = nil) -> String? {
        guard !isAttributed else { return nil }
        guard let outcome else {
            return evidenceIsLoaded
                ? appString(
                    "This segment carries no recorded speaker evidence.",
                    locale: locale
                )
                : appString(
                    "The acoustic evidence is not loaded beside a translation. The source run still has it.",
                    locale: locale
                )
        }
        switch outcome {
        case .noOverlappingTurn:
            return appString(
                "No speaker was active on the speaker timeline during this segment.",
                locale: locale
            )
        case .coverageBelowThreshold:
            let coverage = Self.percent(timelineCoverage ?? 0, locale: locale)
            guard let thresholds else {
                return appString(
                    "The speaker timeline covered \(coverage) of this segment, below what this run requires.",
                    locale: locale
                )
            }
            let minimum = Self.percent(
                thresholds.minimumTimelineCoverage,
                locale: locale
            )
            return appString(
                "The speaker timeline covered \(coverage) of this segment, below the \(minimum) it needs.",
                locale: locale
            )
        case .noDominantSpeaker:
            guard let thresholds else {
                return appString(
                    "No speaker held enough of this segment's speech, so none was named.",
                    locale: locale
                )
            }
            let share = Self.percent(thresholds.dominantSpeakerShare, locale: locale)
            return appString(
                "No speaker held \(share) of this segment's speech, so none was named.",
                locale: locale
            )
        case .attributed:
            return nil
        }
    }

    static func percent(
        _ value: Double,
        locale: Locale? = nil,
        fractionDigits: Int = 0
    ) -> String {
        var style = FloatingPointFormatStyle<Double>.Percent.percent
            .precision(.fractionLength(fractionDigits))
        if let locale { style = style.locale(locale) }
        return value.formatted(style)
    }

    static func overlap(_ seconds: Double, locale: Locale? = nil) -> String {
        var style = Measurement<UnitDuration>.FormatStyle.measurement(
            width: .abbreviated,
            usage: .asProvided,
            numberFormatStyle: .number.precision(.fractionLength(1))
        )
        if let locale { style = style.locale(locale) }
        return Measurement(value: seconds, unit: UnitDuration.seconds).formatted(style)
    }
}

/// Why the rows below carry no acoustic evidence, said once above them rather
/// than repeated on each. Both cases are ordinary states of a loaded run, not
/// errors, so this reads as a note and not as a warning.
enum TranscriptEvidenceGap: Equatable, Sendable {
    /// A translation result replaces the text and drops the conflicts the
    /// evidence rides on. Nothing is lost on disk.
    case notLoadedWithTranslation
    /// The run attributed no speaker to some segments and recorded no
    /// candidates for them either.
    case someSegmentsHaveNoRecord

    func sentence(locale: Locale? = nil) -> String {
        switch self {
        case .notLoadedWithTranslation:
            appString(
                "The acoustic evidence is not loaded beside a translation. The source run still has it.",
                locale: locale
            )
        case .someSegmentsHaveNoRecord:
            appString(
                "Some segments carry no recorded speaker evidence.",
                locale: locale
            )
        }
    }
}

// MARK: - Proposals

/// What D46's marked layer says about one segment: a proposed speaker, or a
/// reason none was proposed. Every segment the source run left unattributed
/// appears in exactly one of those states, so "nothing was said here" is not a
/// state this can produce.
///
/// The proposed speaker is deliberately never merged into
/// `SegmentAttributionSummary`. Acoustic evidence and a non-acoustic proposal
/// are different kinds of claim, judgment rule 4 turns on keeping them apart,
/// and one type holding both is how they stop being apart.
enum SegmentSpeakerProposal: Equatable, Sendable {
    case proposed(speaker: String, reason: String)
    case declined(reason: String)

    var proposedSpeaker: String? {
        if case let .proposed(speaker, _) = self { return speaker }
        return nil
    }

    var reason: String {
        switch self {
        case let .proposed(_, reason), let .declined(reason): reason
        }
    }
}

/// The proposal document indexed by segment, and the acoustic evidence it
/// carries inline for segments it examined.
struct TranscriptProposalLayer: Equatable, Sendable {
    struct InlineEvidence: Equatable, Sendable {
        var outcome: String
        var timelineCoverage: Double
        var candidates: [SpeakerCandidateEvidence]
    }

    let sourceCoverage: DerivedSourceCoverage
    private let bySegment: [Int: SegmentSpeakerProposal]
    private let evidenceBySegment: [Int: InlineEvidence]

    init(document: SpeakerProposalDocument) {
        sourceCoverage = document.sourceCoverage
        var proposals: [Int: SegmentSpeakerProposal] = [:]
        var evidence: [Int: InlineEvidence] = [:]
        for proposal in document.proposals {
            proposals[proposal.segmentIndex] = .proposed(
                speaker: proposal.proposedSpeaker,
                reason: proposal.reason
            )
            evidence[proposal.segmentIndex] = InlineEvidence(
                outcome: proposal.acousticOutcome,
                timelineCoverage: proposal.acousticTimelineCoverage,
                candidates: proposal.acousticCandidates
            )
        }
        for declination in document.declined {
            proposals[declination.segmentIndex] = .declined(reason: declination.reason)
            evidence[declination.segmentIndex] = InlineEvidence(
                outcome: declination.acousticOutcome,
                timelineCoverage: declination.acousticTimelineCoverage,
                candidates: declination.acousticCandidates
            )
        }
        bySegment = proposals
        evidenceBySegment = evidence
    }

    var examinedSegmentCount: Int { bySegment.count }

    var proposedCount: Int {
        bySegment.values.count { $0.proposedSpeaker != nil }
    }

    var declinedCount: Int { examinedSegmentCount - proposedCount }

    func proposal(at segmentIndex: Int) -> SegmentSpeakerProposal? {
        bySegment[segmentIndex]
    }

    /// The acoustic evidence P4 copies into its own document, used only when
    /// the segment's conflict record is not at hand. The numbers and their
    /// order are P1's, so this is the same evidence by a shorter route rather
    /// than a second opinion.
    func inlineEvidence(at segmentIndex: Int) -> SegmentAttributionSummary? {
        guard let entry = evidenceBySegment[segmentIndex] else { return nil }
        return SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            outcome: SpeakerAttributionOutcome(rawValue: entry.outcome),
            candidates: entry.candidates.map {
                SpeakerCandidate(speaker: $0.speaker, overlapS: $0.overlapS, share: $0.share)
            },
            timelineCoverage: entry.timelineCoverage
        )
    }
}

// MARK: - Flags

/// The flags this app has words for. A raw flag token never reaches the
/// reading surface: `conflict` and `uncertain` are carried by the review
/// marker, `backend_speaker_evidence` is provenance that appears on almost
/// every segment, and anything else is shown in the segment's detail under a
/// heading that says what it is.
enum TranscriptFlagVocabulary {
    static let conflict = "conflict"
    static let uncertain = "uncertain"
    static let backendSpeakerEvidence = "backend_speaker_evidence"

    static func marksUncertainty(_ flags: [String]) -> Bool {
        flags.contains {
            $0.localizedCaseInsensitiveContains(uncertain)
                || $0.localizedCaseInsensitiveContains(conflict)
        }
    }

    static func hasBackendSpeakerEvidence(_ flags: [String]) -> Bool {
        flags.contains { $0.caseInsensitiveCompare(backendSpeakerEvidence) == .orderedSame }
    }

    static func otherMarkers(_ flags: [String]) -> [String] {
        let known = [conflict, uncertain, backendSpeakerEvidence]
        return flags.filter { flag in
            !known.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
        }
    }
}

// MARK: - Review targets

/// What a review sheet may offer for one segment, split by what the conflict
/// record actually carries.
///
/// `MergeConflict.candidates` holds texts for `asrDisagreement` and speaker IDs
/// for `ambiguousSpeaker` and `overlappingSpeech`, and the library merges
/// post-processing text candidates onto an existing speaker conflict, so one
/// record can hold both. Offering a speaker ID as replacement transcript text
/// would write `"0"` into the transcript; keeping the two apart here is the
/// only thing that prevents it.
struct TranscriptReviewTarget: Equatable, Sendable {
    var speakerEvidence: SpeakerAttribution?
    var speakerCandidates: [String]
    var textAlternatives: [String]
    var reason: String?
    var hasBackendSpeakerEvidence: Bool
    var otherMarkers: [String]

    init(item: TranscriptSegment) {
        let flags = item.segment.flags ?? []
        hasBackendSpeakerEvidence = TranscriptFlagVocabulary.hasBackendSpeakerEvidence(flags)
        otherMarkers = TranscriptFlagVocabulary.otherMarkers(flags)
        guard let conflict = item.conflict else {
            speakerEvidence = nil
            speakerCandidates = []
            textAlternatives = []
            reason = nil
            return
        }
        reason = conflict.reason
        speakerEvidence = conflict.speakerAttribution
        switch conflict.kind {
        case .asrDisagreement:
            speakerCandidates = []
            textAlternatives = conflict.candidates.filter { $0 != item.segment.text }
        case .ambiguousSpeaker, .overlappingSpeech:
            // P1 made the legacy `candidates` array a projection of the ranked
            // speaker list, so the speaker IDs are its prefix. Without the
            // disclosure — a conflict file written before P1 — every candidate
            // on a speaker conflict is a speaker ID.
            let speakerCount = conflict.speakerAttribution?.candidates.count
                ?? conflict.candidates.count
            speakerCandidates = Array(conflict.candidates.prefix(speakerCount))
            textAlternatives = Array(conflict.candidates.dropFirst(speakerCount))
                .filter { $0 != item.segment.text }
        }
    }
}

// MARK: - Review queue

/// Where the review stepper goes next. The count of unresolved segments is a
/// control rather than a label, so this decides what the control does: it walks
/// only unresolved segments, in transcript order, and wraps at both ends.
enum TranscriptReviewQueue {
    static func step(from focused: Int?, in queue: [Int], direction: Int) -> Int? {
        guard !queue.isEmpty else { return nil }
        guard let focused, let position = queue.firstIndex(of: focused) else {
            return direction >= 0 ? queue[0] : queue[queue.count - 1]
        }
        let next = (position + direction + queue.count) % queue.count
        return queue[next]
    }
}

// MARK: - Search

enum TranscriptSearch {
    static func filter(
        _ segments: [TranscriptSegment],
        query: String,
        text: (TranscriptSegment) -> String,
        speaker: (TranscriptSegment) -> String
    ) -> [TranscriptSegment] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return segments }
        return segments.filter { item in
            text(item).localizedStandardContains(trimmed)
                || speaker(item).localizedStandardContains(trimmed)
        }
    }
}

// MARK: - Playback

/// Playback for the transcript surface: pause and resume, a playhead over the
/// whole recording, and no stop at a segment boundary. Correction work is
/// listening work, and the previous behaviour stopped after one segment —
/// 4.9 seconds on the measured run — so following a conversation cost one
/// click per segment.
///
/// This owns its own player rather than driving the app model's, because the
/// model's play path is a fire-and-forget seek with no pause and no position.
/// It resolves the source read-only and never rewrites a stale bookmark; that
/// stays the library repository's job.
@MainActor
@Observable
final class TranscriptPlaybackController {
    private(set) var isPlaying = false
    private(set) var positionS: Double = 0
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var accessedURL: URL?

    // No `deinit` teardown: it would have to reach main-actor state from a
    // nonisolated context. The view calls `stop()` in `onDisappear`, which is
    // the only path that ends a transcript session.

    func play(from seconds: Double, record: LibraryRecord) {
        guard preparePlayer(for: record) else { return }
        seek(to: seconds, record: record)
        player?.play()
        isPlaying = true
    }

    func togglePlayPause(record: LibraryRecord) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        guard preparePlayer(for: record) else { return }
        player?.play()
        isPlaying = true
    }

    func seek(to seconds: Double, record: LibraryRecord) {
        guard preparePlayer(for: record) else { return }
        let clamped = max(0, seconds)
        positionS = clamped
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stop() {
        player?.pause()
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player = nil
        isPlaying = false
        positionS = 0
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }

    /// Which of the visible segments the playhead is inside, so the list can
    /// follow along.
    func playingSegmentIndex(in segments: [TranscriptSegment]) -> Int? {
        guard isPlaying else { return nil }
        return TranscriptPlaybackTimeline.segmentIndex(at: positionS, in: segments)
    }

    private func preparePlayer(for record: LibraryRecord) -> Bool {
        if player != nil { return true }
        guard let url = Self.sourceURL(for: record) else {
            errorMessage = appString("The original recording could not be found.")
            return false
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        let player = AVPlayer(url: url)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.positionS = max(0, time.seconds)
            }
        }
        errorMessage = nil
        return true
    }

    /// Read-only resolution of the recording. A stale bookmark still resolves;
    /// persisting the refreshed bookmark belongs to the library repository, and
    /// doing it here would have two writers for one index.
    static func sourceURL(for record: LibraryRecord) -> URL? {
        if let bookmark = record.securityScopedBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return FileManager.default.fileExists(atPath: record.sourceURL.path)
            ? record.sourceURL
            : nil
    }
}

enum TranscriptPlaybackTimeline {
    static func segmentIndex(
        at seconds: Double,
        in segments: [TranscriptSegment]
    ) -> Int? {
        segments.first {
            seconds >= $0.segment.startS && seconds < $0.segment.endS
        }?.index
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3_600 {
            return String(
                format: "%d:%02d:%02d",
                total / 3_600,
                (total / 60) % 60,
                total % 60
            )
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Copy

enum TranscriptCopyScope: Equatable, Sendable {
    case transcript
    case selection(segmentCount: Int)
}

struct TranscriptCopyConfirmation: Equatable, Sendable {
    let layer: TranscriptDisplayLayer
    let scope: TranscriptCopyScope

    func message(locale: Locale? = nil) -> String {
        switch (layer, scope) {
        case (.speakerLabelled, .transcript):
            appString("Copied the speaker-labelled transcript.", locale: locale)
        case (.corrected, .transcript):
            appString("Copied the corrected transcript.", locale: locale)
        case (.translated, .transcript):
            appString("Copied the translated transcript.", locale: locale)
        case (.proposed, .transcript):
            appString("Copied the proposed transcript.", locale: locale)
        case (.speakerLabelled, .selection):
            appString("Copied the speaker-labelled selection.", locale: locale)
        case (.corrected, .selection):
            appString("Copied the corrected selection.", locale: locale)
        case (.translated, .selection):
            appString("Copied the translated selection.", locale: locale)
        case (.proposed, .selection):
            appString("Copied the proposed selection.", locale: locale)
        }
    }
}

enum TranscriptCopyError: Error, Equatable {
    case staleSelection
    case clipboardWriteFailed
}

@MainActor
protocol TranscriptClipboardWriting: AnyObject {
    func write(_ text: String) -> Bool
}

@MainActor
final class SystemTranscriptClipboard: TranscriptClipboardWriting {
    static let shared = SystemTranscriptClipboard()

    private init() {}

    func write(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

struct TranscriptCopyPayload: Equatable, Sendable {
    let text: String
    let confirmation: TranscriptCopyConfirmation
}

@MainActor
struct TranscriptCopyCommand {
    let clipboard: any TranscriptClipboardWriting

    func payload(
        run: LoadedRun,
        record: LibraryRecord,
        selectedSegmentIDs: Set<TranscriptSegmentID>,
        layer: TranscriptDisplayLayer? = nil
    ) throws -> TranscriptCopyPayload {
        let selectedSegments = run.segments.filter { selectedSegmentIDs.contains($0.id) }
        guard selectedSegmentIDs.isEmpty || selectedSegments.count == selectedSegmentIDs.count else {
            throw TranscriptCopyError.staleSelection
        }
        let selectedIndices = Set(selectedSegments.map(\.index))
        let text = try TranscriptExporter.copyText(
            run: run,
            record: record,
            selectedSegmentIndices: selectedIndices,
            layer: layer
        )
        return TranscriptCopyPayload(
            text: text,
            confirmation: TranscriptCopyConfirmation(
                layer: layer ?? TranscriptDisplayLayer.displayed(in: run),
                scope: selectedSegmentIDs.isEmpty
                    ? .transcript
                    : .selection(segmentCount: selectedSegments.count)
            )
        )
    }

    func perform(
        run: LoadedRun,
        record: LibraryRecord,
        selectedSegmentIDs: Set<TranscriptSegmentID>,
        layer: TranscriptDisplayLayer? = nil
    ) throws -> TranscriptCopyConfirmation {
        let payload = try payload(
            run: run,
            record: record,
            selectedSegmentIDs: selectedSegmentIDs,
            layer: layer
        )
        guard clipboard.write(payload.text) else {
            throw TranscriptCopyError.clipboardWriteFailed
        }
        return payload.confirmation
    }
}

private struct TranscriptCopyFeedback: Equatable {
    let message: String
    let isError: Bool
}

// MARK: - Header controls
//
// The controls below are internal rather than file-private so an offscreen
// render harness can build one screen state at a time and read the image back,
// which is how this surface is judged under D48.
//
// Two harness facts shaped this file and are worth keeping in mind before
// editing it. `ImageRenderer` draws nothing at all inside a scrolling
// container — `ScrollView`, `List`, and `Form(.grouped)` all come back blank —
// and it draws AppKit-backed button styles (`.borderless`, `.link`) as a
// yellow placeholder glyph. So the scrolling parts of this screen are split
// into views that can be rendered on their own, and every control here uses
// `.plain`.

/// Everything above the transcript that changes what the transcript shows:
/// what this recording is, which layer, what is searched, where the review
/// stepper is, and where the playhead is.
struct TranscriptHeaderBar: View {
    let title: String
    let summary: String
    let layerOptions: [TranscriptLayerOption]
    let selectedLayer: TranscriptDisplayLayer
    let selectLayer: (TranscriptDisplayLayer) -> Void
    @Binding var searchText: String
    let matchCount: Int?
    let reviewQueue: [Int]
    let focusedSegmentIndex: Int?
    let step: (Int) -> Void
    /// Stated once here rather than under every unnamed row.
    var evidenceGap: TranscriptEvidenceGap?
    let playback: TranscriptPlaybackController
    let totalDurationS: Double
    let togglePlayback: () -> Void
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppTheme.Spacing.large) {
                    titleBlock
                    Spacer(minLength: AppTheme.Spacing.large)
                    transport
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
                    titleBlock
                    transport
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppTheme.Spacing.medium) {
                    layerBar
                    Spacer(minLength: AppTheme.Spacing.small)
                    stepper
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    layerBar
                    stepper
                }
            }

            if let evidenceGap {
                Label {
                    Text(verbatim: evidenceGap.sentence())
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            TranscriptSearchField(text: $searchText, matchCount: matchCount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
            Text(verbatim: title)
                .font(AppTheme.Typography.screenTitle)
                .lineLimit(2)
            Text(verbatim: summary)
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var layerBar: some View {
        TranscriptLayerBar(
            options: layerOptions,
            selection: selectedLayer,
            select: selectLayer
        )
    }

    private var stepper: some View {
        TranscriptReviewStepper(
            queue: reviewQueue,
            focused: focusedSegmentIndex,
            step: step
        )
    }

    private var transport: some View {
        TranscriptTransport(
            playback: playback,
            totalDurationS: totalDurationS,
            toggle: togglePlayback,
            seek: seek
        )
    }
}

/// The transcript itself, without the scroll view around it, so it can be
/// rendered offscreen exactly as it appears on screen.
struct TranscriptSegmentColumn: View {
    let segments: [TranscriptSegment]
    let roster: SpeakerRoster
    let displayName: (String) -> String
    let text: (TranscriptSegment) -> String
    let needsReview: (TranscriptSegment) -> Bool
    let isReviewable: (TranscriptSegment) -> Bool
    let focusedSegmentIndex: Int?
    let playingSegmentIndex: Int?
    let selectedSegmentIDs: Set<TranscriptSegmentID>
    /// False for a translation result, whose load path drops the conflicts the
    /// acoustic evidence rides on.
    var evidenceIsLoaded: Bool = true
    /// Non-nil only while the proposal layer is the one being shown, so a
    /// proposal can never appear on a layer the reader did not ask for.
    var proposalLayer: TranscriptProposalLayer?
    let play: (TranscriptSegment) -> Void
    let select: (TranscriptSegment) -> Void
    let rename: (TranscriptSegment) -> Void
    let review: (TranscriptSegment) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            if segments.isEmpty {
                Text(appLocalized("No segment matches this search."))
                    .font(AppTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, AppTheme.Spacing.screen)
            }
            ForEach(segments) { item in
                TranscriptSegmentRow(
                    item: item,
                    attribution: attribution(for: item),
                    proposal: proposalLayer?.proposal(at: item.index),
                    displaySpeaker: displayName(item.segment.speaker),
                    speakerName: displayName,
                    speakerColor: { roster.color(for: $0) },
                    text: text(item),
                    needsReview: needsReview(item),
                    isReviewable: isReviewable(item),
                    isFocused: focusedSegmentIndex == item.index,
                    isPlaying: playingSegmentIndex == item.index,
                    isSelected: selectedSegmentIDs.contains(item.id),
                    play: { play(item) },
                    select: { select(item) },
                    rename: { rename(item) },
                    review: { review(item) }
                )
                .id(item.id)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .padding(AppTheme.Spacing.screen)
        .frame(maxWidth: .infinity)
    }

    /// The joined conflict record is the evidence of record. The proposal
    /// document's inline copy is the fallback for a segment whose record did
    /// not reach this surface, so the same numbers are never rendered twice by
    /// two routes.
    private func attribution(for item: TranscriptSegment) -> SegmentAttributionSummary {
        let joined = SegmentAttributionSummary(
            item: item,
            evidenceIsLoaded: evidenceIsLoaded
        )
        guard !joined.hasEvidence,
              let inline = proposalLayer?.inlineEvidence(at: item.index)
        else { return joined }
        return SegmentAttributionSummary(
            speaker: item.segment.speaker,
            outcome: inline.outcome,
            candidates: inline.candidates,
            timelineCoverage: inline.timelineCoverage,
            evidenceIsLoaded: evidenceIsLoaded
        )
    }
}


struct TranscriptLayerBar: View {
    let options: [TranscriptLayerOption]
    let selection: TranscriptDisplayLayer
    let select: (TranscriptDisplayLayer) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.tight) {
            ForEach(options) { option in
                Button {
                    select(option.layer)
                } label: {
                    Text(option.layer.title)
                        .font(AppTheme.Typography.metaStrong)
                        .padding(.horizontal, AppTheme.Spacing.medium)
                        .padding(.vertical, 5)
                        .background(background(for: option), in: .rect(cornerRadius: AppTheme.Radius.chip))
                        .foregroundStyle(foreground(for: option))
                }
                .buttonStyle(.plain)
                .disabled(!option.isAvailable)
                .help(option.isAvailable
                    ? appString("Show this layer of the transcript.")
                    : option.unavailability?.sentence() ?? "")
                .accessibilityLabel(Text(option.layer.title))
                .accessibilityHint(Text(verbatim: option.unavailability?.sentence() ?? ""))
                .accessibilityAddTraits(option.layer == selection ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(.quaternary, in: .rect(cornerRadius: AppTheme.Radius.chip + 3))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func background(for option: TranscriptLayerOption) -> Color {
        guard option.isAvailable else { return .clear }
        return option.layer == selection
            ? Color.accentColor.opacity(0.85)
            : .clear
    }

    private func foreground(for option: TranscriptLayerOption) -> Color {
        // A layer this run cannot show still has to be readable: the bar is
        // where a reader learns what the product can produce. Dimmer than this
        // failed against the dark control ground.
        guard option.isAvailable else { return .secondary.opacity(0.8) }
        return option.layer == selection ? .white : .primary
    }
}

struct TranscriptSearchField: View {
    @Binding var text: String
    let matchCount: Int?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(appLocalized("Search this transcript"), text: $text)
                .textFieldStyle(.plain)
                .font(AppTheme.Typography.body)
            if let matchCount {
                Text(appLocalized("\(matchCount) matching"))
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(appLocalized("Clear the search"))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, AppTheme.Spacing.small)
        .background(.quaternary, in: .rect(cornerRadius: AppTheme.Radius.chip))
    }
}

struct TranscriptReviewStepper: View {
    let queue: [Int]
    let focused: Int?
    let step: (Int) -> Void

    private var position: Int? {
        guard let focused else { return nil }
        return queue.firstIndex(of: focused).map { $0 + 1 }
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(systemName: queue.isEmpty ? "checkmark.circle" : "flag")
                .foregroundStyle(queue.isEmpty ? Color.secondary : AppTheme.Palette.reviewPending)
                .accessibilityHidden(true)
            Text(label)
                .font(AppTheme.Typography.metaStrong)
                .monospacedDigit()
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
                .accessibilityLabel(appLocalized("Go to the previous segment to review"))
            Button { step(1) } label: { Image(systemName: "chevron.down") }
                .accessibilityLabel(appLocalized("Go to the next segment to review"))
        }
        .buttonStyle(.plain)
        .disabled(queue.isEmpty)
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, 5)
        .background(.quaternary, in: .rect(cornerRadius: AppTheme.Radius.chip))
    }

    private var label: LocalizedStringResource {
        guard !queue.isEmpty else { return appLocalized("Nothing left to review") }
        guard let position else { return appLocalized("\(queue.count) to review") }
        return appLocalized("\(position) of \(queue.count) to review")
    }
}

struct TranscriptTransport: View {
    let playback: TranscriptPlaybackController
    let totalDurationS: Double
    let toggle: () -> Void
    let seek: (Double) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            Button(action: toggle) {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying
                ? appLocalized("Pause playback")
                : appLocalized("Play the recording"))

            Text(verbatim: TranscriptPlaybackTimeline.clock(playback.positionS))
                .font(AppTheme.Typography.metaStrong)
                .monospacedDigit()

            Slider(
                value: Binding(
                    get: { min(max(playback.positionS, 0), max(totalDurationS, 1)) },
                    set: { seek($0) }
                ),
                in: 0 ... max(totalDurationS, 1)
            )
            .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
            .accessibilityLabel(appLocalized("Playhead"))

            Text(verbatim: TranscriptPlaybackTimeline.clock(totalDurationS))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .padding(.vertical, AppTheme.Spacing.tight)
        .background(.quaternary, in: .rect(cornerRadius: AppTheme.Radius.chip))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Segment row

struct TranscriptSegmentRow: View {
    let item: TranscriptSegment
    let attribution: SegmentAttributionSummary
    /// Present only on the proposal layer. Rendered under the acoustics, never
    /// in place of them and never as the segment's speaker.
    var proposal: SegmentSpeakerProposal?
    let displaySpeaker: String
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color
    let text: String
    let needsReview: Bool
    let isReviewable: Bool
    let isFocused: Bool
    let isPlaying: Bool
    let isSelected: Bool
    let play: () -> Void
    let select: () -> Void
    let rename: () -> Void
    let review: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
            SpeakerRule(
                color: attribution.isAttributed
                    ? speakerColor(item.segment.speaker)
                    : AppTheme.Palette.unattributed,
                isAttributed: attribution.isAttributed
            )

            VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                metaRow
                Text(text)
                    .font(AppTheme.Typography.body)
                    .lineSpacing(AppTheme.Typography.bodyLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !attribution.isAttributed {
                    SpeakerEvidenceBlock(
                        attribution: attribution,
                        speakerName: speakerName,
                        speakerColor: speakerColor,
                        showsReason: SpeakerEvidenceBlock.showsReason(
                            for: attribution,
                            isFocused: isFocused
                        )
                    )
                }
                if let proposal {
                    SegmentProposalBlock(
                        proposal: proposal,
                        speakerName: speakerName,
                        speakerColor: speakerColor
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.Spacing.row)
        .background(background, in: .rect(cornerRadius: AppTheme.Radius.row))
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: AppTheme.Radius.row)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isSelected {
                RoundedRectangle(cornerRadius: AppTheme.Radius.row)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var metaRow: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            if attribution.isAttributed {
                Button(action: rename) {
                    Text(displaySpeaker)
                        .font(AppTheme.Typography.speaker)
                        .foregroundStyle(speakerColor(item.segment.speaker))
                }
                .buttonStyle(.plain)
                .help(appLocalized("Rename this speaker everywhere in this transcript."))
                if let share = attribution.contestedTopShare {
                    // Labelled, because a bare percent next to a name reads as
                    // "64 % sure this is Jina" rather than "Jina held 64 % of
                    // this segment's speech". The first is a confidence this
                    // product does not compute; the second is what the merger
                    // measured. The bare form is the narrow-width fallback
                    // only, where the label cannot fit.
                    ViewThatFits(in: .horizontal) {
                        Text(appLocalized("\(SegmentAttributionSummary.percent(share)) of speech"))
                        Text(verbatim: SegmentAttributionSummary.percent(share))
                    }
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(appLocalized("This speaker held this much of the segment's speech."))
                    .accessibilityLabel(appLocalized("This speaker held this much of the segment's speech."))
                }
            } else {
                Label {
                    Text(displaySpeaker)
                        .font(AppTheme.Typography.speaker)
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .foregroundStyle(.secondary)
            }

            Button(action: play) {
                Label {
                    Text(verbatim: TranscriptPlaybackTimeline.clock(item.segment.startS))
                } icon: {
                    Image(systemName: isPlaying ? "waveform" : "play.fill")
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .font(AppTheme.Typography.meta)
            .monospacedDigit()
            .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
            .help(appLocalized("Play the recording from this segment."))

            // The review marker sits with the speaker and the time rather than
            // across the row. 192 of 248 segments carry one on the measured
            // run, so a reader scans this column constantly, and a marker
            // pinned to the far edge makes that scan cross the whole page.
            if isReviewable {
                Button(action: review) {
                    Image(systemName: needsReview ? "flag" : "checkmark.circle.fill")
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(needsReview ? AppTheme.Palette.reviewPending : Color.secondary)
                .help(needsReview
                    ? appLocalized("Review what the pipeline was unsure about here.")
                    : appLocalized("You already reviewed this segment."))
                .accessibilityLabel(needsReview
                    ? appLocalized("Review what the pipeline was unsure about here.")
                    : appLocalized("You already reviewed this segment."))
            }

            // Both controls live with the speaker and the time. They do
            // different things — the flag opens the review, the circle adds the
            // segment to a copy selection — and pinning the second one to the
            // right edge of an 860-point reading measure made the eye travel
            // the width of the page to reach a secondary affordance.
            // A checkbox, not a circle. `checkmark.circle.fill` already means
            // "you reviewed this" on the marker eight points to the left, and
            // "this run finished" in the library sidebar; three meanings for
            // one glyph, two of them on the same row, is not a distinction a
            // reader can be asked to make from colour alone. A checkbox is
            // also what macOS uses for "include this in a bulk action", which
            // is what this is.
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.7))
            .help(appLocalized("Select this segment for copying."))
            .accessibilityLabel(isSelected
                ? appLocalized("Remove this segment from the copy selection.")
                : appLocalized("Select this segment for copying."))

            Spacer(minLength: AppTheme.Spacing.small)
        }
    }

    /// Flagging is not a background here. On the measured run 77.4 % of
    /// segments are flagged, so tinting them all says nothing; the page stays
    /// calm and only the segment the reader is on is loud.
    private var background: Color {
        if isFocused { return Color.accentColor.opacity(0.12) }
        if isPlaying { return Color.accentColor.opacity(0.06) }
        if isSelected { return Color.accentColor.opacity(0.08) }
        // Deliberately nothing. `controlBackgroundColor` resolves to the window
        // colour in both appearances, so a per-row card was invisible anyway,
        // and at 77.4 % flagged the page reads better as one document than as
        // 248 boxes.
        return .clear
    }
}

/// A speaker's colour, as a rule down the left edge of its segment. Faded when
/// no speaker was named. Colour carries nothing here that the speaker chip's
/// name and its glyph do not already carry, so a reader who cannot separate the
/// colours loses nothing.
struct SpeakerRule: View {
    let color: Color
    let isAttributed: Bool

    var body: some View {
        Capsule()
            .fill(color.opacity(isAttributed ? 1 : 0.35))
            .frame(width: 4)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }
}

/// The acoustic evidence for a segment nobody was named for: which speakers
/// overlapped it, for how long each, and one sentence saying why none was
/// chosen. This is what lets a reader settle a segment without the audio.
struct SpeakerEvidenceBlock: View {
    let attribution: SegmentAttributionSummary
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color
    /// See `showsReason(for:isFocused:)`.
    var showsReason: Bool = true

    /// Whether this segment's row prints its reason sentence.
    ///
    /// On the measured run 108 of the 110 unnamed segments collapse for the
    /// same reason, so printing that sentence under every one of them is 108
    /// copies of one fact. The shares carry it; the sentence appears on the
    /// segment the reader is on, and always for the two rarer outcomes, which
    /// say something the shares do not.
    ///
    /// **No outcome at all is its own case and never prints per row.** A
    /// translation result drops the conflicts, so every unnamed segment has a
    /// `nil` outcome; an earlier form of this predicate compared `nil` against
    /// one outcome, which is true, and reinstated the 110-copy wall on exactly
    /// the layer that had the least to say. It is stated once in the header
    /// instead — see `TranscriptEvidenceGap`.
    static func showsReason(
        for attribution: SegmentAttributionSummary,
        isFocused: Bool
    ) -> Bool {
        if isFocused { return true }
        guard let outcome = attribution.outcome else { return false }
        return outcome != .noDominantSpeaker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
            if !attribution.candidates.isEmpty {
                ShareMeter(
                    candidates: attribution.candidates,
                    color: speakerColor
                )
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AppTheme.Spacing.large) { candidateLabels }
                    VStack(alignment: .leading, spacing: 2) { candidateLabels }
                }
            }
            if showsReason, let reason = attribution.reason() {
                Text(verbatim: reason)
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var candidateLabels: some View {
        ForEach(attribution.candidates, id: \.speaker) { candidate in
            HStack(spacing: 5) {
                Circle()
                    .fill(speakerColor(candidate.speaker))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: speakerName(candidate.speaker))
                    .font(AppTheme.Typography.meta)
                Text(verbatim: SegmentAttributionSummary.percent(candidate.share))
                    .font(AppTheme.Typography.metaStrong)
                    .monospacedDigit()
                Text(verbatim: SegmentAttributionSummary.overlap(candidate.overlapS))
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// A proposed speaker, marked as a proposal wherever it appears. It sits under
/// the acoustic evidence, is labelled, is bordered rather than filled, and
/// never borrows the speaker chip's treatment — a reader must not be able to
/// mistake it for the segment's speaker, which is judgment rule 4 and the
/// condition D46 allows this layer to exist under.
struct SegmentProposalBlock: View {
    let proposal: SegmentSpeakerProposal
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: AppTheme.Spacing.small) {
                Text(proposal.proposedSpeaker == nil
                    ? appLocalized("No speaker proposed")
                    : appLocalized("Proposed, not measured"))
                    .font(AppTheme.Typography.meta)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.chip)
                            .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .foregroundStyle(.secondary)
                if let speaker = proposal.proposedSpeaker {
                    // The candidate treatment — a dot and a plain name — not
                    // the speaker chip's. Rendering a proposal the way an
                    // attributed speaker is rendered is the one mistake this
                    // block exists to avoid.
                    HStack(spacing: 5) {
                        Circle()
                            .fill(speakerColor(speaker))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(verbatim: speakerName(speaker))
                            .font(AppTheme.Typography.meta)
                    }
                }
            }
            Text(verbatim: proposal.reason)
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What the proposal layer is standing on. A proposal over a transcript with a
/// hole in it must say so where the proposals are, not in a manifest.
struct ProposalLayerNotice: View {
    let layer: TranscriptProposalLayer

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
            Label {
                Text(appLocalized("\(layer.proposedCount) proposed, \(layer.declinedCount) declined. Not acoustic evidence, and not measured."))
            } icon: {
                Image(systemName: "questionmark.bubble")
            }
            .font(AppTheme.Typography.meta)
            .foregroundStyle(.secondary)

            if !layer.sourceCoverage.complete {
                Label {
                    Text(appLocalized("\(SegmentAttributionSummary.overlap(layer.sourceCoverage.missingDurationS)) of this recording produced no transcript, so these proposals cover \(TranscriptPlaybackTimeline.clock(layer.sourceCoverage.processedDurationS)) of \(TranscriptPlaybackTimeline.clock(layer.sourceCoverage.inputDurationS))."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.reviewPending)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppTheme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: AppTheme.Radius.chip))
    }
}

struct ShareMeter: View {
    let candidates: [SpeakerCandidate]
    let color: (String) -> Color

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(candidates, id: \.speaker) { candidate in
                    Rectangle()
                        .fill(color(candidate.speaker).opacity(0.75))
                        .frame(width: max(2, geometry.size.width * candidate.share))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 320)
        .frame(height: 5)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

// MARK: - Sheets

struct SpeakerRenamePopover: View {
    let originalSpeaker: String
    @Binding var name: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            Text(appLocalized("Rename Speaker"))
                .font(AppTheme.Typography.sectionTitle)
            Text(appLocalized("This name applies to every \(originalSpeaker) segment in exports."))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
            TextField(appLocalized("Speaker name"), text: $name)
                .focused($focused)
                .onSubmit(save)
            HStack {
                Button(appLocalized("Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(appLocalized("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.large)
        .frame(width: 320)
        .task { focused = true }
    }
}

/// One sheet, three different things to show, chosen by what the conflict
/// record carries. A speaker conflict never offers text alternatives, because
/// its candidates are speaker IDs.
struct SegmentReviewSheet: View {
    let item: TranscriptSegment
    let target: TranscriptReviewTarget
    let displayedText: String
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color
    let currentResolution: String?
    let isTranslation: Bool
    let choose: (String) -> Void
    let rename: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            content
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: AppTheme.Spacing.medium) {
                if target.speakerEvidence != nil,
                   SpeakerRoster.isAttributed(item.segment.speaker)
                {
                    Button(appLocalized("Rename Speaker"), action: rename)
                }
                Spacer()
                if currentResolution == nil {
                    Button(appLocalized("Mark Reviewed")) { choose(item.segment.text) }
                        .buttonStyle(.borderedProminent)
                }
                Button(appLocalized("Close"), action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppTheme.Spacing.large)
            .background(.bar)
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 380, idealHeight: 520)
    }

    /// Rendered without the scroll view by the offscreen harness.
    var content: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            header

            if target.speakerEvidence != nil || !target.speakerCandidates.isEmpty {
                speakerSection
            }

            if !target.textAlternatives.isEmpty || isTranslation {
                textSection
            }

            provenanceSection

            Text(isTranslation
                ? appLocalized("Your acceptance applies only to this exact translated text. The immutable source transcript and translation remain unchanged.")
                : appLocalized("Your selection is stored as a correction beside the immutable raw transcript."))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
        }
        .padding(AppTheme.Spacing.screen)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Label(appLocalized("Review This Segment"), systemImage: "flag")
                .font(AppTheme.Typography.screenTitle)
            Text(verbatim: TranscriptPlaybackTimeline.clock(item.segment.startS))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(verbatim: displayedText)
                .font(AppTheme.Typography.body)
                .lineSpacing(AppTheme.Typography.bodyLineSpacing)
                .textSelection(.enabled)
                .padding(.top, AppTheme.Spacing.tight)
        }
    }

    private var speakerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Text(appLocalized("Who Was Speaking"))
                .font(AppTheme.Typography.sectionTitle)
            SpeakerEvidenceBlock(
                attribution: SegmentAttributionSummary(
                    speaker: item.segment.speaker,
                    attribution: target.speakerEvidence
                ),
                speakerName: speakerName,
                speakerColor: speakerColor
            )
            if let evidence = target.speakerEvidence {
                // The bar itself is already in the sentence above; repeating it
                // here made three grey sentences that say two things.
                Text(appLocalized("Timeline coverage \(SegmentAttributionSummary.percent(evidence.timelineCoverage))."))
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(.secondary)
            }
            Text(appLocalized("Maccheroni will not assign a speaker without acoustic evidence, so this stays as it is."))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Text(appLocalized("Wording"))
                .font(AppTheme.Typography.sectionTitle)
            CandidateButton(
                source: isTranslation
                    ? appLocalized("Post-processing")
                    : appLocalized("Primary Model"),
                text: item.segment.text,
                isSelected: currentResolution == item.segment.text,
                choose: choose
            )
            ForEach(Array(target.textAlternatives.enumerated()), id: \.offset) { index, candidate in
                CandidateButton(
                    source: appLocalized("Verification Model \(index + 1)"),
                    text: candidate,
                    isSelected: currentResolution == candidate,
                    choose: choose
                )
            }
        }
    }

    /// The merger's own reason text is engineering prose and is not localized.
    /// It is shown only where this surface has no localized sentence of its
    /// own: a text disagreement, or a speaker conflict written before the
    /// candidates were disclosed.
    private var untranslatedReason: String? {
        target.speakerEvidence == nil ? target.reason : nil
    }

    @ViewBuilder
    private var provenanceSection: some View {
        if target.hasBackendSpeakerEvidence || !target.otherMarkers.isEmpty
            || untranslatedReason != nil
        {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
                Text(appLocalized("What The Pipeline Recorded"))
                    .font(AppTheme.Typography.sectionTitle)
                if let reason = untranslatedReason {
                    Text(verbatim: reason)
                        .font(AppTheme.Typography.meta)
                        .foregroundStyle(.secondary)
                }
                if target.hasBackendSpeakerEvidence {
                    Text(appLocalized("The speech model also reported a speaker for this segment. It is kept as evidence and never becomes the speaker."))
                        .font(AppTheme.Typography.meta)
                        .foregroundStyle(.secondary)
                }
                if !target.otherMarkers.isEmpty {
                    Text(appLocalized("Other markers"))
                        .font(AppTheme.Typography.meta)
                    Text(verbatim: target.otherMarkers.joined(separator: ", "))
                        .font(AppTheme.Typography.meta.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct CandidateButton: View {
    let source: LocalizedStringResource
    let text: String
    let isSelected: Bool
    let choose: (String) -> Void

    var body: some View {
        Button {
            choose(text)
        } label: {
            HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
                    Text(source)
                        .font(AppTheme.Typography.meta)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(AppTheme.Spacing.medium)
            .background(.quaternary, in: .rect(cornerRadius: AppTheme.Radius.chip))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.chip)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct SpeakerEdit: Identifiable {
    let speaker: String
    var id: String { speaker }
}

private struct ExistingRunAction: Identifiable {
    let operation: PostprocessMode
    var id: String { operation.rawValue }
}

private struct ExistingRunPostprocessSheet: View {
    let operation: PostprocessMode
    let start: (PostprocessChoice, AppLanguage?) -> Void
    let cancel: () -> Void
    @State private var backend: PostprocessChoice
    @State private var targetLanguage: AppLanguage

    init(
        model: MaccheroniAppModel,
        operation: PostprocessMode,
        start: @escaping (PostprocessChoice, AppLanguage?) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.operation = operation
        self.start = start
        self.cancel = cancel
        _backend = State(initialValue: model.selectedPostprocess == .none
            ? .local
            : model.selectedPostprocess)
        _targetLanguage = State(initialValue: model.selectedTranslationTarget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.large) {
            Text(PostprocessOperationChoice(operation).title)
                .font(AppTheme.Typography.screenTitle)
            Picker(appLocalized("Backend"), selection: $backend) {
                Text(PostprocessChoice.codex.title).tag(PostprocessChoice.codex)
                Text(PostprocessChoice.local.title).tag(PostprocessChoice.local)
            }
            .pickerStyle(.segmented)
            if operation == .translation {
                Picker(appLocalized("Target Language"), selection: $targetLanguage) {
                    ForEach(AppLanguage.translationTargets) { language in
                        Text(language.title).tag(language)
                    }
                }
                .pickerStyle(.menu)
            }
            HStack {
                Button(appLocalized("Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    start(
                        backend,
                        operation == .translation ? targetLanguage : nil
                    )
                } label: {
                    Text(PostprocessOperationChoice(operation).title)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.screen)
        .frame(minWidth: 440)
    }
}
