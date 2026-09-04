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
    /// What the run did not transcribe, read once from the run's own record
    /// and `nil` for a run that covered its input.
    private let missingCoverage: TranscriptMissingCoverage?
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

    /// `initialLayer` seeds the reader's layer choice, exactly as if the tab
    /// had been clicked before the first draw: an unavailable layer falls back
    /// to the default the same way a stale choice does, and `nil`, the app's
    /// own value, changes nothing. It exists so the offscreen harness can
    /// render the shipped view on each layer; the app never passes it.
    init(
        model: MaccheroniAppModel,
        record: LibraryRecord,
        run: LoadedRun,
        proposal: SpeakerProposalDocument? = nil,
        initialLayer: TranscriptDisplayLayer? = nil
    ) {
        self.model = model
        self.record = record
        self.run = run
        self.proposal = proposal
        missingCoverage = TranscriptMissingCoverage.load(run: run, record: record)
        _selectedLayer = State(initialValue: initialLayer)
    }

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
    private var missingEvidence: TranscriptMissingEvidence? {
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
            // The boundary between the two grammars: product UI above it, the
            // editorial table below.
            AppHairline()
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
                    layer: displayLayer,
                    proposal: proposal
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
            // The result under the view changed, so what is playing is no
            // longer what is displayed. `preparePlayer` also refuses another
            // record's player; this ends the sound as well, rather than
            // leaving it running until the next control is touched.
            playback.stop()
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
                missingEvidence: missingEvidence,
                missingCoverage: missingCoverage,
                playback: playback,
                totalDurationS: max(record.durationS, run.manifest.coverage.inputDurationS),
                togglePlayback: {
                    model.stopPlayback()
                    playback.togglePlayPause(record: record)
                },
                seek: { playback.seek(to: $0, record: record) }
            )
            if displayLayer == .proposed, let proposalLayer {
                ProposalLayerNotice(layer: proposalLayer, showsCoverage: missingCoverage == nil)
            }
            if let copyFeedback {
                Label(
                    copyFeedback.message,
                    systemImage: copyFeedback.isError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(AppTheme.Typography.meta)
                .foregroundStyle(copyFeedback.isError ? AppTheme.Palette.error : AppTheme.Palette.inkSecondary)
                .transition(.opacity)
            }
            postprocessStatus
        }
        // The same measure and centring as the segment column below, so a
        // control and the thing it controls share one left edge. Full-bleed
        // chrome over a centred column put 261 points between the layer bar and
        // the first segment it switches, and a reader crosses that on every
        // pass down the page.
        .frame(maxWidth: AppTheme.Layout.measure, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.screen)
        .padding(.top, AppTheme.Spacing.large)
        .padding(.bottom, AppTheme.Spacing.medium)
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
                    Text(verbatim: modelID).foregroundStyle(AppTheme.Palette.inkSecondary)
                }
                Button(appLocalized("Cancel"), role: .cancel) {
                    model.cancelTranscription()
                }
            }
            .font(AppTheme.Typography.meta)
        } else if let failure = model.existingRunPostprocessFailure(for: record.id) {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.error)
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
                    gaps: searchText.isEmpty ? (missingCoverage?.gaps ?? []) : [],
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
                layer: displayLayer,
                proposal: proposal
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
enum TranscriptMissingEvidence: Equatable, Sendable {
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
    /// Everything the layer recorded about one declined segment.
    ///
    /// A decline used to arrive here as a bare sentence, which threw away the
    /// three fields D50's constraint writes precisely so a later measurement
    /// can tell what the constraint did from what the model did: the
    /// machine-readable `cause`, the `topRankedCandidate` the model was asked to
    /// confirm, and the model's own `modelAnswer` whenever the constraint
    /// rather than the model decided the outcome.
    struct Decline: Equatable, Sendable {
        /// The sentence the artifact carries. On a decline the constraint
        /// made, this is the runner's own English wording; on a decline the
        /// model made, it is the model's words in the transcript's language.
        var reason: String
        /// Absent on artifacts written before the confirm-or-decline
        /// constraint of 2026-09-02, which is why every reading of it treats
        /// `nil` as "say what the artifact said and nothing more".
        var cause: SpeakerProposalDeclineCause? = nil
        /// The top-ranked candidate the model was asked to confirm, when one
        /// existed. Not printed again: it is already the top row of the
        /// segment's share figures, by name and by share.
        var topRankedCandidate: String? = nil
        /// The model's own decision when the constraint, not the model,
        /// decided. A disagreement lives here and must survive to the reader.
        var modelAnswer: SpeakerProposalDecision? = nil
        /// The acoustic candidates this decline was measured against, carried
        /// so the sentence can tell an exact tie from a near one. Empty on
        /// artifacts written before the constraint, and on the cause that has
        /// no candidates at all.
        var candidates: [SpeakerCandidateEvidence] = []

        /// True when the model's own decline adds nothing this app's cause
        /// sentence does not already say, so printing both says one fact
        /// twice.
        ///
        /// It is exactly the no-candidates case, and for a structural reason
        /// rather than by comparing wordings: with no acoustic candidates the
        /// model was never asked to confirm anybody, so its decline can only
        /// restate that the segment has no speaker. The rendered rows say it
        /// plainly — "No speaker was active on the speaker timeline during
        /// this segment." followed by "The segment is silence and has no
        /// top-ranked candidate to confirm.", both in English, both the same
        /// fact. A tie is the opposite case and never folds: there the model
        /// was asked about a real pair of candidates and its answer is the
        /// evidence P11b kept.
        var modelRestatesCause: Bool {
            cause == .noAcousticCandidates && modelAnswer?.disposition == .decline
        }

        /// True when the top candidates hold the same overlap and no top-ranked candidate
        /// can be picked out of them.
        ///
        /// This asks the proposer's own rule rather than restating it, so the
        /// row can never call a tie the artifact did not, or miss one it did:
        /// `topRankedCandidate(among:)` returns a speaker only when exactly one
        /// candidate is within a nanosecond of the largest overlap, and `nil`
        /// otherwise. The comparison is on the overlapped seconds the merger
        /// measured, never on the percentages the row prints — those round,
        /// and rounding is what hides a tie. On the 2026-09-01 run a model
        /// decline at 0.5015 / 0.4985 and a true tie at 0.5000 / 0.5000 both
        /// print as 50 % / 50 %.
        var holdsEqualOverlap: Bool {
            !candidates.isEmpty
                && SpeakerProposalConstraint.topRankedCandidate(among: candidates) == nil
        }

