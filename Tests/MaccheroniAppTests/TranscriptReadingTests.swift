import AppKit
import AVFoundation
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import SwiftUI
import Testing
@testable import MaccheroniApp

/// The reading surface reworked in P5, tested against the shape of the real
/// 2026-09-01 meeting rather than a clean two-segment fixture: 44.4 % of
/// segments with no speaker and 77.4 % flagged. `TranscriptFixtures` builds
/// that shape synthetically so no private recording is needed here, and so the
/// offscreen render harness in P6 can build the same views from the same data.
struct TranscriptReadingTests {
    // MARK: Layers

    @Test
    func aSourceRunOffersTheRawLayerAndSaysWhyTheOthersAreNotThere() {
        let fixture = TranscriptFixtures.meetingShaped()
        let options = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )

        #expect(options.map(\.layer) == [.speakerLabelled, .corrected, .translated, .proposed])
        #expect(options[0].isAvailable)
        #expect(options[1].unavailability == .notProduced)
        #expect(options[2].unavailability == .notProduced)
        #expect(options[3].unavailability == .proposalNotYetProduced)
        #expect(
            TranscriptLayerCatalog.defaultLayer(run: fixture.run, record: fixture.record)
                == .speakerLabelled
        )
    }

    @Test
    func anAcceptedCorrectionOpensTheCorrectedLayerAndTheRawLayerKeepsTheRawText() {
        var fixture = TranscriptFixtures.meetingShaped()
        let index = 1
        fixture.record.conflictResolutions[index] = "Accepted wording"
        let item = fixture.run.segments[index]

        let options = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )

        #expect(options[0].isAvailable)
        #expect(options[1].isAvailable)
        #expect(
            TranscriptLayerCatalog.text(
                .speakerLabelled,
                for: item,
                run: fixture.run,
                record: fixture.record
            ) == item.segment.text
        )
        #expect(
            TranscriptLayerCatalog.text(
                .corrected,
                for: item,
                run: fixture.run,
                record: fixture.record
            ) == "Accepted wording"
        )
    }

    @Test
    func aTranslationKeepsTheRawLayerVisibleAndSaysTheSourceIsUnchangedOnDisk() {
        let fixture = TranscriptFixtures.translationShaped()
        let options = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )

        #expect(options[0].unavailability == .sourceTextNotLoadedWithTranslation)
        #expect(options[2].isAvailable)
        #expect(
            TranscriptLayerCatalog.defaultLayer(run: fixture.run, record: fixture.record)
                == .translated
        )
        let sentence = TranscriptLayerUnavailability
            .sourceTextNotLoadedWithTranslation
            .sentence(locale: Locale(identifier: "en"))
        #expect(sentence.contains("unchanged on disk"))
    }

    @Test
    func everyLayerHasATitleAndACopyHeaderIncludingTheOneWaitingOnItsProducer() {
        for layer in TranscriptDisplayLayer.allCases {
            let header = layer.copyHeader(locale: Locale(identifier: "en"))
            #expect(header.hasPrefix("Transcript layer: "))
            #expect(header.count > "Transcript layer: ".count)
        }
        #expect(TranscriptDisplayLayer.allCases.count == 4)
    }

    @Test @MainActor
    func copyingWhileTheRawLayerIsShownCopiesRawTextRatherThanTheCorrection() throws {
        var fixture = TranscriptFixtures.meetingShaped()
        fixture.record.conflictResolutions[1] = "Accepted wording"
        let raw = fixture.run.segments[1].segment.text
        let command = TranscriptCopyCommand(clipboard: RecordingClipboard())

        let rawPayload = try command.payload(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIDs: [],
            layer: .speakerLabelled
        )
        let correctedPayload = try command.payload(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIDs: [],
            layer: .corrected
        )

        #expect(rawPayload.text.contains(raw))
        #expect(!rawPayload.text.contains("Accepted wording"))
        #expect(correctedPayload.text.contains("Accepted wording"))
        #expect(rawPayload.confirmation.layer == .speakerLabelled)
        #expect(correctedPayload.confirmation.layer == .corrected)
    }

    /// The clipboard's header names a layer, and the rows under it have to be
    /// that layer's. Beside a translation the speaker-labelled layer is the
    /// source-language transcript the loaded run kept; the copy path used to
    /// enumerate `run.transcript`, so it said "Speaker-labelled" over
    /// translated rows.
    @Test @MainActor
    func speakerLabelledCopyBesideATranslationExportsTheSourceLanguageRows() throws {
        var fixture = TranscriptFixtures.translationShaped()
        let source = TranscriptFixtures.meetingShaped().run.transcript
        fixture.run.sourceTranscript = source
        let command = TranscriptCopyCommand(clipboard: RecordingClipboard())

        let raw = try command.payload(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIDs: [],
            layer: .speakerLabelled
        )
        let translated = try command.payload(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIDs: [],
            layer: .translated
        )

        #expect(raw.text.hasPrefix("Transcript layer: Speaker-labelled\n\n"))
        #expect(raw.text.contains(source.segments[0].text))
        #expect(!raw.text.contains("Translated line "))
        #expect(translated.text.hasPrefix("Transcript layer: Translated\n\n"))
        #expect(translated.text.contains("Translated line "))
        #expect(!translated.text.contains(source.segments[0].text))
        // The layer is a reading of what is loaded; copying it writes nothing.
        #expect(fixture.run.transcript == TranscriptFixtures.translationShaped().run.transcript)
    }

    /// D46 lets a non-acoustic proposal exist only because the acoustic
    /// candidates and their shares stay beside it and it is marked as a
    /// proposal. Text pasted into another document is where that condition
    /// would be dropped without anyone seeing it, so the clipboard carries the
    /// same evidence the screen does: the proposed speaker under the same
    /// label, or the decline and its reason, the candidates with their shares,
    /// and the disclosure that none of it was measured.
    @Test @MainActor
    func proposedLayerCopyCarriesTheProposalsDeclinesAndAcousticEvidence() throws {
        let english = Locale(identifier: "en")
        let fixture = TranscriptFixtures.meetingShaped()
        let document = TranscriptFixtures.proposalDocument(for: fixture.run)
        let proposed = try #require(document.proposals.first)
        let declined = try #require(
            document.declined.first { $0.cause == .noTopRankedCandidate }
        )

        let text = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: [],
            locale: english,
            layer: .proposed,
            proposal: document
        )

        // The disclosure, once, above the rows, with D49's coverage hole.
        #expect(text.hasPrefix("Transcript layer: Proposed\n"))
        #expect(text.contains(
            "\(document.proposals.count) proposed, \(document.declined.count) declined. Not acoustic evidence, and not measured."
        ))
        #expect(text.contains("of this recording produced no transcript"))

        // A proposal: the dashed label the row uses, then the speaker, under
        // the name this library gives that speaker rather than its raw ID.
        func name(_ speaker: String) -> String {
            fixture.record.speakerNames[speaker] ?? speaker
        }
        #expect(name(proposed.proposedSpeaker) == "Jina")
        #expect(text.contains("Proposed, not measured: \(name(proposed.proposedSpeaker))"))
        #expect(text.contains(proposed.reason))
        for candidate in proposed.acousticCandidates {
            #expect(text.contains(
                "\(name(candidate.speaker)) \(SegmentAttributionSummary.percent(candidate.share, locale: english))"
            ))
        }

        // A decline: what was not proposed, why, and the tie sentence, which
        // is the one the row prints only because the shares round to equal.
        #expect(text.contains("No speaker proposed"))
        #expect(text.contains(
            "The top speakers held the same time in this segment, to within a nanosecond."
        ))
        let modelAnswer = try #require(declined.modelAnswer)
        #expect(text.contains(modelAnswer.reason))

        // Nothing of the layer leaks into a layer the reader did not ask for.
        let raw = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: [],
            locale: english,
            layer: .speakerLabelled,
            proposal: document
        )
        #expect(!raw.contains("Proposed, not measured"))
        #expect(!raw.contains("Acoustic candidates"))
        #expect(!raw.contains("Not acoustic evidence, and not measured."))
    }

    // MARK: Speakers

    @Test
    func speakerColoursComeFromTheSortedRosterSoTwoSpeakersNeverCollide() {
        let roster = SpeakerRoster(segments: TranscriptFixtures.meetingShaped().run.transcript.segments)

        #expect(roster.index(of: "0") == 0)
        #expect(roster.index(of: "1") == 1)
        #expect(roster.index(of: SpeakerRoster.unnamed) == nil)
        #expect(
            AppTheme.Palette.speakerSwatch(atRosterIndex: 0)
                != AppTheme.Palette.speakerSwatch(atRosterIndex: 1)
        )
        #expect(roster.color(for: SpeakerRoster.unnamed) == AppTheme.Palette.unattributed)
    }

    // MARK: Tokens

    /// Every colour a reader reads meets 4.5:1 on both grounds, and the
    /// grounds are the ones the renders measured: white and #1E1E1E. This
    /// checks the token table's values; the rendered pixels are checked by the
    /// offscreen render pass, which is the check of record under D48.
    @Test
    func everyInkAndSpeakerColourMeetsTheTextFloorInBothAppearances() {
        let textSwatches = [
            AppTheme.Palette.inkSecondarySwatch,
            AppTheme.Palette.accentSwatch,
            AppTheme.Palette.openSwatch,
            AppTheme.Palette.errorSwatch,
        ] + AppTheme.Palette.speakerSwatches

        #expect(AppTheme.Palette.speakerSwatches.count == 7)
        for swatch in textSwatches {
            #expect(WCAG.contrast(swatch.light, against: "#FFFFFF") >= 4.5, "\(swatch.light) on white")
            #expect(WCAG.contrast(swatch.dark, against: "#1E1E1E") >= 4.5, "\(swatch.dark) on #1E1E1E")
        }
        // A speaker keeps its hue across appearances, and no two speakers
        // share a value in either.
        #expect(Set(AppTheme.Palette.speakerSwatches.map(\.light)).count == 7)
        #expect(Set(AppTheme.Palette.speakerSwatches.map(\.dark)).count == 7)
        // The eighth speaker wraps rather than crashing.
        #expect(AppTheme.Palette.speakerSwatch(atRosterIndex: 7) == AppTheme.Palette.speakerSwatch(atRosterIndex: 0))
    }

    @Test
    func theGutterLeavesTheTextColumnItsMeasure() {
        let gutter = AppTheme.Layout.gutterWidth

        #expect(Int(gutter) == 14 + 8 + 48 + 8 + 132 + 8 + 76 + 12)
        #expect(AppTheme.Layout.textWidth(rowWidth: 860 - 48) == 812 - gutter)
        #expect(AppTheme.Layout.textWidth(rowWidth: 100) == 0)
        #expect(AppTheme.Radius.control == 4)
        #expect(AppTheme.Radius.chip == 2)
    }

    @Test
    func theReviewChipIsNeutralUnlessAWordingMustBeChosen() {
        let pending = TranscriptReviewChip.State(needsReview: true, hasWordingToChoose: false)
        let wording = TranscriptReviewChip.State(needsReview: true, hasWordingToChoose: true)
        let resolved = TranscriptReviewChip.State(needsReview: false, hasWordingToChoose: true)

        #expect(!pending.isOpen)
        #expect(wording.isOpen)
        // A resolved segment is never open, whatever it once offered.
        #expect(!resolved.isOpen)
    }

    @Test
    func onTheRealShapeEveryChipIsNeutralBecauseNoWordingIsInPlay() {
        let fixture = TranscriptFixtures.meetingShaped()
        let flagged = fixture.run.segments.filter {
            TranscriptFlagVocabulary.marksUncertainty($0.segment.flags ?? [])
        }

        #expect(flagged.count == 192)
        let open = flagged.count { !TranscriptReviewTarget(item: $0).textAlternatives.isEmpty }
        #expect(open == 0)
    }

    /// The density the table was built for, measured by rendering one row the
    /// way the offscreen harness does. A one-line attributed segment is one
    /// line tall: 12 + 18 + 12 + 1. An unnamed one adds the figures line and
    /// the band under the speaker cell and measures 69 on the real run.
    @Test @MainActor
    func aOneLineSegmentIsOneLineTallAndAnUnnamedOneStaysCompact() {
        let fixture = TranscriptFixtures.meetingShaped()
        let roster = SpeakerRoster(segments: fixture.run.transcript.segments)
        let rowWidth: CGFloat = 812
        func height(_ item: TranscriptSegment, isFocused: Bool = false) -> CGFloat {
            let attribution = SegmentAttributionSummary(item: item)
            let row = TranscriptSegmentRow(
                item: item,
                attribution: attribution,
                proposal: nil,
                displaySpeaker: SpeakerRoster.fallbackName(for: item.segment.speaker, locale: Locale(identifier: "en")),
                speakerName: { SpeakerRoster.fallbackName(for: $0, locale: Locale(identifier: "en")) },
                speakerColor: { roster.color(for: $0) },
                text: "One line.",
                reviewState: TranscriptReviewChip.State(needsReview: true, hasWordingToChoose: false),
                isFocused: isFocused,
                isPlaying: false,
                isSelected: false,
                isLast: false,
                play: {},
                select: {},
                rename: {},
                review: {}
            )
            let renderer = ImageRenderer(
                content: row.frame(width: rowWidth).environment(\.locale, Locale(identifier: "en"))
            )
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(width: rowWidth, height: nil)
            return CGFloat(renderer.cgImage?.height ?? 0)
        }
        let attributed = try! #require(fixture.run.segments.first { SpeakerRoster.isAttributed($0.segment.speaker) })
        let unnamed = try! #require(fixture.run.segments.first { !SpeakerRoster.isAttributed($0.segment.speaker) })

        let one = height(attributed)
        let evidence = height(unnamed)
        #expect(one > 0)
        #expect(one <= 44, "attributed one-line row \(one)")
        #expect(evidence <= 70, "unnamed one-line row \(evidence)")
        // Focus adds the reason sentence under the text and nothing else —
        // no box, no padding — so it never shrinks the row and, on a one-line
        // segment whose gutter is already the taller column, does not grow it.
        #expect(height(unnamed, isFocused: true) >= evidence)
        #expect(height(unnamed, isFocused: true) <= evidence + 20)
    }

    @Test
    func neitherRefusedNorPendingAttributionReachesTheReadingSurfaceAsARawToken() {
        #expect(!SpeakerRoster.isAttributed(SpeakerRoster.unnamed))
        #expect(!SpeakerRoster.isAttributed(SpeakerRoster.unattributed))
        #expect(!SpeakerRoster.isAttributed(""))
        #expect(SpeakerRoster.isAttributed("0"))
        #expect(SpeakerRoster.fallbackName(for: SpeakerRoster.unnamed) != "UNKNOWN")
        #expect(SpeakerRoster.fallbackName(for: SpeakerRoster.unattributed) != "UNASSIGNED")
        #expect(SpeakerRoster.fallbackName(for: "0", locale: Locale(identifier: "en")) == "Speaker 0")
    }

    @Test
    func anUnnamedSegmentCarriesItsCandidateSharesAndOneSentencePerCollapseSite() {
        let english = Locale(identifier: "en")
        let measured = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: TranscriptFixtures.attribution(
                outcome: .noDominantSpeaker,
                candidates: [("0", 30.546, 0.5383978144002827), ("1", 26.189, 0.4616021855997173)],
                coverage: 0.9737953599048194
            )
        )

        #expect(!measured.isAttributed)
        #expect(measured.candidates.count == 2)
        #expect(SegmentAttributionSummary.percent(measured.candidates[0].share, locale: english) == "54%")
        #expect(SegmentAttributionSummary.overlap(30.546, locale: english).contains("30.5"))
        let dominant = try! #require(measured.reason(locale: english))
        #expect(dominant.contains("60%"))

        let coverage = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: TranscriptFixtures.attribution(
                outcome: .coverageBelowThreshold,
                candidates: [("0", 0.4, 1.0)],
                coverage: 0.31
            )
        ).reason(locale: english)
        let none = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: TranscriptFixtures.attribution(
                outcome: .noOverlappingTurn,
                candidates: [],
                coverage: 0
            )
        ).reason(locale: english)
        let undisclosed = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: nil
        ).reason(locale: english)
        let notLoaded = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: nil,
            evidenceIsLoaded: false
        ).reason(locale: english)

        #expect(coverage != nil)
        #expect(coverage != dominant)
        #expect(none != nil)
        #expect(none != coverage)
        #expect(undisclosed != nil)
        // Evidence that was never recorded and evidence that is not loaded
        // beside a translation must not read the same.
        #expect(notLoaded != nil)
        #expect(notLoaded != undisclosed)
        #expect(Set([dominant, coverage, none, undisclosed, notLoaded]).count == 5)
    }

    @Test
    func anAttributedSegmentShowsAShareOnlyWhenSomebodyElseWasAlsoTalking() {
        let alone = SegmentAttributionSummary(
            speaker: "0",
            attribution: TranscriptFixtures.attribution(
                outcome: .attributed,
                candidates: [("0", 4.0, 1.0)],
                coverage: 0.9
            )
        )
        let contested = SegmentAttributionSummary(
            speaker: "0",
            attribution: TranscriptFixtures.attribution(
                outcome: .attributed,
                candidates: [("0", 4.0, 0.72), ("1", 1.6, 0.28)],
                coverage: 0.95
            )
        )

        #expect(alone.contestedTopShare == nil)
        #expect(contested.contestedTopShare == 0.72)
        #expect(contested.reason() == nil)
    }

    // MARK: Reviewing

    @Test
    func aSpeakerConflictNeverOffersASpeakerIDAsReplacementTranscriptText() {
        let attribution = TranscriptFixtures.attribution(
            outcome: .noDominantSpeaker,
            candidates: [("0", 17.3, 0.573), ("1", 12.9, 0.427)],
            coverage: 0.97
        )
        let item = TranscriptSegment(
            id: TranscriptSegmentID(runID: "run", index: 4),
            index: 4,
            segment: Segment(
                speaker: SpeakerRoster.unnamed,
                startS: 10,
                endS: 30.3,
                text: "Original wording",
                flags: ["conflict", "uncertain"]
            ),
            conflict: MergeConflict(
                segmentIndex: 4,
                kind: .ambiguousSpeaker,
                candidates: ["0", "1"],
                reason: "No speaker was dominant.",
                speakerAttribution: attribution
            )
        )

        let target = TranscriptReviewTarget(item: item)

        #expect(target.textAlternatives.isEmpty)
        #expect(target.speakerCandidates == ["0", "1"])
        #expect(target.speakerEvidence == attribution)
    }

    @Test
    func aPostprocessCandidateMergedOntoASpeakerConflictStaysTheOnlyTextOffered() {
        let attribution = TranscriptFixtures.attribution(
            outcome: .attributed,
            candidates: [("0", 3.0, 0.7), ("1", 1.3, 0.3)],
            coverage: 0.9
        )
        let item = TranscriptSegment(
            id: TranscriptSegmentID(runID: "run", index: 7),
            index: 7,
            segment: Segment(
                speaker: "0",
                startS: 1,
                endS: 5,
                text: "Original wording",
                flags: ["conflict", "uncertain"]
            ),
            // The library appends post-processing text candidates onto an
            // existing speaker conflict; P1 made the speaker IDs its prefix.
            conflict: MergeConflict(
                segmentIndex: 7,
                kind: .overlappingSpeech,
                candidates: ["0", "1", "Original wording", "Suggested wording"],
                reason: "Speakers overlapped. The comparison backend disagreed.",
                speakerAttribution: attribution
            )
        )

        let target = TranscriptReviewTarget(item: item)

        #expect(target.textAlternatives == ["Suggested wording"])
        #expect(target.speakerCandidates == ["0", "1"])
    }

    @Test
    func aSpeakerConflictWrittenBeforeTheDisclosureStillOffersNoTextAtAll() {
        let item = TranscriptSegment(
            id: TranscriptSegmentID(runID: "run", index: 2),
            index: 2,
            segment: Segment(
                speaker: SpeakerRoster.unnamed,
                startS: 0,
                endS: 4,
                text: "Original wording",
                flags: ["conflict", "uncertain"]
            ),
            conflict: MergeConflict(
                segmentIndex: 2,
                kind: .ambiguousSpeaker,
                candidates: ["0", "1"],
                reason: "No speaker was dominant."
            )
        )

        let target = TranscriptReviewTarget(item: item)

        #expect(target.textAlternatives.isEmpty)
        #expect(target.speakerCandidates == ["0", "1"])
        #expect(target.speakerEvidence == nil)
    }

    @Test
    func atextConflictStillOffersItsAlternativesAndDropsTheCurrentText() {
        let item = TranscriptSegment(
            id: TranscriptSegmentID(runID: "run", index: 3),
            index: 3,
            segment: Segment(
                speaker: "0",
                startS: 0,
                endS: 4,
                text: "Original wording",
                flags: ["conflict"]
            ),
            conflict: MergeConflict(
                segmentIndex: 3,
                kind: .asrDisagreement,
                candidates: ["Original wording", "Alternative wording"],
                reason: "The comparison backend disagreed."
            )
        )

        let target = TranscriptReviewTarget(item: item)

        #expect(target.textAlternatives == ["Alternative wording"])
        #expect(target.speakerCandidates.isEmpty)
    }

    @Test
    func knownFlagTokensNeverReachTheReadingSurfaceAndUnknownOnesGoToTheDetail() {
        let flags = ["conflict", "uncertain", "backend_speaker_evidence", "clipped_edge"]

        #expect(TranscriptFlagVocabulary.marksUncertainty(flags))
        #expect(TranscriptFlagVocabulary.hasBackendSpeakerEvidence(flags))
        #expect(TranscriptFlagVocabulary.otherMarkers(flags) == ["clipped_edge"])
        #expect(TranscriptFlagVocabulary.otherMarkers(["backend_speaker_evidence"]).isEmpty)
        #expect(!TranscriptFlagVocabulary.marksUncertainty(["backend_speaker_evidence"]))
    }

    @Test
    func theReviewNavigatorWalksOnlyUnresolvedSegmentsAndWrapsAtBothEnds() {
        let queue = [3, 11, 42]

        #expect(TranscriptReviewQueue.step(from: nil, in: queue, direction: 1) == 3)
        #expect(TranscriptReviewQueue.step(from: nil, in: queue, direction: -1) == 42)
        #expect(TranscriptReviewQueue.step(from: 3, in: queue, direction: 1) == 11)
        #expect(TranscriptReviewQueue.step(from: 42, in: queue, direction: 1) == 3)
        #expect(TranscriptReviewQueue.step(from: 3, in: queue, direction: -1) == 42)
        // A focus that is not in the queue any more — the reader resolved it —
        // restarts rather than dead-ends.
        #expect(TranscriptReviewQueue.step(from: 7, in: queue, direction: 1) == 3)
        #expect(TranscriptReviewQueue.step(from: 3, in: [], direction: 1) == nil)
    }

    // MARK: Search

    @Test
    func searchMatchesTranscriptTextAndSpeakerNameWithoutCaseOrDiacritics() {
        let fixture = TranscriptFixtures.meetingShaped()
        let record = fixture.record
        let named: (TranscriptSegment) -> String = { item in
            record.speakerNames[item.segment.speaker] ?? item.segment.speaker
        }

        let byText = TranscriptSearch.filter(
            fixture.run.segments,
            query: "SEGMENT 000012",
            text: { $0.segment.text },
            speaker: named
        )
        let bySpeaker = TranscriptSearch.filter(
            fixture.run.segments,
            query: "jina",
            text: { $0.segment.text },
            speaker: named
        )
        let empty = TranscriptSearch.filter(
            fixture.run.segments,
            query: "   ",
            text: { $0.segment.text },
            speaker: named
        )

        #expect(byText.count == 1)
        #expect(byText.first?.index == 12)
        #expect(bySpeaker.count == fixture.run.transcript.segments.count { $0.speaker == "0" })
        #expect(empty.count == fixture.run.segments.count)
    }

    // MARK: Playback

    @Test
    func thePlayheadNamesTheSegmentItIsInsideAndNothingOnceItLeaves() {
        let fixture = TranscriptFixtures.meetingShaped()
        let segments = fixture.run.segments

        #expect(TranscriptPlaybackTimeline.segmentIndex(at: 0, in: segments) == 0)
        #expect(TranscriptPlaybackTimeline.segmentIndex(at: 25.1, in: segments) == 5)
        #expect(TranscriptPlaybackTimeline.segmentIndex(at: -1, in: segments) == nil)
        #expect(TranscriptPlaybackTimeline.segmentIndex(at: 1_000_000, in: segments) == nil)
    }

    @Test
    func theClockStaysReadableAcrossAMeetingLengthRecording() {
        #expect(TranscriptPlaybackTimeline.clock(0) == "00:00")
        #expect(TranscriptPlaybackTimeline.clock(-4) == "00:00")
        #expect(TranscriptPlaybackTimeline.clock(1_243.08) == "20:43")
        #expect(TranscriptPlaybackTimeline.clock(3_661) == "1:01:01")
    }

    @Test @MainActor
    func playbackResolvesTheRecordingReadOnlyAndReportsWhenItIsGone() {
        var fixture = TranscriptFixtures.meetingShaped()
        fixture.record.sourceURL = URL(fileURLWithPath: "/nonexistent/meeting.wav")

        #expect(TranscriptPlaybackController.sourceURL(for: fixture.record) == nil)

        let controller = TranscriptPlaybackController()
        controller.play(from: 12, record: fixture.record)

        #expect(!controller.isPlaying)
        #expect(controller.errorMessage != nil)
        #expect(controller.playingSegmentIndex(in: fixture.run.segments) == nil)
    }

    /// The controller outlives a selection change whenever SwiftUI keeps the
    /// transcript view's identity, and it used to return the player it already
    /// had for whatever record was asked about. Run A's audio then played,
    /// seeked and resumed under run B's transcript.
    ///
    /// The player is injected so this is settled without audio, a window
    /// server, or a decodable file: what is asserted is which URL each player
    /// was built from and when the old one was let go.
    @Test @MainActor
    func selectingAnotherRecordBuildsThatRecordsPlayerInsteadOfReusingTheOldOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniPlaybackTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func recording(_ name: String) throws -> URL {
            let url = root.appendingPathComponent("\(name).wav")
            try Data("not audio, and never decoded".utf8).write(to: url)
            return url
        }

        var first = TranscriptFixtures.meetingShaped()
        first.record.sourceURL = try recording("a")
        var second = TranscriptFixtures.meetingShaped()
        second.record.id = UUID()
        second.record.sourceURL = try recording("b")

        var built: [URL] = []
        let controller = TranscriptPlaybackController { url in
            built.append(url)
            return AVPlayer()
        }

        controller.play(from: 12, record: first.record)
        #expect(built == [first.record.sourceURL])
        #expect(controller.isPlaying)
        #expect(controller.preparedRecordID == first.record.id)
        #expect(controller.isPrepared(for: first.record))
        #expect(!controller.isPrepared(for: second.record))

        // Seeking while the other record is selected must not drive the first
        // record's player.
        controller.seek(to: 30, record: second.record)
        #expect(built == [first.record.sourceURL, second.record.sourceURL])
        #expect(controller.preparedRecordID == second.record.id)
        #expect(controller.positionS == 30)

        // Resuming is the same question, and a pause press while another
        // record's audio is playing builds this record's player rather than
        // pausing the other one.
        controller.togglePlayPause(record: second.record)
        #expect(controller.isPlaying)
        #expect(built.count == 2)
        controller.togglePlayPause(record: second.record)
        #expect(!controller.isPlaying)

        // A record whose file moved is not the record the player was built
        // for, even under the same identity.
        var moved = second
        moved.record.sourceURL = try recording("c")
        controller.play(from: 1, record: moved.record)
        #expect(built.count == 3)
        #expect(controller.preparedRecordID == moved.record.id)

        controller.stop()
        #expect(controller.preparedRecordID == nil)
        #expect(!controller.isPrepared(for: moved.record))
    }

    // MARK: Inspector

    @Test
    func theInspectorWordsEveryStoredIdentifierItPutsOnItsSummary() {
        let english = Locale(identifier: "en")

        #expect(String(localized: RunInspectorWording.status(.partial, locale: english)) == "Partial")
        #expect(String(localized: RunInspectorWording.status(.succeeded, locale: english)) == "Completed")
        #expect(String(localized: RunInspectorWording.role(.asr, locale: english)) == "Speech Recognition")
        #expect(String(localized: RunInspectorWording.role(.diarization, locale: english)) == "Speaker Separation")
        #expect(
            String(localized: RunInspectorWording.injection(.freeTextContext, locale: english))
                != GlossaryInjectionMode.freeTextContext.rawValue
        )
        #expect(
            String(localized: RunInspectorWording.glossarySemantics(.sourceRun, locale: english))
                != DerivedGlossarySemantics.sourceRun.rawValue
        )
    }

    @Test
    func coverageReadsAsTimeRatherThanAsAChunkRatioAndNamesTheLoss() {
        let english = Locale(identifier: "en")
        let partial = RunInspectorWording.coverage(
            Coverage(
                inputDurationS: 1_243.08,
                processedDurationS: 1_212.52,
                truncated: true,
                strategy: .full,
                chunksPlanned: 11,
                chunksCompleted: 10
            ),
            locale: english
        )
        let complete = RunInspectorWording.coverage(
            Coverage(
                inputDurationS: 1_243.08,
                processedDurationS: 1_243.08,
                truncated: false,
                strategy: .full,
                chunksPlanned: 11,
                chunksCompleted: 11
            ),
            locale: english
        )

        #expect(partial.contains("20:12"))
        #expect(partial.contains("20:43"))
        #expect(partial.contains("97.5%"))
        #expect(complete == "20:43")
    }

    @Test
    func theSegmentSummaryCountsWhatHasNoSpeakerRatherThanHidingIt() {
        let fixture = TranscriptFixtures.meetingShaped()
        let english = Locale(identifier: "en")

        let summary = RunInspectorWording.segments(
            fixture.run.transcript.segments,
            locale: english
        )

        #expect(summary.contains("248"))
        #expect(summary.contains("110"))
        #expect(RunInspectorWording.segments([
            Segment(speaker: "0", startS: 0, endS: 1, text: "a"),
        ], locale: english) == "1")
    }



    // MARK: The reason sentence stays off the rows

    @Test @MainActor
    func aMissingOutcomeNeverPrintsItsReasonOnEveryRow() {
        // The regression this pins: `nil != .noDominantSpeaker` is true, so a
        // predicate written that way put the sentence back under all 110
        // unnamed rows of a translation — the exact wall the row design was
        // reworked to remove.
        let notLoaded = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: nil,
            evidenceIsLoaded: false
        )
        let noRecord = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: nil
        )

        #expect(!SpeakerEvidenceBlock.showsReason(for: notLoaded, isFocused: false))
        #expect(!SpeakerEvidenceBlock.showsReason(for: noRecord, isFocused: false))
        // The reader still gets it on the segment they are working on.
        #expect(SpeakerEvidenceBlock.showsReason(for: notLoaded, isFocused: true))
        #expect(SpeakerEvidenceBlock.showsReason(for: noRecord, isFocused: true))
    }

    @Test @MainActor
    func theCommonOutcomeStaysOffTheRowsAndTheRareOnesStayOnThem() {
        func summary(_ outcome: SpeakerAttributionOutcome) -> SegmentAttributionSummary {
            SegmentAttributionSummary(
                speaker: SpeakerRoster.unnamed,
                attribution: TranscriptFixtures.attribution(
                    outcome: outcome,
                    candidates: [("0", 1, 0.55), ("1", 1, 0.45)],
                    coverage: 0.9
                )
            )
        }

        #expect(!SpeakerEvidenceBlock.showsReason(for: summary(.noDominantSpeaker), isFocused: false))
        #expect(SpeakerEvidenceBlock.showsReason(for: summary(.noOverlappingTurn), isFocused: false))
        #expect(SpeakerEvidenceBlock.showsReason(for: summary(.coverageBelowThreshold), isFocused: false))
        #expect(SpeakerEvidenceBlock.showsReason(for: summary(.noDominantSpeaker), isFocused: true))
    }

    @Test
    func aTranslationSaysOnceWhyItsRowsCarryNoEvidence() {
        let english = Locale(identifier: "en")
        let notLoaded = TranscriptMissingEvidence.notLoadedWithTranslation.sentence(locale: english)
        let noRecord = TranscriptMissingEvidence.someSegmentsHaveNoRecord.sentence(locale: english)

        #expect(notLoaded.contains("The source run still has it"))
        #expect(notLoaded != noRecord)
        // The header sentence and the focused row's sentence are the same fact,
        // so they must not contradict each other.
        let rowSentence = SegmentAttributionSummary(
            speaker: SpeakerRoster.unnamed,
            attribution: nil,
            evidenceIsLoaded: false
        ).reason(locale: english)
        #expect(rowSentence == notLoaded)
    }

    // MARK: The proposal layer (D46)

    @Test
    func theProposalLayerOpensOnlyWhenAProposalExistsAndNeverBecomesTheDefault() {
        let fixture = TranscriptFixtures.meetingShaped()
        let document = TranscriptFixtures.proposalDocument(for: fixture.run)

        let without = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )
        let with = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record,
            proposal: document
        )

        #expect(without[3].unavailability == .proposalNotYetProduced)
        #expect(with[3].isAvailable)
        // D46 does not settle whether a non-acoustic proposal may ever be the
        // layer a reader is handed, and this surface must not settle it either.
        #expect(
            TranscriptLayerCatalog.defaultLayer(
                run: fixture.run,
                record: fixture.record,
                proposal: document
            ) == .speakerLabelled
        )
    }

    @Test
    func aSpeakerProposalResultIsReadThroughItsKindRatherThanItsMode() {
        let fixture = TranscriptFixtures.proposalResultShaped()

        // The manifest keeps `mode == .correction` for a structural reason, so
        // reading `mode` would show this run as a corrected transcript and
        // offer a Corrected layer whose text was never corrected.
        #expect(fixture.run.resultOperation?.mode == .correction)
        #expect(fixture.run.resultOperation?.kind == .speakerProposal)
        #expect(TranscriptDisplayLayer.displayed(in: fixture.run) == .speakerLabelled)

        let options = TranscriptLayerCatalog.options(
            run: fixture.run,
            record: fixture.record
        )
        #expect(options[0].isAvailable)
        #expect(options[1].unavailability == .notProduced)
    }

    @Test
    func everyUnattributedSegmentIsEitherProposedForOrDeclinedWithAReason() {
        let fixture = TranscriptFixtures.meetingShaped()
        let layer = TranscriptProposalLayer(
            document: TranscriptFixtures.proposalDocument(for: fixture.run)
        )
        let unattributed = fixture.run.segments.filter {
            !SpeakerRoster.isAttributed($0.segment.speaker)
        }

        #expect(unattributed.count == 110)
        #expect(layer.examinedSegmentCount == 110)
        #expect(layer.proposedCount == 98)
        #expect(layer.declinedCount == 12)

        for item in unattributed {
            let proposal = try! #require(layer.proposal(at: item.index))
            #expect(!proposal.reason.isEmpty, "segment \(item.index)")
            if let speaker = proposal.proposedSpeaker {
                // The proposal never invents a speaker, and when the acoustics
                // named candidates it stays inside them.
                let candidates = layer.inlineEvidence(at: item.index)?.candidates ?? []
                if !candidates.isEmpty {
                    #expect(candidates.map(\.speaker).contains(speaker), "segment \(item.index)")
                }
            }
        }
        // An attributed segment is never touched by this layer.
        let attributed = try! #require(fixture.run.segments.first {
            SpeakerRoster.isAttributed($0.segment.speaker)
        })
        #expect(layer.proposal(at: attributed.index) == nil)
    }

    @Test
    func aDeclinedSegmentCannotBeRenderedAsAnAssignment() {
        let declined = SegmentSpeakerProposal.declined(
            SegmentSpeakerProposal.Decline(reason: "Too little context.")
        )
        let proposed = SegmentSpeakerProposal.proposed(
            speaker: "0",
            reason: "Answers the question at 00:31."
        )

        #expect(declined.proposedSpeaker == nil)
        #expect(proposed.proposedSpeaker == "0")
        #expect(declined.reason == "Too little context.")
    }

    /// P9 found that the view model flattened a decline to its sentence, which
    /// dropped the three fields D50's constraint writes so a later measurement
    /// can tell what the constraint did from what the model did. Each is named
    /// individually, because whole-value equality would still hold if a later
    /// change dropped one on both sides.
    @Test
    func aDeclineCarriesItsCauseTopRankedCandidateAndModelAnswerThroughToTheRow() throws {
        let fixture = TranscriptFixtures.meetingShaped()
        let document = TranscriptFixtures.proposalDocument(for: fixture.run)
        let layer = TranscriptProposalLayer(document: document)

        for record in document.declined {
            let decline = try #require(
                layer.proposal(at: record.segmentIndex)?.decline,
                "segment \(record.segmentIndex)"
            )
            #expect(decline.reason == record.reason)
            #expect(decline.cause == record.cause)
            #expect(decline.topRankedCandidate == record.topRankedCandidate)
            #expect(decline.modelAnswer == record.modelAnswer)
        }

        // Not vacuous: the fixture carries all three causes the real D50 run
        // produced, a top-ranked candidate on the model's own decline, and a kept model
        // answer on the two the constraint decided.
        let causes = Set(document.declined.compactMap(\.cause))
        #expect(causes == [.modelDeclined, .noTopRankedCandidate, .noAcousticCandidates])
        #expect(document.declined.contains { $0.topRankedCandidate != nil })
        #expect(document.declined.contains { $0.modelAnswer != nil })
    }

    /// The cause reaches the reader as a sentence this app owns, in the
    /// reader's own language, and only for the two causes the constraint
    /// decided. No new key was minted for it: both sentences already existed
    /// for the acoustic outcome that produced the decline.
    @Test
    func aDeclinesCauseIsSaidInTheReadersOwnLanguage() {
        let english = Locale(identifier: "en")
        let korean = Locale(identifier: "ko")
        func decline(
            _ cause: SpeakerProposalDeclineCause?,
            answer: SpeakerProposalDecision? = nil
        ) -> SegmentSpeakerProposal.Decline {
            SegmentSpeakerProposal.Decline(
                reason: "Declined under confirm-or-decline: … The model also declined: it is unclear.",
                cause: cause,
                topRankedCandidate: nil,
                modelAnswer: answer
            )
        }
        let modelDecline = SpeakerProposalDecision(
            segmentIndex: 7,
            proposedSpeaker: "",
            disposition: .decline,
            reason: "it is unclear."
        )

        #expect(
            decline(.noAcousticCandidates, answer: modelDecline)
                .sentences(locale: english)
                == [
                    "No speaker was active on the speaker timeline during this segment.",
                    "it is unclear.",
                ]
        )
        #expect(
            decline(.noTopRankedCandidate, answer: modelDecline)
                .sentences(locale: english)
                == [
                    "No speaker held enough of this segment's speech, so none was named.",
                    "it is unclear.",
                ]
        )
        // A model decline is the model's own reasoning; the app has nothing to
        // add and says nothing, which is what tells the two apart on the row.
        #expect(decline(.modelDeclined).causeSentence(locale: english) == nil)
        #expect(decline(.noDecision).causeSentence(locale: english) == nil)

        let koreanSentences = decline(.noTopRankedCandidate, answer: modelDecline)
            .sentences(locale: korean)
        #expect(koreanSentences[0] == "이 구간 발화를 충분히 차지한 화자가 없어 화자를 정하지 않았습니다.")
        #expect(koreanSentences[1] == "it is unclear.")
    }

    /// The case D50 exists to preserve. When the model named somebody the
    /// constraint refused, the artifact's own sentence names both that speaker
    /// and the top-ranked candidate, so it is printed whole rather than replaced by
    /// a sentence that would mention neither.
    @Test
    func aPreservedDisagreementKeepsTheSentenceThatNamesBothAnswers() {
        let english = Locale(identifier: "en")
        let overturn = "Declined under confirm-or-decline: the language evidence pointed to speaker 1, but the top-ranked candidate is speaker 0 at 56% of the overlapped speech, and a proposal may only confirm that candidate. The model's reason: 1 answers the question."
        let disagreed = SegmentSpeakerProposal.Decline(
            reason: overturn,
            cause: .modelDisagreedWithTopRankedCandidate,
            topRankedCandidate: "0",
            modelAnswer: SpeakerProposalDecision(
                segmentIndex: 12,
                proposedSpeaker: "1",
                disposition: .propose,
                reason: "1 answers the question."
            )
        )
        #expect(disagreed.sentences(locale: english) == [overturn])
        #expect(disagreed.sentences(locale: english, omittingCause: true) == [overturn])

        // The same holds when the constraint declined for a structural reason
        // and the model had still named somebody: replacing the sentence would
        // erase the name the model proposed.
        let proposedOverTie = SegmentSpeakerProposal.Decline(
            reason: "Declined under confirm-or-decline: the acoustic candidates 0 and 1 hold equal overlap, so there is no top-ranked candidate to confirm. The model proposed speaker 1: 1 is mid-answer.",
            cause: .noTopRankedCandidate,
            topRankedCandidate: nil,
            modelAnswer: SpeakerProposalDecision(
                segmentIndex: 13,
                proposedSpeaker: "1",
                disposition: .propose,
                reason: "1 is mid-answer."
            )
        )
        #expect(proposedOverTie.sentences(locale: english) == [proposedOverTie.reason])
    }

    /// P11b left a tie legible only from two printed percentages, and rounding
    /// is exactly what hides one. Both records below are real rows of the D50
    /// set on the 2026-09-01 run: segment 38 is a true tie the constraint
    /// declined, segment 7 is the model's own decline 73 milliseconds off
    /// level. They print the same two percentages and must not print the same
    /// sentence.
    @Test
    func anExactTieSaysSoWhereANearTieDoesNot() {
        let english = Locale(identifier: "en")
        let korean = Locale(identifier: "ko")
        let tieSentence = "The top speakers held the same time in this segment, to within a nanosecond."
        let tie = SegmentSpeakerProposal.Decline(
            reason: "Declined under confirm-or-decline: the acoustic candidates 0 and 1 hold equal overlap, so there is no top-ranked candidate to confirm. The model also declined: 공동 발화가 동률이라 선두 화자가 없습니다.",
            cause: .noTopRankedCandidate,
            topRankedCandidate: nil,
            modelAnswer: SpeakerProposalDecision(
                segmentIndex: 38,
                proposedSpeaker: "",
                disposition: .decline,
                reason: "공동 발화가 동률이라 선두 화자가 없습니다."
            ),
            candidates: [
                SpeakerCandidateEvidence(speaker: "0", overlapS: 3.800_000_000_000_011_4, share: 0.5),
                SpeakerCandidateEvidence(speaker: "1", overlapS: 3.800_000_000_000_011_4, share: 0.5),
            ]
        )
        let nearTie = SegmentSpeakerProposal.Decline(
            reason: "내용만으로는 발화자를 0으로 확인할 수 없습니다.",
            cause: .modelDeclined,
            topRankedCandidate: "0",
            candidates: [
                SpeakerCandidateEvidence(
                    speaker: "0",
                    overlapS: 11.903_999_999_999_996,
                    share: 0.501_537_813_355_803_5
                ),
                SpeakerCandidateEvidence(
                    speaker: "1",
                    overlapS: 11.831_000_000_000_003,
                    share: 0.498_462_186_644_196_5
                ),
            ]
        )

        // The premise: what the row prints for the two is identical.
        #expect(
            SegmentAttributionSummary.percent(tie.candidates[0].share, locale: english)
                == SegmentAttributionSummary.percent(
                    nearTie.candidates[0].share,
                    locale: english
                )
        )
        #expect(tie.holdsEqualOverlap)
        #expect(!nearTie.holdsEqualOverlap)

        #expect(
            tie.sentences(locale: english)
                == [tieSentence, "공동 발화가 동률이라 선두 화자가 없습니다."]
        )
        #expect(
            nearTie.sentences(locale: english)
                == ["내용만으로는 발화자를 0으로 확인할 수 없습니다."]
        )
        #expect(!nearTie.sentences(locale: english).contains(tieSentence))
        #expect(
            tie.sentences(locale: korean).first
                == "이 구간에서 상위 화자들이 1나노초 차이 이내로 같은 시간을 차지했습니다."
        )

        // The tie sentence never stands down for the acoustic reason. That
        // reason names the run's dominant-share bar and is true of all 110
        // unattributed segments, so it cannot carry the tie.
        #expect(
            tie.sentences(locale: english, omittingCause: true)
                == [tieSentence, "공동 발화가 동률이라 선두 화자가 없습니다."]
        )
        #expect(
            tieSentence != SegmentAttributionSummary(
                speaker: SpeakerRoster.unnamed,
                outcome: .noDominantSpeaker,
                candidates: [],
                timelineCoverage: 1,
                thresholds: SpeakerAttributionThresholds(
                    dominantSpeakerShare: 0.60,
                    minimumTimelineCoverage: 0.50
                )
            ).reason(locale: english)
        )
    }

    /// The row said "exactly equal" while the comparison behind it admits a
    /// tie inside `topRankedMarginS`. The sentence is the half that moved:
    /// making the comparison exact instead would have let a row deny a tie the
    /// artifact recorded, because the artifact's own `cause` is decided by
    /// `topRankedCandidate(among:)` and by nothing else.
    ///
    /// The margin is a nanosecond and the sentence says so, so this pins the
    /// two together: a change to the constant fails here rather than leaving a
    /// sentence that quietly overstates what was measured.
    @Test
    func theTieSentenceNamesTheMargin() {
        let english = Locale(identifier: "en")
        #expect(SpeakerProposalConstraint.topRankedMarginS == 1e-9)

        // Not exactly equal, and inside the margin: the artifact records no
        // top-ranked candidate here, so the row has to agree with it.
        let insideTheMargin = SegmentSpeakerProposal.Decline(
            reason: "Declined under confirm-or-decline: the acoustic candidates 0 and 1 hold equal overlap, so there is no top-ranked candidate to confirm.",
            cause: .noTopRankedCandidate,
            candidates: [
                SpeakerCandidateEvidence(speaker: "0", overlapS: 3.8, share: 0.5),
                SpeakerCandidateEvidence(speaker: "1", overlapS: 3.8 - 5e-10, share: 0.5),
            ]
        )
        // Outside it by a hundredth of a second: a top-ranked candidate
        // exists, and this sentence must not appear.
        let outsideTheMargin = SegmentSpeakerProposal.Decline(
            reason: "Declined under confirm-or-decline.",
            cause: .noTopRankedCandidate,
            candidates: [
                SpeakerCandidateEvidence(speaker: "0", overlapS: 3.8, share: 0.5),
                SpeakerCandidateEvidence(speaker: "1", overlapS: 3.79, share: 0.5),
            ]
        )

        #expect(insideTheMargin.candidates[0].overlapS != insideTheMargin.candidates[1].overlapS)
        #expect(insideTheMargin.holdsEqualOverlap)
        #expect(!outsideTheMargin.holdsEqualOverlap)
        #expect(
            insideTheMargin.causeSentence(locale: english)
                == "The top speakers held the same time in this segment, to within a nanosecond."
        )
        #expect(
            outsideTheMargin.causeSentence(locale: english)
                == "No speaker held enough of this segment's speech, so none was named."
        )
    }

    /// The tie is read off the candidates, so the candidates have to reach the
    /// row. A `no_top_ranked_candidate` decline that arrived without them would
    /// silently fall back to the threshold sentence and look correct.
    @Test
    func theLayerCarriesTheCandidatesTheTieIsReadFrom() throws {
        let english = Locale(identifier: "en")
        let fixture = TranscriptFixtures.meetingShaped()
        let document = TranscriptFixtures.proposalDocument(for: fixture.run)
        let layer = TranscriptProposalLayer(document: document)

        for record in document.declined {
            let decline = try #require(
                layer.proposal(at: record.segmentIndex)?.decline,
                "segment \(record.segmentIndex)"
            )
            #expect(decline.candidates == record.acousticCandidates)
        }

        let ties = document.declined.filter { $0.cause == .noTopRankedCandidate }
        #expect(!ties.isEmpty)
        for record in ties {
            let decline = try #require(
                layer.proposal(at: record.segmentIndex)?.decline
            )
            #expect(decline.holdsEqualOverlap, "segment \(record.segmentIndex)")
            #expect(
                decline.sentences(locale: english).first
                    == "The top speakers held the same time in this segment, to within a nanosecond."
            )
        }
    }

    /// An artifact written before the constraint carries no cause, and reads
    /// exactly as it did before this change: the artifact's own sentence,
    /// once.
    @Test
    func aDeclineWithoutACauseReadsAsItAlwaysDid() {
        let english = Locale(identifier: "en")
        let old = SegmentSpeakerProposal.declined(
            SegmentSpeakerProposal.Decline(
                reason: "Both speakers are mid-sentence here."
            )
        )
        #expect(old.sentences(locale: english) == ["Both speakers are mid-sentence here."])
        #expect(
            old.sentences(locale: english, omittingCause: true)
                == ["Both speakers are mid-sentence here."]
        )
        #expect(old.decline?.cause == nil)
        #expect(old.decline?.topRankedCandidate == nil)
        #expect(old.decline?.modelAnswer == nil)
    }

    /// The row prints the acoustic reason and the proposal's sentences in one
    /// column, and the cause sentence restates that reason. When the row is
    /// already printing it, the cause sentence stands down — but the model's
    /// own words never do, because nothing else on the row carries them.
    @Test
    func theCauseSentenceStandsDownWhereTheAcousticReasonAlreadySaysIt() {
        let english = Locale(identifier: "en")
        let decline = SegmentSpeakerProposal.Decline(
            reason: "Declined under confirm-or-decline: no diarization turn overlapped this segment, so there is no top-ranked candidate to confirm. The model also declined: this stretch is silence.",
            cause: .noAcousticCandidates,
            topRankedCandidate: nil,
            modelAnswer: SpeakerProposalDecision(
                segmentIndex: 9,
                proposedSpeaker: "",
                disposition: .decline,
                reason: "this stretch is silence."
            )
        )
        let full = decline.sentences(locale: english)
        let trimmed = decline.sentences(locale: english, omittingCause: true)

        #expect(full.count == 2)
        #expect(trimmed == ["this stretch is silence."])
        // The sentence that stands down is exactly the one the row's acoustic
        // reason already prints for this outcome.
        #expect(
            full[0] == SegmentAttributionSummary(
                speaker: SpeakerRoster.unnamed,
                outcome: .noOverlappingTurn,
                candidates: [],
                timelineCoverage: 0
            ).reason(locale: english)
        )
    }

    @Test
    func theProposalLayerChangesNoTranscriptText() {
        let fixture = TranscriptFixtures.meetingShaped()
        let item = fixture.run.segments[0]

        #expect(
            TranscriptLayerCatalog.text(
                .proposed,
                for: item,
                run: fixture.run,
                record: fixture.record
            ) == item.segment.text
        )
    }

    @Test
    func theProposalsInlineEvidenceStandsInWhenTheConflictRecordIsNotAtHand() throws {
        let fixture = TranscriptFixtures.meetingShaped()
        let layer = TranscriptProposalLayer(
            document: TranscriptFixtures.proposalDocument(for: fixture.run)
        )
        let unnamed = try #require(fixture.run.segments.first {
            !SpeakerRoster.isAttributed($0.segment.speaker)
        })
        let english = Locale(identifier: "en")

        let inline = try #require(layer.inlineEvidence(at: unnamed.index))
        let joined = SegmentAttributionSummary(item: unnamed)

        #expect(inline.candidates.map(\.speaker) == joined.candidates.map(\.speaker))
        #expect(inline.candidates.map(\.share) == joined.candidates.map(\.share))
        #expect(inline.thresholds == nil)
        // Without the thresholds the sentence names no number rather than
        // inventing one, and it is still a different sentence per outcome.
        let sentence = try #require(inline.reason(locale: english))
        #expect(!sentence.contains("%"))
        #expect(sentence != joined.reason(locale: english))
    }

    @Test
    func theProposalLayerStatesTheHoleInTheTranscriptItIsBuiltOn() {
        let fixture = TranscriptFixtures.meetingShaped()
        let layer = TranscriptProposalLayer(
            document: TranscriptFixtures.proposalDocument(for: fixture.run)
        )

        #expect(!layer.sourceCoverage.complete)
        #expect(abs(layer.sourceCoverage.missingDurationS - 30.56) < 1e-6)
        #expect(layer.sourceCoverage.message?.isEmpty == false)
        // Recomputed on decode, so an edited file cannot claim a smaller hole
        // than its own durations imply.
        #expect(
            abs(
                layer.sourceCoverage.inputDurationS
                    - layer.sourceCoverage.processedDurationS
                    - layer.sourceCoverage.missingDurationS
            ) < 1e-9
        )
    }

    // MARK: The real transcript's shape

    @Test
    func theRealMeetingShapeShowsEveryUnnamedSegmentItsEvidence() {
        let fixture = TranscriptFixtures.meetingShaped()
        let english = Locale(identifier: "en")
        let unnamed = fixture.run.segments.filter {
            !SpeakerRoster.isAttributed($0.segment.speaker)
        }
        let flagged = fixture.run.segments.filter {
            TranscriptFlagVocabulary.marksUncertainty($0.segment.flags ?? [])
        }

        #expect(fixture.run.segments.count == 248)
        #expect(unnamed.count == 110)
        #expect(flagged.count == 192)

        for item in unnamed {
            let summary = SegmentAttributionSummary(item: item)
            #expect(summary.reason(locale: english) != nil, "segment \(item.index)")
            #expect(!summary.candidates.isEmpty, "segment \(item.index)")
            let shares = summary.candidates.reduce(0) { $0 + $1.share }
            #expect(abs(shares - 1) < 1e-9, "segment \(item.index)")
        }
    }
}

