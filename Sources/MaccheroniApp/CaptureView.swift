import MaccheroniPostprocess
import SwiftUI

struct CaptureView: View {
    @Bindable var model: MaccheroniAppModel
    let chooseFile: () -> Void
    @State private var glossaryProfile: AppProfileID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                CaptureHeader(isRecording: model.isRecording)
                if model.isRecording {
                    RecordingProfileSummary(profile: model.selectedProfile)
                } else {
                    CaptureControls(model: model, glossaryProfile: $glossaryProfile)
                }
                RecordingControl(model: model)
                if !model.isRecording {
                    FileDropZone(
                        isEnabled: model.canImportAudio,
                        chooseFile: chooseFile,
                        importAudio: model.importAudio
                    )
                    PrivacyNotice(postprocess: model.selectedPostprocess)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(appLocalized("New Recording"))
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canImportAudio else { return false }
            model.importAudio(urls)
            return true
        }
        .sheet(item: $glossaryProfile) { profileID in
            GlossaryEditor(model: model, profileID: profileID)
        }
    }
}

private struct CaptureHeader: View {
    let isRecording: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isRecording ? appLocalized("Recording") : appLocalized("Capture a Conversation"))
                .font(.largeTitle)
            if !isRecording {
                Text(appLocalized("Record microphone and system audio as separate local originals, or import an existing audio file."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RecordingProfileSummary: View {
    let profile: AppProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profile.id.title)
                .font(.headline)
            ProfileBenchmarkSummary(profile: profile)
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profile.id.title)
    }
}

