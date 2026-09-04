// P5: the accessibility audit of the app screens, as an offscreen walk of the
// AppKit accessibility tree (see `AccessibilityAuditSupport.swift`).
//
// One test per screen. Each hosts the real screen on synthetic fixtures, reads
// the tree back, and checks the invariants that hold today: every control has
// a name, no name is a raw identifier or enum token, no glyph reaches a client
// by its symbol name, every reachable element has a role, and the controls and
// sentences the screen exists for are in the tree. Where the screen currently
// violates one, the violation is listed as a named exception beside the test,
// so the test passes now, fails when a new violation appears, and also fails
// when an accepted exception stops firing, which is either a fix that landed
// or a control that vanished, and either way the list has to change. The
// exceptions are the warning table of the audit report this file was written
// with, and each carries the proposed fix that report records.
//
// No pixel is drawn and no private recording is read; the whole file runs on a
// fresh clone inside any window-server session.
import AppKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import SwiftUI
import Testing
@testable import MaccheroniApp

@Suite(.serialized, .enabled(if: AccessibilityAudit.hasWindowServerSession))
struct AccessibilityAuditTests {
    typealias Exception = AccessibilityFinding.Exception
    typealias Expectation = AccessibilityRules.Expectation

    /// Runs the generic rules and the screen's own expectations against the
    /// tree, and fails on any finding outside the accepted list or any
    /// accepted finding that no longer occurs.
    @MainActor
    private func audit(
        _ tree: AccessibilityTree,
        expecting expectations: [Expectation] = [],
        accepting exceptions: [Exception]
    ) {
        let result = AccessibilityRules.audit(tree, expecting: expectations, accepting: exceptions)
        print("A11Y \(tree.name): \(tree.elements.count) elements, \(tree.interactive.count) interactive, \(exceptions.count) accepted, \(result.unexpected.count) unexpected, \(result.stale.count) stale")
        for finding in result.unexpected { print("A11Y   unexpected \(finding)") }
        for exception in result.stale { print("A11Y   stale \(exception.kind.rawValue) \(exception.role) \"\(exception.name)\"") }
        #expect(result.unexpected.isEmpty, "\(tree.name): unexpected findings \(result.unexpected)")
        #expect(result.stale.isEmpty, "\(tree.name): accepted exceptions that no longer occur \(result.stale)")
    }

    // MARK: - Capture

    /// The profile pop-up has no name of its own (report W-A11Y, capture 1),
    /// the two segmented pickers have none either (capture 2), and the
    /// readiness and Codex notices combine their children into one button
    /// named by their text, which swallows *Check Again* (capture 3, 4).
    static let captureExceptions: [Exception] = [
        Exception(kind: .unlabelledControl, role: "AXPopUpButton", name: ""),
        Exception(kind: .unnamedSegmentedControl, role: "AXRadioGroup", name: ""),
    ]