@MainActor
private final class RecordingClipboard: TranscriptClipboardWriting {
    private(set) var written: String?

    func write(_ text: String) -> Bool {
        written = text
        return true
    }
}

/// Fixtures shaped like the measured 2026-09-01 run. Synthetic text and
/// synthetic timings, real proportions: 248 segments, 110 with no speaker, 192
/// flagged, two speakers, 43 % of segments contested. P6's offscreen render
/// harness builds its views from these so the images show the case the design
/// was chosen for.
enum TranscriptFixtures {
    static let segmentCount = 248
    static let unnamedCount = 110
    static let flaggedCount = 192
    static let recordingDurationS = 1_243.08

    static func attribution(
        outcome: SpeakerAttributionOutcome,
        candidates: [(String, Double, Double)],
        coverage: Double
    ) -> SpeakerAttribution {
        SpeakerAttribution(
            outcome: outcome,
            candidates: candidates.map {
                SpeakerCandidate(speaker: $0.0, overlapS: $0.1, share: $0.2)
            },
            timelineCoverage: coverage,
            thresholds: SpeakerAttributionThresholds(
                dominantSpeakerShare: 0.60,
                minimumTimelineCoverage: 0.50
            )
        )
    }

    /// The source run: acoustic attribution only, no derived result.
    static func meetingShaped() -> (run: LoadedRun, record: LibraryRecord) {
        var segments: [Segment] = []
        var conflicts: [MergeConflict] = []
        var start = 0.0
        var flaggedSoFar = 0

        for index in 0 ..< segmentCount {
            let duration = 3.0 + Double(index % 7)
            let end = start + duration
            // 192 of 248 flagged, and 110 of those flagged carry no speaker,
            // spread through the transcript rather than bunched at the front:
            // the page's real rhythm is a compact attributed row next to a tall
            // evidence row, and a fixture that blocks them together hides that.
            // Unnamed is a subset of flagged because the merger flags every
            // segment it refuses to attribute.
            let isFlagged = (index * flaggedCount) % segmentCount < flaggedCount
            var isUnnamed = false
            if isFlagged {
                isUnnamed = (flaggedSoFar * unnamedCount) % flaggedCount < unnamedCount
                flaggedSoFar += 1
            }
            let speaker = isUnnamed
                ? SpeakerRoster.unnamed
                : (index % 2 == 0 ? "0" : "1")
            var flags: [String] = ["backend_speaker_evidence"]
            if isFlagged { flags.append(contentsOf: ["conflict", "uncertain"]) }

            segments.append(
                Segment(
                    speaker: speaker,
                    startS: start,
                    endS: end,
                    text: sentence(index: index, speaker: speaker),
                    language: "ko",
                    flags: flags
                )
            )

            if isUnnamed {
                let top = 0.50 + Double(index % 9) / 100
                conflicts.append(
                    MergeConflict(
                        segmentIndex: index,
                        kind: .ambiguousSpeaker,
                        candidates: ["0", "1"],
                        reason: "No speaker reached the dominant share for this segment.",
                        speakerAttribution: attribution(
                            outcome: .noDominantSpeaker,
                            candidates: [
                                ("0", duration * top, top),
                                ("1", duration * (1 - top), 1 - top),
                            ],
                            coverage: 0.90 + Double(index % 9) / 100
                        )
                    )
                )
            } else if isFlagged {
                let top = 0.62 + Double(index % 30) / 100
                conflicts.append(
                    MergeConflict(
                        segmentIndex: index,
                        kind: .overlappingSpeech,
                        candidates: [speaker, speaker == "0" ? "1" : "0"],
                        reason: "Two speakers overlapped inside this segment.",
                        speakerAttribution: attribution(
                            outcome: .attributed,
                            candidates: [
                                (speaker, duration * top, top),
                                (speaker == "0" ? "1" : "0", duration * (1 - top), 1 - top),
                            ],
                            coverage: 0.88 + Double(index % 11) / 100
                        )
                    )
                )
            }
            start = end
        }

        let transcript = SegmentsDocument(
            segments: segments,
            numSpeakers: 2,
            source: SourceAudio(
                fileName: "meeting.wav",
                sha256: String(repeating: "b", count: 64),
                durationS: recordingDurationS
            )
        )
        let conflictsBySegment = Dictionary(
            conflicts.map { ($0.segmentIndex, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let run = LoadedRun(
            manifest: manifest(),
            transcript: transcript,
            conflicts: conflicts,
            segments: transcript.segments.enumerated().map { index, segment in
                TranscriptSegment(
                    id: TranscriptSegmentID(runID: "20260901T122702Z-f2d938", index: index),
                    index: index,
                    segment: segment,
                    conflict: conflictsBySegment[index]
                )
            }
        )
        return (run, record())
    }

    /// The same run seen through a translation result: the text is replaced and
    /// the merge conflicts are gone, which is what the library loads.
    static func translationShaped() -> (run: LoadedRun, record: LibraryRecord) {
        var fixture = meetingShaped()
        let postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "codex-app-server", version: "fixture"),
            modelID: "gpt-5.6-sol",
            mode: .translation,
            targetLanguage: "en",
            sourceSegmentsSHA256: String(repeating: "c", count: 64)
        )
        fixture.run.manifest.postprocess = postprocess
        fixture.run.conflicts = []
        for index in fixture.run.segments.indices {
            fixture.run.segments[index].conflict = nil
            fixture.run.segments[index].segment.text =
                "Translated line \(String(format: "%06d", index))."
            fixture.run.transcript.segments[index].text =
                fixture.run.segments[index].segment.text
        }
        return fixture
    }

    private static func sentence(index: Int, speaker: String) -> String {
        let stem = speaker == SpeakerRoster.unnamed
            ? "Overlapping exchange"
            : "Meeting line"
        return "\(stem) segment \(String(format: "%06d", index)) about the release plan."
    }

    private static func manifest() -> Manifest {
        Manifest(
            runID: "20260901T122702Z-f2d938",
            status: .partial,
            input: InputAudio(
                fileName: "meeting.wav",
                sha256: String(repeating: "b", count: 64),
                sizeBytes: 41_000_000
            ),
            backend: BackendDescriptor(name: "maccheroni", version: "fixture"),
            models: [
                ModelDescriptor(
                    role: .asr,
                    hfModelID: "mlx-community/VibeVoice-ASR-8bit",
                    revision: "725c72e54d6ef875472c27fbc50fab470a960940",
                    quantization: "int8"
                ),
                ModelDescriptor(
                    role: .diarization,
                    hfModelID: "aufklarer/Pyannote-Community-1-CoreML",
                    revision: "a14e6c420d56e8472850649b016a486fd0acbe81",
                    quantization: "coreml-fp32"
                ),
            ],
            glossary: ManifestGlossary(
                provided: true,
                sha256: String(repeating: "d", count: 64),
                itemCount: 24,
                injectionMode: .freeTextContext,
                applied: true
            ),
            preprocessing: PreprocessingConfiguration(
                sampleRateHz: 16_000,
                channels: 1,
                peakNormalization: true,
                vad: ProcessingSwitch(enabled: true, backend: "silero-vad"),
                enhancement: ProcessingSwitch(enabled: false, backend: nil)
            ),
            coverage: Coverage(
                inputDurationS: recordingDurationS,
                processedDurationS: 1_212.52,
                truncated: true,
                strategy: .full,
                chunksPlanned: 11,
                chunksCompleted: 10
            ),
            chunkBoundaries: [],
            timing: RunTiming(
                startedAt: "2026-09-01T12:27:02Z",
                finishedAt: "2026-09-01T12:55:41Z",
                wallTimeS: 1_719
            ),
            artifacts: [],
            failure: nil
        )
    }

    private static func record() -> LibraryRecord {
        LibraryRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000f2")!,
            createdAt: Date(timeIntervalSince1970: 1_788_000_000),
            displayName: "Weekly product sync",
            sourceKind: .importedFile,
            sourceURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
            securityScopedBookmark: nil,
            microphoneURL: nil,
            systemAudioURL: nil,
            runURL: URL(fileURLWithPath: "/tmp/20260901T122702Z-f2d938"),
            profileID: .koreanITMeeting,
            postprocess: .none,
            durationS: recordingDurationS,
            state: .hasConflicts,
            speakerNames: ["0": "Jina"],
            conflictResolutions: [:],
            failureMessage: nil
        )
    }

