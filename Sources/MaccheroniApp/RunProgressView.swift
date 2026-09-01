import SwiftUI

struct RunProgressView: View {
    @Bindable var model: MaccheroniAppModel
    let record: LibraryRecord

    /// What the run's own records say happened. Loaded off the first render
    /// so no manifest is read during a view update, and reloaded whenever the
    /// entry, its state, or its run directory changes.
    @State private var outcome: RunOutcome?

    private var recordProgress: RunProgressSnapshot? {
        model.progress(for: record.id)
    }

    private var recordIsTranscribing: Bool {
        model.isTranscribing(recordID: record.id)
    }

    /// A finished run has an outcome to explain. A recording waiting to be
    /// transcribed and a run in flight do not.
    private var isFinishedRun: Bool {
        switch record.state {
        case .failed, .cancelled, .interrupted: !recordIsTranscribing
        default: false
        }
    }

    private var diagnosis: RunOutcome? {
        isFinishedRun ? outcome : nil
    }

    private var cause: RunFailureCause? {
        guard let diagnosis, diagnosis.isFailureLike else { return nil }
        return diagnosis.cause
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.isMOSSLimitExhausted(record),
                   model.usesUnchangedMOSSConfiguration(record) {
                    MOSSConstraintRetryNotice()
                }
                stageList
                runDetails
                if let detail = diagnosis?.detail, !detail.isEmpty {
                    RunFailureDetailBox(detail: detail)
                }
                actions
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(record.displayName)
        .task(id: outcomeReloadKey) {
            guard isFinishedRun else {
                outcome = nil
                return
            }
            outcome = RunOutcome.load(
                runURL: record.runURL,
                recordState: record.state,
                recordFailureMessage: record.failureMessage,
                postprocessRequested: record.postprocess != .none
            )
        }
    }