    @Test @MainActor
    func captureScreen() async throws {
        struct Variant {
            var label: String
            var report: ProfileReadinessReport
            var postprocess: PostprocessChoice
            var expectations: [Expectation]
            var exceptions: [Exception]
        }
        let variants = [
            Variant(
                label: "ready",
                report: AccessibilityAuditFixtures.readyReport(),
                postprocess: .local,
                expectations: [
                    .noTextContaining("not ready"),
                ],
                exceptions: Self.captureExceptions
            ),
            Variant(
                label: "notready",
                report: AccessibilityAuditFixtures.unprovisionedReport(),
                postprocess: .local,
                expectations: [
                    .element(role: "AXLink", name: "Check Again"),
                ],
                exceptions: Self.captureExceptions + [
                    Exception(kind: .controlNamedByCombinedText, role: "AXButton", name: "This profile is not ready to run."),
                    Exception(kind: .missingElement, role: "AXLink", name: "Check Again"),
                ]
            ),
            Variant(
                label: "codex",
                report: AccessibilityAuditFixtures.readyReport(),
                postprocess: .codex,
                expectations: [
                    .element(role: "AXLink", name: "Check Again"),
                ],
                exceptions: Self.captureExceptions + [
                    Exception(kind: .controlNamedByCombinedText, role: "AXButton", name: "Codex CLI was not found."),
                    Exception(kind: .missingElement, role: "AXLink", name: "Check Again"),
                ]
            ),
        ]
        for variant in variants {
            let model = try AccessibilityAuditFixtures.model(report: variant.report)
            model.selectedPostprocess = variant.postprocess
            let hosting = AccessibilityAudit.mount(
                CaptureView(model: model, chooseFile: {}), width: 820, height: 1_200
            )
            #expect(await AccessibilityAuditFixtures.settleReadiness(model))
            let tree = AccessibilityAudit.read(hosting, name: "capture-\(variant.label)")

            // What every capture screen must expose, whatever readiness says.
            #expect(tree.contains(role: "AXButton", named: "Start Recording"))
            #expect(tree.first(role: "AXButton", named: "Start Recording")?.help.isEmpty == false)
            #expect(tree.contains(role: "AXButton", named: "Choose Audio File…"))
            #expect(tree.contains(role: "AXButton", named: "Edit Glossary"))
            #expect(tree.contains(role: "AXRadioButton", named: "Codex"))
            #expect(tree.contains(role: "AXRadioButton", named: "Local"))
            #expect(tree.contains(role: "AXRadioButton", named: "None"))
            #expect(tree.first(role: "AXPopUpButton", named: "")?.value == "Korean IT Meeting")
            #expect(tree.contains(text: "Audio never leaves this Mac."))
            #expect(tree.images.isEmpty, "every glyph on the capture screen is hidden")
            switch variant.label {
            case "notready":
                // The notice is one button whose name is every sentence in it,
                // provisioning command included, and its *Check Again* is one
                // of that button's custom actions rather than a control.
                let notice = tree.buttons.first { $0.name.hasPrefix("This profile is not ready to run.") }
                #expect(notice?.name.contains("setup-transcription-runtime.zsh") == true)
                #expect(notice?.customActionCount == 2)
                #expect(tree.first(role: "AXButton", named: "Start Recording")?.isEnabled == false)
            case "codex":
                let notice = tree.buttons.first { $0.name.hasPrefix("Codex CLI was not found.") }
                #expect(notice?.customActionCount == 1)
            default:
                #expect(tree.first(role: "AXButton", named: "Start Recording")?.isEnabled == true)
            }

            audit(tree, expecting: variant.expectations, accepting: variant.exceptions)
        }
    }

    // MARK: - Run progress and failure

    /// The stage glyphs reach a client as images named by SwiftUI's own
    /// description of the symbol: a finished stage reads *Selected*, a failed
    /// one *Close*, an unreached one *circle* (report W-A11Y, progress 1).
    @Test @MainActor
    func runProgressScreens() throws {
        let root = try AccessibilityAuditFixtures.temporaryRoot()
        let failedRun = try AccessibilityAuditFixtures.failedRunDirectory(in: root)
        let source = try AccessibilityAuditFixtures.silentWAV(in: root)
        let recorded = AccessibilityAuditFixtures.record(
            named: "Board review", runURL: nil, durationS: 600, state: .recorded,
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
            sourceURL: source
        )
        let failed = AccessibilityAuditFixtures.record(
            named: "Weekly product sync", runURL: failedRun, durationS: 1_243.08, state: .failed,
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
        )
        let model = try AccessibilityAuditFixtures.model(records: [recorded, failed])

        let ready = AccessibilityAudit.host(
            RunProgressView(model: model, record: recorded), name: "progress-recorded", width: 820
        )
        #expect(ready.contains(text: "Ready to Transcribe"))
        #expect(ready.first(role: "AXButton", named: "Try Again")?.isEnabled == true)
        #expect(ready.contains(text: "Speaker Diarization"))
        audit(ready, accepting: [
            Exception(kind: .imageExposedWithSymbolName, role: "AXImage", name: "circle (circle)"),
        ])

        let failure = AccessibilityAudit.host(
            RunProgressView(model: model, record: failed), name: "progress-failed", width: 820
        )
        #expect(failure.contains(text: "Transcription Failed"))
        #expect(failure.contains(text: RunFailureCause.repetitionLooping.sentenceText(locale: AccessibilityAudit.english)))
        #expect(failure.contains(text: "This stage stopped the run."))
        #expect(failure.contains(role: "AXHeading", named: "Failure Details"))
        #expect(failure.contains(role: "AXButton", named: "Reveal Preserved Run"))
        #expect(!failure.containsText(containing: "ASR_REPETITION_LOOPING"), "the error code stays out of the reading surface")
        audit(failure, accepting: [
            Exception(kind: .imageExposedWithSymbolName, role: "AXImage", name: "Selected (checkmark.circle.fill)"),
            Exception(kind: .imageExposedWithSymbolName, role: "AXImage", name: "Close (xmark.circle.fill)"),
            Exception(kind: .imageExposedWithSymbolName, role: "AXImage", name: "circle (circle)"),
        ])
    }