private struct CaptureControls: View {
    @Bindable var model: MaccheroniAppModel
    @Binding var glossaryProfile: AppProfileID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(appLocalized("Profile"), selection: $model.selectedProfileID) {
                ForEach(model.profiles) { profile in
                    Text(profile.id.title).tag(profile.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isRecording)

            ProfileBenchmarkSummary(profile: model.selectedProfile)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Picker(appLocalized("Post-processing"), selection: $model.selectedPostprocess) {
                    ForEach(PostprocessChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRecording)

                Button(appLocalized("Edit Glossary")) {
                    glossaryProfile = model.selectedProfileID
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.isRecording)
            }

            if model.selectedPostprocess != .none {
                PostprocessOperationControls(model: model)
            }

            if model.selectedPostprocess == .codex {
                CodexReadinessNotice(
                    availability: model.codexAvailability,
                    refresh: {
                        Task { await model.refreshCodexAvailability() }
                    }
                )
            }
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }
}

private struct PostprocessOperationControls: View {
    @Bindable var model: MaccheroniAppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { controls }
            VStack(alignment: .leading, spacing: 10) { controls }
        }
    }

    @ViewBuilder private var controls: some View {
        Picker(appLocalized("Operation"), selection: $model.selectedPostprocessMode) {
            ForEach(PostprocessOperationChoice.allCases) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .disabled(model.isRecording)

        if model.selectedPostprocessMode == .translation {
            Picker(appLocalized("Translate Into"), selection: $model.selectedTranslationTarget) {
                ForEach(AppLanguage.translationTargets) { language in
                    Text(language.title).tag(language)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(model.isRecording)
            .accessibilityHint(appLocalized("Chooses the language the transcript is translated into."))
        }
    }
}

private struct CodexReadinessNotice: View {
    let availability: CodexAvailability
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(
                systemName: availability.isAuthenticated
                    ? "checkmark.seal.fill"
                    : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(availability.isAuthenticated ? Color.green : Color.orange)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if availability.isAuthenticated {
                    HStack(spacing: 6) {
                        Text(appLocalized("Codex is signed in and ready."))
                        Text(verbatim: availability.version)
                            .foregroundStyle(.secondary)
                    }
                } else if availability.authenticationCheckFailed {
                    Text(appLocalized("Codex is installed, but its sign-in status could not be checked. Try again or select Local meanwhile."))
                } else if availability.isInstalled {
                    Text(appLocalized("Codex is installed but not signed in. Run codex login in Terminal, or select Local meanwhile."))
                } else {
                    Text(appLocalized("Codex CLI was not found. Install it and run codex login in Terminal, or select Local meanwhile."))
                }
                Text(appLocalized("Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating. Audio and source artifacts stay on this Mac unchanged."))
                    .foregroundStyle(.secondary)
                if !availability.isAuthenticated {
                    Button(appLocalized("Check Again"), action: refresh)
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileBenchmarkSummary: View {
    let profile: AppProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label(profile.asrBackend, systemImage: "waveform")
                Text(appLocalized("+"))
                    .accessibilityHidden(true)
                Label(profile.diarizationBackend, systemImage: "person.2.wave.2")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if profile.metrics.isEmpty {
                Text(appLocalized("No local benchmark is available for this profile yet."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits {
                    HStack(spacing: 6) {
                        ForEach(profile.metrics) { metric in
                            BenchmarkChip(metric: metric)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(profile.metrics) { metric in
                            BenchmarkChip(metric: metric)
                        }
                    }
                }
            }
        }
    }
}

struct BenchmarkChip: View {
    let metric: BenchmarkMetric

    var body: some View {
        HStack(spacing: 3) {
            switch metric.key {
            case "term_recall":
                Text(appLocalized("Term Recall"))
                Text(verbatim: metricValue)
            case "backchannels":
                Text(appLocalized("Backchannels"))
                Text(verbatim: metricValue)
            default:
                Text(verbatim: metric.display)
            }
        }
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    private var metricValue: String {
        switch metric.key {
        case "term_recall", "backchannels":
            metric.display.split(separator: " ").last.map(String.init) ?? metric.display
        default:
            metric.display
        }
    }
}

private struct RecordingControl: View {
    @Bindable var model: MaccheroniAppModel

    var body: some View {
        VStack(spacing: 18) {
            if model.isRecording {
                Text(Duration.seconds(model.captureElapsedS), format: .time(pattern: .hourMinuteSecond))
                    .font(.system(.title, design: .monospaced))
                    .contentTransition(.numericText())
                HStack(spacing: 20) {
                    LevelMeter(
                        label: appLocalized("Microphone"),
                        systemImage: "mic.fill",
                        level: model.captureMeters.microphone
                    )
                    LevelMeter(
                        label: appLocalized("System Audio"),
                        systemImage: "speaker.wave.2.fill",
                        level: model.captureMeters.systemAudio
                    )
                }
            }

            Button {
                if model.isRecording {
                    model.stopRecordingAndTranscribe()
                } else {
                    model.startRecording()
                }
            } label: {
                Label(
                    model.isRecording ? appLocalized("Stop Recording") : appLocalized("Start Recording"),
                    systemImage: model.isRecording ? "stop.fill" : "record.circle"
                )
                .font(.title3)
                .frame(minWidth: 190)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityHint(model.isRecording
                ? appLocalized("Stops capture and begins transcription.")
                : appLocalized("Starts separate microphone and system audio capture."))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

private struct LevelMeter: View {
    let label: LocalizedStringResource
    let systemImage: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: systemImage)
                .font(.caption)
            ProgressView(value: Double(max(0, min(1, level))))
                .progressViewStyle(.linear)
                .frame(minWidth: 180)
                .accessibilityValue(appLocalized("\(Int(max(0, min(1, level)) * 100)) percent"))
        }
    }
}

private struct FileDropZone: View {
    let isEnabled: Bool
    let chooseFile: () -> Void
    let importAudio: ([URL]) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(appLocalized("Drop an audio file here"))
                .font(.headline)
            Button(appLocalized("Choose Audio File…"), action: chooseFile)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!isEnabled)
        }
        .frame(maxWidth: .infinity, minHeight: 126)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
        }
        .clipShape(.rect(cornerRadius: 12))
        .opacity(isEnabled ? 1 : 0.55)
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled else { return false }
            importAudio(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}

private struct PrivacyNotice: View {
    let postprocess: PostprocessChoice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(appLocalized("Audio never leaves this Mac."))
                    .font(.headline)
                if postprocess == .codex {
                    Text(appLocalized("Codex receives bounded transcript text, the active profile's full glossary and its hash, post-processing instructions, and the target language when translating. Audio and source artifacts stay on this Mac unchanged."))
                } else {
                    Text(appLocalized("Transcription and the selected post-processing path run locally. The original audio and raw transcript stay unchanged."))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
