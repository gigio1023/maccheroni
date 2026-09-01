import SwiftUI

struct LibrarySidebar: View {
    @Bindable var model: MaccheroniAppModel

    var body: some View {
        List(selection: $model.selection) {
            Section(appLocalized("Library")) {
                Label(appLocalized("New Recording"), systemImage: "waveform.badge.mic")
                    .tag(AppSelection.capture)

                ForEach(model.records) { record in
                    LibraryRecordRow(
                        record: record,
                        isPostprocessing: model.isPostprocessingExistingRun(recordID: record.id)
                    )
                        .tag(AppSelection.record(record.id))
                        .contextMenu {
                            Button(appLocalized("Reveal Original in Finder")) {
                                model.revealOriginal(record)
                            }
                            if record.runURL != nil {
                                Button(appLocalized("Reveal Run in Finder")) {
                                    model.revealRun(record)
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(appLocalized("Library"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
    }
}

private struct LibraryRecordRow: View {
    let record: LibraryRecord
    let isPostprocessing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.small + 2) {
            Group {
                if isPostprocessing {
                    ProgressView().controlSize(.small)
                } else {
                    StatusGlyph(state: record.state)
                }
            }
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.tight) {
                Text(record.displayName)
                    .font(AppTheme.Typography.body)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text(verbatim: "•")
                        .accessibilityHidden(true)
                    Text(Duration.seconds(record.durationS), format: .time(pattern: .minuteSecond))
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
                HStack(spacing: AppTheme.Spacing.tight + 2) {
                    Text(record.profileID.title)
                    Text(record.state.title)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                .font(AppTheme.Typography.meta)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(verbatim: "\(record.displayName), \(record.state.localizedTitle())")
        )
    }
}

private struct StatusGlyph: View {
    let state: LibraryItemState

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(style)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .recorded: "record.circle"
        case .transcribing: "waveform"
        case .done: "checkmark.circle.fill"
        case .hasConflicts: "exclamationmark.bubble.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle"
        case .interrupted: "exclamationmark.arrow.trianglehead.counterclockwise"
        }
    }

    private var style: Color {
        switch state {
        case .recorded: .secondary
        case .transcribing: .accentColor
        case .done: .green
        case .hasConflicts: .orange
        case .failed: .red
        case .cancelled, .interrupted: .secondary
        }
    }
}