    // MARK: - Transcript

    /// What the transcript header currently gets wrong (report W-A11Y,
    /// transcript 1-3): the playhead and the three unavailable layer tabs are
    /// reachable elements with a name and no role, and the search field is
    /// named only by its placeholder.
    static let transcriptHeaderExceptions: [Exception] = [
        Exception(kind: .elementWithoutRole, role: "AXUnknown", name: "Playhead"),
        Exception(kind: .elementWithoutRole, role: "AXUnknown", name: "Corrected"),
        Exception(kind: .elementWithoutRole, role: "AXUnknown", name: "Translated"),
        Exception(kind: .textFieldNamedByPlaceholderOnly, role: "AXTextField", name: "Search this transcript"),
    ]

    /// What the rows currently get wrong (transcript 4, 5): the contested
    /// share replaces its number with a sentence, so the percentage is never
    /// read, and the *Wording* chip is named by the same sentence as the
    /// *Review* chip, so its visible word is not in its name.
    static let transcriptRowExceptions: [Exception] = [
        Exception(kind: .unexpectedText, role: "AXStaticText", name: "This speaker held this much of the segment's speech."),
        Exception(kind: .missingElement, role: "AXButton", name: "Wording"),
    ]

    static let transcriptRowExpectations: [Expectation] = [
        .noText("This speaker held this much of the segment's speech."),
        .element(role: "AXButton", name: "Wording"),
    ]

    /// Every row is a group holding a selection button, a time button that
    /// plays from the segment, and its text; a named speaker is a rename
    /// button and an unnamed one is the words *Speaker not named* with the
    /// candidates' figures beside it.
    @MainActor
    private func checkRows(_ tree: AccessibilityTree, run: LoadedRun, count: Int) {
        let rows = tree.elements.filter { $0.isGroup && $0.className == "AccessibilityNode" && $0.depth >= 2 }
        #expect(rows.count == count, "\(tree.name): \(rows.count) rows exposed")
        for (row, item) in zip(rows, run.segments.prefix(count)) {
            let children = tree.children(of: row)
            let time = TranscriptPlaybackTimeline.clock(item.segment.startS)
            #expect(children.contains { $0.role == "AXButton" && $0.name.hasSuffix("segment for copying.") || $0.name.hasSuffix("copy selection.") }, "\(tree.name) row \(item.index): selection button")
            #expect(children.contains { $0.role == "AXButton" && $0.name == time && $0.help == "Play the recording from this segment." }, "\(tree.name) row \(item.index): time button")
            #expect(children.contains { $0.isStaticText && $0.text == item.segment.text }, "\(tree.name) row \(item.index): text")
            if SpeakerRoster.isAttributed(item.segment.speaker) {
                #expect(children.contains { $0.role == "AXButton" && $0.help == "Rename this speaker everywhere in this transcript." }, "\(tree.name) row \(item.index): rename button")
            } else {
                #expect(children.contains { $0.isStaticText && $0.text == "Speaker not named" }, "\(tree.name) row \(item.index): unnamed speaker")
                let candidates = item.conflict?.speakerAttribution?.candidates ?? []
                if !candidates.isEmpty {
                    #expect(children.contains { $0.isStaticText && $0.text.contains("%") && $0.text.contains("Jina") }, "\(tree.name) row \(item.index): candidate figures")
                }
            }
            for child in children where child.isStaticText {
                #expect(!AccessibilityRules.bareTokens.contains(child.text), "\(tree.name) row \(item.index): raw speaker token")
            }
        }
    }

