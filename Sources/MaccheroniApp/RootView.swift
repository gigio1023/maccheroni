import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var model: MaccheroniAppModel
    @State private var isImporting = false

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(model: model)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.showCapture()
                } label: {
                    Label(appLocalized("New Recording"), systemImage: "waveform.badge.mic")
                }
                .help(appLocalized("Open the capture view."))

                Button {
                    isImporting = true
                } label: {
                    Label(appLocalized("Import Audio"), systemImage: "plus")
                }
                .help(appLocalized("Import an audio file for transcription."))
                .disabled(!model.canImportAudio)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canImportAudio else { return false }
            model.importAudio(urls)
            return true
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            model.handleImportResult(result)
        }
        .alert(appLocalized("Maccheroni Needs Attention"), isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button(appLocalized("OK"), role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .focusedSceneValue(
            \.maccheroniActions,
            MaccheroniMenuActions(
                newRecording: model.showCapture,
                importAudio: { isImporting = true },
                cancelTranscription: model.cancelTranscription,
                canImportAudio: model.canImportAudio,
                canCancelTranscription: model.isTranscribing
            )
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.shutdown()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            model.syncPostprocessSelectionsFromDefaults()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .capture:
            CaptureView(model: model, chooseFile: { isImporting = true })
        case let .record(id):
            if let record = model.records.first(where: { $0.id == id }) {
                switch record.state {
                case .done, .hasConflicts:
                    if let run = model.selectedRun {
                        TranscriptView(model: model, record: record, run: run)
                    } else {
                        RunUnavailableView(
                            record: record,
                            issue: model.selectedRunIssue ?? .missing,
                            reveal: { model.revealRun(record) }
                        )
                    }
                case .recorded, .transcribing, .failed, .cancelled, .interrupted:
                    RunProgressView(model: model, record: record)
                }
            } else {
                ContentUnavailableView(
                    appLocalized("Recording Not Found"),
                    systemImage: "waveform.slash",
                    description: Text(appLocalized("The library entry is no longer available."))
                )
            }
        }
    }
}

private struct RunUnavailableView: View {
    let record: LibraryRecord
    let issue: RunLoadIssue
    let reveal: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(appLocalized("Run Could Not Be Opened"), systemImage: "exclamationmark.triangle")
        } description: {
            switch issue {
            case .missing:
                Text(appLocalized("Recording Not Found"))
            case let .missingArtifact(message), let .decoding(message):
                Text(verbatim: message)
            case .integrity:
                Text(appLocalized("The raw run remains on disk, but one or more required artifacts failed an integrity check."))
            }
        } actions: {
            if record.runURL != nil, issue.canReveal {
                Button(appLocalized("Reveal Run in Finder"), action: reveal)
            }
        }
        .navigationTitle(record.displayName)
    }
}

struct MaccheroniMenuActions {
    var newRecording: () -> Void
    var importAudio: () -> Void
    var cancelTranscription: () -> Void
    var canImportAudio: Bool
    var canCancelTranscription: Bool
}

private struct MaccheroniActionsKey: FocusedValueKey {
    typealias Value = MaccheroniMenuActions
}

extension FocusedValues {
    var maccheroniActions: MaccheroniMenuActions? {
        get { self[MaccheroniActionsKey.self] }
        set { self[MaccheroniActionsKey.self] = newValue }
    }
}
