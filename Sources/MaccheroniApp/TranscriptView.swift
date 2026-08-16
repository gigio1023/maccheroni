import Accessibility
import AppKit
import MaccheroniCore
import MaccheroniMerge
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    @Bindable var model: MaccheroniAppModel
    let record: LibraryRecord
    let run: LoadedRun
    @State private var isInspectorPresented = true
    @State private var editingSpeaker: SpeakerEdit?
    @State private var speakerDraft = ""
    @State private var selectedConflict: TranscriptSegment?
    @State private var exportDocument: TranscriptDataDocument?
    @State private var exportType = UTType.json
    @State private var exportFilename = "transcript"
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var postprocessAction: ExistingRunAction?
    @State private var selectedSegmentIDs: Set<TranscriptSegmentID> = []
    @State private var copyFeedback: TranscriptCopyFeedback?
    @State private var copyFeedbackGeneration = 0

    private var isTranslation: Bool {
        run.isTranslation
    }

    private var displayLayer: TranscriptDisplayLayer {
        TranscriptDisplayLayer.displayed(in: run)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    transcriptHeader
                    ForEach(run.segments) { item in
                        TranscriptSegmentRow(
                            item: item,
                            displaySpeaker: displaySpeaker(item.segment.speaker),
                            correctedText: correctedText(item),
                            color: speakerColor(item.segment.speaker),
                            isResolved: isResolved(item),
                            isSelected: selectedSegmentIDs.contains(item.id),
                            allowsTextResolution: true,
                            play: { model.play(segment: item.segment) },
                            select: { toggleSelection(of: item.id) },
                            rename: {
                                editingSpeaker = SpeakerEdit(speaker: item.segment.speaker)
                                speakerDraft = displaySpeaker(item.segment.speaker)
                            },
                            inspectConflict: { selectedConflict = item }
                        )
                        .id(item.id)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: selectedConflict?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
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
                    selectedSegmentIDs: selectedSegmentIDs
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
                .help(appLocalized("Show or hide exact run and model details."))
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
        .sheet(item: $selectedConflict) { item in
            ConflictResolutionSheet(
                item: item,
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
                    selectedConflict = nil
                },
                cancel: { selectedConflict = nil }
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
        }
    }

    private var transcriptHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appLocalized("Transcript"))
                    .font(.largeTitle)
                Text(appLocalized("\(run.transcript.segments.count) segments, \(run.transcript.numSpeakers) speakers"))
                    .foregroundStyle(.secondary)
                Label(displayLayer.title, systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let copyFeedback {
                    Label(
                        copyFeedback.message,
                        systemImage: copyFeedback.isError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(copyFeedback.isError ? Color.red : Color.secondary)
                    .transition(.opacity)
                }
                if let active = model.activeExistingRunPostprocess,
                   active.recordID == record.id
                {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(PostprocessOperationChoice(active.operation).title)
                        if let modelID = active.progress.modelID {
                            Text(verbatim: modelID).foregroundStyle(.secondary)
                        }
                        Button(appLocalized("Cancel"), role: .cancel) {
                            model.cancelTranscription()
                        }
                    }
                    .font(.caption)
                } else if let failure = model.existingRunPostprocessFailure(for: record.id) {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if unresolvedConflictCount > 0 {
                Label(appLocalized("\(unresolvedConflictCount) unresolved"), systemImage: "exclamationmark.bubble")
                    .font(.callout)
                    .foregroundStyle(unresolvedConflictCount == 0 ? Color.secondary : Color.orange)
            }
        }
        .padding(.bottom, 8)
    }

    private var unresolvedConflictCount: Int {
        if isTranslation {
            return run.transcript.segments.enumerated().filter { index, segment in
                let flags = segment.flags ?? []
                return flags.contains(where: {
                    $0.localizedCaseInsensitiveContains("uncertain")
                        || $0.localizedCaseInsensitiveContains("conflict")
                }) && !run.isTranslationAcknowledged(
                    at: index,
                    text: segment.text,
                    record: record
                )
            }.count
        }
        let unresolvedConflictIndices = Set(run.conflicts.compactMap { conflict in
            run.correctionResolution(
                at: conflict.segmentIndex,
                record: record
            ) == nil
                ? conflict.segmentIndex
                : nil
        })
        let unresolvedFlagIndices = Set(run.transcript.segments.enumerated().compactMap {
            index, segment in
            let flags = segment.flags ?? []
            return flags.contains(where: {
                $0.localizedCaseInsensitiveContains("uncertain")
                    || $0.localizedCaseInsensitiveContains("conflict")
            }) && run.correctionResolution(at: index, record: record) == nil
                ? index : nil
        })
        return unresolvedConflictIndices.union(unresolvedFlagIndices).count
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
        record.speakerNames[raw] ?? raw
    }

    private func correctedText(_ item: TranscriptSegment) -> String {
        guard !isTranslation else { return item.segment.text }
        return run.correctionResolution(at: item.index, record: record)
            ?? item.segment.text
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
                selectedSegmentIDs: selectedSegmentIDs
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

    private func speakerColor(_ speaker: String) -> Color {
        let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .brown, .green]
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in speaker.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
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
        case (.speakerLabelled, .selection):
            appString("Copied the speaker-labelled selection.", locale: locale)
        case (.corrected, .selection):
            appString("Copied the corrected selection.", locale: locale)
        case (.translated, .selection):
            appString("Copied the translated selection.", locale: locale)
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
        selectedSegmentIDs: Set<TranscriptSegmentID>
    ) throws -> TranscriptCopyPayload {
        let selectedSegments = run.segments.filter { selectedSegmentIDs.contains($0.id) }
        guard selectedSegmentIDs.isEmpty || selectedSegments.count == selectedSegmentIDs.count else {
            throw TranscriptCopyError.staleSelection
        }
        let selectedIndices = Set(selectedSegments.map(\.index))
        let text = try TranscriptExporter.copyText(
            run: run,
            record: record,
            selectedSegmentIndices: selectedIndices
        )
        return TranscriptCopyPayload(
            text: text,
            confirmation: TranscriptCopyConfirmation(
                layer: TranscriptDisplayLayer.displayed(in: run),
                scope: selectedSegmentIDs.isEmpty
                    ? .transcript
                    : .selection(segmentCount: selectedSegments.count)
            )
        )
    }

    func perform(
        run: LoadedRun,
        record: LibraryRecord,
        selectedSegmentIDs: Set<TranscriptSegmentID>
    ) throws -> TranscriptCopyConfirmation {
        let payload = try payload(
            run: run,
            record: record,
            selectedSegmentIDs: selectedSegmentIDs
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

private struct TranscriptSegmentRow: View {
    let item: TranscriptSegment
    let displaySpeaker: String
    let correctedText: String
    let color: Color
    let isResolved: Bool
    let isSelected: Bool
    let allowsTextResolution: Bool
    let play: () -> Void
    let select: () -> Void
    let rename: () -> Void
    let inspectConflict: () -> Void

    private var isUncertain: Bool {
        item.segment.flags?.contains(where: { $0.localizedCaseInsensitiveContains("uncertain") }) == true
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(color)
                .frame(width: 4)
                .clipShape(Capsule())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button(action: rename) {
                        Text(displaySpeaker)
                            .font(.headline)
                            .foregroundStyle(color)
                    }
                    .buttonStyle(.plain)
                    .help(appLocalized("Rename this speaker everywhere in this transcript."))

                    Button(action: play) {
                        Label(timestamp(item.segment.startS), systemImage: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(appLocalized("Play this segment from the source audio."))

                    Spacer()

                    if let conflict = item.conflict, allowsTextResolution {
                        Button(action: inspectConflict) {
                            Label(
                                isResolved ? appLocalized("Resolved") : conflictTitle(conflict.kind),
                                systemImage: isResolved ? "checkmark.circle" : "exclamationmark.bubble.fill"
                            )
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(isResolved ? Color.secondary : Color.orange)
                    } else if isUncertain, allowsTextResolution {
                        Button(action: inspectConflict) {
                            Label(
                                isResolved ? appLocalized("Resolved") : appLocalized("Uncertain"),
                                systemImage: isResolved ? "checkmark.circle" : "questionmark.diamond.fill"
                            )
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(isResolved ? Color.secondary : Color.orange)
                    } else if isUncertain {
                        Label(
                            appLocalized("Uncertain"),
                            systemImage: "questionmark.diamond.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    Button(action: select) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .help(appLocalized("Select this segment for copying."))
                    .accessibilityLabel(isSelected
                        ? appLocalized("Remove this segment from the copy selection.")
                        : appLocalized("Select this segment for copying."))
                }

                TranscriptSegmentBody(
                    correctedText: correctedText,
                    flags: item.segment.flags ?? [],
                    play: play
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(rowBackground, in: .rect(cornerRadius: 10))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            } else if item.conflict != nil || isUncertain {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isResolved ? Color.secondary.opacity(0.25) : Color.orange.opacity(0.55))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var rowBackground: Color {
        if item.conflict != nil || isUncertain {
            return Color.orange.opacity(isResolved ? 0.035 : 0.075)
        }
        if isSelected {
            return Color.accentColor.opacity(0.1)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }

    private func conflictTitle(_ kind: MergeConflictKind) -> LocalizedStringResource {
        switch kind {
        case .ambiguousSpeaker: appLocalized("Ambiguous Speaker")
        case .overlappingSpeech: appLocalized("Overlapping Speech")
        case .asrDisagreement: appLocalized("Transcript Disagreement")
        }
    }
}

private struct TranscriptSegmentBody: View {
    let correctedText: String
    let flags: [String]
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 7) {
                Text(correctedText)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !flags.isEmpty {
                    ViewThatFits {
                        HStack(spacing: 5) { FlagChips(flags: flags) }
                        VStack(alignment: .leading, spacing: 4) { FlagChips(flags: flags) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(correctedText)
        .accessibilityHint(appLocalized("Play this segment from the source audio."))
    }
}

private struct FlagChips: View {
    let flags: [String]

    var body: some View {
        ForEach(flags, id: \.self) { flag in
            Text(flag)
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}

private struct SpeakerRenamePopover: View {
    let originalSpeaker: String
    @Binding var name: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appLocalized("Rename Speaker"))
                .font(.headline)
            Text(appLocalized("This name applies to every \(originalSpeaker) segment in exports."))
                .font(.caption)
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
        .padding(16)
        .frame(width: 320)
        .task { focused = true }
    }
}

private struct ConflictResolutionSheet: View {
    let item: TranscriptSegment
    let currentResolution: String?
    let isTranslation: Bool
    let choose: (String) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label(appLocalized("Review Uncertain Transcript"), systemImage: "exclamationmark.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Group {
                    if let reason = item.conflict?.reason {
                        Text(reason)
                    } else {
                        Text(appLocalized("This segment was marked uncertain by the pipeline."))
                    }
                }
                .foregroundStyle(.secondary)
            }

            CandidateButton(
                source: isTranslation
                    ? appLocalized("Post-processing")
                    : appLocalized("Primary Model"),
                text: item.segment.text,
                isSelected: currentResolution == item.segment.text,
                choose: choose
            )

            ForEach(Array((item.conflict?.candidates ?? []).enumerated()), id: \.offset) { index, candidate in
                CandidateButton(
                    source: appLocalized("Verification Model \(index + 1)"),
                    text: candidate,
                    isSelected: currentResolution == candidate,
                    choose: choose
                )
            }

            Text(isTranslation
                ? appLocalized("Your acceptance applies only to this exact translated text. The immutable source transcript and translation remain unchanged.")
                : appLocalized("Your selection is stored as a correction beside the immutable raw transcript."))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(appLocalized("Leave Unresolved"), action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 320)
    }
}

private struct CandidateButton: View {
    let source: LocalizedStringResource
    let text: String
    let isSelected: Bool
    let choose: (String) -> Void

    var body: some View {
        Button {
            choose(text)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(text)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 9))
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
        VStack(alignment: .leading, spacing: 18) {
            Text(PostprocessOperationChoice(operation).title)
                .font(.title2)
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
        .padding(24)
        .frame(minWidth: 440)
    }
}