    private var outcomeReloadKey: String {
        [
            record.id.uuidString,
            record.state.rawValue,
            record.runURL?.path ?? "",
            recordIsTranscribing ? "active" : "idle",
        ].joined(separator: "|")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(headerTitle, systemImage: headerSymbol)
                .font(.largeTitle)
                .foregroundStyle(headerColor)
            Text(headerMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let supporting = headerSupportingMessage {
                Text(supporting)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleStages, id: \.self) { stage in
                HStack(spacing: 12) {
                    Image(systemName: stageSymbol(stage))
                        .frame(width: 20)
                        .foregroundStyle(stageColor(stage))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stage.title)
                        if let elapsedS = recordProgress?.stageElapsedS[stage] {
                            Text(Duration.seconds(elapsedS), format: .time(pattern: .hourMinuteSecond))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .accessibilityLabel(appLocalized("Elapsed"))
                        }
                        if stage == .asr,
                           let snapshot = recordProgress,
                           snapshot.plannedChunks > 0 {
                            Text(appLocalized("Chunk \(snapshot.completedChunks) of \(snapshot.plannedChunks)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let note = stageNote(stage) {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if recordProgress?.stage == stage, recordIsTranscribing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 11)
                if stage != visibleStages.last {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
    }

    private var runDetails: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            if let snapshot = recordProgress {
                GridRow {
                    Text(appLocalized("Elapsed"))
                        .foregroundStyle(.secondary)
                    Text(Duration.seconds(snapshot.elapsedS), format: .time(pattern: .hourMinuteSecond))
                        .monospacedDigit()
                }
                if let modelID = snapshot.modelID {
                    GridRow {
                        Text(snapshot.modelLabel())
                            .foregroundStyle(.secondary)
                        Text(modelID)
                            .textSelection(.enabled)
                    }
                }
                if let message = snapshot.message, !message.isEmpty {
                    GridRow {
                        Text(appLocalized("Status"))
                            .foregroundStyle(.secondary)
                        Text(message)
                    }
                }
            }
            if let stage = diagnosis?.failedStage {
                GridRow {
                    Text(appLocalized("Stopped At"))
                        .foregroundStyle(.secondary)
                    Text(stage.title)
                }
            }
            if let coverage = diagnosis?.coverage, coverage.inputDurationS > 0 {
                GridRow {
                    Text(appLocalized("Transcribed"))
                        .foregroundStyle(.secondary)
                    Text(coverage.transcribedLabel)
                        .monospacedDigit()
                }
                if let ranges = coverage.missingRangeLabel() {
                    GridRow {
                        Text(appLocalized("Not Transcribed"))
                            .foregroundStyle(.secondary)
                        Text(verbatim: ranges)
                            .monospacedDigit()
                    }
                }
            }
            GridRow {
                Text(appLocalized("Profile"))
                    .foregroundStyle(.secondary)
                Text(record.profileID.title)
            }
            GridRow {
                Text(appLocalized("Post-processing"))
                    .foregroundStyle(.secondary)
                Text(record.postprocess.title)
            }
            if record.postprocess != .none {
                GridRow {
                    Text(appLocalized("Operation"))
                        .foregroundStyle(.secondary)
                    Text(PostprocessOperationChoice(
                        record.postprocessMode ?? .correction
                    ).title)
                }
            }
            if record.postprocessMode == .translation,
               let target = record.translationTargetLanguage
            {
                GridRow {
                    Text(appLocalized("Target Language"))
                        .foregroundStyle(.secondary)
                    if let language = AppLanguage(rawValue: target) {
                        Text(language.title)
                    } else {
                        Text(verbatim: target)
                    }
                }
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var actions: some View {
        if recordIsTranscribing {
            HStack {
                Button(appLocalized("Cancel Transcription"), role: .cancel) {
                    model.cancelTranscription()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Label(appLocalized("Cancelling keeps completed chunks and intermediate artifacts."), systemImage: "archivebox")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if model.isMOSSLimitExhausted(record),
                  model.usesUnchangedMOSSConfiguration(record) {
            HStack {
                if model.canRevealRun(record) {
                    Button(appLocalized("Reveal Preserved Run")) {
                        model.revealRun(record)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(appLocalized("Review Profiles")) {
                    model.showCapture()
                }
                .buttonStyle(.bordered)
            }
        } else if record.state == .failed || record.state == .cancelled
                    || record.state == .recorded || record.state == .interrupted {
            HStack {
                Button(appLocalized("Try Again")) {
                    model.retrySelectedTranscription()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRetryTranscription(record))
                if model.canRevealRun(record) {
                    Button(appLocalized("Reveal Preserved Run")) {
                        model.revealRun(record)
                    }
                }
            }
        }
    }

    private var visibleStages: [PipelineStage] {
        RunOutcome.stageOrder(includesPostprocess: record.postprocess != .none)
    }

    private var headerTitle: LocalizedStringResource {
        if let diagnosis, diagnosis.disposition == .partial {
            return appLocalized("Partial Transcript")
        }
        if let diagnosis, diagnosis.disposition == .unreadable {
            return appLocalized("Run Record Unreadable")
        }
        if model.isMOSSLimitExhausted(record) {
            return appLocalized("Transcription Limit Reached")
        }
        if record.postprocess == .codex, record.state == .transcribing {
            return appLocalized(
                "Audio stays on this Mac. Transcription runs locally; during post-processing Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating."
            )
        }
        return switch record.state {
        case .failed: appLocalized("Transcription Failed")
        case .cancelled: appLocalized("Transcription Cancelled")
        case .interrupted: record.state.title
        case .recorded: appLocalized("Ready to Transcribe")
        default: appLocalized("Transcribing")
        }
    }

    /// The reason, in user language. It is the first thing a failed run says,
    /// and it comes from the manifest's own failure code and coverage rather
    /// than from one sentence shared by every failure.
    private var headerMessage: LocalizedStringResource {
        if let cause {
            return cause.sentence()
        }
        if let diagnosis, diagnosis.disposition == .partial {
            return appLocalized(
                "Part of this recording was transcribed and the rest produced no text."
            )
        }
        return switch record.state {
        case .failed: appLocalized("The original audio and completed artifacts were preserved. You can inspect the run or try again.")
        case .cancelled, .interrupted: appLocalized("The original audio and every completed intermediate artifact were preserved.")
        case .recorded: appLocalized("The recording is preserved and ready for the selected profile.")
        default: appLocalized("Maccheroni is processing the full recording locally.")
        }
    }

    /// The preservation promise, kept as its own line so the reason above it
    /// stays one sentence.
    private var headerSupportingMessage: LocalizedStringResource? {
        guard let diagnosis, diagnosis.isFailureLike else { return nil }
        if diagnosis.disposition == .partial {
            return appLocalized(
                "The recovered transcript, the original audio, and every completed artifact were preserved. This run is recorded as partial, not complete."
            )
        }
        return appLocalized(
            "The original audio and completed artifacts were preserved. You can inspect the run or try again."
        )
    }

    private var headerSymbol: String {
        if let diagnosis, diagnosis.disposition == .partial {
            return "exclamationmark.triangle.fill"
        }
        if model.isMOSSLimitExhausted(record) {
            return "exclamationmark.triangle.fill"
        }
        return switch record.state {
        case .failed: "xmark.octagon.fill"
        case .cancelled, .interrupted: "stop.circle.fill"
        case .recorded: "record.circle"
        default: "waveform"
        }
    }

    private var headerColor: Color {
        if let diagnosis, diagnosis.disposition == .partial {
            return .orange
        }
        if model.isMOSSLimitExhausted(record) {
            return .orange
        }
        return switch record.state {
        case .failed: .red
        case .cancelled, .interrupted, .recorded: .secondary
        default: .primary
        }
    }

    /// The note under the stage that stopped. Only the failing stage carries
    /// one, so the checklist stays a checklist.
    private func stageNote(_ stage: PipelineStage) -> LocalizedStringResource? {
        guard let diagnosis, stage == diagnosis.failedStage else { return nil }
        return switch diagnosis.status(of: stage) {
        case .failed: appLocalized("This stage stopped the run.")
        case .incomplete: appLocalized("This stage covered only part of the recording.")
        case .finished, .notReached: nil
        }
    }

    private func stageSymbol(_ stage: PipelineStage) -> String {
        if let diagnosis {
            return switch diagnosis.status(of: stage) {
            case .finished: "checkmark.circle.fill"
            case .incomplete: "exclamationmark.circle.fill"
            case .failed: "xmark.circle.fill"
            case .notReached: "circle"
            }
        }
        guard let current = recordProgress?.stage else { return "circle" }
        if current == .failed { return "xmark.circle.fill" }
        if current == .cancelled { return "stop.circle.fill" }
        guard let currentIndex = visibleStages.firstIndex(of: current),
              let stageIndex = visibleStages.firstIndex(of: stage)
        else { return "circle" }
        if stageIndex < currentIndex || current == .complete { return "checkmark.circle.fill" }
        if stageIndex == currentIndex { return "circle.inset.filled" }
        return "circle"
    }

    private func stageColor(_ stage: PipelineStage) -> Color {
        switch stageSymbol(stage) {
        case "xmark.circle.fill": .red
        case "exclamationmark.circle.fill": .orange
        case "checkmark.circle.fill": .green
        case "circle": .secondary
        default: .accentColor
        }
    }
}

extension RunFailureCause {
    /// One sentence per cause. Two failures the manifest told apart must not
    /// arrive on the screen as the same words.
    func sentence(locale: Locale? = nil) -> LocalizedStringResource {
        switch self {
        case .repetitionDegeneration:
            appLocalized(
                "Speech recognition stopped producing new words and repeated itself to the end of its output budget, so that stretch of audio produced no usable text.",
                locale: locale
            )
        case .asrLimitExhausted:
            appLocalized(
                "Speech recognition reached the output limit for this audio before it finished, and splitting the audio into smaller pieces did not bring it back under the limit.",
                locale: locale
            )
        case .mossLimitExhausted:
            appLocalized(
                "Speech recognition reached the MOSS output limit even after the failed range had been split into smaller pieces.",
                locale: locale
            )
        case .asrTimedOut:
            appLocalized(
                "Speech recognition ran past the time budget for this audio and was stopped.",
                locale: locale
            )
        case .asrOutputUnusable:
            appLocalized(
                "Speech recognition returned output Maccheroni could not verify, so nothing was promoted into the transcript.",
                locale: locale
            )
        case .modelIdentityMismatch:
            appLocalized(
                "The speech model that answered is not the exact model this profile pins, so its output was refused.",
                locale: locale
            )
        case .diarizationRejectedTimeline:
            appLocalized(
                "Speaker separation returned a speaker timeline Maccheroni cannot trust, so the run stopped before transcription.",
                locale: locale
            )
        case .audioNotPreparable:
            appLocalized(
                "Maccheroni could not prepare this audio for transcription.",
                locale: locale
            )
        case .mergeRejected:
            appLocalized(
                "Maccheroni could not join the transcript with the speaker timeline.",
                locale: locale
            )
        case .postprocessFailed:
            appLocalized(
                "Post-processing did not finish. The speaker-labelled transcript is unaffected.",
                locale: locale
            )
        case .glossaryRejected:
            appLocalized(
                "The glossary for this profile could not be used for this run.",
                locale: locale
            )
        case .profileRejected:
            appLocalized(
                "This profile could not run with the settings it was given.",
                locale: locale
            )
        case .missingDependency:
            appLocalized(
                "A component this profile needs is not installed on this Mac, so the run never got started.",
                locale: locale
            )
        case .missingFile:
            appLocalized(
                "A file this run needs is no longer where Maccheroni left it.",
                locale: locale
            )
        case .integrityMismatch:
            appLocalized(
                "A file this run depends on no longer matches the fingerprint recorded for it, so Maccheroni stopped rather than trust it.",
                locale: locale
            )
        case .unreadableRunRecord:
            appLocalized(
                "The run record for this transcription cannot be read, so Maccheroni cannot say what happened.",
                locale: locale
            )
        case .canceled:
            appLocalized(
                "The run was cancelled before it finished.",
                locale: locale
            )
        case .unspecified:
            appLocalized(
                "Maccheroni stopped this run and its record does not name a more specific cause.",
                locale: locale
            )
        }
    }

    /// The same sentence as a `String`, for callers that need one.
    func sentenceText(locale: Locale? = nil) -> String {
        String(localized: sentence(locale: locale))
    }
}

extension RunCoverageSummary {
    /// How much audio the run transcribed, stated from `processed_duration_s`
    /// against `input_duration_s`. The chunk counts are never used: a chunk
    /// whose leaf promoted only a prefix is still recorded `succeeded`.
    var transcribedLabel: LocalizedStringResource {
        let covered = runDurationLabel(processedDurationS)
        let total = runDurationLabel(inputDurationS)
        let share = coveredFraction.formatted(.percent.precision(.fractionLength(0)))
        return appLocalized("\(covered) of \(total) (\(share))")
    }

    /// The source ranges that produced no transcript, from
    /// `primary/partial-coverage.json`. Their terminal reasons are read but
    /// never shown: the reason is already stated in user language above.
    func missingRangeLabel(limit: Int = 3) -> String? {
        guard !missingRanges.isEmpty else { return nil }
        let shown = missingRanges.prefix(limit).map {
            "\(runDurationLabel($0.startS))\u{2013}\(runDurationLabel($0.endS))"
        }
        let list = shown.joined(separator: ", ")
        return missingRanges.count > limit ? "\(list), \u{2026}" : list
    }
}

/// Clock-style label for a duration in seconds. Digits only, so it carries no
/// wording to translate.
func runDurationLabel(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    return Duration.seconds(clamped).formatted(
        .time(pattern: clamped >= 3600 ? .hourMinuteSecond : .minuteSecond)
    )
}

/// Why an identical retry is withheld after the MOSS recovery tree is spent.
/// It explains a disabled control; the reason for the failure itself is in the
/// header.
private struct MOSSConstraintRetryNotice: View {
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(appLocalized(
                    "An identical retry is disabled because it would use the same model, glossary, and chunk policy."
                ))
                .fixedSize(horizontal: false, vertical: true)
                Text(appLocalized(
                    "Inspect the preserved run. For a new attempt, choose a different profile or transcribe a shorter copy. The original recording stays unchanged."
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(
                appLocalized("Same-settings retry unavailable"),
                systemImage: "arrow.clockwise.circle"
            )
        }
    }
}

/// The engine's own words, after the run directory, run ID, and any hex
/// fingerprint have been stripped out.
private struct RunFailureDetailBox: View {
    let detail: String

    var body: some View {
        GroupBox {
            Text(verbatim: detail)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(appLocalized("Failure Details"), systemImage: "text.magnifyingglass")
        }
    }
}
