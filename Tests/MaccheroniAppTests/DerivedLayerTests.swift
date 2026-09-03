import CryptoKit
import Foundation
import MaccheroniCore
import MaccheroniMerge
import MaccheroniPostprocess
import Testing

@testable import MaccheroniApp

/// Reading a run that carries a derived layer.
///
/// Two gates closed here, both of which made a source run fail to open rather
/// than fail to render: an unrecognised derived family took the manifest decode
/// down with it, and the derived path verified its source with
/// `verifyCompletedRun`, which refuses a run whose ASR coverage is partial. The
/// real 20.7-minute recording is partial, so the layer D46 exists to enable
/// could never have been shown on it.
@Suite
struct DerivedLayerTests {
    @Test
    func aSpeakerProposalSetLoadsBesideTheAcousticTranscript() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        let mergedHash = try derivedLayerSHA256(of: fixture.segmentsURL)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-a",
            finishedAt: "2026-09-01T23:13:07Z"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        let proposal = try #require(loaded.speakerProposal)
        #expect(proposal.constraint == .confirmOrDecline)
        #expect(proposal.proposals.map(\.segmentIndex) == [1])
        #expect(proposal.proposals[0].proposedSpeaker == "SPEAKER_00")
        #expect(proposal.declined.map(\.segmentIndex) == [2])
        #expect(proposal.declined[0].cause == .noTopRankedCandidate)
        // The acoustic record travels with the proposal, so a reader always
        // sees what the acoustics said beside what the proposal added.
        #expect(proposal.proposals[0].acousticCandidates.map(\.speaker)
            == ["SPEAKER_00", "SPEAKER_01"])

        // The source transcript is what is displayed. A proposal names no
        // speaker in the record and rewrites no text.
        #expect(loaded.transcript == fixture.transcript)
        #expect(loaded.segments.map(\.segment.speaker)
            == ["SPEAKER_00", "UNKNOWN", "UNKNOWN", "SPEAKER_01"])
        #expect(loaded.resultID == nil)
        #expect(loaded.derivedResults.map(\.id) == ["proposal-a"])
        #expect(loaded.derivedResults.map(\.kind) == [.speakerProposal])
        #expect(loaded.derivedResults.map(\.isCurrent) == [true])
        #expect(loaded.unreadableDerivedSets.isEmpty)
        #expect(try derivedLayerSHA256(of: fixture.segmentsURL) == mergedHash)
    }

    /// D49. The run the whole layer exists for is `status: partial`, so if this
    /// regresses the feature is dead on the only recording that has it.
    @Test
    func aPartialSourceRunCarriesItsProposalLayerAndSaysSo() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-partial",
            finishedAt: "2026-09-01T23:13:07Z"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        let proposal = try #require(loaded.speakerProposal)
        #expect(proposal.sourceCoverage.complete == false)
        #expect(proposal.sourceCoverage.inputDurationS == 8)
        #expect(proposal.sourceCoverage.processedDurationS == 6)
        // Recomputed on decode, so the durations and the difference cannot
        // disagree in a file someone edited.
        #expect(proposal.sourceCoverage.missingDurationS == 2)
        #expect(loaded.derivedResults.map(\.kind) == [.speakerProposal])
    }

    /// The relaxation is for the speaker-proposal family only. Correction and
    /// translation rewrite or mirror every segment, so a hole in the transcript
    /// would produce a set claiming coverage it does not have.
    @Test
    func aPartialSourceRunStillRefusesACorrectionSet() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        try derivedLayerWriteCorrection(
            fixture: fixture,
            id: "correction-on-partial",
            finishedAt: "2026-09-01T10:00:00Z",
            text: "Corrected zero"
        )

        #expect(throws: RunIntegrityError.sourceRunNotComplete) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
    }

    /// The failure mode this task exists to remove, in the form it would come
    /// back in: a derived family a later version writes and this build has no
    /// case for. It is rejected as a set, named, and the source run still opens.
    @Test
    func anUnrecognisedDerivedKindIsRejectedAndTheSourceRunStillOpens() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-known",
            finishedAt: "2026-09-01T23:13:07Z"
        )
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "future-family",
            finishedAt: "2026-09-02T23:13:07Z",
            overrideKind: "topic-segmentation"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.unreadableDerivedSets == [
            UnreadableDerivedSet(
                id: "future-family",
                reason: .unrecognisedKind("topic-segmentation")
            ),
        ])
        // Rejected, not applied, and not allowed to hide the set that is
        // readable.
        #expect(loaded.derivedResults.map(\.id) == ["proposal-known"])
        #expect(loaded.speakerProposal?.proposals.map(\.segmentIndex) == [1])
        #expect(loaded.transcript == fixture.transcript)
    }

    /// A manifest that is simply broken must still fail loudly. Only an
    /// unrecognised kind is read as "newer" rather than "corrupt".
    @Test
    func aCorruptDerivedManifestStillFailsTheRun() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "corrupt",
            finishedAt: "2026-09-01T23:13:07Z"
        )
        try Data("{ not a manifest".utf8).write(
            to: fixture.runURL.appendingPathComponent("derived/corrupt/manifest.json")
        )

        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
    }

    @Test
    func correctionAndTranslationSetsStillLoadUnchanged() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrected = try derivedLayerRunFixture(in: root, runID: "corrected-run")
        try derivedLayerWriteCorrection(
            fixture: corrected,
            id: "correction-a",
            finishedAt: "2026-09-01T10:00:00Z",
            text: "Corrected zero"
        )
        let translated = try derivedLayerRunFixture(in: root, runID: "translated-run")
        try derivedLayerWriteTranslation(
            fixture: translated,
            id: "translation-a",
            finishedAt: "2026-09-01T10:00:00Z",
            targetLanguage: "it"
        )

        let correctionRun = try LibraryRepository(root: root)
            .loadRun(at: corrected.runURL)
        #expect(correctionRun.resultID == "correction-a")
        #expect(correctionRun.transcript.segments[0].text == "Corrected zero")
        #expect(correctionRun.derivedResults.map(\.kind) == [.textPostprocess])
        #expect(correctionRun.derivedResults.map(\.operation) == [.correction])
        #expect(correctionRun.speakerProposal == nil)

        let translationRun = try LibraryRepository(root: root)
            .loadRun(at: translated.runURL)
        #expect(translationRun.resultID == "translation-a")
        #expect(translationRun.transcript.segments.map(\.text)
            == ["it: Zero", "it: One", "it: Two", "it: Three"])
        #expect(translationRun.derivedResults.map(\.targetLanguage) == ["it"])
    }

    /// P5's second handover item. `loadRun` used to decode the source
    /// transcript, write the translated text over it and throw the decoded
    /// document away, so the acoustic record could not be shown beside the
    /// translation.
    @Test
    func aTranslationKeepsTheSourceTranscriptBesideIt() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteTranslation(
            fixture: fixture,
            id: "translation-a",
            finishedAt: "2026-09-01T10:00:00Z",
            targetLanguage: "it"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        let source = try #require(loaded.sourceTranscript)
        #expect(source == fixture.transcript)
        #expect(source.segments.map(\.text) == ["Zero", "One", "Two", "Three"])
        #expect(loaded.effectiveSourceTranscript == fixture.transcript)
        // The speakers survive too, which is what the layer needs.
        #expect(source.segments.map(\.speaker)
            == ["SPEAKER_00", "UNKNOWN", "UNKNOWN", "SPEAKER_01"])
    }

    /// A run with no derived set is its own source, and nothing pretends
    /// otherwise.
    @Test
    func aPlainRunReportsItselfAsItsOwnSource() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.sourceTranscript == nil)
        #expect(loaded.effectiveSourceTranscript == fixture.transcript)
        #expect(loaded.speakerProposal == nil)
        #expect(loaded.unreadableDerivedSets.isEmpty)
    }

    /// D39 chose the freshest derived set because every set then replaced the
    /// transcript's text. A proposal replaces none, so it must not win that
    /// slot and hide a correction behind a set that corrected nothing.
    @Test
    func aFresherProposalDoesNotDisplaceACorrection() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteCorrection(
            fixture: fixture,
            id: "correction-a",
            finishedAt: "2026-09-01T10:00:00Z",
            text: "Corrected zero"
        )
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-a",
            finishedAt: "2026-09-02T10:00:00Z"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.resultID == "correction-a")
        #expect(loaded.transcript.segments[0].text == "Corrected zero")
        #expect(loaded.speakerProposal?.proposals.map(\.segmentIndex) == [1])
        #expect(loaded.derivedResults.map(\.id) == ["proposal-a", "correction-a"])
        // One current member per family, because the two answer different
        // questions.
        #expect(loaded.derivedResults.map(\.isCurrent) == [true, true])
        #expect(loaded.derivedResults.map(\.kind)
            == [.speakerProposal, .textPostprocess])
    }

    /// Two proposal sets over one run carry one name, so the inspector needs a
    /// second and a third thing to tell them apart. The timestamp is one. The
    /// counts are the other, and they have to come from each set's own
    /// artifact: only the current member is loaded as a document, so a count
    /// recomputed at display time would exist for one row and not the other.
    @Test
    func twoProposalSetsOfOneRunCarryTheirOwnTimestampsAndCounts() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "20260901T163213Z-6d1f66",
            finishedAt: "2026-09-01T16:32:13Z",
            declineSegmentOne: true
        )
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "20260901T230950Z-8f6b5c",
            finishedAt: "2026-09-01T23:09:50Z"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.derivedResults.count == 2)
        #expect(loaded.derivedResults.map(\.kind) == [.speakerProposal, .speakerProposal])
        // One name for both rows: this is the defect the timestamp and the
        // counts exist to answer.
        #expect(
            String(localized: RunInspectorWording.derivedSet(loaded.derivedResults[0]))
                == String(localized: RunInspectorWording.derivedSet(loaded.derivedResults[1]))
        )
        #expect(loaded.derivedResults[0].createdAt != loaded.derivedResults[1].createdAt)
        let fresher = try #require(loaded.derivedResults[0].speakerProposalCounts)
        let older = try #require(loaded.derivedResults[1].speakerProposalCounts)
        #expect(fresher == SpeakerProposalCounts(proposed: 1, declined: 1))
        #expect(older == SpeakerProposalCounts(proposed: 0, declined: 2))
        #expect(fresher != older)
        // Both sets examined every unattributed segment; what differs is what
        // each one did with them.
        #expect(fresher.examined == older.examined)

        // Read from each set, not from the layer on screen. Only the fresher
        // set is loaded as a document, and the older row still has its numbers.
        let currentDocument = try #require(loaded.speakerProposal)
        #expect(currentDocument.proposals.count == fresher.proposed)
        #expect(currentDocument.declined.count == fresher.declined)
        #expect(loaded.derivedResults[0].isCurrent)
        #expect(!loaded.derivedResults[1].isCurrent)
    }

    /// A text set has no proposal and no decline, so it prints no count rather
    /// than a pair of zeroes that would read as a set that proposed nothing.
    @Test
    func aTextDerivedSetCarriesNoProposalCount() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteCorrection(
            fixture: fixture,
            id: "correction-a",
            finishedAt: "2026-09-01T10:00:00Z",
            text: "Corrected zero"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        #expect(loaded.derivedResults.map(\.id) == ["correction-a"])
        #expect(loaded.derivedResults[0].speakerProposalCounts == nil)
    }

    @Test
    func aProposalSetWhoseArtifactWasEditedAfterSealingIsRejected() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "tampered",
            finishedAt: "2026-09-01T23:13:07Z"
        )
        let artifactURL = fixture.runURL.appendingPathComponent(
            "derived/tampered/speaker/proposals.json"
        )
        var document = try JSONDecoder().decode(
            SpeakerProposalDocument.self,
            from: Data(contentsOf: artifactURL)
        )
        document.proposals[0].proposedSpeaker = "SPEAKER_01"
        try JSONEncoder().encode(document).write(to: artifactURL)

        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
    }

    /// D50 on the reading side. A document that says it ran under
    /// confirm-or-decline may not contain a proposal that overturns the
    /// top-ranked candidate, whatever its hash says.
    @Test
    func aConfirmOrDeclineSetMayNotOverturnTheTopRankedCandidate() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "overturn",
            finishedAt: "2026-09-01T23:13:07Z",
            proposedSpeakerForSegmentOne: "SPEAKER_01"
        )

        try expectRejectedProposal(root: root, runURL: fixture.runURL, id: "overturn")
    }

    /// Judgment rule 4 as amended by D46: a proposal completes acoustic
    /// evidence, it never replaces it.
    @Test
    func aProposalOnAnAlreadyAttributedSegmentIsRejected() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "overrides",
            finishedAt: "2026-09-01T23:13:07Z",
            extraProposalOnAttributedSegment: true
        )

        try expectRejectedProposal(root: root, runURL: fixture.runURL, id: "overrides")
    }

    /// Exactly once over proposals plus declined, across every unattributed
    /// segment. A set that quietly skipped one would read as though that
    /// segment had never been examined.
    @Test
    func aProposalSetThatSkipsAnUnattributedSegmentIsRejected() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "incomplete",
            finishedAt: "2026-09-01T23:13:07Z",
            omitDeclines: true
        )

        try expectRejectedProposal(root: root, runURL: fixture.runURL, id: "incomplete")
    }

    /// The acoustic evidence in the artifact is checked against the run's own
    /// conflicts, not taken on trust from the artifact.
    @Test
    func aProposalCarryingAcousticSharesTheRunDidNotMeasureIsRejected() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "fabricated-evidence",
            finishedAt: "2026-09-01T23:13:07Z",
            inflateFirstCandidateShare: true
        )

        try expectRejectedProposal(root: root, runURL: fixture.runURL, id: "fabricated-evidence")
    }

    /// A decline's explanation is checked against the acoustic record, not
    /// taken on trust from the artifact.
    ///
    /// `cause`, `top_ranked_candidate` and the nested `model_answer` are the
    /// three fields D50's constraint writes so a later measurement can tell
    /// what the constraint did from what the model did, and they were read
    /// straight onto the screen. Each case below keeps the artifact hash
    /// consistent and the acoustic evidence exactly as the run measured it,
    /// and lies only in the explanation — which is the part a reader reads.
    @Test
    func aDeclineWhoseExplanationContradictsTheAcousticRecordIsRejected() throws {
        // Segment 2 is the exact tie; segment 1 has a clear sub-threshold
        // leader in SPEAKER_00. Both shapes are needed: a cause is false only
        // against the candidates it sits beside.
        let lies: [(String, ([SpeakerProposalDecline]) -> [SpeakerProposalDecline])] = [
            ("no-acoustic-candidates-with-candidates", { declines in
                declines.map {
                    var decline = $0
                    decline.cause = .noAcousticCandidates
                    return decline
                }
            }),
            ("no-top-ranked-candidate-on-a-clear-leader", { declines in
                declines.map { decline in
                    guard decline.segmentIndex == 1 else { return decline }
                    var edited = decline
                    edited.cause = .noTopRankedCandidate
                    edited.topRankedCandidate = nil
                    return edited
                }
            }),
            ("top-ranked-candidate-names-the-other-speaker", { declines in
                declines.map { decline in
                    guard decline.segmentIndex == 1 else { return decline }
                    var edited = decline
                    edited.topRankedCandidate = "SPEAKER_01"
                    return edited
                }
            }),
            ("model-answer-from-another-segment", { declines in
                declines.map { decline in
                    guard var answer = decline.modelAnswer else { return decline }
                    var edited = decline
                    answer.segmentIndex = 0
                    edited.modelAnswer = answer
                    return edited
                }
            }),
            ("model-declined-carrying-a-proposal", { declines in
                declines.map { decline in
                    guard decline.cause == .modelDeclined else { return decline }
                    var edited = decline
                    edited.modelAnswer = SpeakerProposalDecision(
                        segmentIndex: decline.segmentIndex,
                        proposedSpeaker: "SPEAKER_00",
                        disposition: .propose,
                        reason: "An answer this cause says was never given."
                    )
                    return edited
                }
            }),
        ]

        for (id, rewrite) in lies {
            let root = try derivedLayerTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try derivedLayerRunFixture(in: root)
            try derivedLayerWriteSpeakerProposal(
                fixture: fixture,
                id: id,
                finishedAt: "2026-09-01T23:13:07Z",
                declineSegmentOne: true,
                rewritingDeclines: rewrite
            )

            let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

            #expect(
                loaded.unreadableDerivedSets == [
                    UnreadableDerivedSet(
                        id: id,
                        reason: .speakerProposalContradictsSourceRun
                    ),
                ],
                "\(id)"
            )
            #expect(loaded.speakerProposal == nil, "\(id)")
            #expect(loaded.transcript == fixture.transcript, "\(id)")
        }
    }

    /// The same set with its explanations intact loads, so the checks above
    /// reject the lie rather than the shape it is written in.
    @Test
    func everyDeclineCauseTheConstraintWritesIsAccepted() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "honest-declines",
            finishedAt: "2026-09-01T23:13:07Z",
            declineSegmentOne: true
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        let proposal = try #require(loaded.speakerProposal)
        #expect(loaded.unreadableDerivedSets.isEmpty)
        #expect(proposal.proposals.isEmpty)
        #expect(proposal.declined.map(\.cause) == [.modelDeclined, .noTopRankedCandidate])
        #expect(proposal.declined.map(\.topRankedCandidate) == ["SPEAKER_00", nil])
        #expect(proposal.declined[0].modelAnswer?.disposition == .decline)
        #expect(proposal.declined[1].modelAnswer?.segmentIndex == 2)
    }

    /// An artifact written before the confirm-or-decline constraint carries
    /// none of the three fields, and is judged by none of these checks.
    @Test
    func aDeclineWrittenBeforeTheConstraintIsNotJudgedByIt() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "pre-constraint",
            finishedAt: "2026-09-01T23:13:07Z",
            rewritingDeclines: { declines in
                declines.map {
                    SpeakerProposalDecline(
                        segmentIndex: $0.segmentIndex,
                        reason: $0.reason,
                        acousticOutcome: $0.acousticOutcome,
                        acousticTimelineCoverage: $0.acousticTimelineCoverage,
                        acousticCandidates: $0.acousticCandidates
                    )
                }
            }
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        let proposal = try #require(loaded.speakerProposal)
        #expect(loaded.unreadableDerivedSets.isEmpty)
        #expect(proposal.declined.map(\.cause) == [nil])
        #expect(proposal.declined[0].topRankedCandidate == nil)
        #expect(proposal.declined[0].modelAnswer == nil)
    }

    /// D49's condition. The manifest must record the coverage the proposal was
    /// made over, and that record must be the coverage the source run has.
    @Test
    func aProposalClaimingCompleteCoverageOverAPartialRunIsRejected() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "coverage-lie",
            finishedAt: "2026-09-01T23:13:07Z",
            claimCompleteCoverage: true
        )

        try expectRejectedProposal(root: root, runURL: fixture.runURL, id: "coverage-lie")
    }

    /// The repository hands the view the whole proposal document, not a
    /// summary of it. P7's finding is why this is pinned: every confirmation in
    /// the real set sits in the share band P2 measured as least reliable, so
    /// the reading surface has to be able to show the candidates and the
    /// top-ranked candidate's share beside a confirmation, and a decline's `cause`,
    /// `topRankedCandidate` and `modelAnswer` are the evidence that a disagreement
    /// was preserved rather than dropped. Nothing on this path may thin them
    /// out.
    @Test
    func theLoadedProposalIsTheWholeDocumentAndNotASummaryOfIt() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-a",
            finishedAt: "2026-09-01T23:13:07Z"
        )

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)

        let onDisk = try JSONDecoder().decode(
            SpeakerProposalDocument.self,
            from: Data(contentsOf: fixture.runURL.appendingPathComponent(
                "derived/proposal-a/speaker/proposals.json"
            ))
        )
        #expect(loaded.speakerProposal == onDisk)

        // Named field by field as well as by whole-document equality, because
        // equality would still hold if a later change dropped a field on both
        // sides of the comparison.
        let proposal = try #require(loaded.speakerProposal)
        let confirmation = try #require(proposal.proposals.first)
        #expect(confirmation.acousticCandidates == [
            SpeakerCandidateEvidence(speaker: "SPEAKER_00", overlapS: 1.1, share: 0.55),
            SpeakerCandidateEvidence(speaker: "SPEAKER_01", overlapS: 0.9, share: 0.45),
        ])
        #expect(confirmation.acousticTimelineCoverage == 0.9)
        #expect(confirmation.acousticOutcome == "no_dominant_speaker")
        // The top-ranked candidate's share is reachable, which is what lets a confirmation
        // read as a decision still owed rather than a settled attribution.
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: confirmation.acousticCandidates
        ) == confirmation.proposedSpeaker)
        #expect(confirmation.acousticCandidates.map(\.share).max() == 0.55)

        let decline = try #require(proposal.declined.first)
        #expect(decline.cause == .noTopRankedCandidate)
        #expect(decline.topRankedCandidate == nil)
        #expect(decline.modelAnswer?.proposedSpeaker == "SPEAKER_00")
        #expect(decline.modelAnswer?.disposition == .propose)
        #expect(!decline.acousticCandidates.isEmpty)
    }

    /// The other half of "the proposal layer is loadable": what the repository
    /// loads is what the reading surface offers. This calls the shipped catalog
    /// on a really loaded run rather than on a hand-built one, which is the
    /// join `RootView` makes.
    @Test
    func aLoadedProposalMakesTheProposedLayerSelectableButNeverTheDefault() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        try derivedLayerWriteSpeakerProposal(
            fixture: fixture,
            id: "proposal-a",
            finishedAt: "2026-09-01T23:13:07Z"
        )
        let record = derivedLayerRecord()

        let loaded = try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        let options = TranscriptLayerCatalog.options(
            run: loaded,
            record: record,
            proposal: loaded.speakerProposal
        )

        #expect(options.first { $0.layer == .proposed }?.isAvailable == true)
        #expect(options.first { $0.layer == .speakerLabelled }?.isAvailable == true)
        // D46 leaves whether a proposal may ever be the default open, and this
        // is not the place to close it.
        #expect(TranscriptLayerCatalog.defaultLayer(
            run: loaded,
            record: record,
            proposal: loaded.speakerProposal
        ) == .speakerLabelled)

        // Without the loaded proposal the same run offers the layer and says
        // why it is not there, which is the state every run was in before.
        let withoutProposal = TranscriptLayerCatalog.options(
            run: loaded,
            record: record,
            proposal: nil
        )
        #expect(withoutProposal.first { $0.layer == .proposed }?.unavailability
            == .proposalNotYetProduced)
    }

    /// A derived set whose lineage does not verify is still rejected, and the
    /// rejection is still loud. Widening what is accepted must not loosen what
    /// is checked.
    @Test
    func aProposalSetFromAnotherRunIsRejected() throws {
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, runID: "host-run")
        let other = try derivedLayerRunFixture(in: root, runID: "other-run")
        try derivedLayerWriteSpeakerProposal(
            fixture: other,
            id: "foreign",
            finishedAt: "2026-09-01T23:13:07Z"
        )
        try FileManager.default.createDirectory(
            at: fixture.runURL.appendingPathComponent("derived", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(
            at: other.runURL.appendingPathComponent("derived/foreign"),
            to: fixture.runURL.appendingPathComponent("derived/foreign")
        )

        #expect(throws: LibraryRepositoryError.self) {
            try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        }
    }
}