    /// D46's marked speaker proposal over the source fixture, in P4's shape:
    /// every unattributed segment appears exactly once, 98 proposed and 12
    /// declined, over a source transcript with a 30.56-second hole.
    ///
    /// In memory only. A speaker-proposal derived run is not written to disk
    /// here, because the library repository still rejects that artifact set and
    /// a source run carrying one fails to open at all until that is fixed.
    static let declineCauses: [SpeakerProposalDeclineCause] = [
        .modelDeclined, .noTopRankedCandidate, .noAcousticCandidates,
    ]

    /// The same candidates holding exactly equal overlap, which is the state
    /// `no_top_ranked_candidate` records: 23 of the 51 declines on the 2026-09-01
    /// run are this. Equality is on the seconds, not on the percentages the
    /// row prints, because those round.
    static func levelled(
        _ candidates: [SpeakerCandidateEvidence]
    ) -> [SpeakerCandidateEvidence] {
        guard !candidates.isEmpty else { return candidates }
        let count = Double(candidates.count)
        let each = candidates.reduce(0.0) { $0 + $1.overlapS } / count
        return candidates.map {
            SpeakerCandidateEvidence(speaker: $0.speaker, overlapS: each, share: 1 / count)
        }
    }

    /// One declined record in the shape the runner writes under
    /// confirm-or-decline: the model's own words when the model declined, and
    /// the runner's English restatement plus the model's kept answer when the
    /// constraint decided before the answer was read.
    static func decline(
        at index: Int,
        cause: SpeakerProposalDeclineCause,
        outcome: String,
        coverage: Double,
        candidates: [SpeakerCandidateEvidence]
    ) -> SpeakerProposalDecline {
        let topRanked = SpeakerProposalConstraint.topRankedCandidate(among: candidates)
        switch cause {
        case .modelDeclined:
            return SpeakerProposalDecline(
                segmentIndex: index,
                reason: "Both speakers are mid-sentence here and the surrounding turns do not settle it.",
                acousticOutcome: outcome,
                acousticTimelineCoverage: coverage,
                acousticCandidates: candidates,
                cause: .modelDeclined,
                topRankedCandidate: topRanked
            )
        case .noTopRankedCandidate:
            // The runner writes this cause only where no top-ranked candidate can be picked
            // out of the candidates, so the record carries a real tie rather
            // than whatever the source conflict happened to hold. The tie is
            // read off these numbers, and a fixture that only *said* tie in
            // its sentence would have left the tie sentence untested.
            return SpeakerProposalDecline(
                segmentIndex: index,
                reason: "Declined under confirm-or-decline: the acoustic candidates 0 and 1 hold equal overlap, so there is no top-ranked candidate to confirm. The model also declined: the turns are simultaneous.",
                acousticOutcome: outcome,
                acousticTimelineCoverage: coverage,
                acousticCandidates: levelled(candidates),
                cause: .noTopRankedCandidate,
                topRankedCandidate: nil,
                modelAnswer: SpeakerProposalDecision(
                    segmentIndex: index,
                    proposedSpeaker: "",
                    disposition: .decline,
                    reason: "the turns are simultaneous."
                )
            )
        default:
            return SpeakerProposalDecline(
                segmentIndex: index,
                reason: "Declined under confirm-or-decline: no diarization turn overlapped this segment, so there is no top-ranked candidate to confirm. The model also declined: this stretch is silence.",
                acousticOutcome: outcome,
                acousticTimelineCoverage: coverage,
                acousticCandidates: candidates,
                cause: .noAcousticCandidates,
                topRankedCandidate: nil,
                modelAnswer: SpeakerProposalDecision(
                    segmentIndex: index,
                    proposedSpeaker: "",
                    disposition: .decline,
                    reason: "this stretch is silence."
                )
            )
        }
    }

