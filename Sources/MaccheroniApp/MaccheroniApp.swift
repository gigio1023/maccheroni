import Foundation
import Observation
import MaccheroniPostprocess
import SwiftUI

@main
struct MaccheroniDesktopApp: App {
    @State private var startup = AppStartupState()
    @State private var languageStore = AppLanguageStore()

    var body: some Scene {
        Window("Maccheroni", id: "main") {
            AppEntryView(startup: startup)
                .environment(languageStore)
        }
        .defaultSize(width: 1_180, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            MaccheroniCommands(languageStore: languageStore)
        }

        Settings {
            SettingsView()
                .environment(languageStore)
        }
    }
}

@MainActor
@Observable
private final class AppStartupState {
    var model: MaccheroniAppModel?
    var errorMessage: String?
    private var didLoad = false

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            let repository = LibraryRepository.local
            let runner = try ProcessTranscriptionRunner(requestsRoot: repository.requestsRoot)
            let codexAvailability = await Task.detached(priority: .utility) {
                await CodexPostprocessBackend.detectAvailability()
            }.value
            model = try MaccheroniAppModel(
                repository: repository,
                profiles: AppProfileRegistry.load(),
                runner: runner,
                recorder: DualChannelRecorder(),
                codexAvailability: codexAvailability
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry() {
        didLoad = false
        errorMessage = nil
        Task { await load() }
    }
}

private struct AppEntryView: View {
    @Bindable var startup: AppStartupState
    @Environment(AppLanguageStore.self) private var languageStore

    var body: some View {
        Group {
            if let model = startup.model {
                RootView(model: model)
            } else if let message = startup.errorMessage {
                ContentUnavailableView {
                    Label(appLocalized("Maccheroni Could Not Start"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button(appLocalized("Try Again"), action: startup.retry)
                }
            } else {
                ProgressView(appLocalized("Preparing Maccheroni…"))
                    .controlSize(.large)
            }
        }
        .id(languageStore.rawValue)
        .environment(\.locale, selectedLanguage.locale)
        .task { await startup.load() }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var selectedLanguage: AppLanguage {
        languageStore.language
    }
}

private struct MaccheroniCommands: Commands {
    @FocusedValue(\.maccheroniActions) private var actions
    let languageStore: AppLanguageStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(appLocalized("New Recording", locale: languageStore.language.locale)) {
                actions?.newRecording()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions == nil)

            Button(appLocalized("Import Audio…", locale: languageStore.language.locale)) {
                actions?.importAudio()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(actions?.canImportAudio != true)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button(appLocalized("Cancel Transcription", locale: languageStore.language.locale)) {
                actions?.cancelTranscription()
            }
            .keyboardShortcut(.escape, modifiers: [.command])
            .disabled(actions?.canCancelTranscription != true)
        }
    }
}