    @Test @MainActor
    func transcriptScreen() throws {
        let meeting = AccessibilityAuditFixtures.meetingRun()
        let focus = meeting.run.segments.first {
            !SpeakerRoster.isAttributed($0.segment.speaker) && $0.index > 2
        }!.index
        let rows = 40
        let tree = AccessibilityAudit.host(
            AccessibilityAuditFixtures.composedTranscript(
                meeting: meeting, proposal: nil, layer: .speakerLabelled,
                focused: focus, selected: [3], rows: rows
            ),
            name: "transcript-composed", width: 1_400, height: 3_600
        )

        // The header, in the order a client reaches it.
        let header = tree.navigationOrder.prefix(5)
        #expect(Array(header) == [
            "AXButton Play the recording",
            "AXButton Speaker-labelled",
            "AXTextField (unnamed)",
            "AXButton Go to the previous segment to review",
            "AXButton Go to the next segment to review",
        ], "\(header)")
        #expect(tree.first(role: "AXButton", named: "Speaker-labelled")?.isSelected == true)
        #expect(tree.contains(text: "248 segments · 2 speakers · 110 without a speaker · 192 to review"))
        #expect(tree.contains(text: "3 of 192 to review"))
        #expect(tree.first(role: "AXUnknown", named: "Proposed")?.help == "A proposed speaker layer would come from a derived run. None has been produced.")

        checkRows(tree, run: meeting.run, count: rows)
        let focused = tree.elements.first { $0.isGroup && $0.depth >= 2 && tree.children(of: $0).contains { $0.name == TranscriptPlaybackTimeline.clock(meeting.run.segments[focus].segment.startS) } }
        #expect(focused.map { tree.children(of: $0).contains { $0.text == "No speaker held 60% of this segment's speech, so none was named." } } == true, "the focused row prints its reason")
        #expect(tree.first(role: "AXButton", named: "Remove this segment from the copy selection.")?.isSelected == true)
        #expect(tree.images.isEmpty, "every glyph in the transcript is hidden or folded into its control")

        audit(
            tree,
            expecting: Self.transcriptRowExpectations,
            accepting: Self.transcriptHeaderExceptions
                + [Exception(kind: .elementWithoutRole, role: "AXUnknown", name: "Proposed")]
                + Self.transcriptRowExceptions
        )

        // The shipped screen: the same header, and the list inside its scroll
        // view, of which the offscreen layout realises the first rows only.
        // Its toolbar is a window toolbar and is not in this tree.
        let model = try AccessibilityAuditFixtures.model()
        let shipped = AccessibilityAudit.host(
            TranscriptView(model: model, record: meeting.record, run: meeting.run, proposal: nil),
            name: "transcript-shipped", width: 1_400, height: 1_000
        )
        #expect(Array(shipped.navigationOrder.prefix(5)) == Array(header))
        #expect(shipped.contains(text: "192 to review"))
        let shippedRows = shipped.elements.filter { $0.isGroup && $0.className == "AccessibilityNode" && $0.depth >= 2 }
        #expect(shippedRows.count >= 10, "\(shippedRows.count) rows realised inside the scroll view")
        #expect(!shipped.contains(role: "AXButton", named: "Copy Transcript"), "the toolbar is not part of the offscreen tree; the report says so")
        audit(
            shipped,
            expecting: [.noText("This speaker held this much of the segment's speech.")],
            accepting: Self.transcriptHeaderExceptions
                + [Exception(kind: .elementWithoutRole, role: "AXUnknown", name: "Proposed")]
                + [Exception(kind: .unexpectedText, role: "AXStaticText", name: "This speaker held this much of the segment's speech.")]
        )
    }

    // MARK: - Proposal layer

    @Test @MainActor
    func proposalLayerScreen() throws {
        let meeting = AccessibilityAuditFixtures.meetingRun()
        let document = AccessibilityAuditFixtures.proposalDocument(for: meeting)
        let layer = TranscriptProposalLayer(document: document)
        let focus = meeting.run.segments.first {
            !SpeakerRoster.isAttributed($0.segment.speaker) && $0.index > 2
        }!.index
        let rows = 40
        let tree = AccessibilityAudit.host(
            AccessibilityAuditFixtures.composedTranscript(
                meeting: meeting, proposal: document, layer: .proposed,
                focused: focus, selected: [], rows: rows
            ),
            name: "proposal-composed", width: 1_400, height: 3_600
        )
        #expect(tree.first(role: "AXButton", named: "Proposed")?.isSelected == true)
        #expect(tree.contains(text: "\(layer.proposedCount) proposed, \(layer.declinedCount) declined. Not acoustic evidence, and not measured."))
        #expect(tree.containsText(containing: "of this recording produced no transcript, so these proposals cover 20:12 of 20:43."))
        checkRows(tree, run: meeting.run, count: rows)
        #expect(tree.contains(text: "Proposed, not measured, Jina") || tree.contains(text: "Proposed, not measured, Speaker 1"), "a proposed row reads its dashed label and the plain name")
        #expect(tree.contains(text: "No speaker proposed"))
        #expect(tree.contains(text: "The model would not say which of the two was speaking."))
        #expect(!tree.containsText(containing: "no_top_ranked_candidate"), "decline causes never reach the surface as tokens")
        audit(
            tree,
            expecting: Self.transcriptRowExpectations,
            accepting: Self.transcriptHeaderExceptions + Self.transcriptRowExceptions
        )

        // One row per decline cause, with the tie focused.
        let causes = AccessibilityAudit.host(
            AccessibilityAuditFixtures.composedRows(
                meeting: meeting, proposal: document,
                indices: [3, meeting.silentSegmentIndex, meeting.tieSegmentIndex, meeting.wordingSegmentIndex],
                focused: meeting.tieSegmentIndex
            ),
            name: "proposal-causes", width: 1_400, height: 700
        )
        #expect(causes.contains(text: "No speaker was active on the speaker timeline during this segment."))
        #expect(causes.contains(text: "The two speakers held equal overlap, so there is no top-ranked candidate to confirm."))
        #expect(causes.contains(text: "No speaker held 60% of this segment's speech, so none was named."))
        audit(
            causes,
            expecting: [.element(role: "AXButton", name: "Wording")],
            accepting: [Exception(kind: .missingElement, role: "AXButton", name: "Wording")]
        )
    }

    // MARK: - Inspector

    @Test @MainActor
    func inspectorScreen() throws {
        let meeting = AccessibilityAuditFixtures.meetingRun()
        for (label, expanded) in [("collapsed", false), ("expanded", true)] {
            let view = Form {
                RunInspectorSections(
                    record: meeting.record, run: meeting.run, showsFingerprints: .constant(expanded)
                )
            }
            .formStyle(.grouped)
            let tree = AccessibilityAudit.host(
                view, name: "inspector-\(label)", width: 350, height: expanded ? 2_600 : 900
            )
            for heading in ["This Run", "Models", "Glossary", "Audio Preparation"] {
                #expect(tree.contains(role: "AXHeading", named: heading), "\(label): \(heading)")
            }
            #expect(tree.first(role: "AXDisclosureTriangle", named: "Exact Identities")?.value == (expanded ? "1" : "0"))
            #expect(tree.contains(text: "248, 110 without a speaker"))
            #expect(tree.contains(text: "20:12 of 20:43 (97.5%)"))
            #expect(tree.contains(text: "Partial"))
            #expect(tree.contains(text: "Run ID") == expanded)
            #expect(tree.contains(text: meeting.run.manifest.runID) == expanded)
            #expect(!tree.contains(text: "partial"), "the status is worded, not its raw value")
            #expect(!tree.contains(text: "free_text_context"), "the injection mode is worded, not its raw value")
            audit(tree, accepting: [])
        }
    }

    // MARK: - Sidebar and window

    /// A renaming row combines its text field into one element with a name
    /// and no role, so the field cannot be found as a field (report W-A11Y,
    /// sidebar 1); every row's label drops the date, duration and profile
    /// the row prints (sidebar 2).
    @Test @MainActor
    func sidebarScreens() throws {
        let records = AccessibilityAuditFixtures.sidebarRecords()
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(records.enumerated()), id: \.offset) { index, item in
                LibraryRecordRow(
                    record: item,
                    isPostprocessing: index == records.count - 1,
                    draftName: index == 1 ? .constant("Weekly product sync") : nil
                )
                .padding(.vertical, 4)
            }
        }
        .padding(AppTheme.Spacing.medium)
        let tree = AccessibilityAudit.host(rows, name: "sidebar-rows", width: 260, height: 600)
        for record in records {
            let expected = "\(record.displayName), \(record.state.localizedTitle(locale: AccessibilityAudit.english))"
            #expect(tree.elements.contains { $0.name == expected || $0.text == expected }, "row \(record.displayName)")
        }
        #expect(tree.images.isEmpty, "status glyphs are hidden; the state's words carry it")
        #expect(tree.first(role: "AXBusyIndicator", named: "Post-processing now, Done") != nil, "the post-processing row announces itself as busy")
        audit(
            tree,
            expecting: [
                .element(role: "AXTextField", name: "Recording Name"),
                .textContaining("Korean IT Meeting"),
            ],
            accepting: [
                Exception(kind: .elementWithoutRole, role: "AXUnknown", name: "Weekly product sync, Transcribing"),
                Exception(kind: .missingElement, role: "AXTextField", name: "Recording Name"),
                Exception(kind: .missingText, role: "AXStaticText", name: "Korean IT Meeting"),
            ]
        )

        // The shipped sidebar is a `List`: offscreen it exposes an outline
        // whose rows are ignored elements with no content, so the rows above
        // are the only way to read them. Recorded, not asserted around.
        let model = try AccessibilityAuditFixtures.model(records: records)
        #expect(model.records.count == records.count)
        let list = AccessibilityAudit.host(
            LibrarySidebar(model: model), name: "sidebar-list", width: 260, height: 600
        )
        #expect(list.elements.contains { $0.role == "AXOutline" })
        #expect(!list.elements.contains { $0.text == "Board review, Recorded" }, "List rows are not readable offscreen; the report says so")

        // The window: split group, sidebar outline, capture detail. The
        // toolbar buttons are window chrome and are not in the tree.
        let root = AccessibilityAudit.host(
            RootView(model: model), name: "root-window", width: 1_200, height: 800
        )
        #expect(root.elements.contains { $0.role == "AXSplitGroup" })
        #expect(root.contains(role: "AXButton", named: "Start Recording"))
        #expect(!root.contains(role: "AXButton", named: "Import Audio"), "the toolbar is not part of the offscreen tree; the report says so")
        audit(root, accepting: Self.captureExceptions)
    }

    // MARK: - Sheets

    /// The review sheet's title is a static text rather than a heading
    /// (report W-A11Y, sheets 1); the rename popover names its field only by
    /// its placeholder and prints the raw speaker ID in its sentence (sheets
    /// 2, 3); the glossary editor names its field only by its placeholder
    /// (sheets 4) and its entry list is a `List` the walk cannot read.
    @Test @MainActor
    func reviewSheets() throws {
        let meeting = AccessibilityAuditFixtures.meetingRun()
        let roster = SpeakerRoster(segments: meeting.run.transcript.segments)
        func name(_ raw: String) -> String {
            if let n = meeting.record.speakerNames[raw], !n.isEmpty { return n }
            return SpeakerRoster.fallbackName(for: raw, locale: AccessibilityAudit.english)
        }
        let unnamed = meeting.run.segments.first {
            !SpeakerRoster.isAttributed($0.segment.speaker) && $0.index > 2
        }!
        let wording = meeting.run.segments[meeting.wordingSegmentIndex]
        func sheet(_ item: TranscriptSegment, resolution: String?) -> SegmentReviewSheet {
            SegmentReviewSheet(
                item: item,
                target: TranscriptReviewTarget(item: item),
                displayedText: item.segment.text,
                speakerName: name,
                speakerColor: { roster.color(for: $0) },
                currentResolution: resolution,
                isTranslation: false,
                choose: { _ in },
                rename: {},
                cancel: {}
            )
        }
        let titleException = Exception(kind: .missingElement, role: "AXHeading", name: "Review This Segment")

        let speaker = AccessibilityAudit.host(sheet(unnamed, resolution: nil), name: "review-speaker", width: 640, height: 700)
        #expect(speaker.containsText(containing: "Jina, 53%, 3.2 sec, Speaker 1, 47%, 2.8 sec, No speaker held 60%"))
        #expect(speaker.contains(text: "Timeline coverage 93%."))
        #expect(speaker.contains(role: "AXButton", named: "Mark Reviewed"))
        #expect(speaker.contains(role: "AXButton", named: "Close"))
        #expect(!speaker.contains(role: "AXButton", named: "Rename Speaker"), "an unnamed segment offers no rename")
        audit(speaker, expecting: [.element(role: "AXHeading", name: "Review This Segment")], accepting: [titleException])

        let text = AccessibilityAudit.host(sheet(wording, resolution: wording.segment.text), name: "review-wording", width: 640, height: 700)
        let primary = text.buttons.first { $0.name.hasPrefix("Primary Model, ") }
        let alternative = text.buttons.first { $0.name.hasPrefix("Verification Model 1, ") }
        #expect(primary?.isSelected == true, "the chosen wording is announced as selected")
        #expect(alternative?.isSelected == false)
        #expect(!text.contains(role: "AXButton", named: "Mark Reviewed"), "a resolved segment offers no second mark")
        audit(text, expecting: [.element(role: "AXHeading", name: "Review This Segment")], accepting: [titleException])

        let popover = AccessibilityAudit.host(
            SpeakerRenamePopover(originalSpeaker: "0", name: .constant("Jina"), save: {}, cancel: {}),
            name: "rename-popover", width: 360, height: 240
        )
        #expect(popover.first(role: "AXTextField", named: "")?.value == "Jina")
        #expect(popover.contains(role: "AXButton", named: "Save"))
        audit(
            popover,
            expecting: [.noTextContaining("every 0 segment")],
            accepting: [
                Exception(kind: .textFieldNamedByPlaceholderOnly, role: "AXTextField", name: "Speaker name"),
                Exception(kind: .unexpectedText, role: "AXStaticText", name: "every 0 segment"),
            ]
        )

        let model = try AccessibilityAuditFixtures.model()
        let glossary = AccessibilityAudit.host(
            GlossaryEditor(model: model, profileID: .koreanITMeeting),
            name: "glossary-editor", width: 640, height: 600
        )
        #expect(glossary.first(role: "AXPopUpButton", named: "Category")?.value == "Terms")
        #expect(glossary.contains(role: "AXButton", named: "Add"))
        #expect(glossary.contains(role: "AXButton", named: "Save"))
        #expect(glossary.elements.contains { $0.role == "AXOutline" }, "the entry list is a List and is not readable offscreen")
        audit(glossary, accepting: [
            Exception(kind: .textFieldNamedByPlaceholderOnly, role: "AXTextField", name: "Add a name, term, or place"),
        ])
    }
}
