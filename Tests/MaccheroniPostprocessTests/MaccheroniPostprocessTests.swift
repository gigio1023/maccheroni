import Darwin
import CryptoKit
import Foundation
import Testing
@testable import MaccheroniCore
@testable import MaccheroniPostprocess

@Suite(.serialized) struct MaccheroniPostprocessTests {
    private func document() -> SegmentsDocument {
        SegmentsDocument(
            segments: [
                Segment(speaker: "S01", startS: 0, endS: 2.5, text: "Codex clii 실행", language: "ko", confidence: 0.8, flags: ["existing"]),
                Segment(speaker: "S02", startS: 2.5, endS: 5, text: "Maccheroni", language: "en", confidence: 0.9, flags: ["uncertain", "conflict"]),
            ],
            numSpeakers: 2,
            source: SourceAudio(fileName: "private.m4a", sha256: "sensitive-source-hash", durationS: 5)
        )
    }

    private func glossary() throws -> Glossary {
        try Glossary.parse(data: Data("# terms\nCodex CLI\nMaccheroni\n".utf8))
    }

    private var correctionGlossaryGuidance: String {
        "Use INPUT.glossary.entries as supporting context for likely transcription errors. The entries are terms the speaker was expected to use, not required output. Do not insert or substitute a glossary term unless the segment plausibly contains that spoken term. If such a correction is plausible but uncertain, use review."
    }

