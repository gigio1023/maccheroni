import SwiftUI

struct LibrarySidebar: View {
    @Bindable var model: MaccheroniAppModel
    /// The record whose name is being edited, if any. Inline rather than in a
    /// sheet: renaming a row is a change to that row, and the Finder's own
    /// sidebars edit in place.
    @State private var renamingRecordID: UUID?
    @State private var draftName = ""
    /// The first of the move-to-Trash's two steps. Nothing moves while this is
    /// set; it is what the confirmation is asking about.
    @State private var pendingTrash: LibraryTrashPlan?

    var body: some View {
        List(selection: $model.selection) {
            Section(appLocalized("Library")) {
                Label(appLocalized("New Recording"), systemImage: "waveform.badge.mic")
                    .tag(AppSelection.capture)

                ForEach(model.records) { record in
                    LibraryRecordRow(
                        record: record,
                        isPostprocessing: model.isPostprocessingExistingRun(recordID: record.id),
                        partialCoverage: model.partialCoverage(for: record),
                        draftName: renamingRecordID == record.id ? $draftName : nil,
                        commitRename: { commitRename(record) },
                        cancelRename: cancelRename
                    )
                        .tag(AppSelection.record(record.id))
                        .contextMenu {
                            Button(appLocalized("Rename…")) { beginRename(record) }

                            Divider()

                            Button(appLocalized("Reveal Original in Finder")) {
                                model.revealOriginal(record)
                            }
                            if record.runURL != nil {
                                Button(appLocalized("Reveal Run in Finder")) {
                                    model.revealRun(record)
                                }
                            }

                            Divider()

                            // The ellipsis is the promise: this opens the
                            // confirmation below, it does not move anything.
                            Button(appLocalized("Move to Trash…"), role: .destructive) {
                                pendingTrash = model.trashPlan(for: record)
                            }
                            .disabled(!model.canMoveToTrash(record))
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(appLocalized("Library"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .confirmationDialog(
            Text(verbatim: LibraryTrashWording.title(for: pendingTrash)),
            isPresented: Binding(
                get: { pendingTrash != nil },
                set: { if !$0 { pendingTrash = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTrash
        ) { plan in
            Button(LibraryTrashWording.confirmLabel(for: plan), role: .destructive) {
                pendingTrash = nil
                Task { await model.moveToTrash(plan) }
            }
            Button(appLocalized("Cancel"), role: .cancel) { pendingTrash = nil }
        } message: { plan in
            Text(verbatim: LibraryTrashWording.message(for: plan))
        }
    }

    private func beginRename(_ record: LibraryRecord) {
        draftName = record.displayName
        renamingRecordID = record.id
    }

    private func commitRename(_ record: LibraryRecord) {
        let name = draftName
        renamingRecordID = nil
        draftName = ""
        model.rename(record, to: name)
    }

    /// Escape, and the safety net under a commit that fires as focus leaves:
    /// the draft is emptied first, and an empty name is not a rename.
    private func cancelRename() {
        draftName = ""
        renamingRecordID = nil
    }
}

/// One library row. Kept out of `LibrarySidebar` so a render harness can stack
/// rows directly: a `List` draws nothing under `ImageRenderer` (D48), and the
/// row is the part whose design has to be judged.
struct LibraryRecordRow: View {
    let record: LibraryRecord
    let isPostprocessing: Bool
    /// What a readable partial run did not transcribe. The row says so in
    /// its own words beside the state, because a reader choosing a recording
    /// must see the loss before opening it, not after (judgment rule 2).
    var partialCoverage: RunPartialCoverage? = nil
    /// Non-nil while this row's name is being edited.
    var draftName: Binding<String>?
    var commitRename: () -> Void = {}
    var cancelRename: () -> Void = {}

    @FocusState private var isEditingName: Bool

    private var partialPhrase: String? {
        partialCoverage.map { LibraryRowStatus.partialPhrase(missingDurationS: $0.missingDurationS) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.small) {
            Group {
                if isPostprocessing {
                    ProgressView().controlSize(.small)
                } else {
                    StatusGlyph(state: record.state, isPartial: partialCoverage != nil)
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                name
                HStack(spacing: 5) {
                    Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                    Text(Duration.seconds(record.durationS), format: .time(pattern: .minuteSecond))
                }
                .monospacedDigit()
                .font(AppTheme.Typography.meta)
                .foregroundStyle(AppTheme.Palette.inkSecondary)
                HStack(spacing: 5) {
                    Text(record.profileID.title)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                        .lineLimit(1)
                    Text(verbatim: "·")
                        .accessibilityHidden(true)
                        .foregroundStyle(AppTheme.Palette.inkSecondary)
                    // The state's own words carry it; the colour is spent only
                    // where the state is genuinely open, and never alone.
                    Text(record.state.title)
                        .foregroundStyle(LibraryRowStatus.tint(record.state))
                    if let partialPhrase {
                        Text(verbatim: "·")
                            .accessibilityHidden(true)
                            .foregroundStyle(AppTheme.Palette.inkSecondary)
                        // A named loss is an open matter and takes the open
                        // tint; the state word beside it stays as it is.
                        Text(verbatim: partialPhrase)
                            .foregroundStyle(AppTheme.Palette.open)
                            .lineLimit(1)
                    }
                }
                .font(AppTheme.Typography.meta)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: LibraryRowStatus.accessibilityLabel(
                for: record,
                partialCoverage: partialCoverage
            ))
        )
    }

    @ViewBuilder
    private var name: some View {
        if let draftName {
            TextField(appLocalized("Recording Name"), text: draftName)
                .textFieldStyle(.plain)
                .font(AppTheme.Typography.sectionTitle)
                .focused($isEditingName)
                .onSubmit(commitRename)
                .onExitCommand(perform: cancelRename)
                .onChange(of: isEditingName) { _, editing in
                    // Clicking away commits, which is what a sidebar rename
                    // does everywhere else on this platform.
                    if !editing { commitRename() }
                }
                .onAppear { isEditingName = true }
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.control)
                        .strokeBorder(AppTheme.Palette.accent, lineWidth: 1)
                }
                .help(appLocalized("Renames this recording in the library only. The audio file and the run folder keep their names."))
        } else {
            Text(record.displayName)
                .font(AppTheme.Typography.sectionTitle)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// The library's status vocabulary in the reading surface's grammar: the glyph
/// carries the shape, the state's own words carry the meaning, and colour is
/// spent only where the state is genuinely open. `Done` is the ordinary case
/// and takes the neutral ink — a library whose rows are mostly green teaches a
/// reader to stop seeing green, which is the colour the open states need.
enum LibraryRowStatus {
    static func symbol(_ state: LibraryItemState) -> String {
        switch state {
        case .recorded: "record.circle"
        case .transcribing: "hourglass"
        case .done: "checkmark.circle"
        // The same flag the transcript's review chip uses: this state is
        // review pending and nothing else.
        case .hasConflicts: "flag"
        case .failed: "exclamationmark.triangle"
        // Not `stop.circle`: at 12 points it is a dot in a circle and cannot
        // be told apart from `record.circle` two rows up.
        case .cancelled: "minus.circle"
        // The name this row carried before,
        // `exclamationmark.arrow.trianglehead.counterclockwise`, does not
        // exist in this SF Symbols release. It drew nothing, and the row's
        // name sat where no other row's name sits. Found by rendering.
        case .interrupted: "exclamationmark.arrow.circlepath"
        }
    }

    static func tint(_ state: LibraryItemState) -> Color {
        switch state {
        case .recorded, .done, .cancelled: AppTheme.Palette.inkSecondary
        // The one thing currently happening, which is what the accent marks.
        case .transcribing: AppTheme.Palette.accent
        case .hasConflicts, .interrupted: AppTheme.Palette.open
        case .failed: AppTheme.Palette.error
        }
    }

    /// A readable partial run keeps its state's glyph shape but takes the
    /// open tint and the triangle: the run finished, and it lost something
    /// the reader has to know about before opening it.
    static func symbol(_ state: LibraryItemState, isPartial: Bool) -> String {
        isPartial && state.isReadable ? "exclamationmark.triangle" : symbol(state)
    }

    static func tint(_ state: LibraryItemState, isPartial: Bool) -> Color {
        isPartial && state.isReadable ? AppTheme.Palette.open : tint(state)
    }

    /// `31s not transcribed`: the loss a partial run names, rounded up so a
    /// loss is never understated, in the row's own units.
    static func partialPhrase(missingDurationS: Double, locale: Locale? = nil) -> String {
        let seconds = missingDurationS.isFinite ? max(0, missingDurationS) : 0
        var style = Duration.UnitsFormatStyle(
            allowedUnits: [.hours, .minutes, .seconds],
            width: .narrow,
            fractionalPart: .hide(rounded: .up)
        )
        if let locale { style = style.locale(locale) }
        let missing = Duration.seconds(seconds).formatted(style)
        return appString("\(missing) not transcribed", locale: locale)
    }

    static func accessibilityLabel(
        for record: LibraryRecord,
        partialCoverage: RunPartialCoverage?,
        locale: Locale? = nil
    ) -> String {
        var parts = [record.displayName, record.state.localizedTitle(locale: locale)]
        if let partialCoverage {
            parts.append(partialPhrase(
                missingDurationS: partialCoverage.missingDurationS,
                locale: locale
            ))
        }
        return parts.joined(separator: ", ")
    }
}

private struct StatusGlyph: View {
    let state: LibraryItemState
    var isPartial = false

    var body: some View {
        Image(systemName: LibraryRowStatus.symbol(state, isPartial: isPartial))
            .font(.system(size: 12))
            .foregroundStyle(LibraryRowStatus.tint(state, isPartial: isPartial))
            .accessibilityHidden(true)
    }
}

/// The two-step move's own words, kept as values rather than written into the
/// dialog, so the sentence a reader agrees to can be read back in a test and
/// in a render without presenting anything.
enum LibraryTrashWording {
    static func title(for plan: LibraryTrashPlan?, locale: Locale? = nil) -> String {
        guard let plan else { return "" }
        let name = plan.displayName
        // The name is quoted the way the Finder quotes it: a recording called
        // "Move the deck" would otherwise read as part of the question.
        return plan.movesNothing
            ? appString("Remove \u{201C}\(name)\u{201D} from the library?", locale: locale)
            : appString("Move \u{201C}\(name)\u{201D} to the Trash?", locale: locale)
    }

    static func message(for plan: LibraryTrashPlan, locale: Locale? = nil) -> String {
        let files: String
        switch (plan.sourceURL != nil, plan.runURL != nil) {
        case (true, true):
            files = appString(
                "This moves the source audio and the run output to the Trash together. Nothing is deleted, and the Finder's Put Back restores them.",
                locale: locale
            )
        case (true, false):
            files = appString(
                "This moves the source audio to the Trash. Nothing is deleted, and the Finder's Put Back restores it.",
                locale: locale
            )
        case (false, true):
            files = appString(
                "This moves the run output to the Trash. Nothing is deleted, and the Finder's Put Back restores it.",
                locale: locale
            )
        case (false, false):
            // A failed request can leave only its engine log behind: the run
            // never wrote a directory and the audio is gone. That is still a
            // move, and the sentence says what moves.
            return plan.requestURL != nil
                ? appString(
                    "This moves the engine log kept from the failed run to the Trash. Nothing is deleted, and the Finder's Put Back restores it.",
                    locale: locale
                )
                : appString(
                    "The files this recording named are no longer on disk, so this removes its library entry and nothing else.",
                    locale: locale
                )
        }
        guard plan.requestURL != nil else { return files }
        return files + " " + appString(
            "This also moves the engine log kept from the failed run.",
            locale: locale
        )
    }

    static func confirmLabel(
        for plan: LibraryTrashPlan,
        locale: Locale? = nil
    ) -> LocalizedStringResource {
        plan.movesNothing
            ? appLocalized("Remove from Library", locale: locale)
            : appLocalized("Move to Trash", locale: locale)
    }
}