    static func proposalDocument(for run: LoadedRun) -> SpeakerProposalDocument {
        var proposals: [SpeakerProposal] = []
        var declined: [SpeakerProposalDecline] = []
        let unattributed = run.segments.filter {
            !SpeakerRoster.isAttributed($0.segment.speaker)
        }
        for (rank, item) in unattributed.enumerated() {
            let attribution = item.conflict?.speakerAttribution
            let candidates = (attribution?.candidates ?? []).map {
                SpeakerCandidateEvidence(
                    speaker: $0.speaker,
                    overlapS: $0.overlapS,
                    share: $0.share
                )
            }
            let outcome = (attribution?.outcome ?? .noDominantSpeaker).rawValue
            let coverage = attribution?.timelineCoverage ?? 0
            // 12 of 110 come back with a reason instead of a speaker, which is
            // roughly the one-in-nine P4 measured.
            if rank % 9 == 4, declined.count < 12 {
                // The three causes D50's constraint actually produced on the
                // real run, in the proportion they appeared: a model decline,
                // a tie with no top-ranked candidate, and a segment nothing overlapped.
                declined.append(
                    decline(
                        at: item.index,
                        cause: Self.declineCauses[declined.count % Self.declineCauses.count],
                        outcome: outcome,
                        coverage: coverage,
                        candidates: candidates
                    )
                )
            } else {
                proposals.append(
                    SpeakerProposal(
                        segmentIndex: item.index,
                        proposedSpeaker: candidates.first?.speaker ?? "0",
                        reason: "Answers the question the other speaker asked in the previous turn.",
                        acousticOutcome: outcome,
                        acousticTimelineCoverage: coverage,
                        acousticCandidates: candidates
                    )
                )
            }
        }
        while proposals.count + declined.count > 110 { proposals.removeLast() }
        return SpeakerProposalDocument(
            sourceSegmentsSHA256: String(repeating: "e", count: 64),
            sourceCoverage: DerivedSourceCoverage(
                complete: false,
                inputDurationS: recordingDurationS,
                processedDurationS: 1_212.52,
                message: "promoted 1212.520 s of 1243.080 s; 1 range(s) produced no transcript after repetition looping exhausted recovery: [871.552, 902.112) s"
            ),
            proposals: proposals,
            declined: declined,
            batches: []
        )
    }