    private func correctionPromptParts(
        _ prompt: String
    ) throws -> (instruction: String, input: [String: Any]) {
        let marker = "\nINPUT:\n"
        let range = try #require(prompt.range(of: marker))
        let payload = String(prompt[range.upperBound...])
        return (
            instruction: String(prompt[..<range.lowerBound]),
            input: try #require(
                JSONSerialization.jsonObject(with: Data(payload.utf8))
                    as? [String: Any]
            )
        )
    }

    // MARK: - Marked non-acoustic speaker proposal

    private static let sourceHash = String(repeating: "a", count: 64)

    /// Segment 1 has an top-ranked candidate below the bar — "0" at 0.573, the
    /// measured 17.3 s against 12.9 s case scaled to a 2 s segment — segment
    /// 3 has no diarization turn at all, and segment 4 is a tie inside the
    /// merger's margin, which no threshold resolves; segments 0 and 2 are
    /// acoustically assigned.
    private func speakerProposalDocument() -> SegmentsDocument {
        SegmentsDocument(
            segments: [
                Segment(speaker: "0", startS: 0, endS: 2, text: "그래서 이거 언제까지죠"),
                Segment(speaker: "UNKNOWN", startS: 2, endS: 4, text: "다음 주 금요일이요"),
                Segment(speaker: "1", startS: 4, endS: 6, text: "알겠습니다"),
                Segment(speaker: "UNASSIGNED", startS: 6, endS: 8, text: "네"),
                Segment(speaker: "UNKNOWN", startS: 8, endS: 10, text: "그럼 그때 뵙죠"),
            ],
            numSpeakers: 2,
            source: SourceAudio(
                fileName: "meeting.m4a",
                sha256: String(repeating: "b", count: 64),
                durationS: 10
            )
        )
    }

    private func speakerProposalEvidence() -> [SegmentSpeakerEvidence] {
        [
            SegmentSpeakerEvidence(
                segmentIndex: 1,
                outcome: "no_dominant_speaker",
                candidates: [
                    SpeakerCandidateEvidence(speaker: "0", overlapS: 1.146, share: 0.573),
                    SpeakerCandidateEvidence(speaker: "1", overlapS: 0.854, share: 0.427),
                ],
                timelineCoverage: 0.97
            ),
            SegmentSpeakerEvidence(
                segmentIndex: 3,
                outcome: "no_overlapping_turn",
                candidates: [],
                timelineCoverage: 0
            ),
            SegmentSpeakerEvidence(
                segmentIndex: 4,
                outcome: "no_dominant_speaker",
                candidates: [
                    SpeakerCandidateEvidence(
                        speaker: "0",
                        overlapS: 1.0000000000000002,
                        share: 0.5000000000000001
                    ),
                    SpeakerCandidateEvidence(
                        speaker: "1",
                        overlapS: 0.9999999999999998,
                        share: 0.4999999999999999
                    ),
                ],
                timelineCoverage: 0.97
            ),
        ]
    }

    /// A source that lost 0.5 s of its 10 s, so the incompleteness has to
    /// reach the artifact rather than only the manifest.
    private func speakerProposalCoverage() -> DerivedSourceCoverage {
        DerivedSourceCoverage(
            complete: false,
            inputDurationS: 10,
            processedDurationS: 9.5,
            message: "1 range(s) produced no transcript: [4.0, 4.5) s"
        )
    }

    private func speakerProposalRequest() -> SpeakerProposalRequest {
        SpeakerProposalRequest(
            document: speakerProposalDocument(),
            evidence: speakerProposalEvidence(),
            sourceSegmentsSHA256: Self.sourceHash,
            sourceCoverage: speakerProposalCoverage()
        )
    }

    @Test
    func aSpeakerProposalCarriesTheAcousticCandidatesItCouldNotSettle() async throws {
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [
                SpeakerProposalDecision(
                    segmentIndex: 1,
                    proposedSpeaker: "0",
                    disposition: .propose,
                    reason: "answers the question the same speaker asked"
                ),
                SpeakerProposalDecision(
                    segmentIndex: 3,
                    proposedSpeaker: "",
                    disposition: .decline,
                    reason: "a bare acknowledgement either speaker could give"
                ),
            ])
        ).propose(speakerProposalRequest())

        #expect(result.document.layer == "speaker-proposal")
        #expect(result.document.constraint == .confirmOrDecline)
        #expect(result.document.sourceSegmentsSHA256 == Self.sourceHash)
        #expect(result.document.proposals.map(\.segmentIndex) == [1])
        #expect(result.document.declined.map(\.segmentIndex) == [3, 4])
        let proposal = try #require(result.document.proposals.first)
        #expect(proposal.proposedSpeaker == "0")
        #expect(proposal.acousticOutcome == "no_dominant_speaker")
        // The shares travel unrounded: what the merger computed is what the
        // reader sees beside the proposal.
        #expect(proposal.acousticCandidates == speakerProposalEvidence()[0].candidates)
        #expect(proposal.acousticTimelineCoverage == 0.97)
        let noTurn = result.document.declined[0]
        #expect(noTurn.acousticOutcome == "no_overlapping_turn")
        #expect(noTurn.acousticCandidates.isEmpty)
        // With nothing to confirm, the constraint is the cause even though the
        // model declined as well; the model's own decline is kept beside it.
        #expect(noTurn.cause == .noAcousticCandidates)
        #expect(noTurn.topRankedCandidate == nil)
        #expect(noTurn.modelAnswer?.disposition == .decline)
        #expect(noTurn.reason.contains(
            "The model also declined: a bare acknowledgement either speaker could give"
        ))
        let silent = result.document.declined[1]
        #expect(silent.cause == .noDecision)
        #expect(silent.modelAnswer == nil)
        // The source's incompleteness is stated in the artifact that carries
        // the proposals, not only in the manifest beside it.
        #expect(result.document.sourceCoverage == speakerProposalCoverage())
        #expect(result.document.sourceCoverage.missingDurationS == 0.5)
        #expect(result.document.sourceCoverage.message?.isEmpty == false)
        #expect(result.manifestPostprocess.sourceSegmentsSHA256 == Self.sourceHash)
        #expect(result.manifestPostprocess.inputMode == .textOnly)
        #expect(result.manifestPostprocess.batching?.batchesPlanned == 1)
    }

    @Test
    func aProposalNeverLandsOnAnAcousticallyAssignedSegment() async throws {
        // Segment 2 already has speaker "1"; a decision about it is the
        // layering going wrong, not a merge conflict to resolve.
        await #expect(throws: PostprocessError.speakerProposalOverridesAssignedSpeaker(
            segmentIndex: 2,
            speaker: "0"
        )) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [
                    SpeakerProposalDecision(
                        segmentIndex: 2,
                        proposedSpeaker: "0",
                        disposition: .propose,
                        reason: "should never be accepted"
                    ),
                ])
            ).propose(self.speakerProposalRequest())
        }
    }

    @Test
    func aProposalNamesOnlyASpeakerTheAcousticsPutInPlay() async throws {
        await #expect(throws: PostprocessError.speakerProposalNotACandidate(
            segmentIndex: 1,
            speaker: "7"
        )) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [
                    SpeakerProposalDecision(
                        segmentIndex: 1,
                        proposedSpeaker: "7",
                        disposition: .propose,
                        reason: "a speaker no turn ever held"
                    ),
                ])
            ).propose(self.speakerProposalRequest())
        }
    }

    @Test
    func aSegmentWithNoOverlappingTurnIsAlwaysDeclinedAndKeepsTheModelsAnswer() async throws {
        let answer = SpeakerProposalDecision(
            segmentIndex: 3,
            proposedSpeaker: "1",
            disposition: .propose,
            reason: "continues the same speaker's turn"
        )
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [answer])
        ).propose(speakerProposalRequest())
        // No candidate means no top-ranked candidate to confirm, so the answer is recorded
        // as evidence rather than applied.
        #expect(result.document.proposals.isEmpty)
        #expect(result.document.declined.map(\.segmentIndex) == [1, 3, 4])
        let decline = result.document.declined[1]
        #expect(decline.segmentIndex == 3)
        #expect(decline.cause == .noAcousticCandidates)
        #expect(decline.topRankedCandidate == nil)
        #expect(decline.modelAnswer == answer)
        // The runner's own sentence is read by a person whenever this app
        // has no sentence of its own for the cause, so it is plain language
        // that names speakers only in the renderable `speaker <id>` form.
        #expect(decline.reason.contains(
            "No speaker was active on the speaker timeline during this segment, so there was nobody to confirm and no speaker is proposed."
        ))
        #expect(decline.reason.contains(
            "The model proposed speaker 1: continues the same speaker's turn"
        ))

        // A speaker the run never resolved is still malformed output, not
        // evidence worth keeping.
        await #expect(throws: PostprocessError.speakerProposalNotACandidate(
            segmentIndex: 3,
            speaker: "9"
        )) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [
                    SpeakerProposalDecision(
                        segmentIndex: 3,
                        proposedSpeaker: "9",
                        disposition: .propose,
                        reason: "invented"
                    ),
                ])
            ).propose(self.speakerProposalRequest())
        }
    }

    @Test
    func aDeclineMayNotSmuggleASpeakerAndAReasonIsAlwaysRequired() async throws {
        await #expect(throws: PostprocessError.speakerDeclineNamesSpeaker(
            segmentIndex: 1,
            speaker: "0"
        )) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [
                    SpeakerProposalDecision(
                        segmentIndex: 1,
                        proposedSpeaker: "0",
                        disposition: .decline,
                        reason: "declined but still naming someone"
                    ),
                ])
            ).propose(self.speakerProposalRequest())
        }
        await #expect(throws: PostprocessError.emptySpeakerProposalReason(1)) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [
                    SpeakerProposalDecision(
                        segmentIndex: 1,
                        proposedSpeaker: "0",
                        disposition: .propose,
                        reason: "   "
                    ),
                ])
            ).propose(self.speakerProposalRequest())
        }
    }

    @Test
    func aSilentProposerLeavesTheArtifactHonestRatherThanEmpty() async throws {
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [])
        ).propose(speakerProposalRequest())
        #expect(result.document.proposals.isEmpty)
        #expect(result.document.declined.map(\.segmentIndex) == [1, 3, 4])
        // Every unattributed segment is still accounted for, with what the
        // acoustics held, a stated reason, and the top-ranked candidate that went unconfirmed.
        #expect(result.document.declined.allSatisfy { !$0.reason.isEmpty })
        #expect(result.document.declined.allSatisfy { $0.cause == .noDecision })
        #expect(result.document.declined.map(\.topRankedCandidate) == ["0", nil, nil])
        #expect(result.document.declined[0].acousticCandidates.count == 2)
    }

    @Test
    func aRunWithNothingUnattributedHasNothingToPropose() async throws {
        var document = speakerProposalDocument()
        document.segments[1].speaker = "0"
        document.segments[3].speaker = "1"
        document.segments[4].speaker = "1"
        await #expect(throws: PostprocessError.noUnattributedSegments) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [])
            ).propose(SpeakerProposalRequest(
                document: document,
                evidence: [],
                sourceSegmentsSHA256: Self.sourceHash,
                sourceCoverage: self.speakerProposalCoverage()
            ))
        }
    }

    @Test
    func everyUnattributedSegmentNeedsItsAcousticRecordBeforeAnyProposalRuns() async throws {
        await #expect(throws: PostprocessError.speakerEvidenceMissing(3)) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [])
            ).propose(SpeakerProposalRequest(
                document: self.speakerProposalDocument(),
                evidence: [self.speakerProposalEvidence()[0]],
                sourceSegmentsSHA256: Self.sourceHash,
                sourceCoverage: self.speakerProposalCoverage()
            ))
        }
        await #expect(throws: PostprocessError.speakerEvidenceForAttributedSegment(0)) {
            _ = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [])
            ).propose(SpeakerProposalRequest(
                document: self.speakerProposalDocument(),
                evidence: self.speakerProposalEvidence() + [
                    SegmentSpeakerEvidence(
                        segmentIndex: 0,
                        outcome: "attributed",
                        candidates: [],
                        timelineCoverage: 1
                    ),
                ],
                sourceSegmentsSHA256: Self.sourceHash,
                sourceCoverage: self.speakerProposalCoverage()
            ))
        }
    }

    @Test
    func theSpeakerPromptMarksTargetsAndShowsTheSharesThatDidNotDecide() async throws {
        let recorder = SpeakerPromptRecorder()
        _ = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [], recorder: recorder)
        ).propose(speakerProposalRequest())
        let prompt = try #require(recorder.prompts.first)
        let parts = try correctionPromptParts(prompt)

        #expect(parts.instruction.contains("proposal for human review"))
        #expect(parts.instruction.contains("never changes it"))
        #expect(parts.instruction.contains("A decline is a correct answer"))
        // The constraint is stated to the model, not only enforced behind it.
        #expect(parts.instruction.hasPrefix("Confirm or decline a speaker"))
        #expect(parts.instruction.contains("Propose only to confirm top_ranked_candidate"))
        #expect(parts.instruction.contains("Never propose any other speaker"))
        #expect(parts.instruction.contains("Decline when top_ranked_candidate is null"))
        // The one field a person reads is written for that person: speakers
        // only in the `speaker <id>` form the reading surface can render with
        // a name, none of this prompt's own vocabulary, in the transcript's
        // language. The schema is untouched.
        #expect(parts.instruction.contains(SpeakerProposalPrompt.reasonInstruction))
        #expect(SpeakerProposalPrompt.reasonInstruction.contains("for example speaker 0"))
        #expect(SpeakerProposalPrompt.reasonInstruction.contains("never by a name, a role, or a bare number"))
        for leaked in ["candidates", "shares", "overlap", "seconds", "acoustics", "diarization", "targets", "confirmation"] {
            #expect(SpeakerProposalPrompt.reasonInstruction.contains(leaked), "the instruction must forbid \(leaked)")
        }
        #expect(SpeakerProposalPrompt.reasonInstruction.contains("language the transcript is written in"))
        #expect(parts.input["known_speakers"] as? [String] == ["0", "1"])
        let segments = try #require(parts.input["segments"] as? [[String: Any]])
        #expect(segments.count == 5)
        #expect(segments.map { $0["target"] as? Bool } == [false, true, false, true, true])
        // Context segments carry their acoustic speaker and no candidate list;
        // targets carry the candidates and no speaker.
        #expect(segments[0]["speaker"] as? String == "0")
        #expect(segments[0]["acoustic_candidates"] == nil)
        #expect(segments[0]["top_ranked_candidate"] == nil)
        #expect(segments[1]["speaker"] == nil)
        let candidates = try #require(
            segments[1]["acoustic_candidates"] as? [[String: Any]]
        )
        #expect(candidates.map { $0["speaker"] as? String } == ["0", "1"])
        #expect(candidates.map { $0["share"] as? Double } == [0.573, 0.427])
        #expect(segments[1]["acoustic_outcome"] as? String == "no_dominant_speaker")
        // Every target names its top-ranked candidate explicitly, as null when there is
        // none: the rounded shares cannot carry that distinction.
        #expect(segments[1]["top_ranked_candidate"] as? String == "0")
        #expect(segments[3]["top_ranked_candidate"] is NSNull)
        #expect(segments[4]["top_ranked_candidate"] is NSNull)
        let tied = try #require(
            segments[4]["acoustic_candidates"] as? [[String: Any]]
        )
        #expect(tied.map { $0["share"] as? Double } == [0.5, 0.5])
        // No timing, and no speaker for a target: the proposer is given text
        // and shares, never the acoustic decision it is meant to complement.
        #expect(segments[1]["start_s"] == nil)
        #expect(segments[1]["end_s"] == nil)
    }

    /// The instruction is a fixed overhead on every batch. It must stay a
    /// small fraction of the prompt budget so the planner still packs real
    /// segments, and the fixture must still fit in one batch under the
    /// policy the proposal lane runs on; both are checked here rather than
    /// assumed after the 2026-09-04 wording change. Measured: 1,855 bytes
    /// before that change, 2,434 after. The local backend's 2,048-byte budget
    /// was already below the old instruction plus one segment, so it could
    /// not run a proposal before and cannot now; the Codex budget is the one
    /// a proposal actually runs under, and no budget is changed here.
    @Test
    func theSpeakerPromptInstructionLeavesTheBudgetToTheSegments() async throws {
        let recorder = SpeakerPromptRecorder()
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [], recorder: recorder)
        ).propose(speakerProposalRequest())
        let prompt = try #require(recorder.prompts.first)
        let parts = try correctionPromptParts(prompt)
        let instructionBytes = parts.instruction.utf8.count
        let policy = CodexPostprocessBackend.defaultBatchPolicy
        #expect(policy.maximumPromptUTF8Bytes == 16_384)
        #expect(instructionBytes * 4 <= policy.maximumPromptUTF8Bytes)
        #expect(prompt.utf8.count <= policy.maximumPromptUTF8Bytes)
        #expect(result.manifestPostprocess.batching?.batchesPlanned == 1)
        #expect(result.document.batches.map(\.promptUTF8Bytes) == [prompt.utf8.count])
    }

    // MARK: Confirm-or-decline (PROJECT.md D50)

    @Test
    func anOverturnOfTheTopRankedCandidateIsRecordedAsADeclineThatKeepsBothAnswers() async throws {
        let answer = SpeakerProposalDecision(
            segmentIndex: 1,
            proposedSpeaker: "1",
            disposition: .propose,
            reason: "replies to the question speaker 0 just asked"
        )
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [answer])
        ).propose(speakerProposalRequest())

        #expect(result.document.constraint == .confirmOrDecline)
        #expect(result.document.proposals.isEmpty)
        #expect(result.document.declined.map(\.segmentIndex) == [1, 3, 4])
        let decline = result.document.declined[0]
        #expect(decline.cause == .modelDisagreedWithTopRankedCandidate)
        #expect(decline.topRankedCandidate == "0")
        #expect(decline.modelAnswer == answer)
        #expect(decline.reason == "The conversation pointed to speaker 1, but speaker 0 held the most of this segment's speech, 57% of it, and only that speaker could be confirmed, so no speaker is proposed. The model's reason: replies to the question speaker 0 just asked")
        // The acoustic evidence beside the decline is the merger's, untouched.
        #expect(decline.acousticOutcome == "no_dominant_speaker")
        #expect(decline.acousticCandidates == speakerProposalEvidence()[0].candidates)
        #expect(decline.acousticTimelineCoverage == 0.97)
    }

    @Test
    func aTieHasNoTopRankedCandidateToConfirmSoItIsDeclinedWhateverTheModelSays() async throws {
        for answer in [
            SpeakerProposalDecision(segmentIndex: 4, proposedSpeaker: "0", disposition: .propose, reason: "the lower id"),
            SpeakerProposalDecision(segmentIndex: 4, proposedSpeaker: "1", disposition: .propose, reason: "the higher id"),
            SpeakerProposalDecision(segmentIndex: 4, proposedSpeaker: "", disposition: .decline, reason: "nothing to confirm"),
        ] {
            let result = try await SpeakerProposer(
                backend: StubSpeakerProposalBackend(decisions: [answer])
            ).propose(speakerProposalRequest())
            #expect(result.document.proposals.isEmpty)
            let decline = try #require(
                result.document.declined.first { $0.segmentIndex == 4 }
            )
            #expect(decline.cause == .noTopRankedCandidate)
            #expect(decline.topRankedCandidate == nil)
            #expect(decline.modelAnswer == answer)
            #expect(decline.reason.hasPrefix(
                "Speaker 0 and speaker 1 held the same time in this segment, so there was nobody to confirm and no speaker is proposed. "
            ))
            #expect(decline.reason.contains(answer.reason))
        }
    }

    @Test
    func aModelDeclineOnARankedSegmentRecordsTheTopRankedCandidateItDidNotConfirm() async throws {
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [
                SpeakerProposalDecision(
                    segmentIndex: 1,
                    proposedSpeaker: "",
                    disposition: .decline,
                    reason: "both speakers are mid-sentence here"
                ),
            ])
        ).propose(speakerProposalRequest())
        let decline = result.document.declined[0]
        #expect(decline.segmentIndex == 1)
        #expect(decline.cause == .modelDeclined)
        #expect(decline.topRankedCandidate == "0")
        #expect(decline.modelAnswer == nil)
        // The model's own words are the reason; nothing is prepended to them.
        #expect(decline.reason == "both speakers are mid-sentence here")
    }

    @Test
    func everyUnattributedSegmentStillAppearsExactlyOnceUnderTheConstraint() async throws {
        // One confirmation, one overturn converted, one tie converted: the
        // exactly-once rule over proposals plus declined is what makes the
        // constraint auditable from the artifact alone.
        let result = try await SpeakerProposer(
            backend: StubSpeakerProposalBackend(decisions: [
                SpeakerProposalDecision(segmentIndex: 1, proposedSpeaker: "0", disposition: .propose, reason: "confirms"),
                SpeakerProposalDecision(segmentIndex: 3, proposedSpeaker: "0", disposition: .propose, reason: "no candidate"),
                SpeakerProposalDecision(segmentIndex: 4, proposedSpeaker: "1", disposition: .propose, reason: "tie"),
            ])
        ).propose(speakerProposalRequest())
        #expect(result.document.proposals.map(\.segmentIndex) == [1])
        #expect(result.document.declined.map(\.segmentIndex) == [3, 4])
        #expect(result.document.declined.map(\.cause) == [.noAcousticCandidates, .noTopRankedCandidate])
        #expect(result.document.declined.compactMap(\.modelAnswer?.proposedSpeaker) == ["0", "1"])
        let covered = result.document.proposals.map(\.segmentIndex)
            + result.document.declined.map(\.segmentIndex)
        #expect(covered.sorted() == [1, 3, 4])
    }

    @Test
    func theTopRankedCandidateIsUniqueInsideTheMergersMargin() {
        func candidate(_ speaker: String, _ overlapS: Double) -> SpeakerCandidateEvidence {
            SpeakerCandidateEvidence(speaker: speaker, overlapS: overlapS, share: 0)
        }
        #expect(SpeakerProposalConstraint.topRankedCandidate(among: []) == nil)
        #expect(SpeakerProposalConstraint.topRankedCandidate(among: [candidate("1", 0.3)]) == "1")
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: [candidate("0", 17.3), candidate("1", 12.9)]
        ) == "0")
        // The top-ranked candidate is the largest overlap, not the first entry.
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: [candidate("0", 12.9), candidate("1", 17.3)]
        ) == "1")
        // Inside the merger's 1e-9 s margin is a tie; outside it is not.
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: [candidate("0", 1.0 + 1e-10), candidate("1", 1.0)]
        ) == nil)
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: [candidate("0", 1.0 + 2e-9), candidate("1", 1.0)]
        ) == "0")
        // Two tied at the top with a third below is still no top-ranked candidate; one
        // clear top over two tied below is.
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: [candidate("0", 2), candidate("1", 2), candidate("2", 1)]
        ) == nil)
        #expect(SpeakerProposalConstraint.topRankedCandidate(
            among: [candidate("0", 3), candidate("1", 2), candidate("2", 2)]
        ) == "0")
    }

    @Test
    func theConstraintIsNamedInTheArtifactAndOlderArtifactsStillDecode() throws {
        let answer = SpeakerProposalDecision(
            segmentIndex: 1,
            proposedSpeaker: "1",
            disposition: .propose,
            reason: "r"
        )
        let document = SpeakerProposalDocument(
            sourceSegmentsSHA256: Self.sourceHash,
            sourceCoverage: speakerProposalCoverage(),
            constraint: .confirmOrDecline,
            proposals: [],
            declined: [
                SpeakerProposalDecline(
                    segmentIndex: 1,
                    reason: "converted",
                    acousticOutcome: "no_dominant_speaker",
                    acousticTimelineCoverage: 0.97,
                    acousticCandidates: speakerProposalEvidence()[0].candidates,
                    cause: .modelDisagreedWithTopRankedCandidate,
                    topRankedCandidate: "0",
                    modelAnswer: answer
                ),
                SpeakerProposalDecline(
                    segmentIndex: 3,
                    reason: "silent",
                    acousticOutcome: "no_overlapping_turn",
                    acousticTimelineCoverage: 0,
                    acousticCandidates: [],
                    cause: .noDecision
                ),
            ],
            batches: []
        )
        let data = try JSONEncoder().encode(document)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["constraint"] as? String == "confirm-or-decline")
        let declined = try #require(json["declined"] as? [[String: Any]])
        #expect(declined[0]["cause"] as? String == "model_disagreed_with_top_ranked_candidate")
        #expect(declined[0]["top_ranked_candidate"] as? String == "0")
        let modelAnswer = try #require(declined[0]["model_answer"] as? [String: Any])
        #expect(modelAnswer["proposed_speaker"] as? String == "1")
        #expect(modelAnswer["disposition"] as? String == "propose")
        #expect(modelAnswer["reason"] as? String == "r")
        // Absent evidence is absent, not null: a key is written only when it
        // carries something.
        #expect(declined[1]["cause"] as? String == "no_decision")
        #expect(declined[1]["top_ranked_candidate"] == nil)
        #expect(declined[1]["model_answer"] == nil)
        #expect(try JSONDecoder().decode(SpeakerProposalDocument.self, from: data) == document)

        // An artifact written before the constraint existed still decodes,
        // and nothing is invented for it.
        var legacy = json
        legacy["constraint"] = nil
        legacy["declined"] = declined.map { record in
            var stripped = record
            stripped["cause"] = nil
            stripped["top_ranked_candidate"] = nil
            stripped["model_answer"] = nil
            return stripped
        }
        let decoded = try JSONDecoder().decode(
            SpeakerProposalDocument.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.constraint == nil)
        #expect(decoded.declined.map(\.segmentIndex) == [1, 3])
        #expect(decoded.declined.allSatisfy { $0.cause == nil })
        #expect(decoded.declined.allSatisfy { $0.topRankedCandidate == nil })
        #expect(decoded.declined.allSatisfy { $0.modelAnswer == nil })
    }

    @Test
    func speakerProposalOutputMustBeExactlyItsSchema() async throws {
        func backend(_ payload: String) -> LocalPostprocessBackend {
            LocalPostprocessBackend(
                runtime: LocalPostprocessRuntime(
                    pythonExecutableURL: URL(fileURLWithPath: "/tests/python"),
                    runnerURL: URL(fileURLWithPath: "/tests/runner.py"),
                    modelSnapshotURL: URL(fileURLWithPath: "/tests/model")
                ),
                executor: MockExecutor(output: Data(payload.utf8))
            )
        }
        for payload in [
            #"{"speaker_proposals":[],"extra":1}"#,
            #"{"proposals":[]}"#,
            #"{"speaker_proposals":[{"segment_index":0,"proposed_speaker":"0","disposition":"propose"}]}"#,
            #"{"speaker_proposals":[{"segment_index":0,"proposed_speaker":"0","disposition":"propose","reason":"r","extra":1}]}"#,
        ] {
            await #expect(throws: PostprocessError.self) {
                _ = try await backend(payload).proposeSpeakers(prompt: "x")
            }
        }
        let accepted = try await backend(
            #"{"speaker_proposals":[{"segment_index":0,"proposed_speaker":"","disposition":"decline","reason":"r"}]}"#
        ).proposeSpeakers(prompt: "x")
        #expect(accepted.decisions == [SpeakerProposalDecision(
            segmentIndex: 0,
            proposedSpeaker: "",
            disposition: .decline,
            reason: "r"
        )])
    }

    @Test
    func theLocalRunnerIsAskedForTheSpeakerProposalMode() async throws {
        let recorder = InvocationRecorder()
        let backend = LocalPostprocessBackend(
            runtime: LocalPostprocessRuntime(
                pythonExecutableURL: URL(fileURLWithPath: "/tests/python"),
                runnerURL: URL(fileURLWithPath: "/tests/runner.py"),
                modelSnapshotURL: URL(fileURLWithPath: "/tests/model")
            ),
            executor: MockExecutor(
                recorder: recorder,
                output: Data(#"{"speaker_proposals":[]}"#.utf8)
            )
        )
        _ = try await backend.proposeSpeakers(prompt: "x")
        let invocation = try #require(recorder.invocations.first)
        #expect(invocation.arguments.contains("speaker-proposal"))
        #expect(invocation.environment["HF_HUB_OFFLINE"] == "1")
    }

    private func expectRegularPackagedFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil)
    }

    @Test func packagedPostprocessRunnerAndPinsAreAdjacentRegularFiles() throws {
        let runtime = LocalPostprocessRuntime.localRuntime(
            environment: [:],
            home: URL(fileURLWithPath: "/packaged-postprocess-test", isDirectory: true)
        )
        let resourceDirectory = runtime.runnerURL.deletingLastPathComponent()

        for name in ["maccheroni_postprocess_runner.py", "pyproject.toml", "uv.lock"] {
            try expectRegularPackagedFile(resourceDirectory.appendingPathComponent(name))
        }
        #expect(runtime.runnerURL.lastPathComponent == "maccheroni_postprocess_runner.py")
    }

    @Test func appliesConfidentCorrectionAndPreservesStructure() async throws {
        let input = document()
        let backend = StubBackend(proposals: [
            PostprocessProposal(segmentIndex: 0, replacementText: "Codex CLI 실행", disposition: .apply, reason: "known product name"),
        ])
        let result = try await TranscriptPostprocessor(backend: backend).process(PostprocessRequest(document: input))

        #expect(result.document.segments[0].text == "Codex CLI 실행")
        #expect(result.document.segments[0].speaker == input.segments[0].speaker)
        #expect(result.document.segments[0].startS == input.segments[0].startS)
        #expect(result.document.segments[0].endS == input.segments[0].endS)
        #expect(result.document.segments[0].language == input.segments[0].language)
        #expect(result.document.segments[0].confidence == input.segments[0].confidence)
        #expect(result.document.segments[0].flags == input.segments[0].flags)
        #expect(result.document.source == input.source)
        #expect(result.document.numSpeakers == input.numSpeakers)
        #expect(result.document.segments.count == input.segments.count)
        #expect(result.conflicts.isEmpty)
    }

    @Test func retainsUncertainCorrectionAsConflictWithDeduplicatedFlags() async throws {
        let input = document()
        let backend = StubBackend(proposals: [
            PostprocessProposal(segmentIndex: 1, replacementText: "Maccheroni app", disposition: .review, reason: "possible name expansion"),
        ])
        let result = try await TranscriptPostprocessor(backend: backend).process(PostprocessRequest(document: input))

        #expect(result.document.segments[1].text == "Maccheroni")
        #expect(result.document.segments[1].flags == ["uncertain", "conflict"])
        #expect(result.conflicts == [PostprocessConflict(
            segmentIndex: 1,
            originalText: "Maccheroni",
            candidateText: "Maccheroni app",
            reason: "possible name expansion"
        )])
    }

    @Test(arguments: [
        PostprocessProposal(segmentIndex: 0, replacementText: "x", disposition: .apply, reason: "a"),
        PostprocessProposal(segmentIndex: 0, replacementText: "y", disposition: .review, reason: "b"),
    ]) func rejectsDuplicateIndices(_ second: PostprocessProposal) async throws {
        let backend = StubBackend(proposals: [
            PostprocessProposal(segmentIndex: 0, replacementText: "x", disposition: .apply, reason: "a"), second,
        ])
        await #expect(throws: PostprocessError.duplicateSegmentIndex(0)) {
            _ = try await TranscriptPostprocessor(backend: backend).process(PostprocessRequest(document: document()))
        }
    }

    @Test func rejectsOutOfRangeAndEmptyReplacements() async throws {
        let outOfRange = StubBackend(proposals: [
            PostprocessProposal(segmentIndex: 2, replacementText: "x", disposition: .apply, reason: "a"),
        ])
        await #expect(throws: PostprocessError.segmentIndexOutOfRange(2)) {
            _ = try await TranscriptPostprocessor(backend: outOfRange).process(PostprocessRequest(document: document()))
        }
        let empty = StubBackend(proposals: [
            PostprocessProposal(segmentIndex: 0, replacementText: " \n", disposition: .apply, reason: "a"),
        ])
        await #expect(throws: PostprocessError.emptyReplacementText(0)) {
            _ = try await TranscriptPostprocessor(backend: empty).process(PostprocessRequest(document: document()))
        }
    }

    @Test func localMetadataAndOfflineSnapshotInvocationAreExact() async throws {
        let recorder = InvocationRecorder()
        let runtime = LocalPostprocessRuntime(
            pythonExecutableURL: URL(fileURLWithPath: "/tests/python"),
            runnerURL: URL(fileURLWithPath: "/tests/runner.py"),
            modelSnapshotURL: URL(fileURLWithPath: "/snapshots/gemma/e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6")
        )
        let backend = LocalPostprocessBackend(runtime: runtime, executor: MockExecutor(recorder: recorder, output: validOutput))
        let parsedGlossary = try glossary()
        let result = try await TranscriptPostprocessor(backend: backend).process(PostprocessRequest(document: document(), glossary: parsedGlossary))

        #expect(backend.id == .local)
        #expect(backend.manifestPostprocess.backend == BackendDescriptor(name: "mlx-vlm", version: "0.6.6"))
        #expect(backend.model == ModelDescriptor(role: .postprocess, hfModelID: "mlx-community/gemma-4-12B-it-qat-4bit", revision: "e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6", quantization: "qat-int4"))
        #expect(result.manifestPostprocess.modelRevision == "e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6")
        #expect(result.manifestPostprocess.glossarySHA256 == parsedGlossary.sha256)
        let invocation = try #require(recorder.invocations.first)
        #expect(invocation.executableURL.path == "/tests/python")
        #expect(invocation.arguments == [
            "/tests/runner.py", "--model-path",
            "/snapshots/gemma/e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6",
            "--mode", "correction", "--max-tokens", "1024",
        ])
        #expect(invocation.environment == ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"])
    }

    @Test func correctionPromptUsesSuppliedGlossaryAndPinsCorrectionContract() throws {
        let parsedGlossary = try glossary()
        let parts = try correctionPromptParts(PostprocessPrompt.make(for: PostprocessRequest(
            document: document(),
            glossary: parsedGlossary
        )))

        #expect(parts.instruction == """
        Correct transcript text only. Do not infer or output speaker labels, timing, source, or metadata.
        \(correctionGlossaryGuidance)
        Return exactly one JSON object with this shape and no commentary:
        {"proposals":[{"segment_index":0,"replacement_text":"corrected full segment text","disposition":"apply","reason":"brief reason"}]}
        The only root key is proposals. Every proposal has exactly segment_index, replacement_text, disposition, and reason. disposition is apply or review. Use apply only when the correction is certain; otherwise use review. Return {"proposals":[]} when no correction is needed.
        """)
        #expect(Set(parts.input.keys) == ["glossary", "segments"])
        let glossaryInput = try #require(parts.input["glossary"] as? [String: Any])
        #expect(Set(glossaryInput.keys) == ["entries", "sha256"])
        #expect(glossaryInput["entries"] as? [String] == ["Codex CLI", "Maccheroni"])
        #expect(glossaryInput["sha256"] as? String == parsedGlossary.sha256)
        let segments = try #require(parts.input["segments"] as? [[String: Any]])
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { Set($0.keys) == ["segment_index", "text"] })
    }

    @Test func correctionPromptOmitsGlossaryGuidanceWithoutEntries() throws {
        let emptyGlossary = try Glossary.parse(data: Data("# no terms\n".utf8))
        let expectedInstruction = """
        Correct transcript text only. Do not infer or output speaker labels, timing, source, or metadata.
        Return exactly one JSON object with this shape and no commentary:
        {"proposals":[{"segment_index":0,"replacement_text":"corrected full segment text","disposition":"apply","reason":"brief reason"}]}
        The only root key is proposals. Every proposal has exactly segment_index, replacement_text, disposition, and reason. disposition is apply or review. Use apply only when the correction is certain; otherwise use review. Return {"proposals":[]} when no correction is needed.
        """

        for glossary in [Optional<Glossary>.none, emptyGlossary] {
            let parts = try correctionPromptParts(PostprocessPrompt.make(for: PostprocessRequest(
                document: document(),
                glossary: glossary
            )))
            #expect(parts.instruction == expectedInstruction)
            #expect(!parts.instruction.contains("INPUT.glossary.entries"))
            let glossaryInput = try #require(parts.input["glossary"] as? [String: Any])
            #expect(glossaryInput["entries"] as? [String] == [])
        }
    }

    @Test func bothBackendsReceiveTheIdenticalTextOnlyGlossaryPrompt() async throws {
        let codexRecorder = CodexInvocationRecorder()
        let localRecorder = InvocationRecorder()
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let codex = CodexPostprocessBackend(
            codexExecutableURL: URL(fileURLWithPath: "/tests/codex"),
            codexVersion: "9.9.9",
            schemaURL: schema,
            temporaryDirectory: root,
            appServerExecutor: MockCodexAppServerExecutor(
                recorder: codexRecorder,
                output: validOutput
            )
        )
        let local = LocalPostprocessBackend(
            runtime: LocalPostprocessRuntime(pythonExecutableURL: URL(fileURLWithPath: "/tests/python"), runnerURL: URL(fileURLWithPath: "/tests/runner.py"), modelSnapshotURL: URL(fileURLWithPath: "/snapshot")),
            executor: MockExecutor(recorder: localRecorder, output: validOutput)
        )
        let request = PostprocessRequest(document: document(), glossary: try glossary())
        _ = try await TranscriptPostprocessor(backend: codex).process(request)
        _ = try await TranscriptPostprocessor(backend: local).process(request)

        let codexInput = try #require(codexRecorder.invocations.first).prompt
        let localInput = String(decoding: try #require(localRecorder.invocations.first).standardInput, as: UTF8.self)
        #expect(codexInput == localInput)
        #expect(codexInput.contains(correctionGlossaryGuidance))
        #expect(codexInput.contains(try glossary().sha256))
        #expect(codexInput.contains("Codex CLI"))
        #expect(!codexInput.contains("private.m4a"))
        #expect(!codexInput.contains("sensitive-source-hash"))
        #expect(!codexInput.contains("S01"))
        #expect(!codexInput.contains("start_s"))
    }

    @Test func correctionPromptBoundaryIsAcceptedBelowAndAtLimitThenRejectedAbove() async throws {
        let parsedGlossary = try glossary()
        func request(text: String, glossary: Glossary?) -> PostprocessRequest {
            PostprocessRequest(
                document: SegmentsDocument(
                    segments: [Segment(speaker: "S", startS: 0, endS: 1, text: text)],
                    numSpeakers: 1,
                    source: SourceAudio(
                        fileName: "ignored.wav",
                        sha256: String(repeating: "d", count: 64),
                        durationS: 1
                    )
                ),
                glossary: glossary
            )
        }
        let below = request(text: "a", glossary: parsedGlossary)
        let at = request(text: "aa", glossary: parsedGlossary)
        let above = request(text: "aaa", glossary: parsedGlossary)
        let maximum = try PostprocessPrompt.make(for: at).utf8.count
        #expect(try PostprocessPrompt.make(for: below).utf8.count == maximum - 1)
        #expect(try PostprocessPrompt.make(for: above).utf8.count == maximum + 1)
        let guidedInstruction = try correctionPromptParts(
            PostprocessPrompt.make(for: at)
        ).instruction
        let bareInstruction = try correctionPromptParts(PostprocessPrompt.make(for: request(
            text: "aa",
            glossary: nil
        ))).instruction
        #expect(
            guidedInstruction.utf8.count - bareInstruction.utf8.count
                == correctionGlossaryGuidance.utf8.count + 1
        )
        let fixturePromptUTF8Bytes = try PostprocessPrompt.make(for: PostprocessRequest(
            document: document(),
            glossary: parsedGlossary
        )).utf8.count
        #expect(fixturePromptUTF8Bytes == 1_120)
        #expect(
            LocalPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes
                - fixturePromptUTF8Bytes == 928
        )
        #expect(
            CodexPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes
                - fixturePromptUTF8Bytes == 15_264
        )
        let fixtureEstimatedOutputTokens =
            LocalPostprocessBackend.defaultBatchPolicy.estimatedOutputTokens(
                inputTextUTF8Bytes: 27,
                segmentCount: 2
            )
        #expect(fixtureEstimatedOutputTokens == 278)
        #expect(
            LocalPostprocessBackend.defaultBatchPolicy.outputTokenPlanningBudget
                - fixtureEstimatedOutputTokens == 490
        )

        let localSaturatingRequest = request(
            text: String(repeating: "a", count: 320),
            glossary: parsedGlossary
        )
        let localSaturatingPromptUTF8Bytes = try PostprocessPrompt.make(
            for: localSaturatingRequest
        ).utf8.count
        #expect(localSaturatingPromptUTF8Bytes == 1_383)
        #expect(
            LocalPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes
                - localSaturatingPromptUTF8Bytes == 665
        )
        #expect(
            LocalPostprocessBackend.defaultBatchPolicy.estimatedOutputTokens(
                inputTextUTF8Bytes: 320,
                segmentCount: 1
            ) == 768
        )

        let codexSaturatingRequest = request(
            text: String(repeating: "a", count: 1_984),
            glossary: parsedGlossary
        )
        let codexSaturatingPromptUTF8Bytes = try PostprocessPrompt.make(
            for: codexSaturatingRequest
        ).utf8.count
        #expect(codexSaturatingPromptUTF8Bytes == 3_047)
        #expect(
            CodexPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes
                - codexSaturatingPromptUTF8Bytes == 13_337
        )
        #expect(
            CodexPostprocessBackend.defaultBatchPolicy.estimatedOutputTokens(
                inputTextUTF8Bytes: 1_984,
                segmentCount: 1
            ) == 4_096
        )

        let policy = PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: maximum,
            maximumSegmentsPerBatch: 8,
            maximumOutputTokens: 1_024,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 768,
            outputTokensPerInputUTF8BytePermille: 2_000,
            baseOutputTokenReserve: 32,
            perSegmentOutputTokenReserve: 96
        )
        let recorder = CorrectionPromptRecorder()
        let processor = TranscriptPostprocessor(
            backend: EchoCorrectionBackend(policy: policy, recorder: recorder)
        )

        _ = try await processor.process(below)
        let atResult = try await processor.process(at)
        await #expect(throws: PostprocessError.batchPromptTooLarge(
            segmentIndex: 0,
            promptUTF8Bytes: maximum + 1,
            maximum: maximum
        )) {
            _ = try await processor.process(above)
        }
        #expect(recorder.prompts.count == 2)
        #expect(atResult.manifestPostprocess.batching?.batchesPlanned == 1)
        #expect(atResult.manifestPostprocess.batching?.maximumObservedPromptUTF8Bytes
            == maximum)
        #expect(atResult.manifestPostprocess.batching?.maximumObservedInputTextUTF8Bytes
            == 2)
        #expect(atResult.manifestPostprocess.batching?.maximumObservedEstimatedOutputTokens
            == 132)
        #expect(atResult.manifestPostprocess.batching?.maximumObservedOutputTextUTF8Bytes
            == 0)
        #expect(atResult.manifestPostprocess.batching?.maximumObservedResponseUTF8Bytes
            == 16)
        #expect(atResult.manifestPostprocess.batching?
            .maximumObservedAcceptedOutputTokenUpperBound == 144)
    }

    @Test func codexUsesSchemaConstrainedAppServerInvocation() async throws {
        let recorder = CodexInvocationRecorder()
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let backend = CodexPostprocessBackend(
            codexExecutableURL: URL(fileURLWithPath: "/tests/codex"),
            codexVersion: "1.2.3",
            schemaURL: schema,
            temporaryDirectory: root,
            appServerExecutor: MockCodexAppServerExecutor(
                recorder: recorder,
                output: validOutput
            )
        )
        _ = try await TranscriptPostprocessor(backend: backend).process(PostprocessRequest(document: document()))

        #expect(backend.manifestPostprocess.backend == BackendDescriptor(name: "codex-app-server", version: "1.2.3"))
        #expect(backend.manifestPostprocess.modelID == "gpt-5.6-sol")
        #expect(backend.manifestPostprocess.modelRevision == nil)
        #expect(backend.manifestPostprocess.quantization == nil)
        #expect(backend.model == nil)
        let invocation = try #require(recorder.invocations.first)
        #expect(invocation.executableURL.path == "/tests/codex")
        #expect(invocation.model == "gpt-5.6-sol")
        #expect(invocation.outputSchema == Data("{}".utf8))
        #expect(invocation.workspaceURL.deletingLastPathComponent() == root)
        #expect(invocation.prompt.contains("Codex clii 실행"))
        #expect(!invocation.prompt.contains("private.m4a"))
    }

    @Test func codexPropagatesAppServerFailureAndRejectsMalformedOutput() async throws {
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = root.appendingPathComponent("schema.json")
        try Data("{}".utf8).write(to: schema)
        let authenticated = CodexAvailability.authenticated(version: "codex-cli fixture")
        let failing = CodexPostprocessBackend(
            codexExecutableURL: URL(fileURLWithPath: "/tests/codex"),
            availability: authenticated,
            schemaURL: schema,
            temporaryDirectory: root,
            appServerExecutor: MockCodexAppServerExecutor(
                output: validOutput,
                runError: .backendFailed("codex app server exited 9")
            )
        )
        await #expect(throws: PostprocessError.backendFailed("codex app server exited 9")) {
            _ = try await failing.propose(prompt: "x")
        }
        let malformed = CodexPostprocessBackend(
            codexExecutableURL: URL(fileURLWithPath: "/tests/codex"),
            availability: authenticated,
            schemaURL: schema,
            temporaryDirectory: root,
            appServerExecutor: MockCodexAppServerExecutor(
                output: Data("not-json".utf8)
            )
        )
        do {
            _ = try await malformed.propose(prompt: "x")
            Issue.record("expected malformed Codex output to fail")
        } catch let error as PostprocessError {
            guard case .malformedOutput = error else {
                Issue.record("expected malformedOutput, got \(error)")
                return
            }
        }
    }

    @Test func sanitizedStandardErrorRedactsAbsolutePathsAndKeepsShortTextIntact() {
        #expect(SubprocessFailureMessage.sanitized(
            standardError: Data("model refused the request\n".utf8)
        ) == "model refused the request")
        #expect(SubprocessFailureMessage.sanitized(
            standardError: Data(
                "cannot read /Users/someone/Recordings/private.m4a next to /tmp/x\n".utf8
            )
        ) == "cannot read <redacted-path> next to <redacted-path>")
        #expect(SubprocessFailureMessage.sanitized(standardError: Data()) == "")
    }

    @Test func sanitizedStandardErrorUsesSharedPathRedactionForFileAndHomePaths() {
        let input = "UserInfo={NSFilePath=/Users/private/model.bin} "
            + "home=~/Library/Caches/Maccheroni/model "
            + "url=file:///Users/private/recording.m4a "
            + "remote=https://example.com/reference\n"
        #expect(SubprocessFailureMessage.sanitized(standardError: Data(input.utf8))
            == "UserInfo={NSFilePath=<redacted-path>} "
                + "home=<redacted-path> "
                + "url=<redacted-path> "
                + "remote=https://example.com/reference")
    }

    @Test func sanitizedStandardErrorTruncatesOnlyAboveTheByteLimit() {
        let limit = SubprocessFailureMessage.maximumUTF8Bytes
        let marker = SubprocessFailureMessage.truncationMarker
        func sanitized(asciiBytes: Int) -> String {
            SubprocessFailureMessage.sanitized(
                standardError: Data(String(repeating: "a", count: asciiBytes).utf8)
            )
        }

        #expect(sanitized(asciiBytes: limit - 1) == String(repeating: "a", count: limit - 1))
        #expect(sanitized(asciiBytes: limit) == String(repeating: "a", count: limit))
        let above = sanitized(asciiBytes: limit + 1)
        #expect(above == String(repeating: "a", count: limit - marker.utf8.count) + marker)
        #expect(above.utf8.count == limit)

        let multibyte = SubprocessFailureMessage.sanitized(
            standardError: Data(String(repeating: "가", count: 200).utf8)
        )
        #expect(multibyte == String(repeating: "가", count: 166) + marker)
        #expect(multibyte.utf8.count == limit)
    }

    @Test func localBackendFailuresCarrySanitizedAndBoundedStandardError() async throws {
        let standardError = Data((
            "traceback at /Users/someone/Library/Caches/runner.py line 4: "
                + String(repeating: "e", count: 900) + "\n"
        ).utf8)
        let leadIn = "traceback at <redacted-path> line 4: "
        let expectedTail = leadIn + String(
            repeating: "e",
            count: SubprocessFailureMessage.maximumUTF8Bytes
                - SubprocessFailureMessage.truncationMarker.utf8.count
                - leadIn.utf8.count
        ) + SubprocessFailureMessage.truncationMarker

        let local = LocalPostprocessBackend(
            runtime: LocalPostprocessRuntime(
                pythonExecutableURL: URL(fileURLWithPath: "/tests/python"),
                runnerURL: URL(fileURLWithPath: "/tests/runner.py"),
                modelSnapshotURL: URL(fileURLWithPath: "/tests/snapshot")
            ),
            executor: MockExecutor(
                output: Data(),
                exitStatus: 3,
                standardError: standardError
            )
        )
        await #expect(throws: PostprocessError.backendFailed(
            "local postprocess runner exited 3: " + expectedTail
        )) {
            _ = try await local.propose(prompt: "x")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[
        "MACCHERONI_RUN_LOCAL_POSTPROCESS_INTEGRATION"
    ] == "1"))
    func actualLocalBackendExecutesPinnedTextFixture() async throws {
        let input = integrationDocument()
        let parsedGlossary = try glossary()
        let result = try await TranscriptPostprocessor(
            backend: LocalPostprocessBackend()
        ).process(PostprocessRequest(
            document: input,
            glossary: parsedGlossary
        ))

        expectStructure(result.document, equals: input)
        expectGlossaryCorrection(in: result)
        #expect(result.manifestPostprocess.backend
            == LocalPostprocessBackend.descriptor)
        #expect(result.manifestPostprocess.modelID
            == LocalPostprocessBackend.pinnedModel.hfModelID)
        #expect(result.manifestPostprocess.modelRevision
            == LocalPostprocessBackend.pinnedModel.revision)
        #expect(result.manifestPostprocess.quantization
            == LocalPostprocessBackend.pinnedModel.quantization)
        #expect(result.manifestPostprocess.glossarySHA256
            == parsedGlossary.sha256)
        let batching = try #require(result.manifestPostprocess.batching)
        #expect(batching.maximumOutputTokens == 1_024)
        #expect(batching.outputTokenPlanningBudget == 768)
        #expect(batching.maximumObservedEstimatedOutputTokens > 0)
        #expect(batching.maximumObservedResponseUTF8Bytes > 0)
        #expect(batching.maximumObservedAcceptedOutputTokenUpperBound > 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[
        "MACCHERONI_RUN_CODEX_POSTPROCESS_INTEGRATION"
    ] == "1"))
    func actualCodexBackendExecutesTextOnlyFixture() async throws {
        let input = integrationDocument()
        let parsedGlossary = try glossary()
        let result = try await TranscriptPostprocessor(
            backend: CodexPostprocessBackend()
        ).process(PostprocessRequest(
            document: input,
            glossary: parsedGlossary
        ))

        expectStructure(result.document, equals: input)
        expectGlossaryCorrection(in: result)
        #expect(result.manifestPostprocess.backend.name == "codex-app-server")
        #expect(result.manifestPostprocess.modelID
            == CodexPostprocessBackend.modelName)
        #expect(result.manifestPostprocess.modelRevision == nil)
        #expect(result.manifestPostprocess.quantization == nil)
        #expect(result.manifestPostprocess.glossarySHA256
            == parsedGlossary.sha256)
    }

    @Test func translationUsesContiguousBoundedBatchesAndCannotCarryStructure() async throws {
        let input = document()
        let recorder = TranslationPromptRecorder()
        let policy = PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: 8_192,
            maximumSegmentsPerBatch: 1,
            maximumOutputTokens: 1_024,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 768,
            outputTokensPerInputUTF8BytePermille: 2_000,
            baseOutputTokenReserve: 32,
            perSegmentOutputTokenReserve: 96
        )
        let result = try await TranscriptTranslator(
            backend: EchoTranslationBackend(policy: policy, recorder: recorder)
        ).translate(TranslationRequest(
            document: input,
            targetLanguage: "en",
            sourceSegmentsSHA256: String(repeating: "c", count: 64),
            glossary: try glossary()
        ))

        #expect(recorder.prompts.count == 2)
        #expect(result.document.targetLanguage == "en")
        #expect(result.document.sourceSegmentsSHA256 == String(repeating: "c", count: 64))
        #expect(result.document.batches.map(\.segmentIndices) == [[0], [1]])
        #expect(result.document.translations == [
            SegmentTranslation(segmentIndex: 0, translatedText: "translated-0"),
            SegmentTranslation(segmentIndex: 1, translatedText: "translated-1"),
        ])
        #expect(result.manifestPostprocess.mode == .translation)
        #expect(result.manifestPostprocess.targetLanguage == "en")
        #expect(result.manifestPostprocess.batching?.batchesPlanned == 2)
        #expect(result.document.batches.allSatisfy {
            $0.promptUTF8Bytes <= policy.maximumPromptUTF8Bytes
                && $0.estimatedOutputTokens <= policy.outputTokenPlanningBudget
                && $0.responseUTF8Bytes >= $0.outputTextUTF8Bytes
                && $0.acceptedOutputTokenUpperBound
                    <= policy.outputTokenPlanningBudget
                && $0.acceptedOutputTokenUpperBound
                    == $0.responseUTF8Bytes
                        + policy.baseOutputTokenReserve
                        + ($0.segmentIndices.count * policy.perSegmentOutputTokenReserve)
        })
        #expect(result.manifestPostprocess.batching?.maximumObservedPromptUTF8Bytes
            == result.document.batches.map(\.promptUTF8Bytes).max())
        #expect(result.manifestPostprocess.batching?.maximumObservedInputTextUTF8Bytes
            == result.document.batches.map(\.inputTextUTF8Bytes).max())
        #expect(result.manifestPostprocess.batching?.maximumObservedEstimatedOutputTokens
            == result.document.batches.map(\.estimatedOutputTokens).max())
        #expect(result.manifestPostprocess.batching?.maximumObservedOutputTextUTF8Bytes
            == result.document.batches.map(\.outputTextUTF8Bytes).max())
        #expect(result.manifestPostprocess.batching?.maximumObservedResponseUTF8Bytes
            == result.document.batches.map(\.responseUTF8Bytes).max())
        #expect(result.manifestPostprocess.batching?
            .maximumObservedAcceptedOutputTokenUpperBound
            == result.document.batches.map(\.acceptedOutputTokenUpperBound).max())

        let encoded = String(
            decoding: try JSONEncoder().encode(result.document),
            as: UTF8.self
        )
        for forbidden in ["speaker", "start_s", "end_s", "private.m4a", "sensitive-source-hash"] {
            #expect(!encoded.contains(forbidden))
        }
        for prompt in recorder.prompts {
            #expect(!prompt.contains("S01"))
            #expect(!prompt.contains("start_s"))
            #expect(!prompt.contains("private.m4a"))
            #expect(!prompt.contains("sensitive-source-hash"))
        }
    }

    @Test func translationPromptBoundaryIsAcceptedBelowAndAtLimitThenRejectedAbove() async throws {
        let hash = String(repeating: "d", count: 64)
        func request(text: String) -> TranslationRequest {
            TranslationRequest(
                document: SegmentsDocument(
                    segments: [Segment(speaker: "S", startS: 0, endS: 1, text: text)],
                    numSpeakers: 1,
                    source: SourceAudio(fileName: "ignored.wav", sha256: hash, durationS: 1)
                ),
                targetLanguage: "en",
                sourceSegmentsSHA256: hash
            )
        }
        let below = request(text: "a")
        let at = request(text: "aa")
        let above = request(text: "aaa")
        let maximum = try TranslationPrompt.make(for: at).utf8.count
        #expect(try TranslationPrompt.make(for: below).utf8.count == maximum - 1)
        #expect(try TranslationPrompt.make(for: above).utf8.count == maximum + 1)
        let policy = PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: maximum,
            maximumSegmentsPerBatch: 8,
            maximumOutputTokens: 1_024,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 768,
            outputTokensPerInputUTF8BytePermille: 2_000,
            baseOutputTokenReserve: 32,
            perSegmentOutputTokenReserve: 96
        )
        let backend = EchoTranslationBackend(
            policy: policy,
            recorder: TranslationPromptRecorder()
        )

        _ = try await TranscriptTranslator(backend: backend).translate(below)
        _ = try await TranscriptTranslator(backend: backend).translate(at)
        await #expect(throws: PostprocessError.batchPromptTooLarge(
            segmentIndex: 0,
            promptUTF8Bytes: maximum + 1,
            maximum: maximum
        )) {
            _ = try await TranscriptTranslator(backend: backend).translate(above)
        }
    }

    @Test func codexTranslationUsesGeneratedSchemaAndAuthenticatedModel() async throws {
        let recorder = CodexInvocationRecorder()
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = Data(#"{"translations":[{"segment_index":0,"translated_text":"Hello"}]}"#.utf8)
        let backend = CodexPostprocessBackend(
            codexExecutableURL: URL(fileURLWithPath: "/tests/codex"),
            availability: .authenticated(version: "codex-cli 9.9.9"),
            temporaryDirectory: root,
            appServerExecutor: MockCodexAppServerExecutor(
                recorder: recorder,
                output: output
            )
        )
        let input = SegmentsDocument(
            segments: [Segment(speaker: "S01", startS: 0, endS: 1, text: "Ciao")],
            numSpeakers: 1,
            source: SourceAudio(
                fileName: "synthetic.wav",
                sha256: String(repeating: "0", count: 64),
                durationS: 1
            )
        )
        let result = try await TranscriptTranslator(backend: backend).translate(
            TranslationRequest(
                document: input,
                targetLanguage: "en",
                sourceSegmentsSHA256: String(repeating: "1", count: 64)
            )
        )

        #expect(result.document.translations == [
            SegmentTranslation(segmentIndex: 0, translatedText: "Hello"),
        ])
        #expect(result.manifestPostprocess.modelID == "gpt-5.6-sol")
        #expect(result.manifestPostprocess.backend.version == "codex-cli 9.9.9")
        let invocation = try #require(recorder.invocations.first)
        let schemaObject = try #require(
            JSONSerialization.jsonObject(with: invocation.outputSchema)
                as? [String: Any]
        )
        #expect(schemaObject["required"] as? [String] == ["translations"])
        #expect(invocation.prompt.contains("Ciao"))
        #expect(!invocation.prompt.contains("S01"))
    }

    @Test func codexExecutableLocatorFindsFallbackOutsideGUIPath() throws {
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("homebrew-bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fallback,
            withIntermediateDirectories: false
        )
        let executable = fallback.appendingPathComponent("codex")
        try Data("#!/bin/sh\n".utf8).write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let resolved = CodexExecutableLocator.resolve(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            fallbackDirectories: [fallback]
        )

        #expect(resolved == executable.standardizedFileURL)
    }

    @Test func missingCodexExecutableStaysUnavailableWithoutLaunchingAnything() async throws {
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let searchDirectory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: searchDirectory,
            withIntermediateDirectories: false
        )
        let witness = root.appendingPathComponent("env-was-launched")
        let decoy = searchDirectory.appendingPathComponent("env")
        try Data("""
        #!/bin/sh
        printf 'launched' > '\(witness.path)'
        exit 0
        """.utf8).write(to: decoy, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: decoy.path
        )

        let resolved = CodexExecutableLocator.resolve(
            environment: ["PATH": searchDirectory.path],
            homeDirectory: root.appendingPathComponent("home", isDirectory: true),
            fallbackDirectories: []
        )
        #expect(resolved == nil)
        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: resolved
        ) == .unavailable)

        let recorder = CodexInvocationRecorder()
        let backend = CodexPostprocessBackend(
            codexExecutableURL: resolved,
            appServerExecutor: MockCodexAppServerExecutor(
                recorder: recorder,
                output: validOutput
            )
        )
        #expect(backend.availability == .unavailable)
        #expect(backend.codexVersion == "unavailable")
        await #expect(throws: PostprocessError.launchFailed(
            "codex CLI executable was not found"
        )) {
            _ = try await backend.propose(prompt: "x")
        }
        #expect(recorder.invocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: witness.path))
    }

    @Test func translationOutputBudgetIsAcceptedBelowAndAtLimitThenRejectedAbove() async throws {
        let hash = String(repeating: "e", count: 64)
        func request(textBytes: Int) -> TranslationRequest {
            TranslationRequest(
                document: SegmentsDocument(
                    segments: [Segment(
                        speaker: "S",
                        startS: 0,
                        endS: 1,
                        text: String(repeating: "a", count: textBytes)
                    )],
                    numSpeakers: 1,
                    source: SourceAudio(
                        fileName: "ignored.wav",
                        sha256: hash,
                        durationS: 1
                    )
                ),
                targetLanguage: "en",
                sourceSegmentsSHA256: hash
            )
        }
        let policy = PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: 8_192,
            maximumSegmentsPerBatch: 8,
            maximumOutputTokens: 256,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 200,
            outputTokensPerInputUTF8BytePermille: 1_000,
            baseOutputTokenReserve: 32,
            perSegmentOutputTokenReserve: 96
        )
        let recorder = TranslationPromptRecorder()
        let translator = TranscriptTranslator(
            backend: EchoTranslationBackend(policy: policy, recorder: recorder)
        )

        _ = try await translator.translate(request(textBytes: 71))
        _ = try await translator.translate(request(textBytes: 72))
        await #expect(throws: PostprocessError.batchOutputBudgetTooLarge(
            segmentIndex: 0,
            inputTextUTF8Bytes: 73,
            estimatedOutputTokens: 201,
            maximum: 200
        )) {
            _ = try await translator.translate(request(textBytes: 73))
        }
        #expect(recorder.prompts.count == 2)
    }

    @Test func translationRawResponseBudgetIsAcceptedBelowAndAtLimitThenRejectedAbove() async throws {
        let hash = String(repeating: "f", count: 64)
        let request = TranslationRequest(
            document: SegmentsDocument(
                segments: [Segment(
                    speaker: "S",
                    startS: 0,
                    endS: 1,
                    text: "a"
                )],
                numSpeakers: 1,
                source: SourceAudio(
                    fileName: "ignored.wav",
                    sha256: hash,
                    durationS: 1
                )
            ),
            targetLanguage: "en",
            sourceSegmentsSHA256: hash
        )
        let policy = PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: 8_192,
            maximumSegmentsPerBatch: 8,
            maximumOutputTokens: 256,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 200,
            outputTokensPerInputUTF8BytePermille: 1_000,
            baseOutputTokenReserve: 32,
            perSegmentOutputTokenReserve: 96
        )
        func translator(responseBytes: Int) -> TranscriptTranslator {
            TranscriptTranslator(backend: EchoTranslationBackend(
                policy: policy,
                recorder: TranslationPromptRecorder(),
                responseUTF8BytesOverride: responseBytes
            ))
        }

        let below = try await translator(responseBytes: 71).translate(request)
        let at = try await translator(responseBytes: 72).translate(request)
        #expect(below.document.batches[0].acceptedOutputTokenUpperBound == 199)
        #expect(at.document.batches[0].acceptedOutputTokenUpperBound == 200)
        await #expect(throws: PostprocessError.backendOutputBudgetExceeded(
            upperBound: 201,
            maximum: 200
        )) {
            _ = try await translator(responseBytes: 73).translate(request)
        }
    }

    @Test func codexAvailabilitySeparatesInstallFromSubscriptionAuthentication() async throws {
        let executable = try executableScript(#"""
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "codex-cli fixture"; exit 0; fi
        exit 2
        """#)
        defer {
            try? FileManager.default.removeItem(at: executable.deletingLastPathComponent())
        }

        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: executable,
            appServerExecutor: MockCodexAppServerExecutor(reportedAccountState: .chatGPT)
        ) == .authenticated(version: "codex-cli fixture"))
        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: executable,
            appServerExecutor: MockCodexAppServerExecutor(reportedAccountState: .signedOut)
        ) == .unauthenticated(version: "codex-cli fixture"))
        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: executable,
            appServerExecutor: MockCodexAppServerExecutor(reportedAccountState: .unsupported)
        ) == .unauthenticated(version: "codex-cli fixture"))
        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: executable,
            appServerExecutor: MockCodexAppServerExecutor(
                accountStateError: .backendFailed("fixture probe failed")
            )
        ) == .authenticationUnknown(version: "codex-cli fixture"))
        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: executable,
            appServerExecutor: MockCodexAppServerExecutor(
                accountStateError: .authenticationRequired(
                    "Your Codex sign-in is expired or too close to expiry. Refresh or sign in through Codex, then retry, or select Local."
                )
            )
        ) == .unauthenticated(version: "codex-cli fixture"))
    }

    @Test func codexVersionProbeHasABoundedTimeout() throws {
        let hanging = try executableScript(#"""
        #!/bin/sh
        /bin/sleep 2
        echo "codex-cli too-late"
        """#)
        defer {
            try? FileManager.default.removeItem(
                at: hanging.deletingLastPathComponent()
            )
        }
        let started = Date()
        #expect(CodexPostprocessBackend.detectVersion(
            executableURL: hanging,
            timeoutS: 0.05
        ) == "unavailable")
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test func codexVersionProbeDrainsLargeStandardErrorWithoutDeadlock() throws {
        let noisy = try executableScript(#"""
        #!/bin/sh
        i=0
        while [ "$i" -lt 8192 ]; do
          printf '0123456789abcdef\n' >&2
          i=$((i + 1))
        done
        printf 'codex-cli fixture\n'
        """#)
        defer {
            try? FileManager.default.removeItem(
                at: noisy.deletingLastPathComponent()
            )
        }

        #expect(CodexPostprocessBackend.detectVersion(
            executableURL: noisy,
            timeoutS: 10
        ) == "codex-cli fixture")
    }

    @Test func codexVersionProbeDrainsLargeStandardOutputWithoutDeadlock() throws {
        let noisy = try executableScript(#"""
        #!/bin/sh
        i=0
        while [ "$i" -lt 8192 ]; do
          printf '                '
          i=$((i + 1))
        done
        printf '\ncodex-cli fixture\n'
        """#)
        defer {
            try? FileManager.default.removeItem(
                at: noisy.deletingLastPathComponent()
            )
        }

        #expect(CodexPostprocessBackend.detectVersion(
            executableURL: noisy,
            timeoutS: 10
        ) == "codex-cli fixture")
    }

    @Test func codexVersionProbeBoundsRetainedStandardOutput() throws {
        let limit = CodexPostprocessBackend.maximumVersionOutputUTF8Bytes
        for byteCount in [limit, limit + 1] {
            let noisy = try executableScript("""
            #!/bin/sh
            /usr/bin/yes v | /usr/bin/head -c \(byteCount)
            """)
            defer {
                try? FileManager.default.removeItem(
                    at: noisy.deletingLastPathComponent()
                )
            }

            let version = CodexPostprocessBackend.detectVersion(
                executableURL: noisy,
                timeoutS: 10
            )
            if byteCount == limit {
                #expect(version != "unavailable")
                #expect(version.utf8.count <= limit)
            } else {
                #expect(version == "unavailable")
            }
        }
    }

    @Test func codexAvailabilityDoesNotDependOnVersionSideChannel() async throws {
        let executable = try executableScript(#"""
        #!/bin/sh
        exit 7
        """#)
        defer {
            try? FileManager.default.removeItem(
                at: executable.deletingLastPathComponent()
            )
        }

        #expect(await CodexPostprocessBackend.detectAvailability(
            executableURL: executable,
            appServerExecutor: MockCodexAppServerExecutor(reportedAccountState: .chatGPT)
        ) == .authenticated(version: "unavailable"))
    }

    @Test func backendRevalidatesReadOnlyNativeAuthenticationAtRunTime() async throws {
        let recorder = CodexInvocationRecorder()
        let message = "Your Codex sign-in is expired or too close to expiry. Refresh or sign in through Codex, then retry, or select Local."
        let backend = CodexPostprocessBackend(
            codexExecutableURL: URL(fileURLWithPath: "/tests/codex"),
            availability: .unauthenticated(version: "codex-cli fixture"),
            appServerExecutor: MockCodexAppServerExecutor(
                recorder: recorder,
                output: validOutput,
                runError: .authenticationRequired(message)
            )
        )
        await #expect(throws: PostprocessError.authenticationRequired(message)) {
            _ = try await backend.propose(prompt: "synthetic text")
        }
        #expect(recorder.invocations.count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[
        "MACCHERONI_RUN_CODEX_TRANSLATION_INTEGRATION"
    ] == "1"))
    func actualCodexTranslationExecutesSyntheticTextOnlyFixture() async throws {
        let evidenceConfiguration = try ActualCodexEvidenceConfiguration.load()
        let invocationRecorder = ActualCodexInvocationRecorder()
        let input = SegmentsDocument(
            segments: [
                Segment(
                    speaker: "SPEAKER_00",
                    startS: 0,
                    endS: 1.5,
                    text: "Ciao, verifichiamo Maccheroni e Codex CLI.",
                    language: "it"
                ),
                Segment(
                    speaker: "SPEAKER_01",
                    startS: 1.5,
                    endS: 3,
                    text: "Questo secondo segmento forza un batch separato.",
                    language: "it"
                ),
            ],
            numSpeakers: 2,
            source: SourceAudio(
                fileName: "synthetic.wav",
                sha256: String(repeating: "0", count: 64),
                durationS: 3
            )
        )
        let unchangedInput = input
        let defaultPolicy = CodexPostprocessBackend.defaultBatchPolicy
        let twoBatchPolicy = PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: defaultPolicy.maximumPromptUTF8Bytes,
            maximumSegmentsPerBatch: 1,
            maximumOutputTokens: defaultPolicy.maximumOutputTokens,
            outputTokenLimitStatus: defaultPolicy.outputTokenLimitStatus,
            outputTokenPlanningBudget: defaultPolicy.outputTokenPlanningBudget,
            outputTokensPerInputUTF8BytePermille:
                defaultPolicy.outputTokensPerInputUTF8BytePermille,
            baseOutputTokenReserve: defaultPolicy.baseOutputTokenReserve,
            perSegmentOutputTokenReserve: defaultPolicy.perSegmentOutputTokenReserve
        )
        let result: TranslationResult
        do {
            result = try await TranscriptTranslator(
                backend: CodexPostprocessBackend(
                    batchPolicy: twoBatchPolicy,
                    appServerExecutor: ActualCodexRecordingExecutor(
                        recorder: invocationRecorder
                    )
                )
            ).translate(TranslationRequest(
                document: input,
                targetLanguage: "en",
                sourceSegmentsSHA256: String(repeating: "1", count: 64)
            ))
        } catch {
            throw ActualCodexEvidenceError.verificationFailed(
                "actual Codex invocation did not complete"
            )
        }

        let encodedArtifact = String(
            decoding: try JSONEncoder().encode(result.document),
            as: UTF8.self
        )

        let invocations = await invocationRecorder.snapshot()
        let inputBefore = try sortedJSONData(unchangedInput)
        let inputAfter = try sortedJSONData(input)
        let translationArtifact = try sortedJSONData(result.document)
        let forbiddenStructureFieldsAbsent = [
            "speaker", "start_s", "end_s", "synthetic.wav",
        ].allSatisfy { !encodedArtifact.contains($0) }
        guard result.document.translations.count == 2,
              result.document.translations.map(\.segmentIndex) == [0, 1],
              result.document.translations.allSatisfy({ !$0.translatedText.isEmpty }),
              result.document.batches.map(\.segmentIndices) == [[0], [1]],
              result.document.batches.allSatisfy({
                  $0.responseUTF8Bytes >= $0.outputTextUTF8Bytes
                      && $0.acceptedOutputTokenUpperBound
                          <= twoBatchPolicy.outputTokenPlanningBudget
              }),
              result.manifestPostprocess.mode == .translation,
              result.manifestPostprocess.targetLanguage == "en",
              result.manifestPostprocess.modelID == CodexPostprocessBackend.modelName,
              result.manifestPostprocess.backend.version != "unavailable",
              result.manifestPostprocess.batching?.batchesPlanned == 2,
              result.manifestPostprocess.batching?.maximumOutputTokens == nil,
              result.manifestPostprocess.batching?.outputTokenLimitStatus
                  == .serviceManagedUnavailable,
              result.manifestPostprocess.batching?.maximumObservedResponseUTF8Bytes
                  == result.document.batches.map(\.responseUTF8Bytes).max(),
              inputBefore == inputAfter,
              forbiddenStructureFieldsAbsent,
              invocations.count == 2,
              invocations.allSatisfy({
                  $0.requiredInvocationContractPresent
                      && $0.standardInputUTF8Bytes > 0
              })
        else {
            throw ActualCodexEvidenceError.verificationFailed(
                "actual synthetic translation did not satisfy the complete evidence contract"
            )
        }
        let evidence = ActualCodexTranslationEvidence(
            runID: evidenceConfiguration.runID,
            gitHead: evidenceConfiguration.gitHead,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modelID: result.manifestPostprocess.modelID,
            codexCLIVersion: result.manifestPostprocess.backend.version,
            targetLanguage: result.document.targetLanguage,
            batchCount: result.document.batches.count,
            batches: result.document.batches,
            serviceOutputTokenLimitStatus:
                result.manifestPostprocess.batching?.outputTokenLimitStatus.rawValue
                    ?? "unavailable",
            maximumObservedResponseUTF8Bytes:
                result.manifestPostprocess.batching?.maximumObservedResponseUTF8Bytes ?? 0,
            inputSHA256Before: sha256Hex(inputBefore),
            inputSHA256After: sha256Hex(inputAfter),
            inputUnchanged: inputBefore == inputAfter,
            translationArtifactSHA256: sha256Hex(translationArtifact),
            forbiddenStructureFieldsAbsent: forbiddenStructureFieldsAbsent,
            privateContentSuppliedToTest: false,
            audioBytesSuppliedToBackend: false,
            operatingSystemReadScopeVerified: false,
            invocations: invocations
        )
        try evidence.writeCreateOnly(to: evidenceConfiguration.outputURL)
    }

    @Test func actualCodexAppServerEvidenceProjectionRedactsPromptAndWorkspacePaths() async throws {
        let root = try freshDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let recorder = ActualCodexInvocationRecorder()
        await recorder.record(CodexAppServerInvocation(
            executableURL: URL(fileURLWithPath: "/Users/someone/.local/bin/codex"),
            model: "gpt-5.6-sol",
            prompt: "synthetic prompt must not be persisted",
            outputSchema: Data(#"{"type":"object"}"#.utf8),
            workspaceURL: workspace
        ))

        let projection = try #require(await recorder.snapshot().first)
        let encoded = String(decoding: try sortedJSONData(projection), as: UTF8.self)
        #expect(projection.requiredInvocationContractPresent)
        #expect(projection.transport == "app-server-stdio")
        #expect(projection.model == "gpt-5.6-sol")
        #expect(!encoded.contains("synthetic prompt must not be persisted"))
        #expect(!encoded.contains(workspace.path))
        #expect(!encoded.contains("/Users/someone"))
        #expect(projection.executableLocationClass == "user-or-custom")
    }

    private var validOutput: Data { Data(#"{"proposals":[]}"#.utf8) }

    private func integrationDocument() -> SegmentsDocument {
        SegmentsDocument(
            segments: [
                Segment(
                    speaker: "SPEAKER_00",
                    startS: 0,
                    endS: 1.5,
                    text: "We use Maccherony with Codecks CLI.",
                    language: "en",
                    confidence: 0.85
                ),
            ],
            numSpeakers: 1,
            source: SourceAudio(
                fileName: "synthetic.wav",
                sha256: String(repeating: "0", count: 64),
                durationS: 1.5
            )
        )
    }

    private func expectStructure(
        _ output: SegmentsDocument,
        equals input: SegmentsDocument
    ) {
        #expect(output.schemaVersion == input.schemaVersion)
        #expect(output.numSpeakers == input.numSpeakers)
        #expect(output.source == input.source)
        #expect(output.segments.count == input.segments.count)
        for index in input.segments.indices {
            #expect(output.segments[index].speaker == input.segments[index].speaker)
            #expect(output.segments[index].startS == input.segments[index].startS)
            #expect(output.segments[index].endS == input.segments[index].endS)
            #expect(output.segments[index].language == input.segments[index].language)
            #expect(output.segments[index].confidence == input.segments[index].confidence)
        }
    }

    private func expectGlossaryCorrection(in result: PostprocessResult) {
        let candidates = result.document.segments.map(\.text)
            + result.conflicts.map(\.candidateText)
        #expect(candidates.contains {
            $0.contains("Maccheroni") && $0.contains("Codex CLI")
        })
    }

    private func freshDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maccheroni-postprocess-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executableScript(_ source: String) throws -> URL {
        let directory = try freshDirectory()
        let url = directory.appendingPathComponent("codex-fixture")
        try Data(source.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }
}

private final class SpeakerPromptRecorder: @unchecked Sendable {
    var prompts: [String] = []
}

/// A proposer whose answers are scripted, so the layering rules can be probed
/// without a model.
private struct StubSpeakerProposalBackend: SpeakerProposalBackend {
    var decisions: [SpeakerProposalDecision]
    var recorder: SpeakerPromptRecorder?
    var responseUTF8BytesOverride: Int?

    var id: PostprocessBackendID { .local }
    var manifestPostprocess: ManifestPostprocess {
        ManifestPostprocess(
            backend: BackendDescriptor(name: "speaker-stub", version: "1"),
            modelID: "speaker-stub"
        )
    }
    var model: ModelDescriptor? { nil }
    var batchPolicy: PostprocessBatchPolicy {
        PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: 1_000_000,
            maximumSegmentsPerBatch: 1_000,
            maximumOutputTokens: 1_024,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 1_024,
            outputTokensPerInputUTF8BytePermille: 1,
            baseOutputTokenReserve: 0,
            perSegmentOutputTokenReserve: 0
        )
    }

    func proposeSpeakers(
        prompt: String
    ) async throws -> SpeakerProposalBackendResponse {
        recorder?.prompts.append(prompt)
        let data = try JSONEncoder().encode(
            SpeakerProposalTestEnvelope(speakerProposals: decisions)
        )
        return SpeakerProposalBackendResponse(
            decisions: decisions,
            responseUTF8Bytes: responseUTF8BytesOverride ?? data.count
        )
    }
}

private struct SpeakerProposalTestEnvelope: Codable {
    var speakerProposals: [SpeakerProposalDecision]

    enum CodingKeys: String, CodingKey {
        case speakerProposals = "speaker_proposals"
    }
}

private struct StubBackend: PostprocessBackend {
    var proposals: [PostprocessProposal]
    var id: PostprocessBackendID { .local }
    var manifestPostprocess: ManifestPostprocess { ManifestPostprocess(backend: BackendDescriptor(name: "stub", version: "1"), modelID: "stub") }
    var model: ModelDescriptor? { nil }
    var batchPolicy: PostprocessBatchPolicy {
        PostprocessBatchPolicy(
            maximumPromptUTF8Bytes: 1_000_000,
            maximumSegmentsPerBatch: 1_000,
            maximumOutputTokens: 1_024,
            outputTokenLimitStatus: .configured,
            outputTokenPlanningBudget: 1_024,
            outputTokensPerInputUTF8BytePermille: 1_000,
            baseOutputTokenReserve: 0,
            perSegmentOutputTokenReserve: 0
        )
    }
    func propose(prompt: String) async throws -> PostprocessBackendResponse {
        let data = try JSONEncoder().encode(ProposalTestEnvelope(proposals: proposals))
        return PostprocessBackendResponse(
            proposals: proposals,
            responseUTF8Bytes: data.count
        )
    }
}

private final class InvocationRecorder: @unchecked Sendable {
    var invocations: [SubprocessInvocation] = []
}

private final class CodexInvocationRecorder: @unchecked Sendable {
    var invocations: [CodexAppServerInvocation] = []
}

private struct MockCodexAppServerExecutor: CodexAppServerExecuting {
    var recorder: CodexInvocationRecorder?
    var output: Data = Data(#"{"proposals":[]}"#.utf8)
    var reportedAccountState: CodexAppServerAccountState = .chatGPT
    var accountStateError: PostprocessError?
    var runError: PostprocessError?

    func accountState(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval
    ) async throws -> CodexAppServerAccountState {
        if let accountStateError { throw accountStateError }
        return reportedAccountState
    }

    func run(_ invocation: CodexAppServerInvocation) async throws -> Data {
        recorder?.invocations.append(invocation)
        if let runError { throw runError }
        return output
    }
}

private final class TranslationPromptRecorder: @unchecked Sendable {
    var prompts: [String] = []
}

private final class CorrectionPromptRecorder: @unchecked Sendable {
    var prompts: [String] = []
}

private struct EchoCorrectionBackend: PostprocessBackend {
    let policy: PostprocessBatchPolicy
    let recorder: CorrectionPromptRecorder

    var id: PostprocessBackendID { .local }
    var manifestPostprocess: ManifestPostprocess {
        ManifestPostprocess(
            backend: BackendDescriptor(name: "correction-stub", version: "1"),
            modelID: "correction-stub"
        )
    }
    var model: ModelDescriptor? { nil }
    var batchPolicy: PostprocessBatchPolicy { policy }

    func propose(prompt: String) async throws -> PostprocessBackendResponse {
        recorder.prompts.append(prompt)
        let data = Data(#"{"proposals":[]}"#.utf8)
        return PostprocessBackendResponse(
            proposals: [],
            responseUTF8Bytes: data.count
        )
    }
}

private struct EchoTranslationBackend: TranslationBackend {
    let policy: PostprocessBatchPolicy
    let recorder: TranslationPromptRecorder
    var responseUTF8BytesOverride: Int? = nil

    var id: PostprocessBackendID { .local }
    var manifestPostprocess: ManifestPostprocess {
        ManifestPostprocess(
            backend: BackendDescriptor(name: "translation-stub", version: "1"),
            modelID: "translation-stub"
        )
    }
    var model: ModelDescriptor? { nil }
    var batchPolicy: PostprocessBatchPolicy { policy }

    func translate(prompt: String) async throws -> TranslationBackendResponse {
        recorder.prompts.append(prompt)
        let marker = "INPUT:\n"
        let payload = try #require(prompt.range(of: marker).map {
            String(prompt[$0.upperBound...])
        })
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any]
        )
        let segments = try #require(object["segments"] as? [[String: Any]])
        let translations = try segments.map { segment in
            let index = try #require(segment["segment_index"] as? Int)
            return SegmentTranslation(
                segmentIndex: index,
                translatedText: "translated-\(index)"
            )
        }
        let data = try JSONEncoder().encode(
            TranslationTestEnvelope(translations: translations)
        )
        return TranslationBackendResponse(
            translations: translations,
            responseUTF8Bytes: responseUTF8BytesOverride ?? data.count
        )
    }
}

private struct ProposalTestEnvelope: Encodable {
    var proposals: [PostprocessProposal]
}

private struct TranslationTestEnvelope: Encodable {
    var translations: [SegmentTranslation]
}

private struct MockExecutor: SubprocessExecuting {
    let recorder: InvocationRecorder?
    let output: Data
    let exitStatus: Int32
    let standardError: Data

    init(
        recorder: InvocationRecorder? = nil,
        output: Data,
        exitStatus: Int32 = 0,
        standardError: Data = Data()
    ) {
        self.recorder = recorder
        self.output = output
        self.exitStatus = exitStatus
        self.standardError = standardError
    }

    func run(_ invocation: SubprocessInvocation) async throws -> SubprocessOutput {
        recorder?.invocations.append(invocation)
        return SubprocessOutput(exitStatus: exitStatus, standardOutput: output, standardError: standardError)
    }
}

private enum ActualCodexEvidenceError: Error, LocalizedError {
    case missingEnvironment(String)
    case invalidEnvironment(String)
    case outputAlreadyExists(String)
    case repositoryState(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingEnvironment(name):
            "actual Codex evidence requires \(name)"
        case let .invalidEnvironment(name):
            "actual Codex evidence received an invalid \(name)"
        case let .outputAlreadyExists(path):
            "actual Codex evidence is create-only and already exists: \(path)"
        case let .repositoryState(message):
            "actual Codex evidence requires an exact clean repository state: \(message)"
        case let .verificationFailed(message):
            "actual Codex evidence verification failed: \(message)"
        }
    }
}

private struct ActualCodexEvidenceConfiguration {
    var outputURL: URL
    var runID: String
    var gitHead: String

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ActualCodexEvidenceConfiguration {
        let outputKey = "MACCHERONI_CODEX_TRANSLATION_EVIDENCE_PATH"
        let runIDKey = "MACCHERONI_EVIDENCE_RUN_ID"
        let gitHeadKey = "MACCHERONI_EVIDENCE_GIT_HEAD"
        guard let outputPath = environment[outputKey], !outputPath.isEmpty else {
            throw ActualCodexEvidenceError.missingEnvironment(outputKey)
        }
        guard outputPath.hasPrefix("/") else {
            throw ActualCodexEvidenceError.invalidEnvironment(outputKey)
        }
        guard let runID = environment[runIDKey],
              !runID.isEmpty,
              runID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw ActualCodexEvidenceError.invalidEnvironment(runIDKey)
        }
        guard let gitHead = environment[gitHeadKey],
              gitHead.count == 40,
              gitHead.allSatisfy(\.isHexDigit)
        else {
            throw ActualCodexEvidenceError.invalidEnvironment(gitHeadKey)
        }
        let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ActualCodexEvidenceError.outputAlreadyExists(outputURL.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: outputURL.deletingLastPathComponent().path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ActualCodexEvidenceError.invalidEnvironment(outputKey)
        }
        guard FileManager.default.isWritableFile(
            atPath: outputURL.deletingLastPathComponent().path
        ) else {
            throw ActualCodexEvidenceError.invalidEnvironment(outputKey)
        }
        let actualGitHead = try gitOutput(["rev-parse", "HEAD"])
        guard actualGitHead == gitHead.lowercased() else {
            throw ActualCodexEvidenceError.repositoryState(
                "MACCHERONI_EVIDENCE_GIT_HEAD does not match HEAD"
            )
        }
        let status = try gitOutput(["status", "--porcelain", "--untracked-files=normal"])
        guard status.isEmpty else {
            throw ActualCodexEvidenceError.repositoryState("the tracked worktree is not clean")
        }
        return ActualCodexEvidenceConfiguration(
            outputURL: outputURL,
            runID: runID,
            gitHead: gitHead.lowercased()
        )
    }

    private static func gitOutput(_ arguments: [String]) throws -> String {
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw ActualCodexEvidenceError.repositoryState(error.localizedDescription)
        }
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ActualCodexEvidenceError.repositoryState(
                String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ActualCodexTranslationEvidence: Codable {
    var schemaVersion = "1.0"
    var verdict = "passed"
    var runID: String
    var gitHead: String
    var createdAt: String
    var fixture = "inline-public-synthetic-text-only"
    var authenticationStatus = "authenticated"
    var modelProvider = "codex-subscription"
    var modelRevision = "service-managed-unavailable"
    var quantization = "not-applicable"
    var modelID: String
    var codexCLIVersion: String
    var targetLanguage: String
    var batchCount: Int
    var batches: [TranslationBatchRecord]
    var serviceOutputTokenLimitStatus: String
    var maximumObservedResponseUTF8Bytes: Int
    var inputSHA256Before: String
    var inputSHA256After: String
    var inputUnchanged: Bool
    var translationArtifactSHA256: String
    var forbiddenStructureFieldsAbsent: Bool
    var privateContentSuppliedToTest: Bool
    var audioBytesSuppliedToBackend: Bool
    var operatingSystemReadScopeVerified: Bool
    var invocations: [ActualCodexInvocationRecord]

    func writeCreateOnly(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .withoutOverwriting)
    }
}

private actor ActualCodexInvocationRecorder {
    private var records: [ActualCodexInvocationRecord] = []

    func record(_ invocation: CodexAppServerInvocation) {
        records.append(ActualCodexInvocationRecord(invocation: invocation))
    }

    func snapshot() -> [ActualCodexInvocationRecord] {
        records
    }
}

private struct ActualCodexRecordingExecutor: CodexAppServerExecuting {
    let recorder: ActualCodexInvocationRecorder
    private let delegate = FoundationCodexAppServerExecutor()

    func accountState(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval
    ) async throws -> CodexAppServerAccountState {
        try await delegate.accountState(
            executableURL: executableURL,
            workspaceURL: workspaceURL,
            timeoutS: timeoutS
        )
    }

    func run(_ invocation: CodexAppServerInvocation) async throws -> Data {
        let output = try await delegate.run(invocation)
        await recorder.record(invocation)
        return output
    }
}

private struct ActualCodexInvocationRecord: Codable {
    var executableName: String
    var executableLocationClass: String
    var transport: String
    var model: String
    var standardInputUTF8Bytes: Int
    var standardInputSHA256: String
    var timeoutSeconds: Int
    var outputSchemaSupplied: Bool
    var workspaceWasEmpty: Bool
    var requiredInvocationContractPresent: Bool

    init(invocation: CodexAppServerInvocation) {
        executableName = invocation.executableURL.lastPathComponent
        executableLocationClass = Self.locationClass(invocation.executableURL)
        transport = "app-server-stdio"
        model = invocation.model
        let promptData = Data(invocation.prompt.utf8)
        standardInputUTF8Bytes = promptData.count
        standardInputSHA256 = sha256Hex(promptData)
        timeoutSeconds = Int(invocation.timeoutS)
        outputSchemaSupplied = !invocation.outputSchema.isEmpty
        workspaceWasEmpty = (try? FileManager.default.contentsOfDirectory(
            at: invocation.workspaceURL,
            includingPropertiesForKeys: nil
        ).isEmpty) == true
        requiredInvocationContractPresent = invocation.model
            == CodexPostprocessBackend.modelName
            && invocation.workspaceURL.isFileURL
            && outputSchemaSupplied
            && workspaceWasEmpty
            && invocation.timeoutS == 600
    }

    private static func locationClass(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") {
            return "package-manager"
        }
        if path.hasPrefix("/usr/bin/") || path.hasPrefix("/bin/") {
            return "system"
        }
        return "user-or-custom"
    }

}

private func sortedJSONData<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
