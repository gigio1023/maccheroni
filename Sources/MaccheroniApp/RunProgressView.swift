import SwiftUI

struct RunProgressView: View {
    @Bindable var model: MaccheroniAppModel
    let record: LibraryRecord

    private var recordProgress: RunProgressSnapshot? {
        model.progress(for: record.id)
    }

    private var recordIsTranscribing: Bool {
        model.isTranscribing(recordID: record.id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if model.isMOSSLimitExhausted(record),
                   model.usesUnchangedMOSSConfiguration(record) {
                    MOSSConstraintFailureNotice(
                        detail: model.failure(for: record)?.message
                    )
                }
                stageList
                runDetails
                actions
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(record.displayName)
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
        var stages: [PipelineStage] = [.preprocessing, .diarization, .asr, .merge]
        if record.postprocess != .none { stages.append(.postprocess) }
        return stages
    }

    private var headerTitle: LocalizedStringResource {
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

    private var headerMessage: LocalizedStringResource {
        if model.isMOSSLimitExhausted(record) {
            return appLocalized(
                "The original audio and completed attempt artifacts were preserved. MOSS still reached its output limit after the failed range was split into smaller chunks."
            )
        }
        return switch record.state {
        case .failed: appLocalized("The original audio and completed artifacts were preserved. You can inspect the run or try again.")
        case .cancelled, .interrupted: appLocalized("The original audio and every completed intermediate artifact were preserved.")
        case .recorded: appLocalized("The recording is preserved and ready for the selected profile.")
        default: appLocalized("Maccheroni is processing the full recording locally.")
        }
    }

    private var headerSymbol: String {
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
        if model.isMOSSLimitExhausted(record) {
            return .orange
        }
        return switch record.state {
        case .failed: .red
        case .cancelled, .interrupted, .recorded: .secondary
        default: .primary
        }
    }

    private func stageSymbol(_ stage: PipelineStage) -> String {
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
        let symbol = stageSymbol(stage)
        if symbol == "xmark.circle.fill" { return .red }
        if symbol == "checkmark.circle.fill" { return .green }
        return symbol == "circle" ? .secondary : .accentColor
    }
}

private struct MOSSConstraintFailureNotice: View {
    let detail: String?

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
                if let detail, !detail.isEmpty {
                    Divider()
                    Text(appLocalized("Failure Details"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
