import Foundation
import MaccheroniCore
import MaccheroniPostprocess
import Testing
@testable import MaccheroniApp

/// The proposal artifact names speakers by the merger's global speaker ID
/// while the reading surface shows the reader's own names. The artifact
/// cannot carry the names — they are assigned later and change — so the IDs
/// are rendered when a sentence is read, through one pure helper. These tests
/// pin what that helper recognises, and what it must leave alone.
struct SpeakerReasonRenderingTests {
    private let names = ["0": "Jina", "1": "Marco"]

    private func name(_ speaker: String) -> String {
        names[speaker] ?? "Speaker \(speaker)"
    }

    private func render(_ reason: String, speakers: [String] = ["0", "1"]) -> String {
        SpeakerReasonRendering.render(reason, speakers: speakers, displayName: name)
    }

    @Test
    func theSpeakerTokenIsRenderedWithTheDisplayNameWhateverItsCase() {
        #expect(
            render("speaker 1 answers the question speaker 0 just asked")
                == "Marco answers the question Jina just asked"
        )
        #expect(render("Speaker 0 is mid-sentence here.") == "Jina is mid-sentence here.")
        #expect(render("SPEAKER 1 continues") == "Marco continues")
        // A possessive and sentence punctuation follow the name directly.
        #expect(render("speaker 0's turn, then speaker 1.") == "Jina's turn, then Marco.")
    }

    @Test
    func aBareDigitIsNeverTakenForASpeaker() {
        // `1` is a segment number, a count, and half of `0.5`; only the
        // `speaker <id>` form is a speaker.
        let reason = "segment 1 follows 0.5 s after segment 0, 1 second before speaker 1"
        #expect(render(reason) == "segment 1 follows 0.5 s after segment 0, 1 second before Marco")
        #expect(render("0 and 1 hold equal overlap") == "0 and 1 hold equal overlap")
    }

    @Test
    func anIDTheRunDoesNotKnowIsLeftExactlyAsWritten() {
        #expect(render("speaker 7 was never resolved by this run") == "speaker 7 was never resolved by this run")
        // `1` must not match inside `10`, and `speaker` must be a whole word.
        #expect(render("speaker 10 and speaker 1") == "speaker 10 and Marco")
        #expect(render("loudspeaker 1 was on") == "loudspeaker 1 was on")
        #expect(render("no speakers named", speakers: []) == "no speakers named")
        #expect(render("", speakers: ["0"]) == "")
    }

    @Test
    func longerIDsWinOverTheirOwnPrefixes() {
        let legacy = ["SPEAKER_00": "Jina", "SPEAKER_0": "Marco"]
        let rendered = SpeakerReasonRendering.render(
            "speaker SPEAKER_00 replies to speaker SPEAKER_0",
            speakers: legacy.keys
        ) { legacy[$0] ?? $0 }
        #expect(rendered == "Jina replies to Marco")
    }

    @Test
    func aKoreanAnswerIsRenderedThroughItsOwnWordAndKeepsItsParticle() {
        // The real run's Korean answers wrote `화자 0`; the particle that
        // follows an ID directly stays where it is.
        #expect(render("화자 0이 질문에 답한다") == "Jina이 질문에 답한다")
        #expect(render("화자 1의 문장이 이어진다") == "Marco의 문장이 이어진다")
        // Korean prose around a Latin token, which is what the prompt asks for.
        #expect(render("speaker 1가 speaker 0의 질문에 답한다") == "Marco가 Jina의 질문에 답한다")
        // The ordinal form the same run also wrote, ID first.
        #expect(render("0번 화자가 1번 화자의 말을 잇는다") == "Jina가 Marco의 말을 잇는다")
        #expect(render("10번 화자는 없다") == "10번 화자는 없다")
    }

    @Test
    func theLegacyTieSentenceIsRenderedThroughItsBareIDs() {
        // Sealed artifacts written before 2026-09-04 name a tie's speakers as
        // bare IDs inside one fixed runner sentence. They are never rewritten
        // (D52), so that sentence is recognised as written.
        let reason = "Declined under confirm-or-decline: the acoustic candidates 0 and 1 hold equal overlap, so there is no top-ranked candidate to confirm. The model proposed speaker 1: 1 is mid-answer."
        #expect(
            render(reason)
                == "Declined under confirm-or-decline: the acoustic candidates Jina and Marco hold equal overlap, so there is no top-ranked candidate to confirm. The model proposed Marco: 1 is mid-answer."
        )
        // Three-way ties list every speaker; an unknown one stays.
        #expect(
            render("the acoustic candidates 0, 1 and 2 hold equal overlap", speakers: ["0", "1", "2"])
                == "the acoustic candidates Jina, Marco and Speaker 2 hold equal overlap"
        )
        #expect(
            render("the acoustic candidates 0 and 9 hold equal overlap")
                == "the acoustic candidates 0 and 9 hold equal overlap"
        )
    }

    @Test
    func theCurrentRunnerSentencesRenderEndToEnd() {
        // The sentences `SpeakerProposer` writes today, with every speaker
        // in the token form.
        #expect(
            render("Speaker 0 and speaker 1 held the same time in this segment, so there was nobody to confirm and no speaker is proposed. The model also declined: either could be answering.")
                == "Jina and Marco held the same time in this segment, so there was nobody to confirm and no speaker is proposed. The model also declined: either could be answering."
        )
        #expect(
            render("The conversation pointed to speaker 1, but speaker 0 held the most of this segment's speech, 57% of it, and only that speaker could be confirmed, so no speaker is proposed. The model's reason: speaker 1 answers speaker 0")
                == "The conversation pointed to Marco, but Jina held the most of this segment's speech, 57% of it, and only that speaker could be confirmed, so no speaker is proposed. The model's reason: Marco answers Jina"
        )
    }

    @Test
    func aDisplayNameWithPatternCharactersIsInsertedLiterally() {
        let odd = ["0": "R$D \\1 (lead)"]
        let rendered = SpeakerReasonRendering.render(
            "speaker 0 opens",
            speakers: ["0"]
        ) { odd[$0] ?? $0 }
        #expect(rendered == "R$D \\1 (lead) opens")
    }

    @Test
    func aDocumentKeepsEveryIDFieldAndRendersOnlyItsSentences() {
        let candidates = [
            SpeakerCandidateEvidence(speaker: "0", overlapS: 1.2, share: 0.6),
            SpeakerCandidateEvidence(speaker: "1", overlapS: 0.8, share: 0.4),
        ]
        let answer = SpeakerProposalDecision(
            segmentIndex: 4,
            proposedSpeaker: "1",
            disposition: .propose,
            reason: "speaker 1 is answering"
        )
        let document = SpeakerProposalDocument(
            sourceSegmentsSHA256: String(repeating: "a", count: 64),
            sourceCoverage: DerivedSourceCoverage(
                complete: true,
                inputDurationS: 10,
                processedDurationS: 10,
                message: nil
            ),
            constraint: .confirmOrDecline,
            proposals: [
                SpeakerProposal(
                    segmentIndex: 2,
                    proposedSpeaker: "0",
                    reason: "speaker 0 asked and keeps the floor",
                    acousticOutcome: "no_dominant_speaker",
                    acousticTimelineCoverage: 0.9,
                    acousticCandidates: candidates
                ),
            ],
            declined: [
                SpeakerProposalDecline(
                    segmentIndex: 4,
                    reason: "The conversation pointed to speaker 1, but speaker 0 held the most of this segment's speech, 60% of it, and only that speaker could be confirmed, so no speaker is proposed. The model's reason: speaker 1 is answering",
                    acousticOutcome: "no_dominant_speaker",
                    acousticTimelineCoverage: 0.9,
                    acousticCandidates: candidates,
                    cause: .modelDisagreedWithTopRankedCandidate,
                    topRankedCandidate: "0",
                    modelAnswer: answer
                ),
            ],
            batches: []
        )

        let rendered = SpeakerReasonRendering.render(
            document,
            speakers: ["0", "1"],
            displayName: name
        )

        #expect(rendered.proposals[0].reason == "Jina asked and keeps the floor")
        #expect(rendered.proposals[0].proposedSpeaker == "0")
        #expect(rendered.proposals[0].acousticCandidates == candidates)
        let decline = rendered.declined[0]
        #expect(decline.reason == "The conversation pointed to Marco, but Jina held the most of this segment's speech, 60% of it, and only that speaker could be confirmed, so no speaker is proposed. The model's reason: Marco is answering")
        #expect(decline.topRankedCandidate == "0")
        #expect(decline.acousticCandidates == candidates)
        #expect(decline.cause == .modelDisagreedWithTopRankedCandidate)
        #expect(decline.modelAnswer?.reason == "Marco is answering")
        #expect(decline.modelAnswer?.proposedSpeaker == "1")
        #expect(decline.modelAnswer?.segmentIndex == 4)
        // Everything that is not a sentence is byte-for-byte the input.
        var expected = document
        expected.proposals[0].reason = rendered.proposals[0].reason
        expected.declined[0].reason = decline.reason
        expected.declined[0].modelAnswer?.reason = "Marco is answering"
        #expect(rendered == expected)
    }

    @Test @MainActor
    func aLoadedRunRendersWithTheRecordsCurrentNamesAndTheRosterFallback() {
        var fixture = TranscriptFixtures.meetingShaped()
        let unattributed = fixture.run.transcript.segments.firstIndex {
            UnattributedSpeaker.isUnattributed($0.speaker)
        }!
        fixture.run.speakerProposal = SpeakerProposalDocument(
            sourceSegmentsSHA256: String(repeating: "b", count: 64),
            sourceCoverage: DerivedSourceCoverage(
                complete: true,
                inputDurationS: 10,
                processedDurationS: 10,
                message: nil
            ),
            constraint: .confirmOrDecline,
            proposals: [
                SpeakerProposal(
                    segmentIndex: unattributed,
                    proposedSpeaker: "0",
                    reason: "speaker 0 answers speaker 1, and speaker 2 is nobody",
                    acousticOutcome: "no_dominant_speaker",
                    acousticTimelineCoverage: 0.9,
                    acousticCandidates: [
                        SpeakerCandidateEvidence(speaker: "0", overlapS: 1, share: 0.55),
                        SpeakerCandidateEvidence(speaker: "1", overlapS: 0.8, share: 0.45),
                    ]
                ),
            ],
            declined: [],
            batches: []
        )
        let en = Locale(identifier: "en")
        #expect(fixture.run.resolvedSpeakerIDs == ["0", "1"])

        // One speaker named by the reader, the other still on the roster's
        // worded fallback, and the ID this run never resolved left alone.
        fixture.record.speakerNames = ["0": "Jina"]
        let named = fixture.run.speakerProposal(renderedFor: fixture.record, locale: en)
        #expect(named?.proposals[0].reason == "Jina answers Speaker 1, and speaker 2 is nobody")
        #expect(named?.proposals[0].proposedSpeaker == "0")

        // A rename after the proposal exists is reflected at the next read:
        // the artifact keeps the IDs and nothing was stored.
        fixture.record.speakerNames = ["0": "Jina", "1": "Marco"]
        let renamed = fixture.run.speakerProposal(renderedFor: fixture.record, locale: en)
        #expect(renamed?.proposals[0].reason == "Jina answers Marco, and speaker 2 is nobody")
        #expect(fixture.run.speakerProposal?.proposals[0].reason == "speaker 0 answers speaker 1, and speaker 2 is nobody")

        var without = fixture.run
        without.speakerProposal = nil
        #expect(without.speakerProposal(renderedFor: fixture.record) == nil)
    }

    @Test
    func theRecordsDisplayNameFallsBackToTheRosterWording() {
        var record = TranscriptFixtures.meetingShaped().record
        record.speakerNames = ["0": "Jina", "1": "   "]
        let en = Locale(identifier: "en")
        #expect(record.displayName(forSpeaker: "0", locale: en) == "Jina")
        // An empty name is no name; a whitespace-only one was never saved,
        // and if it were it is still shown rather than rendering blank.
        #expect(record.displayName(forSpeaker: "1", locale: en) == "   ")
        record.speakerNames = ["0": ""]
        #expect(record.displayName(forSpeaker: "0", locale: en) == "Speaker 0")
        #expect(record.displayName(forSpeaker: "1", locale: en) == "Speaker 1")
    }
}
