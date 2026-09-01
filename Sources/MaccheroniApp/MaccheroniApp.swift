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

/// One appearance vocabulary for the reading surfaces, defined once instead of
/// being re-invented as inline numbers per view. Sizes are points.
///
/// The floor matters more than the scale here: nothing a reader reads is set
/// below `AppTheme.Typography.meta`, which is 12. The surface this replaced set
/// flags, evidence and provenance at `caption2` — 10 points — which made the
/// smallest text on screen the text carrying the reasons.
enum AppTheme {
    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let row: CGFloat = 14
        static let large: CGFloat = 16
        static let screen: CGFloat = 24
    }

    enum Radius {
        static let chip: CGFloat = 6
        static let row: CGFloat = 10
    }

    enum Typography {
        static let screenTitle = Font.system(size: 22, weight: .semibold)
        static let sectionTitle = Font.system(size: 15, weight: .semibold)
        static let body = Font.system(size: 15)
        static let speaker = Font.system(size: 13, weight: .semibold)
        static let meta = Font.system(size: 12)
        static let metaStrong = Font.system(size: 12, weight: .semibold)
        static let bodyLineSpacing: CGFloat = 3
    }

    enum Palette {
        /// Indexed by the speaker's position in the run's sorted roster rather
        /// than by a hash of its name: a hash can seat two speakers of a
        /// two-speaker recording on the same colour, which this surface then
        /// has no way to distinguish. Neither the accent (the segment the
        /// reader is on) nor the review colour appears here, so a speaker
        /// colour can never be mistaken for a state.
        static let speakers: [Color] = [
            .teal, .purple, .pink, .indigo, .brown, .green, .cyan,
        ]
        static let unattributed = Color.secondary
        static let reviewPending = Color.orange

        static func speaker(atRosterIndex index: Int?) -> Color {
            guard let index, index >= 0 else { return unattributed }
            return speakers[index % speakers.count]
        }
    }
}