/// A speaker-proposal set the loader refuses, and the source run that opens
/// anyway.
///
/// The bytes are the ones the manifest hashed in every case here, so what is
/// wrong is what the artifact claims rather than whether it is intact. That is
/// recorded against the set and the run is read: a derived layer beside a run
/// must not decide whether the run itself can be opened, which is the defect
/// the unrecognised-kind path was repaired for and which every one of these
/// checks used to reproduce.
private func expectRejectedProposal(
    root: URL,
    runURL: URL,
    id: String,
    sourceFileID: String = #fileID,
    sourceLine: Int = #line
) throws {
    let loaded = try LibraryRepository(root: root).loadRun(at: runURL)
    let location = SourceLocation(fileID: sourceFileID, filePath: #filePath, line: sourceLine, column: 1)
    #expect(
        loaded.unreadableDerivedSets == [
            UnreadableDerivedSet(id: id, reason: .speakerProposalContradictsSourceRun),
        ],
        sourceLocation: location
    )
    #expect(loaded.speakerProposal == nil, sourceLocation: location)
    #expect(loaded.derivedResults.isEmpty, sourceLocation: location)
    // The immutable record is what the reader still gets.
    #expect(loaded.segments.count == 4, sourceLocation: location)
    #expect(loaded.resultID == nil, sourceLocation: location)
}