    /// The same run loaded through a speaker-proposal derived result, whose
    /// manifest keeps `mode == .correction` while `kind` says what it is.
    static func proposalResultShaped() -> (run: LoadedRun, record: LibraryRecord) {
        var fixture = meetingShaped()
        fixture.run.resultID = "20260902T010203Z-proposal"
        fixture.run.resultOperation = DerivedOperation(
            profileName: "ko-meeting",
            mode: .correction,
            glossarySemantics: .sourceRun,
            glossaryItemCount: 24,
            kind: .speakerProposal,
            sourceCoverage: DerivedSourceCoverage(
                complete: false,
                inputDurationS: recordingDurationS,
                processedDurationS: 1_212.52,
                message: nil
            )
        )
        return fixture
    }

    /// An app model wired to inert fakes, so a render harness can build a whole
    /// `TranscriptView` offscreen. Nothing here runs, records, or writes
    /// outside `root`.
    @MainActor
    static func model(root: URL) throws -> MaccheroniAppModel {
        let suite = "MaccheroniFixtures-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return try MaccheroniAppModel(
            repository: LibraryRepository(root: root),
            profiles: AppProfileRegistry.load(),
            runner: InertRunner(),
            recorder: InertRecorder(),
            defaults: defaults,
            codexAvailability: .unavailable,
            recordSaver: { _ in },
            readinessProbe: nil,
            capturePermissions: { CapturePermissions(microphone: .granted, systemAudio: .granted) }
        )
    }
}

private enum FixtureError: Error {
    case notImplemented
}

private final class InertRunner: TranscriptionRunning {
    func run(
        _: TranscriptionRequest,
        progress _: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        throw FixtureError.notImplemented
    }

    func cancel() {}
}

@MainActor
private final class InertRecorder: RecordingControlling {
    var meters = CaptureMeters.silent

    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}

    func start(in _: URL) async throws -> RecordingSessionMetadata {
        throw FixtureError.notImplemented
    }

    func stop() async throws -> RecordingArtifacts {
        throw FixtureError.notImplemented
    }

    func cancel() async {}
}

/// WCAG 2.x relative luminance and contrast ratio, for the token table.
enum WCAG {
    static func contrast(_ hex: String, against ground: String) -> Double {
        let a = luminance(hex)
        let b = luminance(ground)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ hex: String) -> Double {
        let color = NSColor(hex: hex)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
