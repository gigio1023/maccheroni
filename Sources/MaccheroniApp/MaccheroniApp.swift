import AppKit
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
/// being re-invented as inline numbers per view. Sizes are points. This is the
/// base, not a layer of corrections over an older one: nothing in the
/// transcript surface, the review sheet or the run inspector sets a colour,
/// size, radius or column width that is not named here.
///
/// The design it implements is `docs/ui-design.md` section 3. Two grammars
/// share these tokens: the header chrome above the rule is product UI and may
/// use a bordered field or a filled selection; the row list below it is an
/// editorial table and uses type, spacing and hairlines only.
enum AppTheme {
    enum Spacing {
        static let tight: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let screen: CGFloat = 24
        /// Vertical padding of one transcript row. With an 18-point body line
        /// and a one-point hairline this makes a one-line row 43 points tall.
        static let rowVertical: CGFloat = 12
    }

    /// Square geometry. Controls in the header take 4, status chips take 2,
    /// everything else takes 0. No pill exists on the reading surfaces.
    enum Radius {
        static let control: CGFloat = 4
        static let chip: CGFloat = 2
    }

    /// The floor matters more than the scale: nothing a reader reads is set
    /// below `label`, which is 11 at heavy weight and reserved for chips and
    /// column headers. Roles are separated by axis in the row gutter rather
    /// than by adding sizes, so the scale stays short.
    enum Typography {
        static let screenTitle = Font.system(size: 22, weight: .semibold)
        /// 13, not 15: a heading set at the body size competes with the body
        /// it heads.
        static let sectionTitle = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 15)
        static let speaker = Font.system(size: 13, weight: .semibold)
        static let meta = Font.system(size: 12)
        static let metaStrong = Font.system(size: 12, weight: .semibold)
        /// Chips and column headers only.
        static let label = Font.system(size: 11, weight: .heavy)
        static let bodyLineSpacing: CGFloat = 3
    }

    /// The transcript table's geometry: one reading measure shared by the
    /// header and the list, and the fixed-width gutter columns that keep every
    /// row's time, speaker and review marker in one column each.
    enum Layout {
        static let measure: CGFloat = 860
        static let selectColumn: CGFloat = 14
        /// Wide enough for `59:59` beside the playing glyph; a recording
        /// never reaches an hour (the ASR duration limit is 59 minutes).
        static let timeColumn: CGFloat = 48
        static let speakerColumn: CGFloat = 132
        static let reviewColumn: CGFloat = 76
        static let columnGap: CGFloat = 8
        static let textGap: CGFloat = 12
        /// Height of the share band under the candidate figures.
        static let bandHeight: CGFloat = 3
        /// Height of the share band in the review sheet, where it stands alone.
        static let sheetBandHeight: CGFloat = 6

        /// The speaker and review columns and the gap between them: the span
        /// of an unnamed segment's evidence line.
        static var evidenceSpan: CGFloat {
            speakerColumn + columnGap + reviewColumn
        }

        /// Everything before the transcript text.
        static var gutterWidth: CGFloat {
            selectColumn + columnGap + timeColumn + columnGap + evidenceSpan + textGap
        }

        static func textWidth(rowWidth: CGFloat) -> CGFloat {
            max(0, rowWidth - gutterWidth)
        }
    }

    /// Every colour here is resolved per appearance, so the light value is
    /// chosen against the light ground and the dark value against the dark
    /// one. Text meets 4.5:1 and meaning-carrying marks meet 3:1 on both
    /// grounds, which measure white and `#1E1E1E`. The system secondary label
    /// colour is deliberately not used: it measures 3.95:1 in the light
    /// appearance.
    enum Palette {
        /// A light and a dark hex value for one token.
        struct Swatch: Equatable, Sendable {
            let light: String
            let dark: String

            var color: Color {
                Color(nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return NSColor(hex: isDark ? self.dark : self.light)
                })
            }
        }

        static let inkSecondarySwatch = Swatch(light: "#5F5F5F", dark: "#A3A3A3")
        static let hairlineSwatch = Swatch(light: "#DADADA", dark: "#3A3A3A")
        /// A control's edge, which is not decorative: for the search field,
        /// the step buttons and the play button the stroke is the whole visual
        /// claim that the thing is operable, and WCAG 1.4.11 asks 3:1 of
        /// exactly that. 3.45:1 light and 3.88:1 dark against the page. Kept
        /// below the secondary ink on purpose — a control's edge should be
        /// findable, not as loud as the text inside it.
        static let controlBorderSwatch = Swatch(light: "#8A8A8A", dark: "#7A7A7A")
        static let accentSwatch = Swatch(light: "#0B57D0", dark: "#7AB8FF")
        static let openSwatch = Swatch(light: "#9E4B08", dark: "#F5A05A")
        static let errorSwatch = Swatch(light: "#C0392B", dark: "#FF7B6B")

        /// Indexed by the speaker's position in the run's sorted roster rather
        /// than by a hash of its name: a hash can seat two speakers of a
        /// two-speaker recording on the same colour, which this surface then
        /// has no way to distinguish. Blue is absent because the accent is
        /// blue, so a speaker colour can never be mistaken for a state. Each
        /// entry keeps its hue across appearances so a speaker keeps its
        /// identity when the appearance changes.
        static let speakerSwatches: [Swatch] = [
            Swatch(light: "#227E91", dark: "#1F96AD"),
            Swatch(light: "#7F2CBA", dark: "#B26CE5"),
            Swatch(light: "#BA2C67", dark: "#E15690"),
            Swatch(light: "#2C2CBA", dark: "#7D7DE8"),
            Swatch(light: "#A95E28", dark: "#D46E25"),
            Swatch(light: "#1F8438", dark: "#1FAD42"),
            Swatch(light: "#2C73BA", dark: "#3C8CDD"),
        ]

        /// Transcript text, names, figures.
        static let ink = Color.primary
        /// Times, counts, reasons, neutral chips, an unnamed speaker.
        static let inkSecondary = inkSecondarySwatch.color
        /// Row separators and the header rule. Decorative: nothing a reader
        /// has to see is drawn in it, and a darker line would turn 248 rows
        /// into a grid.
        static let hairline = hairlineSwatch.color
        /// The boundary of something a reader can type in, click or drag.
        static let controlBorder = controlBorderSwatch.color
        /// The focused row, the displayed tab, a checked box, the playing glyph.
        static let accent = accentSwatch.color
        /// A genuinely open state: the review navigator's flag, the wording chip,
        /// the missing-range notice. Always beside a text label.
        static let open = openSwatch.color
        /// A failure the reader must see. Always beside a text label.
        static let error = errorSwatch.color
        /// The page ground, which the pinned column header must paint over
        /// the rows scrolling beneath it.
        static let ground = Color(nsColor: .windowBackgroundColor)

        static let speakers: [Color] = speakerSwatches.map(\.color)
        /// An unnamed speaker is a state, not a colour; it takes the secondary
        /// ink beside its words.
        static let unattributed = inkSecondary

        static func speaker(atRosterIndex index: Int?) -> Color {
            guard let index, index >= 0 else { return unattributed }
            return speakers[index % speakers.count]
        }

        static func speakerSwatch(atRosterIndex index: Int) -> Swatch {
            speakerSwatches[max(0, index) % speakerSwatches.count]
        }
    }
}

extension NSColor {
    /// `#RRGGBB` in sRGB. A malformed value is a programming error in the
    /// token table, so it falls back to a colour that is visibly wrong rather
    /// than crashing the reading surface.
    convenience init(hex: String) {
        var value: UInt64 = 0
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, Scanner(string: digits).scanHexInt64(&value) else {
            self.init(srgbRed: 1, green: 0, blue: 1, alpha: 1)
            return
        }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