// MARK: - Fixtures

private struct DerivedLayerRunFixture {
    var runURL: URL
    var segmentsURL: URL
    var conflictsURL: URL
    var transcript: SegmentsDocument
    var conflicts: [MergeConflict]
    var manifest: Manifest
}

private func derivedLayerRecord() -> LibraryRecord {
    LibraryRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000d9")!,
        createdAt: Date(timeIntervalSince1970: 1_756_000_000),
        displayName: "Derived layer fixture",
        sourceKind: .importedFile,
        sourceURL: URL(fileURLWithPath: "/dev/null"),
        securityScopedBookmark: nil,
        microphoneURL: nil,
        systemAudioURL: nil,
        runURL: nil,
        profileID: .koreanITMeeting,
        postprocess: .none,
        durationS: 8,
        state: .hasConflicts,
        speakerNames: [:],
        conflictResolutions: [:],
        failureMessage: nil
    )
}

private func derivedLayerTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MaccheroniDerivedLayerTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func derivedLayerSHA256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }
        .joined()
}

private let derivedLayerThresholds = SpeakerAttributionThresholds(
    dominantSpeakerShare: 0.60,
    minimumTimelineCoverage: 0.50
)

/// A four-segment run with two segments the acoustics declined to name: one
/// with a clear sub-threshold top-ranked candidate, one an exact tie with no top-ranked candidate at all.
/// Those are the two shapes the proposer and D50 behave differently on.
private func derivedLayerRunFixture(
    in root: URL,
    runID: String = "derived-layer-run",
    complete: Bool = true
) throws -> DerivedLayerRunFixture {
    let runURL = root.appendingPathComponent(runID, isDirectory: true)
    let primaryURL = runURL.appendingPathComponent("primary", isDirectory: true)
    let diarizationURL = runURL.appendingPathComponent("diarization", isDirectory: true)
    let mergedURL = runURL.appendingPathComponent("merged", isDirectory: true)
    for directory in [primaryURL, diarizationURL, mergedURL] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }
    let rawURL = primaryURL.appendingPathComponent("raw.txt")
    let primarySegmentsURL = primaryURL.appendingPathComponent("segments.json")
    let timelineURL = diarizationURL.appendingPathComponent("timeline.json")
    let segmentsURL = mergedURL.appendingPathComponent("segments.json")
    let conflictsURL = mergedURL.appendingPathComponent("conflicts.json")
    try Data("immutable raw transcript".utf8).write(to: rawURL)

    let source = SourceAudio(
        fileName: "meeting-\(runID).wav",
        sha256: String(repeating: "b", count: 64),
        durationS: 8
    )
    let transcript = SegmentsDocument(
        segments: [
            Segment(speaker: "SPEAKER_00", startS: 0, endS: 2, text: "Zero"),
            Segment(speaker: "UNKNOWN", startS: 2, endS: 4, text: "One"),
            Segment(speaker: "UNKNOWN", startS: 4, endS: 6, text: "Two"),
            Segment(speaker: "SPEAKER_01", startS: 6, endS: 8, text: "Three"),
        ],
        numSpeakers: 2,
        source: source
    )
    let conflicts = [
        // A sub-threshold top-ranked candidate: 0.55 against a 0.60 bar.
        MergeConflict(
            segmentIndex: 1,
            kind: .ambiguousSpeaker,
            candidates: ["SPEAKER_00", "SPEAKER_01"],
            reason: "No speaker reached the dominant share.",
            speakerAttribution: SpeakerAttribution(
                outcome: .noDominantSpeaker,
                candidates: [
                    SpeakerCandidate(speaker: "SPEAKER_00", overlapS: 1.1, share: 0.55),
                    SpeakerCandidate(speaker: "SPEAKER_01", overlapS: 0.9, share: 0.45),
                ],
                timelineCoverage: 0.9,
                thresholds: derivedLayerThresholds
            )
        ),
        // An exact tie, which the margin rule refuses at every threshold and
        // which therefore has no top-ranked candidate to confirm.
        MergeConflict(
            segmentIndex: 2,
            kind: .ambiguousSpeaker,
            candidates: ["SPEAKER_00", "SPEAKER_01"],
            reason: "The two speakers held equal overlap.",
            speakerAttribution: SpeakerAttribution(
                outcome: .noDominantSpeaker,
                candidates: [
                    SpeakerCandidate(speaker: "SPEAKER_00", overlapS: 1.0, share: 0.5),
                    SpeakerCandidate(speaker: "SPEAKER_01", overlapS: 1.0, share: 0.5),
                ],
                timelineCoverage: 0.95,
                thresholds: derivedLayerThresholds
            )
        ),
    ]
    try JSONEncoder().encode(transcript).write(to: segmentsURL)
    try JSONEncoder().encode(transcript).write(to: primarySegmentsURL)
    try JSONEncoder().encode([
        TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 4),
        TimelineSegment(speaker: "SPEAKER_01", startS: 4, endS: 8),
    ]).write(to: timelineURL)
    try JSONEncoder().encode(conflicts).write(to: conflictsURL)

    // A `partial` run has to say what it lost and why: the manifest carries the
    // failure and, when its coverage is short, `primary/partial-coverage.json`
    // states the missing range. A partial fixture without those is not a run
    // this product would write, and the derivable-source gate refuses it —
    // correctly, because a proposal over a transcript with an unnamed hole in
    // it is the false claim D49's conditions exist to prevent.
    //
    // The field names and wire values are the ones `PartialCoverageRecord` and
    // `SourceMissingRange` actually write, `stop_reason` included: a fixture
    // that spelled them its own way would pass this suite while standing in
    // for a file no run produces.
    let partialCoverageURL = primaryURL.appendingPathComponent("partial-coverage.json")
    if !complete {
        try Data(#"""
        {"schema_version":"1.0.0","input_duration_s":8.0,"promoted_duration_s":6.0,"missing_duration_s":2.0,"missing":[{"attempt_id":"fixture-leaf-1","start_s":6.0,"end_s":8.0,"stop_reason":"repetitionLooping","failure_code":"ASR_REPETITION_LOOPING"}],"partial_attempt_ids":[]}
        """#.utf8).write(to: partialCoverageURL)
    }
    let partialArtifacts = complete ? [] : [
        Artifact(
            kind: "partial_coverage",
            path: "primary/partial-coverage.json",
            sha256: try derivedLayerSHA256(of: partialCoverageURL)
        ),
    ]

    let manifest = Manifest(
        runID: runID,
        status: complete ? .succeeded : .partial,
        input: InputAudio(
            fileName: source.fileName,
            sha256: source.sha256,
            sizeBytes: 4_096
        ),
        backend: BackendDescriptor(name: "fixture", version: "1"),
        models: [
            ModelDescriptor(
                role: .asr,
                hfModelID: "fixture/asr",
                revision: String(repeating: "a", count: 40),
                quantization: "fixture"
            ),
        ],
        glossary: .absent,
        preprocessing: PreprocessingConfiguration(
            sampleRateHz: 16_000,
            channels: 1,
            peakNormalization: true,
            vad: ProcessingSwitch(enabled: true, backend: "fixture"),
            enhancement: ProcessingSwitch(enabled: false, backend: nil)
        ),
        coverage: Coverage(
            inputDurationS: 8,
            processedDurationS: complete ? 8 : 6,
            truncated: !complete,
            strategy: .full,
            chunksPlanned: 1,
            chunksCompleted: complete ? 1 : 0,
            message: complete
                ? nil
                : "promoted 6.000 s of 8.000 s; 1 range(s) produced no transcript: [6.000, 8.000) s"
        ),
        chunkBoundaries: [
            ChunkBoundary(
                index: 0,
                startS: 0,
                endS: complete ? 8 : 6,
                status: complete ? .succeeded : .failed
            ),
        ],
        timing: RunTiming(
            startedAt: "2026-09-01T12:27:02Z",
            finishedAt: "2026-09-01T12:47:02Z",
            wallTimeS: 1_200
        ),
        artifacts: [
            Artifact(
                kind: "merged_segments",
                path: "merged/segments.json",
                sha256: try derivedLayerSHA256(of: segmentsURL)
            ),
            Artifact(
                kind: "merged_conflicts",
                path: "merged/conflicts.json",
                sha256: try derivedLayerSHA256(of: conflictsURL)
            ),
            Artifact(
                kind: "primary_raw",
                path: "primary/raw.txt",
                sha256: try derivedLayerSHA256(of: rawURL)
            ),
            Artifact(
                kind: "primary_segments",
                path: "primary/segments.json",
                sha256: try derivedLayerSHA256(of: primarySegmentsURL)
            ),
            Artifact(
                kind: "diarization_timeline",
                path: "diarization/timeline.json",
                sha256: try derivedLayerSHA256(of: timelineURL)
            ),
        ] + partialArtifacts,
        // The sentence shape the CLI seals on a partial run, in this fixture's
        // numbers: what was promoted, out of what, and which range was lost.
        failure: complete
            ? nil
            : Failure(
                code: "ASR_REPETITION_LOOPING",
                message: "promoted 6.000 s of 8.000 s; 1 range(s) produced no transcript after repetition looping exhausted recovery: [6.000, 8.000) s"
            )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(manifest).write(
        to: runURL.appendingPathComponent("manifest.json")
    )
    return DerivedLayerRunFixture(
        runURL: runURL,
        segmentsURL: segmentsURL,
        conflictsURL: conflictsURL,
        transcript: transcript,
        conflicts: conflicts,
        manifest: manifest
    )
}

private func derivedLayerBatching(
    batchesPlanned: Int = 1,
    observing batches: [TranslationBatchRecord] = []
) -> ManifestPostprocessBatching {
    ManifestPostprocessBatching(
        maximumPromptUTF8Bytes: 16_384,
        maximumSegmentsPerBatch: 32,
        maximumOutputTokens: nil,
        outputTokenLimitStatus: .serviceManagedUnavailable,
        outputTokenPlanningBudget: 4_096,
        outputTokensPerInputUTF8BytePermille: 2_000,
        baseOutputTokenReserve: 32,
        perSegmentOutputTokenReserve: 96,
        batchesPlanned: batchesPlanned,
        maximumObservedPromptUTF8Bytes: batches.map(\.promptUTF8Bytes).max() ?? 4_285,
        maximumObservedInputTextUTF8Bytes: batches.map(\.inputTextUTF8Bytes).max() ?? 1_541,
        maximumObservedEstimatedOutputTokens: batches.map(\.estimatedOutputTokens).max() ?? 3_690,
        maximumObservedOutputTextUTF8Bytes: batches.map(\.outputTextUTF8Bytes).max() ?? 270,
        maximumObservedResponseUTF8Bytes: batches.map(\.responseUTF8Bytes).max() ?? 527,
        maximumObservedAcceptedOutputTokenUpperBound:
            batches.map(\.acceptedOutputTokenUpperBound).max() ?? 847
    )
}

private func derivedLayerBatch(segmentIndices: [Int]) -> TranslationBatchRecord {
    TranslationBatchRecord(
        batchIndex: 0,
        segmentIndices: segmentIndices,
        promptUTF8Bytes: 4_285,
        inputTextUTF8Bytes: 1_541,
        estimatedOutputTokens: 3_690,
        outputTextUTF8Bytes: 270,
        responseUTF8Bytes: 527,
        acceptedOutputTokenUpperBound: 847
    )
}

/// The translation batch record the repository recomputes and compares against.
/// Derived from the actual texts with the same formula rather than written out,
/// so the fixture cannot drift away from the contract it is meant to satisfy.
private func derivedLayerTranslationBatch(
    sourceTexts: [String],
    translatedTexts: [String],
    batching: ManifestPostprocessBatching
) -> TranslationBatchRecord {
    let inputTextUTF8Bytes = sourceTexts.reduce(0) { $0 + $1.utf8.count }
    let outputTextUTF8Bytes = translatedTexts.reduce(0) { $0 + $1.utf8.count }
    let segmentCount = sourceTexts.count
    func upperBound(_ textUTF8Bytes: Int) -> Int {
        textUTF8Bytes
            + batching.baseOutputTokenReserve
            + segmentCount * batching.perSegmentOutputTokenReserve
    }
    let scaled = inputTextUTF8Bytes * batching.outputTokensPerInputUTF8BytePermille
    let responseUTF8Bytes = outputTextUTF8Bytes + 29
    return TranslationBatchRecord(
        batchIndex: 0,
        segmentIndices: Array(sourceTexts.indices),
        promptUTF8Bytes: 200,
        inputTextUTF8Bytes: inputTextUTF8Bytes,
        estimatedOutputTokens: upperBound((scaled + 999) / 1_000),
        outputTextUTF8Bytes: outputTextUTF8Bytes,
        responseUTF8Bytes: responseUTF8Bytes,
        acceptedOutputTokenUpperBound: upperBound(responseUTF8Bytes)
    )
}

/// Writes a sealed speaker-proposal derived set exactly as the CLI does, with
/// named holes for the ways one can lie about its source.
private func derivedLayerWriteSpeakerProposal(
    fixture: DerivedLayerRunFixture,
    id: String,
    finishedAt: String,
    overrideKind: String? = nil,
    proposedSpeakerForSegmentOne: String = "SPEAKER_00",
    omitDeclines: Bool = false,
    /// Move segment 1 from the proposals to the declines, so two sets over one
    /// run can carry the same name and different counts.
    declineSegmentOne: Bool = false,
    extraProposalOnAttributedSegment: Bool = false,
    inflateFirstCandidateShare: Bool = false,
    claimCompleteCoverage: Bool = false,
    /// The last hook: rewrite the sealed declines. A decline explains why no
    /// speaker was proposed, and every way of lying about that lies in a field
    /// the hash still covers.
    rewritingDeclines: ([SpeakerProposalDecline]) -> [SpeakerProposalDecline] = { $0 }
) throws {
    let source = try RunIntegrityVerifier.verifyMergedRun(at: fixture.runURL)
    let directory = fixture.runURL.appendingPathComponent(
        "derived/\(id)",
        isDirectory: true
    )
    let speakerDirectory = directory.appendingPathComponent("speaker", isDirectory: true)
    try FileManager.default.createDirectory(
        at: speakerDirectory,
        withIntermediateDirectories: true
    )
    let coverage = claimCompleteCoverage
        ? DerivedSourceCoverage(
            complete: true,
            inputDurationS: source.coverage.inputDurationS,
            processedDurationS: source.coverage.inputDurationS,
            message: nil
        )
        : source.coverage

    func candidates(at index: Int) -> [SpeakerCandidateEvidence] {
        let attribution = fixture.conflicts
            .first { $0.segmentIndex == index }?
            .speakerAttribution
        let mapped = (attribution?.candidates ?? []).map {
            SpeakerCandidateEvidence(
                speaker: $0.speaker,
                overlapS: $0.overlapS,
                share: $0.share
            )
        }
        guard inflateFirstCandidateShare, index == 1, var first = mapped.first else {
            return mapped
        }
        first.share = 0.75
        return [first] + mapped.dropFirst()
    }

    var proposals = declineSegmentOne ? [] : [
        SpeakerProposal(
            segmentIndex: 1,
            proposedSpeaker: proposedSpeakerForSegmentOne,
            reason: "The preceding turn continues the same speaker's explanation.",
            acousticOutcome: SpeakerAttributionOutcome.noDominantSpeaker.rawValue,
            acousticTimelineCoverage: 0.9,
            acousticCandidates: candidates(at: 1)
        ),
    ]
    if extraProposalOnAttributedSegment {
        proposals.append(
            SpeakerProposal(
                segmentIndex: 0,
                proposedSpeaker: "SPEAKER_01",
                reason: "An overriding proposal, which must be refused.",
                acousticOutcome: SpeakerAttributionOutcome.attributed.rawValue,
                acousticTimelineCoverage: 1,
                acousticCandidates: []
            )
        )
    }
    var declined = omitDeclines ? [] : [
        SpeakerProposalDecline(
            segmentIndex: 2,
            reason: "The two speakers held equal overlap, so there is no top-ranked candidate to confirm.",
            acousticOutcome: SpeakerAttributionOutcome.noDominantSpeaker.rawValue,
            acousticTimelineCoverage: 0.95,
            acousticCandidates: candidates(at: 2),
            cause: .noTopRankedCandidate,
            topRankedCandidate: nil,
            modelAnswer: SpeakerProposalDecision(
                segmentIndex: 2,
                proposedSpeaker: "SPEAKER_00",
                disposition: .propose,
                reason: "The model named a speaker the acoustics did not single out."
            )
        ),
    ]
    if declineSegmentOne, !omitDeclines {
        declined.insert(
            SpeakerProposalDecline(
                segmentIndex: 1,
                reason: "The model would not say which of the two was speaking.",
                acousticOutcome: SpeakerAttributionOutcome.noDominantSpeaker.rawValue,
                acousticTimelineCoverage: 0.9,
                acousticCandidates: candidates(at: 1),
                cause: .modelDeclined,
                topRankedCandidate: "SPEAKER_00",
                modelAnswer: SpeakerProposalDecision(
                    segmentIndex: 1,
                    proposedSpeaker: "",
                    disposition: .decline,
                    reason: "The model would not say which of the two was speaking."
                )
            ),
            at: 0
        )
    }
    let document = SpeakerProposalDocument(
        sourceSegmentsSHA256: source.lineage.segmentsSHA256,
        sourceCoverage: coverage,
        constraint: .confirmOrDecline,
        proposals: proposals,
        declined: rewritingDeclines(declined),
        batches: [derivedLayerBatch(segmentIndices: [1, 2])]
    )
    let artifactURL = speakerDirectory.appendingPathComponent("proposals.json")
    try JSONEncoder().encode(document).write(to: artifactURL)

    let operation = DerivedOperation(
        profileName: "ko-meeting",
        mode: .correction,
        targetLanguage: nil,
        glossarySemantics: .currentProfile,
        glossarySHA256: nil,
        glossaryItemCount: 0,
        kind: .speakerProposal,
        sourceCoverage: coverage
    )
    let manifest = DerivedManifest(
        derivedID: id,
        status: .succeeded,
        source: source.lineage,
        operation: operation,
        timing: RunTiming(
            startedAt: "2026-09-01T23:09:50Z",
            finishedAt: finishedAt,
            wallTimeS: 197
        ),
        artifacts: [
            Artifact(
                kind: "speaker_proposals",
                path: "speaker/proposals.json",
                sha256: try derivedLayerSHA256(of: artifactURL)
            ),
        ],
        failure: nil,
        postprocess: ManifestPostprocess(
            backend: BackendDescriptor(name: "fixture", version: "1"),
            modelID: "fixture/proposer",
            glossarySHA256: nil,
            mode: .correction,
            sourceSegmentsSHA256: source.lineage.segmentsSHA256,
            batching: derivedLayerBatching()
        )
    )
    var encoded = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(manifest)
    ) as! [String: Any]
    if let overrideKind {
        var operationObject = encoded["operation"] as! [String: Any]
        operationObject["kind"] = overrideKind
        encoded["operation"] = operationObject
    }
    try JSONSerialization
        .data(withJSONObject: encoded, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent("manifest.json"))
}

private func derivedLayerWriteCorrection(
    fixture: DerivedLayerRunFixture,
    id: String,
    finishedAt: String,
    text: String
) throws {
    let source = try RunIntegrityVerifier.verifyMergedRun(at: fixture.runURL)
    let directory = fixture.runURL.appendingPathComponent(
        "derived/\(id)",
        isDirectory: true
    )
    let postprocessDirectory = directory.appendingPathComponent(
        "postprocess",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: postprocessDirectory,
        withIntermediateDirectories: true
    )
    var document = fixture.transcript
    document.segments[0].text = text
    let segmentsURL = postprocessDirectory.appendingPathComponent("segments.json")
    let conflictsURL = postprocessDirectory.appendingPathComponent("conflicts.json")
    try JSONEncoder().encode(document).write(to: segmentsURL)
    try JSONEncoder().encode([PostprocessConflict]()).write(to: conflictsURL)
    let manifest = DerivedManifest(
        derivedID: id,
        status: .succeeded,
        source: source.lineage,
        operation: DerivedOperation(
            profileName: "ko-meeting",
            mode: .correction,
            glossarySemantics: .currentProfile,
            glossarySHA256: nil,
            glossaryItemCount: 0
        ),
        timing: RunTiming(
            startedAt: "2026-09-01T09:00:00Z",
            finishedAt: finishedAt,
            wallTimeS: 1
        ),
        artifacts: [
            Artifact(
                kind: "postprocess_segments",
                path: "postprocess/segments.json",
                sha256: try derivedLayerSHA256(of: segmentsURL)
            ),
            Artifact(
                kind: "postprocess_conflicts",
                path: "postprocess/conflicts.json",
                sha256: try derivedLayerSHA256(of: conflictsURL)
            ),
        ],
        failure: nil,
        postprocess: ManifestPostprocess(
            backend: BackendDescriptor(name: "fixture", version: "1"),
            modelID: "fixture/postprocess",
            glossarySHA256: nil,
            mode: .correction,
            batching: derivedLayerBatching()
        )
    )
    try JSONEncoder().encode(manifest).write(
        to: directory.appendingPathComponent("manifest.json")
    )
}

private func derivedLayerWriteTranslation(
    fixture: DerivedLayerRunFixture,
    id: String,
    finishedAt: String,
    targetLanguage: String
) throws {
    let source = try RunIntegrityVerifier.verifyMergedRun(at: fixture.runURL)
    let directory = fixture.runURL.appendingPathComponent(
        "derived/\(id)",
        isDirectory: true
    )
    let postprocessDirectory = directory.appendingPathComponent(
        "postprocess",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: postprocessDirectory,
        withIntermediateDirectories: true
    )
    let sourceTexts = fixture.transcript.segments.map(\.text)
    let translatedTexts = sourceTexts.map { "\(targetLanguage): \($0)" }
    let batch = derivedLayerTranslationBatch(
        sourceTexts: sourceTexts,
        translatedTexts: translatedTexts,
        batching: derivedLayerBatching()
    )
    // The observed maxima the repository recomputes have to be the ones this
    // batch actually shows, so they are taken from it rather than written out.
    let batching = derivedLayerBatching(observing: [batch])
    let translation = TranslationDocument(
        targetLanguage: targetLanguage,
        sourceSegmentsSHA256: source.lineage.segmentsSHA256,
        batches: [batch],
        translations: translatedTexts.enumerated().map { index, text in
            SegmentTranslation(segmentIndex: index, translatedText: text)
        }
    )
    let translationURL = postprocessDirectory.appendingPathComponent("translation.json")
    try JSONEncoder().encode(translation).write(to: translationURL)
    let manifest = DerivedManifest(
        derivedID: id,
        status: .succeeded,
        source: source.lineage,
        operation: DerivedOperation(
            profileName: "ko-meeting",
            mode: .translation,
            targetLanguage: targetLanguage,
            glossarySemantics: .currentProfile,
            glossarySHA256: nil,
            glossaryItemCount: 0
        ),
        timing: RunTiming(
            startedAt: "2026-09-01T09:00:00Z",
            finishedAt: finishedAt,
            wallTimeS: 1
        ),
        artifacts: [
            Artifact(
                kind: "postprocess_translation",
                path: "postprocess/translation.json",
                sha256: try derivedLayerSHA256(of: translationURL)
            ),
        ],
        failure: nil,
        postprocess: ManifestPostprocess(
            backend: BackendDescriptor(name: "fixture", version: "1"),
            modelID: "fixture/postprocess",
            glossarySHA256: nil,
            mode: .translation,
            targetLanguage: targetLanguage,
            sourceSegmentsSHA256: source.lineage.segmentsSHA256,
            batching: batching
        )
    )
    try JSONEncoder().encode(manifest).write(
        to: directory.appendingPathComponent("manifest.json")
    )
}