        /// What this app can say in the reader's own language about why no
        /// speaker was proposed, or `nil` when only the artifact's sentence
        /// says it.
        ///
        /// Every sentence here already exists for the acoustic outcome that
        /// caused the decline, except the tie, which had no wording anywhere:
        /// a segment with no overlapping turn had no speaker active on the
        /// timeline, and a segment whose top candidates hold equal overlap had
        /// no speaker holding enough of the speech. The three causes that are
        /// the *model's* answer rather than the constraint's rule get no
        /// sentence, because the artifact's own wording is the model's
        /// reasoning and no app sentence can stand in for it.
        func causeSentence(locale: Locale? = nil) -> String? {
            switch cause {
            case .noAcousticCandidates:
                appString(
                    "No speaker was active on the speaker timeline during this segment.",
                    locale: locale
                )
            case .noTopRankedCandidate where holdsEqualOverlap:
                // The tie said as a tie. Nothing else on the row says it: the
                // shares round to 50 % / 50 % and the threshold sentence
                // below is true of every unattributed segment.
                //
                // "To within a nanosecond" rather than "exactly equal",
                // because the artifact's own `cause` is decided by
                // `topRankedCandidate(among:)`, which admits a tie inside
                // `topRankedMarginS` — a nanosecond of overlap. Saying exact
                // would let this row make a claim the artifact does not, and
                // making the comparison exact instead would let the row deny a
                // tie the artifact recorded. `theTieSentenceNamesTheMargin`
                // pins the sentence to the constant.
                appString(
                    "The top speakers held the same time in this segment, to within a nanosecond.",
                    locale: locale
                )
            case .noTopRankedCandidate:
                appString(
                    "No speaker held enough of this segment's speech, so none was named.",
                    locale: locale
                )
            case .modelDisagreedWithTopRankedCandidate, .modelDeclined, .noDecision, .none:
                nil
            }
        }

        /// The sentences that print under the segment's text, in order.
        ///
        /// When the constraint declined and the model declined too, the
        /// artifact's sentence is the runner's English restatement of the
        /// cause followed by the model's words; this app can say the first
        /// half itself, so it does and keeps only the model's half verbatim.
        /// When the model *proposed* somebody the constraint refused, the
        /// artifact's sentence names both that speaker and the top-ranked candidate, and it
        /// is kept whole — that disagreement is the evidence D50 exists to
        /// preserve, and it is deliberately carried as a sentence rather than
        /// as a name with a dot, which would put a non-acoustic answer beside
        /// the acoustic candidates as if it were one of them.
        ///
        /// `omittingCause` is for a row that is already printing the acoustic
        /// reason the cause sentence restates. See
        /// `TranscriptSegmentRow.proposalSentences`. A tie's sentence is the
        /// exception and never stands down: the acoustic reason it would defer
        /// to names the run's dominant-share bar, which is true of all 110
        /// unattributed segments, and says nothing about two candidates being
        /// exactly level. Standing down there would put the fact back where
        /// P11b found it, legible only from two rounded percentages that are
        /// equal for a near-tie too.
        func sentences(locale: Locale? = nil, omittingCause: Bool = false) -> [String] {
            guard let cause = causeSentence(locale: locale),
                  let answer = modelAnswer,
                  answer.disposition == .decline,
                  !answer.reason.isEmpty
            else { return [reason] }
            let omit = omittingCause && !holdsEqualOverlap
            return omit ? [answer.reason] : [cause, answer.reason]
        }
    }

    case proposed(speaker: String, reason: String)
    case declined(Decline)

    var proposedSpeaker: String? {
        if case let .proposed(speaker, _) = self { return speaker }
        return nil
    }

    var decline: Decline? {
        if case let .declined(decline) = self { return decline }
        return nil
    }

    /// The artifact's own sentence, whichever state this is.
    var reason: String {
        switch self {
        case let .proposed(_, reason): reason
        case let .declined(decline): decline.reason
        }
    }

    /// What prints under the segment's text. A proposal has only the
    /// proposer's reason; a decline may have the cause in this app's words
    /// first. See `Decline.sentences(locale:omittingCause:)`.
    func sentences(locale: Locale? = nil, omittingCause: Bool = false) -> [String] {
        switch self {
        case let .proposed(_, reason):
            [reason]
        case let .declined(decline):
            decline.sentences(locale: locale, omittingCause: omittingCause)
        }
    }

