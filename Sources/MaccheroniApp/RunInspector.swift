import MaccheroniCore
import SwiftUI

/// Provenance as a summary a reader can read, with the exact identities one
/// disclosure away. The panel this replaced opened onto a run ID, four SHA-256
/// digests, three raw enum `rawValue`s and a printf format string, which is
/// everything a reader does not need first and nothing they do.
struct RunInspector: View {
    let record: LibraryRecord
    let run: LoadedRun
    @State private var showsFingerprints = false

    var body: some View {
        Form {
            RunInspectorSections(
                record: record,
                run: run,
                showsFingerprints: $showsFingerprints
            )
        }
        .formStyle(.grouped)
        .inspectorColumnWidth(min: 300, ideal: 350, max: 450)
    }
}

/// The inspector's content without the scrolling form around it. `Form` with
/// the grouped style renders empty under `ImageRenderer`, so the sections are
/// their own view and a render harness can put them in a plain stack.
struct RunInspectorSections: View {
    let record: LibraryRecord
    let run: LoadedRun
    @Binding var showsFingerprints: Bool

    var body: some View {
        Group {
            Section(run.resultOperation == nil
                ? appLocalized("This Run")
                : appLocalized("Source Run"))
            {
                LabeledContent(appLocalized("Outcome")) {
                    Text(RunInspectorWording.status(run.manifest.status))
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Transcribed")) {
                    Text(verbatim: RunInspectorWording.coverage(run.manifest.coverage))
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Speakers")) {
                    Text(run.transcript.numSpeakers.formatted())
                        .monospacedDigit()
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Segments")) {
                    Text(verbatim: RunInspectorWording.segments(run.transcript.segments))
                        .monospacedDigit()
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Duration")) {
                    Text(Duration.seconds(run.manifest.timing.wallTimeS), format: .time(pattern: .hourMinuteSecond))
                        .monospacedDigit()
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Profile")) {
                    Text(record.profileID.title)
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Recording")) {
                    Text(verbatim: run.manifest.input.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .inspectorValue()
                }
            }

            if let operation = run.resultOperation {
                Section(appLocalized("Current Derived Result")) {
                    LabeledContent(appLocalized("Operation")) {
                        Text(PostprocessOperationChoice(operation.mode).title)
                            .inspectorValue()
                    }
                    if let target = operation.targetLanguage {
                        LabeledContent(appLocalized("Target Language")) {
                            Group {
                                if let language = AppLanguage(rawValue: target) {
                                    Text(language.title)
                                } else {
                                    Text(verbatim: target)
                                }
                            }
                            .inspectorValue()
                        }
                    }
                    LabeledContent(appLocalized("Glossary Used")) {
                        Text(RunInspectorWording.glossarySemantics(operation.glossarySemantics))
                            .inspectorValue()
                    }
                    LabeledContent(appLocalized("Glossary Terms")) {
                        Text(operation.glossaryItemCount.formatted())
                            .monospacedDigit()
                            .inspectorValue()
                    }
                }
            }

            if let postprocess = run.effectivePostprocess {
                Section(run.resultOperation == nil
                    ? appLocalized("Post-processing")
                    : appLocalized("Current Derived Post-processing"))
                {
                    LabeledContent(appLocalized("Operation")) {
                        Text(PostprocessOperationChoice(postprocess.mode).title)
                            .inspectorValue()
                    }
                    if let target = postprocess.targetLanguage {
                        LabeledContent(appLocalized("Target Language")) {
                            Group {
                                if let language = AppLanguage(rawValue: target) {
                                    Text(language.title)
                                } else {
                                    Text(verbatim: target)
                                }
                            }
                            .inspectorValue()
                        }
                    }
                    LabeledContent(appLocalized("Model")) {
                        Text(verbatim: postprocess.modelID)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .inspectorValue()
                    }
                    LabeledContent(appLocalized("Sent to the Model")) {
                        Group {
                            switch postprocess.inputMode {
                            case .textOnly:
                                Text(appLocalized("Transcript text only. Audio stayed on this Mac."))
                            }
                        }
                        .inspectorValue()
                    }
                }
            }

            if !run.derivedResults.isEmpty {
                Section(appLocalized("Derived Results")) {
                    ForEach(run.derivedResults) { result in
                        VStack(
                            alignment: .leading,
                            spacing: AppTheme.Spacing.tight
                        ) {
                            LabeledContent {
                                // Two speaker-proposal sets carry the same
                                // name, so when each was made is what a reader
                                // chooses on and it has to be readable side by
                                // side. The year is dropped: it never tells two
                                // derived sets of one run apart, and at the
                                // inspector's 300-point minimum it pushed the
                                // value onto a second line, where the two rows
                                // stopped being comparable by eye.
                                Text(result.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .monospacedDigit()
                                    .foregroundStyle(AppTheme.Palette.inkSecondary)
                            } label: {
                                Label {
                                    Text(RunInspectorWording.derivedSet(result))
                                } icon: {
                                    // The accent is what marks the current
                                    // thing everywhere else on this surface.
                                    Image(systemName: result.isCurrent ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(result.isCurrent
                                            ? AppTheme.Palette.accent
                                            : AppTheme.Palette.inkSecondary)
                                }
                            }
                            // Two proposal sets made minutes apart are told
                            // apart by a timestamp only if the reader already
                            // knows which one they wanted. What each set did is
                            // the answer, so it is printed here — the same
                            // sentence the transcript surface prints over the
                            // proposed layer, for the same two numbers, rather
                            // than a second wording for one fact.
                            if let counts = result.speakerProposalCounts {
                                Text(appLocalized("\(counts.proposed) proposed, \(counts.declined) declined. Not acoustic evidence, and not measured."))
                                    .font(AppTheme.Typography.meta)
                                    .foregroundStyle(AppTheme.Palette.inkSecondary)
                                    .monospacedDigit()
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            Section(appLocalized("Models")) {
                // Stacked rather than label-and-value: at the inspector's width
                // a trailing model ID truncates in the middle, which removes
                // exactly the part that identifies it.
                ForEach(Array(run.manifest.models.enumerated()), id: \.offset) { _, model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RunInspectorWording.role(model.role))
                            .font(AppTheme.Typography.meta)
                            .foregroundStyle(AppTheme.Palette.inkSecondary)
                        Text(verbatim: model.hfModelID)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }

            Section(run.resultOperation == nil
                ? appLocalized("Glossary")
                : appLocalized("Source Run Glossary"))
            {
                LabeledContent(appLocalized("Terms")) {
                    Text(run.manifest.glossary.itemCount.formatted())
                        .monospacedDigit()
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Reached the Model")) {
                    Text(run.manifest.glossary.applied
                        ? appLocalized("Yes")
                        : appLocalized("No"))
                        .inspectorValue()
                }
                LabeledContent(appLocalized("How")) {
                    Text(RunInspectorWording.injection(run.manifest.glossary.injectionMode))
                        .inspectorValue()
                }
            }

            Section(appLocalized("Audio Preparation")) {
                LabeledContent(appLocalized("Sample Rate")) {
                    Text(verbatim: "\(run.manifest.preprocessing.sampleRateHz.formatted()) Hz")
                        .monospacedDigit()
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Channels")) {
                    Text(run.manifest.preprocessing.channels.formatted())
                        .monospacedDigit()
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Peak Normalization")) {
                    Text(run.manifest.preprocessing.peakNormalization ? appLocalized("On") : appLocalized("Off"))
                        .inspectorValue()
                }
                LabeledContent(appLocalized("Voice Activity Detection")) {
                    Group {
                        if let backend = run.manifest.preprocessing.vad.backend {
                            Text(verbatim: backend)
                        } else {
                            Text(appLocalized("Off"))
                        }
                    }
                    .inspectorValue()
                }
                LabeledContent(appLocalized("Enhancement")) {
                    Group {
                        if let backend = run.manifest.preprocessing.enhancement.backend {
                            Text(verbatim: backend)
                        } else {
                            Text(appLocalized("Off"))
                        }
                    }
                    .inspectorValue()
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showsFingerprints) {
                    RunFingerprints(record: record, run: run)
                } label: {
                    Label(appLocalized("Exact Identities"), systemImage: "number")
                }
            } footer: {
                Text(appLocalized("Run and result identifiers, file fingerprints, model revisions, and the batching numbers behind post-processing."))
                    .font(AppTheme.Typography.meta)
                    .foregroundStyle(AppTheme.Palette.inkSecondary)
            }
        }
    }
}

/// Plain-language wording for values that are stored as identifiers. Nothing
/// here invents a fact; it renames one.
enum RunInspectorWording {
    static func status(
        _ status: RunStatus,
        locale: Locale? = nil
    ) -> LocalizedStringResource {
        switch status {
        case .succeeded: appLocalized("Completed", locale: locale)
        case .partial: appLocalized("Partial", locale: locale)
        case .failed: appLocalized("Failed", locale: locale)
        case .canceled: appLocalized("Cancelled", locale: locale)
        }
    }

    static func role(
        _ role: ModelRole,
        locale: Locale? = nil
    ) -> LocalizedStringResource {
        switch role {
        case .asr: appLocalized("Speech Recognition", locale: locale)
        case .diarization: appLocalized("Speaker Separation", locale: locale)
        case .alignment: appLocalized("Alignment", locale: locale)
        case .vad: appLocalized("Voice Activity", locale: locale)
        case .enhancement: appLocalized("Audio Enhancement", locale: locale)
        case .postprocess: appLocalized("Post-processing", locale: locale)
        }
    }

    static func injection(
        _ mode: GlossaryInjectionMode,
        locale: Locale? = nil
    ) -> LocalizedStringResource {
        switch mode {
        case .none: appLocalized("Not passed to the model", locale: locale)
        case .freeTextContext: appLocalized("In the model's context prompt", locale: locale)
        case .hotwordInstruction: appLocalized("As a hotword instruction", locale: locale)
        case .ctcVocabulary: appLocalized("As a decoder vocabulary", locale: locale)
        }
    }

    /// What family a derived set belongs to, read from `kind` and never from
    /// `mode`. A speaker-proposal manifest keeps `mode == .correction` for a
    /// structural reason in the derived contract and corrected no text, so
    /// naming it from `mode` labels it "Correct" in the one panel a reader
    /// consults to find out what a set actually is.
    static func derivedSet(
        _ result: DerivedResultSummary,
        locale: Locale? = nil
    ) -> LocalizedStringResource {
        switch result.kind {
        case .speakerProposal:
            appLocalized("Speaker Proposal", locale: locale)
        case .textPostprocess:
            switch result.operation {
            case .correction: appLocalized("Correct", locale: locale)
            case .translation: appLocalized("Translate", locale: locale)
            }
        }
    }

    static func glossarySemantics(
        _ semantics: DerivedGlossarySemantics,
        locale: Locale? = nil
    ) -> LocalizedStringResource {
        switch semantics {
        case .currentProfile: appLocalized("The profile's current glossary", locale: locale)
        case .sourceRun: appLocalized("The glossary the source run used", locale: locale)
        }
    }

    /// `20:41 of 20:43 (97 %)`, or just the duration when nothing was lost.
    static func coverage(_ coverage: Coverage, locale: Locale? = nil) -> String {
        let processed = TranscriptPlaybackTimeline.clock(coverage.processedDurationS)
        let total = TranscriptPlaybackTimeline.clock(coverage.inputDurationS)
        guard coverage.truncated || coverage.processedDurationS < coverage.inputDurationS
        else {
            return total
        }
        let ratio = coverage.inputDurationS > 0
            ? coverage.processedDurationS / coverage.inputDurationS
            : 0
        // One decimal: this project records 97.5 % coverage, and rounding that
        // to 98 % in the one place a reader looks for it is not a rounding.
        let share = SegmentAttributionSummary.percent(
            ratio,
            locale: locale,
            fractionDigits: 1
        )
        return appString("\(processed) of \(total) (\(share))", locale: locale)
    }

    static func segments(_ segments: [Segment], locale: Locale? = nil) -> String {
        let unattributed = segments.count { !SpeakerRoster.isAttributed($0.speaker) }
        guard unattributed > 0 else { return segments.count.formatted() }
        return appString(
            "\(segments.count), \(unattributed) without a speaker",
            locale: locale
        )
    }
}

private struct RunFingerprints: View {
    let record: LibraryRecord
    let run: LoadedRun

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            FingerprintRow(
                label: appLocalized("Run ID"),
                value: run.manifest.runID
            )
            if run.resultID != nil {
                FingerprintRow(
                    label: appLocalized("Derived Result ID"),
                    value: run.effectiveResultID
                )
            }
            FingerprintRow(
                label: appLocalized("Recording SHA-256"),
                value: run.manifest.input.sha256
            )
            FingerprintRow(
                label: appLocalized("Recording Size"),
                value: ByteCountFormatStyle(style: .file)
                    .format(Int64(run.manifest.input.sizeBytes))
            )
            FingerprintRow(
                label: appLocalized("Chunks"),
                value: "\(run.manifest.coverage.chunksCompleted)/\(run.manifest.coverage.chunksPlanned)"
            )
            if let hash = run.manifest.glossary.sha256 {
                FingerprintRow(
                    label: appLocalized("Glossary SHA-256"),
                    value: hash
                )
            }
            if let operation = run.resultOperation, let hash = operation.glossarySHA256 {
                FingerprintRow(
                    label: appLocalized("Derived Glossary SHA-256"),
                    value: hash
                )
            }
            ForEach(Array(run.manifest.models.enumerated()), id: \.offset) { _, model in
                FingerprintRow(
                    label: RunInspectorWording.role(model.role),
                    value: "\(model.hfModelID) · \(model.revision) · \(model.quantization)"
                )
            }
            FingerprintRow(
                label: appLocalized("Transcription Backend"),
                value: "\(run.manifest.backend.name) \(run.manifest.backend.version)"
            )
            if let postprocess = run.effectivePostprocess {
                FingerprintRow(
                    label: appLocalized("Post-processing Backend"),
                    value: "\(postprocess.backend.name) \(postprocess.backend.version)"
                )
                if let hash = postprocess.sourceSegmentsSHA256 {
                    FingerprintRow(
                        label: appLocalized("Source Segments SHA-256"),
                        value: hash
                    )
                }
                if let batching = postprocess.batching {
                    BatchingFingerprints(batching: batching)
                }
            }
            ForEach(run.derivedResults) { result in
                FingerprintRow(
                    label: RunInspectorWording.derivedSet(result),
                    value: result.id
                )
            }
        }
        .padding(.vertical, AppTheme.Spacing.small)
    }
}

private struct BatchingFingerprints: View {
    let batching: ManifestPostprocessBatching

    var body: some View {
        Group {
            FingerprintRow(
                label: appLocalized("Prompt Limit"),
                value: "\(batching.maximumPromptUTF8Bytes.formatted()) B"
            )
            FingerprintRow(
                label: appLocalized("Segments per Batch"),
                value: batching.maximumSegmentsPerBatch.formatted()
            )
            FingerprintRow(
                label: appLocalized("Batches Planned"),
                value: batching.batchesPlanned.formatted()
            )
            FingerprintRow(
                label: appLocalized("Output Token Limit"),
                value: outputTokenLimit
            )
            FingerprintRow(
                label: appLocalized("Output Planning Budget"),
                value: batching.outputTokenPlanningBudget.formatted()
            )
            FingerprintRow(
                label: appLocalized("Output Estimate Formula"),
                value: String(
                    format: "%.3f token/input-byte + %d + %d/segment",
                    Double(batching.outputTokensPerInputUTF8BytePermille) / 1_000,
                    batching.baseOutputTokenReserve,
                    batching.perSegmentOutputTokenReserve
                )
            )
            FingerprintRow(
                label: appLocalized("Largest Batch Input"),
                value: "\(batching.maximumObservedInputTextUTF8Bytes.formatted()) B"
            )
            FingerprintRow(
                label: appLocalized("Largest Raw Response"),
                value: "\(batching.maximumObservedResponseUTF8Bytes.formatted()) B"
            )
            FingerprintRow(
                label: appLocalized("Largest Accepted Output Bound"),
                value: batching.maximumObservedAcceptedOutputTokenUpperBound.formatted()
            )
        }
    }

    private var outputTokenLimit: String {
        if batching.outputTokenLimitStatus == .configured,
           let tokens = batching.maximumOutputTokens
        {
            return tokens.formatted()
        }
        return appString("Service-managed (limit unavailable)")
    }
}

private extension View {
    /// The inspector's values, in the ink token.
    ///
    /// `LabeledContent` styles its trailing content with the system secondary
    /// label by default. Rendered, that measured **2.67–3.03:1** against the
    /// grouped form's `#F9F9F9` card in the light appearance — every value on
    /// the panel, below the 4.5:1 floor, and exactly the colour
    /// `docs/ui-design.md` names as the cause of most of the light-appearance
    /// failures the first rework shipped with. An explicit foreground style on
    /// the content wins over the style's default, so the ban is enforced here
    /// rather than trusting twenty call sites to remember it.
    func inspectorValue() -> some View {
        foregroundStyle(AppTheme.Palette.ink)
    }
}

private struct FingerprintRow: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
            Text(verbatim: value)
                .font(AppTheme.Typography.meta.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