    /// The same sentences for a surface that prints no acoustic reason of its
    /// own — the clipboard, and a row that is not showing one. Nothing stands
    /// down here, because there is nothing beside it saying the same thing;
    /// the one fact still said once is the model decline that only restates
    /// this app's cause sentence.
    ///
    /// Shared with `TranscriptSegmentRow.proposalSentences` rather than
    /// restated there: two copies of this rule would let the clipboard and the
    /// screen disagree about what a decline said.
    func sentencesWithoutAcousticReason(locale: Locale? = nil) -> [String] {
        if let decline, decline.modelRestatesCause {
            return decline.causeSentence(locale: locale).map { [$0] } ?? [decline.reason]
        }
        return sentences(locale: locale, omittingCause: false)
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
        for decline in document.declined {
            proposals[decline.segmentIndex] = .declined(
                SegmentSpeakerProposal.Decline(
                    reason: decline.reason,
                    cause: decline.cause,
                    topRankedCandidate: decline.topRankedCandidate,
                    modelAnswer: decline.modelAnswer,
                    candidates: decline.acousticCandidates
                )
            )
            evidence[decline.segmentIndex] = InlineEvidence(
                outcome: decline.acousticOutcome,
                timelineCoverage: decline.acousticTimelineCoverage,
                candidates: decline.acousticCandidates
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

    /// A segment whose text is the engine's non-speech marker. The row itself
    /// is the word for it, so it is not an "other marker".
    static let nonSpeechEvent = NonSpeechEvent.flag

    static func otherMarkers(_ flags: [String]) -> [String] {
        let known = [conflict, uncertain, backendSpeakerEvidence, nonSpeechEvent]
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

/// Where the review navigator goes next. The count of unresolved segments is a
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
    /// Which record the live player was built for. A controller outlives a
    /// selection change whenever SwiftUI keeps the transcript view's identity,
    /// so "a player exists" is not "the right player exists".
    @ObservationIgnored private(set) var preparedRecordID: UUID?
    /// The source the live player was built from, as the record declared it.
    /// Compared rather than re-resolved: `seek` runs on every frame of a
    /// scrubber drag, and resolving a security-scoped bookmark there would put
    /// file-system work in the drag loop. A record whose file moves keeps its
    /// declared URL only while the library index is unchanged, and the index
    /// changing is what replaces the record here.
    @ObservationIgnored private(set) var preparedSourceURL: URL?
    /// How the player is built. Injected so a test can watch this lifecycle
    /// without audio, a window server, or a decodable file.
    @ObservationIgnored private let makePlayer: (URL) -> AVPlayer

    init(makePlayer: @escaping (URL) -> AVPlayer = { AVPlayer(url: $0) }) {
        self.makePlayer = makePlayer
    }

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
        // Pausing is about the audio that is playing, so it applies only when
        // the audio that is playing is this record's. Otherwise this is the
        // first press on a newly selected record and has to build its player.
        if isPlaying, isPrepared(for: record) {
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
        preparedRecordID = nil
        preparedSourceURL = nil
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

    /// Whether the live player is this record's.
    func isPrepared(for record: LibraryRecord) -> Bool {
        player != nil
            && preparedRecordID == record.id
            && preparedSourceURL == record.sourceURL
    }

    private func preparePlayer(for record: LibraryRecord) -> Bool {
        if isPrepared(for: record) { return true }
        // A player built for another record is torn down rather than reused.
        // Reusing it played run A's audio under run B's transcript, with run
        // B's playhead and run B's segment highlight following it.
        if player != nil { stop() }
        guard let url = Self.sourceURL(for: record) else {
            errorMessage = appString("The original recording could not be found.")
            return false
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        let player = makePlayer(url)
        self.player = player
        preparedRecordID = record.id
        preparedSourceURL = record.sourceURL
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
        layer: TranscriptDisplayLayer? = nil,
        proposal: SpeakerProposalDocument? = nil
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
            layer: layer,
            proposal: proposal
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
        layer: TranscriptDisplayLayer? = nil,
        proposal: SpeakerProposalDocument? = nil
    ) throws -> TranscriptCopyConfirmation {
        let payload = try payload(
            run: run,
            record: record,
            selectedSegmentIDs: selectedSegmentIDs,
            layer: layer,
            proposal: proposal
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
//
// Two grammars, one boundary. Everything in this section is product UI: a
// control may carry a hairline border and the displayed tab an accent
// underline. The row list further down is an editorial table and has none of
// that. `AppHairline` is the rule between them.

/// A one-point rule in the hairline colour.
struct AppHairline: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Everything above the transcript that changes what the transcript shows:
/// what this recording is, which layer, what is searched, where the review
/// navigator is, and where the playhead is.
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
    var missingEvidence: TranscriptMissingEvidence?
    /// The run's missing ranges, stated once above the rows on every layer.
    var missingCoverage: TranscriptMissingCoverage?
    let playback: TranscriptPlaybackController
    let totalDurationS: Double
    let togglePlayback: () -> Void
    let seek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.large) {
                    titleBlock
                    Spacer(minLength: AppTheme.Spacing.large)
                    transport
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    titleBlock
                    transport
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppTheme.Spacing.large) {
                    layerBar
                    searchField
                        .frame(minWidth: 220)
                    reviewNavigator
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    HStack(spacing: AppTheme.Spacing.large) {
                        layerBar
                        Spacer(minLength: AppTheme.Spacing.small)
                        reviewNavigator
                    }
                    searchField
                }
            }

            if let missingEvidence {
                Label {
                    Text(verbatim: missingEvidence.sentence())
                } icon: {
                    Image(systemName: "questionmark.circle")
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            // A hole in the record is open work for the reader, so this is the
            // open colour beside a sentence: how much, where, and what the
            // transcript covers. It prints on every layer.
            if let missingCoverage {
                Label {
                    Text(verbatim: missingCoverage.sentence())
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.open)
                .fixedSize(horizontal: false, vertical: true)
            }
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
                .foregroundStyle(AppTheme.Palette.inkSecondary)
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

    private var searchField: some View {
        TranscriptSearchField(text: $searchText, matchCount: matchCount)
    }

    private var reviewNavigator: some View {
        TranscriptReviewNavigator(
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

/// Four text tabs, always all four. The displayed layer is semibold with an
/// accent underline; an available one is regular; one this run cannot show is
/// the secondary ink, disabled, and says why. No fill, no pill: the bar is
/// where a reader learns what the product can produce, and it should read as
/// a list of names rather than as a control that hides three of them.
struct TranscriptLayerBar: View {
    let options: [TranscriptLayerOption]
    let selection: TranscriptDisplayLayer
    let select: (TranscriptDisplayLayer) -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.large) {
            ForEach(options) { option in
                if option.isAvailable {
                    Button {
                        select(option.layer)
                    } label: {
                        tab(option)
                    }
                    .buttonStyle(.plain)
                    .help(appString("Show this layer of the transcript."))
                    .accessibilityLabel(Text(option.layer.title))
                    .accessibilityAddTraits(option.layer == selection ? [.isSelected] : [])
                } else {
                    // Not a disabled button. `.disabled` dims the label on top
                    // of the declared colour, which took the unavailable tabs
                    // to 1.98:1 in light and 2.95:1 in dark on the rendered
                    // pixels — the bar a reader learns the product's
                    // capabilities from was the least legible thing on it.
                    // A layer this run cannot show is a name, not a control
                    // that refuses to work, so it is drawn as one and keeps
                    // the secondary ink it declares.
                    tab(option)
                        .help(option.unavailability?.sentence() ?? "")
                        .accessibilityElement()
                        .accessibilityLabel(Text(option.layer.title))
                        .accessibilityHint(Text(verbatim: option.unavailability?.sentence() ?? ""))
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tab(_ option: TranscriptLayerOption) -> some View {
        Text(option.layer.title)
            .font(option.layer == selection
                ? AppTheme.Typography.speaker
                : Font.system(size: 13))
            .foregroundStyle(option.isAvailable
                ? AppTheme.Palette.ink
                : AppTheme.Palette.inkSecondary)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
                if option.layer == selection {
                    Rectangle()
                        .fill(AppTheme.Palette.accent)
                        .frame(height: 2)
                }
            }
            .contentShape(.rect)
    }
}

struct TranscriptSearchField: View {
    @Binding var text: String
    let matchCount: Int?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                .accessibilityHidden(true)
            TextField(appLocalized("Search this transcript"), text: $text)
                .textFieldStyle(.plain)
                .font(Font.system(size: 13))
            if let matchCount {
                Text(appLocalized("\(matchCount) matching"))
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(AppTheme.Palette.inkSecondary)
                    .monospacedDigit()
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                .accessibilityLabel(appLocalized("Clear the search"))
            }
        }
        .padding(.horizontal, AppTheme.Spacing.small)
        .padding(.vertical, 5)
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                .strokeBorder(AppTheme.Palette.controlBorder, lineWidth: 1)
        }
    }
}

/// The unresolved count as a control. The flag beside it is the one place on
/// the screen where the open colour marks the reader's open work as a whole.
struct TranscriptReviewNavigator: View {
    let queue: [Int]
    let focused: Int?
    let step: (Int) -> Void

    private var position: Int? {
        guard let focused else { return nil }
        return queue.firstIndex(of: focused).map { $0 + 1 }
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(systemName: queue.isEmpty ? "checkmark" : "flag")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(queue.isEmpty ? AppTheme.Palette.inkSecondary : AppTheme.Palette.open)
                .accessibilityHidden(true)
            Text(label)
                .font(AppTheme.Typography.metaStrong)
                .monospacedDigit()
            StepButton(glyph: "chevron.up", action: { step(-1) })
                .accessibilityLabel(appLocalized("Go to the previous segment to review"))
            StepButton(glyph: "chevron.down", action: { step(1) })
                .accessibilityLabel(appLocalized("Go to the next segment to review"))
        }
        .disabled(queue.isEmpty)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var label: LocalizedStringResource {
        guard !queue.isEmpty else { return appLocalized("Nothing left to review") }
        guard let position else { return appLocalized("\(queue.count) to review") }
        return appLocalized("\(position) of \(queue.count) to review")
    }
}

/// A square glyph button at the control radius, bordered in the control-border
/// token: the stroke is the whole visual claim that this is operable, so it is
/// not drawn in the decorative hairline.
struct StepButton: View {
    let glyph: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                        .strokeBorder(AppTheme.Palette.controlBorder, lineWidth: 1)
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                            .strokeBorder(AppTheme.Palette.controlBorder, lineWidth: 1)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying
                ? appLocalized("Pause playback")
                : appLocalized("Play the recording"))

            Text(verbatim: TranscriptPlaybackTimeline.clock(playback.positionS))
                .font(AppTheme.Typography.metaStrong)
                .monospacedDigit()

            TranscriptPlayhead(
                positionS: playback.positionS,
                totalDurationS: totalDurationS,
                seek: seek
            )

            Text(verbatim: TranscriptPlaybackTimeline.clock(totalDurationS))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                .monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Where you are in the recording, drawn from the tokens.
///
/// This was a system `Slider` until it was rendered for the first time. Its
/// knob is `#FAFAFA` and takes no tint, so at the position the screen opens on
/// it measured **1.04:1 against the page and 1.14:1 against its own track** in
/// the light appearance: the one control that says where you are was the least
/// visible thing in the header, and only became legible once the value moved
/// far enough for the system's blue leading fill to appear. The knob here is
/// the accent at 6.4:1 light and 8.0:1 dark from the first frame, with a
/// page-coloured ring so it stays separate from its own fill.
struct TranscriptPlayhead: View {
    let positionS: Double
    let totalDurationS: Double
    let seek: (Double) -> Void

    private let trackHeight: CGFloat = 4
    private let knobDiameter: CGFloat = 12

    private var total: Double { max(totalDurationS, 1) }

    private var fraction: CGFloat {
        CGFloat(min(max(positionS, 0), total) / total)
    }

    var body: some View {
        GeometryReader { geometry in
            let travel = max(0, geometry.size.width - knobDiameter)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Palette.hairline)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(AppTheme.Palette.accent)
                    .frame(width: knobDiameter / 2 + travel * fraction, height: trackHeight)
                Circle()
                    .fill(AppTheme.Palette.accent)
                    .overlay {
                        Circle().strokeBorder(AppTheme.Palette.ground, lineWidth: 1.5)
                    }
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard travel > 0 else { return }
                        let x = min(max(value.location.x - knobDiameter / 2, 0), travel)
                        seek(Double(x / travel) * total)
                    }
            )
        }
        .frame(minWidth: 120, idealWidth: 200, maxWidth: 260)
        .frame(height: knobDiameter)
        .accessibilityElement()
        .accessibilityLabel(appLocalized("Playhead"))
        .accessibilityValue(Text(verbatim: TranscriptPlaybackTimeline.clock(positionS)))
        .accessibilityAdjustableAction { direction in
            let step = max(total / 20, 1)
            switch direction {
            case .increment: seek(min(positionS + step, total))
            case .decrement: seek(max(positionS - step, 0))
            @unknown default: break
            }
        }
    }
}

/// What the proposal layer is standing on. A proposal over a transcript with a
/// hole in it must say so where the proposals are, not in a manifest.
struct ProposalLayerNotice: View {
    let layer: TranscriptProposalLayer
    /// False when the header already prints the run's missing ranges, which
    /// say the same thing with the places named.
    var showsCoverage: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
            Label {
                Text(appLocalized("\(layer.proposedCount) proposed, \(layer.declinedCount) declined. Not acoustic evidence, and not measured."))
            } icon: {
                Image(systemName: "questionmark.bubble")
            }
            .font(AppTheme.Typography.meta)
            .foregroundStyle(AppTheme.Palette.inkSecondary)

            if showsCoverage, !layer.sourceCoverage.complete {
                Label {
                    Text(appLocalized("\(SegmentAttributionSummary.overlap(layer.sourceCoverage.missingDurationS)) of this recording produced no transcript, so these proposals cover \(TranscriptPlaybackTimeline.clock(layer.sourceCoverage.processedDurationS)) of \(TranscriptPlaybackTimeline.clock(layer.sourceCoverage.inputDurationS))."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.open)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The row list
//
// Below the rule the grammar changes. This is an editorial table: hierarchy
// from type, spacing and hairlines; no card, no fill, no coloured strip, no
// pill; one accent for the current thing; status colour only for a genuinely
// open state and always beside a word. Every row is a set of fixed-width
// gutter columns beside the text, so the eye reads down one column.

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
    /// Where the recording produced no transcript, each shown as a row at its
    /// place in time so a reader sees where the hole is.
    var gaps: [TranscriptGap] = []
    let play: (TranscriptSegment) -> Void
    let select: (TranscriptSegment) -> Void
    let rename: (TranscriptSegment) -> Void
    let review: (TranscriptSegment) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                if segments.isEmpty {
                    Text(appLocalized("No segment matches this search."))
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                        .padding(.vertical, AppTheme.Spacing.screen)
                }
                let entries = self.entries
                ForEach(entries) { entry in
                    switch entry {
                    case let .segment(item):
                        TranscriptSegmentRow(
                            item: item,
                            attribution: attribution(for: item),
                            proposal: proposalLayer?.proposal(at: item.index),
                            displaySpeaker: displayName(item.segment.speaker),
                            speakerName: displayName,
                            speakerColor: { roster.color(for: $0) },
                            text: text(item),
                            reviewState: reviewState(for: item),
                            isFocused: focusedSegmentIndex == item.index,
                            isPlaying: playingSegmentIndex == item.index,
                            isSelected: selectedSegmentIDs.contains(item.id),
                            isLast: entry.id == entries.last?.id,
                            play: { play(item) },
                            select: { select(item) },
                            rename: { rename(item) },
                            review: { review(item) }
                        )
                        .id(item.id)
                    case let .gap(gap):
                        TranscriptGapRow(gap: gap, isLast: entry.id == entries.last?.id)
                    }
                }
            } header: {
                TranscriptColumnHeader()
            }
        }
        .frame(maxWidth: AppTheme.Layout.measure, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.screen)
        .padding(.bottom, AppTheme.Spacing.screen)
        .frame(maxWidth: .infinity)
    }

    private var entries: [TranscriptRowEntry] {
        Self.entries(segments: segments, gaps: gaps)
    }

    /// The rows in reading order: every segment, with each gap placed before
    /// the first segment that starts at or after it, or after the last.
    static func entries(
        segments: [TranscriptSegment],
        gaps: [TranscriptGap]
    ) -> [TranscriptRowEntry] {
        guard !gaps.isEmpty else { return segments.map(TranscriptRowEntry.segment) }
        let positions = TranscriptGap.positions(
            of: gaps,
            amongSegmentsStartingAt: segments.map(\.segment.startS)
        )
        var entries: [TranscriptRowEntry] = []
        for (index, item) in segments.enumerated() {
            entries.append(contentsOf: (positions[index] ?? []).map(TranscriptRowEntry.gap))
            entries.append(.segment(item))
        }
        entries.append(contentsOf: (positions[segments.count] ?? []).map(TranscriptRowEntry.gap))
        return entries
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

    private func reviewState(for item: TranscriptSegment) -> TranscriptReviewChip.State? {
        guard isReviewable(item) else { return nil }
        return TranscriptReviewChip.State(
            needsReview: needsReview(item),
            hasWordingToChoose: !TranscriptReviewTarget(item: item).textAlternatives.isEmpty
        )
    }
}

/// One row of the table: a segment, or the place where a stretch of the
/// recording produced no transcript.
enum TranscriptRowEntry: Identifiable, Equatable {
    case segment(TranscriptSegment)
    case gap(TranscriptGap)

    enum ID: Hashable {
        case segment(TranscriptSegmentID)
        case gap(String)
    }

    var id: ID {
        switch self {
        case let .segment(item): .segment(item.id)
        case let .gap(gap): .gap(gap.id)
        }
    }
}

/// The row at a hole in the record. It keeps the table's columns so the eye
/// reading down the times finds it where it belongs: the gap's start in the
/// time column and one sentence in the text column, both in the open colour
/// beside a glyph, nothing in the speaker or review columns, and the same
/// hairline as every other row. No fill, no strip.
struct TranscriptGapRow: View {
    let gap: TranscriptGap
    var isLast: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Color.clear
                .frame(width: AppTheme.Layout.selectColumn, height: 1)
            Spacer().frame(width: AppTheme.Layout.columnGap)
            Text(verbatim: TranscriptPlaybackTimeline.clock(gap.startS))
                .font(AppTheme.Typography.metaStrong)
                .monospacedDigit()
                .lineLimit(1)
                .foregroundStyle(AppTheme.Palette.open)
                .frame(width: AppTheme.Layout.timeColumn, alignment: .leading)
            Spacer().frame(width: AppTheme.Layout.columnGap)
            Color.clear
                .frame(width: AppTheme.Layout.evidenceSpan, height: 1)
            Spacer().frame(width: AppTheme.Layout.textGap)
            Label {
                Text(verbatim: gap.sentence())
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(AppTheme.Typography.meta)
            .foregroundStyle(AppTheme.Palette.open)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppTheme.Spacing.rowVertical)
        .overlay(alignment: .bottom) {
            if !isLast { AppHairline() }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The column names, once, pinned above the rows. This is where the share
/// column gets its label: a `64%` under SHARE cannot be misread as a
/// confidence, and the label is printed once rather than beside every figure.
struct TranscriptColumnHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Layout.columnGap) {
            Color.clear
                .frame(width: AppTheme.Layout.selectColumn, height: 1)
            columnLabel(appLocalized("Time"))
                .frame(width: AppTheme.Layout.timeColumn, alignment: .leading)
            HStack(alignment: .firstTextBaseline) {
                columnLabel(appLocalized("Speaker"))
                Spacer(minLength: AppTheme.Spacing.tight)
                columnLabel(appLocalized("Share"))
            }
            .frame(width: AppTheme.Layout.speakerColumn)
            columnLabel(appLocalized("Review"))
                .frame(width: AppTheme.Layout.reviewColumn, alignment: .leading)
            columnLabel(appLocalized("Text"))
                .padding(.leading, AppTheme.Layout.textGap - AppTheme.Layout.columnGap)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, AppTheme.Spacing.medium)
        .padding(.bottom, AppTheme.Spacing.small)
        .overlay(alignment: .bottom) { AppHairline() }
        .background(AppTheme.Palette.ground)
        .accessibilityHidden(true)
    }

    private func columnLabel(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(AppTheme.Typography.label)
            .textCase(.uppercase)
            .foregroundStyle(AppTheme.Palette.inkSecondary)
            .lineLimit(1)
    }
}

// MARK: - Segment row

/// One row of the table: select, time, speaker and share, review, text. The
/// gutter is fixed-width so every column aligns across rows; an unnamed
/// segment adds a second gutter line for its evidence and, on the proposal
/// layer, a third for the proposal. Nothing here is a box: the focused row is
/// marked by the accent on its time, a heavier weight, and a 2-point rule
/// where its hairline would be.
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
    /// `nil` when the segment has nothing to review.
    let reviewState: TranscriptReviewChip.State?
    let isFocused: Bool
    let isPlaying: Bool
    let isSelected: Bool
    var isLast: Bool = false
    let play: () -> Void
    let select: () -> Void
    let rename: () -> Void
    let review: () -> Void

    private var showsReason: Bool {
        SpeakerEvidenceBlock.showsReason(for: attribution, isFocused: isFocused)
    }

    /// The acoustic reason this row is already printing, if it is printing one.
    private var acousticReason: String? {
        guard !attribution.isAttributed, showsReason else { return nil }
        return attribution.reason()
    }

    /// What the proposal layer adds under the text.
    ///
    /// A decline's cause sentence is this app's fallback for a row whose
    /// acoustic reason is not on screen. When that reason *is* on screen it
    /// says the same thing and says it better — it names the run's own
    /// threshold — so the cause sentence stands down rather than printing a
    /// near-duplicate beneath it. Nothing is lost either way: the model's own
    /// words are the second sentence and always print.
    private var proposalSentences: [String] {
        guard let proposal else { return [] }
        // A decline whose model answer only restates the cause prints the
        // fact once: this app's sentence when the row has no acoustic reason
        // of its own, and nothing at all when the row already prints one —
        // which for this cause is the same sentence again.
        guard acousticReason != nil else {
            return proposal.sentencesWithoutAcousticReason()
        }
        if proposal.decline?.modelRestatesCause == true { return [] }
        return proposal.sentences(omittingCause: true)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            selectionBox
                .frame(width: AppTheme.Layout.selectColumn, alignment: .leading)
            Spacer().frame(width: AppTheme.Layout.columnGap)
            timeControl
                .frame(width: AppTheme.Layout.timeColumn, alignment: .leading)
            Spacer().frame(width: AppTheme.Layout.columnGap)
            gutter
                .frame(width: AppTheme.Layout.evidenceSpan, alignment: .leading)
            Spacer().frame(width: AppTheme.Layout.textGap)
            textColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, AppTheme.Spacing.rowVertical)
        .overlay(alignment: .bottom) {
            if isFocused {
                Rectangle()
                    .fill(AppTheme.Palette.accent)
                    .frame(height: 2)
                    .accessibilityHidden(true)
            } else if !isLast {
                AppHairline()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // A checkbox, not a circle. `checkmark.circle.fill` already means "you
    // reviewed this" elsewhere, and a checkbox is what macOS uses for "include
    // this in a bulk action", which is what this is.
    private var selectionBox: some View {
        Button(action: select) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppTheme.Palette.accent : AppTheme.Palette.inkSecondary)
        .help(appLocalized("Select this segment for copying."))
        .accessibilityLabel(isSelected
            ? appLocalized("Remove this segment from the copy selection.")
            : appLocalized("Select this segment for copying."))
    }

    /// The segment's start, and the control that plays from it. The waveform
    /// glyph appears only while this segment is playing; 248 play triangles
    /// down a column would say nothing, and the focused row is marked by the
    /// accent and the weight, not by a glyph.
    private var timeControl: some View {
        Button(action: play) {
            HStack(spacing: 3) {
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(verbatim: TranscriptPlaybackTimeline.clock(item.segment.startS))
                    .font(isFocused ? AppTheme.Typography.metaStrong : AppTheme.Typography.meta)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isPlaying || isFocused ? AppTheme.Palette.accent : AppTheme.Palette.inkSecondary)
        .help(appLocalized("Play the recording from this segment."))
    }

    private var gutter: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Layout.columnGap) {
                speakerCell
                    .frame(width: AppTheme.Layout.speakerColumn, alignment: .leading)
                reviewCell
                    .frame(width: AppTheme.Layout.reviewColumn, alignment: .leading)
            }
            if !attribution.isAttributed, !attribution.candidates.isEmpty {
                SpeakerShareFigures(
                    candidates: attribution.candidates,
                    speakerName: speakerName,
                    speakerColor: speakerColor
                )
            }
            if let proposal {
                SegmentProposalLine(
                    proposal: proposal,
                    speakerName: speakerName,
                    speakerColor: speakerColor
                )
            }
        }
    }

    @ViewBuilder
    private var speakerCell: some View {
        if attribution.isAttributed {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.tight) {
                Button(action: rename) {
                    Text(displaySpeaker)
                        .font(AppTheme.Typography.speaker)
                        .foregroundStyle(speakerColor(item.segment.speaker))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(appLocalized("Rename this speaker everywhere in this transcript."))
                if let share = attribution.contestedTopShare {
                    Spacer(minLength: 0)
                    Text(verbatim: SegmentAttributionSummary.percent(share))
                        .font(AppTheme.Typography.meta)
                        .monospacedDigit()
                        .help(appLocalized("This speaker held this much of the segment's speech."))
                        .accessibilityLabel(appLocalized("This speaker held this much of the segment's speech."))
                }
            }
        } else {
            Text(displaySpeaker)
                .font(AppTheme.Typography.speaker)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var reviewCell: some View {
        if let reviewState {
            Button(action: review) {
                TranscriptReviewChip(state: reviewState)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(reviewState.needsReview
                ? appLocalized("Review what Maccheroni was unsure about here.")
                : appLocalized("You already reviewed this segment."))
            .accessibilityLabel(reviewState.needsReview
                ? appLocalized("Review what Maccheroni was unsure about here.")
                : appLocalized("You already reviewed this segment."))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    /// The engine's non-speech marker, when this row's text is one and nothing
    /// else. Read from the flag the run wrote, or from the text for a run
    /// sealed before the flag existed.
    private var nonSpeechEvent: NonSpeechEvent? {
        NonSpeechEvent.of(text: text, flags: item.segment.flags)
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
            if let nonSpeechEvent {
                NonSpeechEventText(event: nonSpeechEvent)
            } else {
                Text(text)
                    .font(AppTheme.Typography.body)
                    .lineSpacing(AppTheme.Typography.bodyLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reason = acousticReason {
                Text(verbatim: reason)
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(AppTheme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(proposalSentences.enumerated()), id: \.offset) { _, sentence in
                Text(verbatim: sentence)
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(AppTheme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The event treatment: what the text column prints for a segment that holds
/// no speech. The engine's marker, `[Silence]`, is a token and never reaches
/// the reading surface; the row prints the event in the reader's language,
/// italic and in the secondary ink, so it reads as a stage direction rather
/// than as something somebody said, and the italic carries the mark for a
/// reader who cannot tell the two inks apart. No glyph, no chip, no brackets.
/// A label outside the known vocabulary prints its own marker, because the
/// marker is the only record of what it was.
struct NonSpeechEventText: View {
    let event: NonSpeechEvent

    var body: some View {
        let label = event.label()
        Text(verbatim: label)
            .font(AppTheme.Typography.body)
            .italic()
            .lineSpacing(AppTheme.Typography.bodyLineSpacing)
            .foregroundStyle(AppTheme.Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(appLocalized("The speech model marked this segment as a non-speech event, not as words."))
            .accessibilityLabel(Text(verbatim: appString("Non-speech event: \(label)")))
    }
}

extension NonSpeechEvent {
    /// The event in the reader's language. `other` has no word of its own and
    /// prints the marker the engine wrote.
    func label(locale: Locale? = nil) -> String {
        switch kind {
        case .silence: appString("Silence", locale: locale)
        case .humanSounds: appString("Human sounds", locale: locale)
        case .environmentalSounds: appString("Environmental sounds", locale: locale)
        case .music: appString("Music", locale: locale)
        case .noise: appString("Noise", locale: locale)
        case .untranscribedSpeech: appString("Speech without words", locale: locale)
        case .other: marker
        }
    }
}

/// The review marker: an 11-point heavy label with a glyph, 2-point radius,
/// one-point border, neutral by default. 192 of 248 rows carry one on the
/// measured run, and a neutral chip in the secondary ink is part of the
/// table's texture rather than a warning. Colour is kept for the one variant
/// whose state is genuinely open — a wording the reader must choose — and
/// review state is carried by the glyph shape and the label, never by colour.
struct TranscriptReviewChip: View {
    struct State: Equatable, Sendable {
        var needsReview: Bool
        /// The segment has alternative wordings to choose between: a text
        /// disagreement, or a post-processing candidate merged onto it.
        var hasWordingToChoose: Bool

        var isOpen: Bool { needsReview && hasWordingToChoose }
    }

    let state: State

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: state.needsReview ? "flag" : "checkmark")
                .font(.system(size: 9, weight: .heavy))
            Text(label)
                .font(AppTheme.Typography.label)
                .lineLimit(1)
        }
        .foregroundStyle(state.isOpen ? AppTheme.Palette.open : AppTheme.Palette.inkSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.chip)
                .strokeBorder(
                    state.isOpen ? AppTheme.Palette.open : AppTheme.Palette.inkSecondary,
                    lineWidth: 1
                )
        }
    }

    private var label: LocalizedStringResource {
        if !state.needsReview { return appLocalized("Reviewed") }
        return state.hasWordingToChoose ? appLocalized("Wording") : appLocalized("Review")
    }
}

/// The acoustic evidence for a segment nobody was named for, as the row shows
/// it: each candidate's name in its colour and its share, always printed, with
/// a 3-point band split by share beneath them. The band answers "how close was
/// it, and who led" faster than two percentages can be compared; the figures
/// are the record and the band is the reading aid. It sits beneath the figures
/// rather than behind them so both keep their contrast.
struct SpeakerShareFigures: View {
    let candidates: [SpeakerCandidate]
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.medium) {
                ForEach(candidates, id: \.speaker) { candidate in
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.tight) {
                        Text(verbatim: speakerName(candidate.speaker))
                            .font(AppTheme.Typography.metaStrong)
                            .foregroundStyle(speakerColor(candidate.speaker))
                            .lineLimit(1)
                        Text(verbatim: SegmentAttributionSummary.percent(candidate.share))
                            .font(AppTheme.Typography.meta)
                            .monospacedDigit()
                    }
                }
            }
            ShareBand(
                candidates: candidates,
                color: speakerColor,
                height: AppTheme.Layout.bandHeight
            )
        }
        .accessibilityElement(children: .combine)
    }
}

/// A proposed speaker, marked as a proposal wherever it appears: a dashed
/// label, then the candidate treatment — a dot and a plain name — never the
/// speaker treatment. A reader must not be able to mistake it for the
/// segment's speaker, which is judgment rule 4 and the condition D46 allows
/// this layer to exist under. A decline is the same dashed label with different
/// words; the reason for either prints under the text.
struct SegmentProposalLine: View {
    let proposal: SegmentSpeakerProposal
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color

    var body: some View {
        // The name goes beside the label where the span allows and under it
        // where it does not; the label never wraps.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.small) {
                label
                candidate
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
                label
                candidate
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(proposal.proposedSpeaker == nil
            ? appLocalized("No speaker proposed")
            : appLocalized("Proposed, not measured"))
            .font(AppTheme.Typography.label)
            .foregroundStyle(AppTheme.Palette.inkSecondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.chip)
                    .strokeBorder(
                        AppTheme.Palette.inkSecondary,
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                    )
            }
    }

    @ViewBuilder
    private var candidate: some View {
        if let speaker = proposal.proposedSpeaker {
            HStack(spacing: AppTheme.Spacing.tight) {
                Circle()
                    .fill(speakerColor(speaker))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(verbatim: speakerName(speaker))
                    .font(AppTheme.Typography.meta)
                    .lineLimit(1)
            }
        }
    }
}

/// The full evidence block, used by the review sheet: the wide band, one line
/// per candidate with name, share and overlapped seconds, and the reason. The
/// row prints a compact form of the same numbers; this is where the seconds
/// and the sentence always are.
struct SpeakerEvidenceBlock: View {
    let attribution: SegmentAttributionSummary
    let speakerName: (String) -> String
    let speakerColor: (String) -> Color
    /// See `showsReason(for:isFocused:)`.
    var showsReason: Bool = true

    /// Whether this segment's row prints its reason sentence.
    ///
    /// On the measured run 100 of the 110 unnamed segments collapse for the
    /// same reason, so printing that sentence under every one of them is 100
    /// copies of one fact. The shares carry it; the sentence appears on the
    /// segment the reader is on, and always for the two rarer outcomes, which
    /// say something the shares do not.
    ///
    /// **No outcome at all is its own case and never prints per row.** A
    /// translation result drops the conflicts, so every unnamed segment has a
    /// `nil` outcome; an earlier form of this predicate compared `nil` against
    /// one outcome, which is true, and reinstated the 110-copy wall on exactly
    /// the layer that had the least to say. It is stated once in the header
    /// instead — see `TranscriptMissingEvidence`.
    static func showsReason(
        for attribution: SegmentAttributionSummary,
        isFocused: Bool
    ) -> Bool {
        if isFocused { return true }
        guard let outcome = attribution.outcome else { return false }
        return outcome != .noDominantSpeaker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            if !attribution.candidates.isEmpty {
                ShareBand(
                    candidates: attribution.candidates,
                    color: speakerColor,
                    height: AppTheme.Layout.sheetBandHeight
                )
                .frame(maxWidth: 320)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
                    ForEach(attribution.candidates, id: \.speaker) { candidate in
                        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.small) {
                            Text(verbatim: speakerName(candidate.speaker))
                                .font(AppTheme.Typography.metaStrong)
                                .foregroundStyle(speakerColor(candidate.speaker))
                            Text(verbatim: SegmentAttributionSummary.percent(candidate.share))
                                .font(AppTheme.Typography.metaStrong)
                                .monospacedDigit()
                            Text(verbatim: SegmentAttributionSummary.overlap(candidate.overlapS))
                                .font(AppTheme.Typography.meta)
                                .foregroundStyle(AppTheme.Palette.inkSecondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            if showsReason, let reason = attribution.reason() {
                Text(verbatim: reason)
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(AppTheme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A filled band split by share, one rectangle per candidate in that
/// candidate's colour, with a 2-point gap of page ground between them so each
/// rectangle's neighbour is the ground it was measured against. Square.
struct ShareBand: View {
    let candidates: [SpeakerCandidate]
    let color: (String) -> Color
    var height: CGFloat = AppTheme.Layout.bandHeight

    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let usable = max(0, geometry.size.width - gap * CGFloat(max(0, candidates.count - 1)))
            HStack(spacing: gap) {
                ForEach(candidates, id: \.speaker) { candidate in
                    Rectangle()
                        .fill(color(candidate.speaker))
                        .frame(width: max(2, usable * candidate.share))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
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
                .foregroundStyle(AppTheme.Palette.inkSecondary)
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
                .foregroundStyle(AppTheme.Palette.inkSecondary)
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
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                .monospacedDigit()
            Group {
                if let event = NonSpeechEvent.of(text: displayedText, flags: item.segment.flags) {
                    NonSpeechEventText(event: event)
                } else {
                    Text(verbatim: displayedText)
                        .font(AppTheme.Typography.body)
                        .lineSpacing(AppTheme.Typography.bodyLineSpacing)
                        .textSelection(.enabled)
                }
            }
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
                    .foregroundStyle(AppTheme.Palette.inkSecondary)
            }
            Text(appLocalized("Maccheroni will not assign a speaker without acoustic evidence, so this stays as it is."))
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
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
                Text(appLocalized("What Maccheroni Recorded"))
                    .font(AppTheme.Typography.sectionTitle)
                if let reason = untranslatedReason {
                    Text(verbatim: reason)
                        .font(AppTheme.Typography.meta)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                }
                if target.hasBackendSpeakerEvidence {
                    Text(appLocalized("The speech model also reported a speaker for this segment. It is kept as evidence and never becomes the speaker."))
                        .font(AppTheme.Typography.meta)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                }
                if !target.otherMarkers.isEmpty {
                    Text(appLocalized("Other markers"))
                        .font(AppTheme.Typography.meta)
                    Text(verbatim: target.otherMarkers.joined(separator: ", "))
                        .font(AppTheme.Typography.meta.monospaced())
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
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
                    .foregroundStyle(isSelected ? AppTheme.Palette.accent : AppTheme.Palette.inkSecondary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
                    Text(source)
                        .font(AppTheme.Typography.meta)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                    Text(text)
                        .font(AppTheme.Typography.body)
                        .foregroundStyle(AppTheme.Palette.ink)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(AppTheme.Spacing.medium)
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                    .strokeBorder(
                        isSelected ? AppTheme.Palette.accent : AppTheme.Palette.controlBorder,
                        lineWidth: isSelected ? 2 : 1
                    )
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
