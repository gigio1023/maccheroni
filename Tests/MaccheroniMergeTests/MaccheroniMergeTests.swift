import Foundation
import Testing
@testable import MaccheroniCore
@testable import MaccheroniMerge

@Suite struct MaccheroniMergeTests {
    private let source = SourceAudio(
        fileName: "synthetic.wav",
        sha256: String(repeating: "a", count: 64),
        durationS: 20
    )

    private func hypothesis(
        _ source: String,
        _ segments: [Segment]
    ) -> ASRHypothesis {
        ASRHypothesis(source: source, segments: segments)
    }

    @Test func keepsGlobalSpeakerIdentityAcrossChunkBoundaryAndUsesDominantOverlap() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 12),
            TimelineSegment(speaker: "SPEAKER_01", startS: 12, endS: 20),
        ])
        let chunks = [
            ChunkTranscript(
                index: 0,
                startS: 0,
                endS: 10,
                primary: hypothesis("primary", [
                    Segment(speaker: "UNASSIGNED", startS: 9, endS: 10, text: "before"),
                ])
            ),
            ChunkTranscript(
                index: 1,
                startS: 10,
                endS: 20,
                primary: hypothesis("primary", [
                    Segment(speaker: "UNASSIGNED", startS: 10, endS: 11, text: "after"),
                    Segment(speaker: "UNASSIGNED", startS: 11, endS: 14, text: "crossing"),
                ])
            ),
        ]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)

        #expect(result.segmentsDocument.segments.map(\.speaker) == [
            "SPEAKER_00", "SPEAKER_00", "SPEAKER_01",
        ])
        #expect(result.segmentsDocument.numSpeakers == 2)
        #expect(result.conflicts.isEmpty)
    }

    @Test func overlappingSpeechPreservesCandidatesAndDoesNotGuessSpeaker() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 4),
            TimelineSegment(speaker: "SPEAKER_01", startS: 1, endS: 3),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 1, endS: 3, text: "simultaneous"),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = try #require(result.segmentsDocument.segments.first)

        #expect(merged.speaker == "UNKNOWN")
        #expect(merged.flags == ["conflict", "uncertain"])
        #expect(result.conflicts.map(\.kind) == [.ambiguousSpeaker, .overlappingSpeech])
        #expect(result.conflicts.allSatisfy {
            $0.candidates == ["SPEAKER_00", "SPEAKER_01"]
        })
    }

    @Test func equalSequentialOverlapIsAnExplicitAmbiguousAssignment() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 1),
            TimelineSegment(speaker: "SPEAKER_01", startS: 1, endS: 2),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 0, endS: 2, text: "boundary"),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)

        #expect(result.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        #expect(result.segmentsDocument.segments.first?.flags == ["conflict", "uncertain"])
        #expect(result.conflicts.map(\.kind) == [.ambiguousSpeaker])
        #expect(result.segmentsDocument.numSpeakers == 0)
    }

    @Test func asrDisagreementFlagsPrimaryWithoutReplacingItsText() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("vibevoice", [
                Segment(
                    speaker: "UNASSIGNED",
                    startS: 2,
                    endS: 4,
                    text: "Maccheroni is ready."
                ),
            ]),
            comparisons: [hypothesis("qwen3", [
                Segment(
                    speaker: "UNASSIGNED",
                    startS: 2,
                    endS: 4,
                    text: "Maccheroni is not ready."
                ),
            ])]
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = try #require(result.segmentsDocument.segments.first)
        let conflict = try #require(result.conflicts.first)
        let conflictsData = try JSONEncoder().encode(result.conflicts)
        let conflictsArray = try #require(
            JSONSerialization.jsonObject(with: conflictsData) as? [[String: Any]]
        )

        #expect(merged.text == "Maccheroni is ready.")
        #expect(merged.flags == ["conflict"])
        #expect(conflict.kind == .asrDisagreement)
        #expect(conflict.candidates == [
            "vibevoice: Maccheroni is ready.",
            "qwen3: Maccheroni is not ready.",
        ])
        #expect(conflictsArray.first?["segment_index"] as? Int == 0)
        #expect(conflictsArray.first?["kind"] as? String == "asr_disagreement")
    }

    @Test func caseAndPunctuationOnlyDifferencesAreNotASRConflicts() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 2, endS: 4, text: "Maccheroni READY!"),
            ]),
            comparisons: [hypothesis("verifier", [
                Segment(speaker: "UNASSIGNED", startS: 2, endS: 4, text: "maccheroni ready"),
            ])]
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)

        #expect(result.conflicts.isEmpty)
        #expect(result.segmentsDocument.segments.first?.flags == nil)
    }

    @Test func mossSpeakerEvidenceCannotOverrideTheGlobalTimeline() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_04", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("moss", [
                Segment(
                    speaker: "S01",
                    startS: 0,
                    endS: 1,
                    text: "Va bene.",
                    language: "it",
                    flags: ["backend_speaker_evidence"]
                ),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = try #require(result.segmentsDocument.segments.first)
        let encoded = try JSONEncoder().encode(result.segmentsDocument)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(merged.speaker == "SPEAKER_04")
        #expect(merged.flags == ["backend_speaker_evidence"])
        #expect(result.segmentsDocument.numSpeakers == 1)
        #expect(object["schema_version"] as? String == MaccheroniSchema.version)
        #expect(object["num_speakers"] as? Int == 1)
    }

    @Test func emptyTimelineProducesUnassignedSegmentsForDiarizationOff() throws {
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", [
                Segment(speaker: "S01", startS: 0, endS: 1, text: "solo"),
            ])
        )]

        let result = try TimelineMerger().merge(
            chunks: chunks,
            timeline: Timeline(segments: []),
            source: source
        )

        #expect(result.segmentsDocument.segments.first?.speaker == "UNASSIGNED")
        #expect(result.segmentsDocument.numSpeakers == 0)
        #expect(result.conflicts.isEmpty)
    }

    private func singleChunk(_ segments: [Segment]) -> [ChunkTranscript] {
        [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("primary", segments)
        )]
    }

    private func speakerAttribution(
        _ conflicts: [MergeConflict],
        kind: MergeConflictKind = .ambiguousSpeaker
    ) throws -> SpeakerAttribution {
        try #require(conflicts.first { $0.kind == kind }?.speakerAttribution)
    }

    @Test func unattributedSegmentDisclosesEachCandidateDurationAndShare() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 6),
            TimelineSegment(speaker: "SPEAKER_01", startS: 2, endS: 8),
        ])
        let chunks = singleChunk([
            Segment(speaker: "UNASSIGNED", startS: 0, endS: 8, text: "overlapped"),
        ])

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let attribution = try speakerAttribution(result.conflicts)

        #expect(result.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        #expect(attribution.outcome == .noDominantSpeaker)
        #expect(attribution.candidates.map(\.speaker) == ["SPEAKER_00", "SPEAKER_01"])
        #expect(attribution.candidates.map(\.overlapS) == [6, 6])
        #expect(attribution.candidates.map(\.share) == [0.5, 0.5])
        #expect(attribution.timelineCoverage == 1)
        #expect(attribution.thresholds.dominantSpeakerShare == 0.60)
        #expect(attribution.thresholds.minimumTimelineCoverage == 0.50)
        #expect(attribution.candidates.map(\.speaker) == result.conflicts.first?.candidates)
    }

    @Test func aNondefaultOverlapEpsilonDecidesTheWinnerAndIsSealedWithIt() throws {
        // 6 s against 5 s clears a 0.5 share bar either way, so the assignment
        // turns entirely on whether the one-second winner margin clears the
        // overlap epsilon. Two runs that differ only in that value therefore
        // name different speakers, which is why the value has to travel with
        // the other two thresholds.
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 6),
            TimelineSegment(speaker: "SPEAKER_01", startS: 6, endS: 11),
        ])
        let chunks = singleChunk([
            Segment(speaker: "UNASSIGNED", startS: 0, endS: 11, text: "one second apart"),
        ])
        var lenient = TimelineMergeConfiguration(
            dominantSpeakerShare: 0.5,
            minimumTimelineCoverage: 0.5
        )
        lenient.overlapEpsilonS = 1e-9
        var strict = lenient
        strict.overlapEpsilonS = 1.5

        let named = try TimelineMerger(configuration: lenient)
            .merge(chunks: chunks, timeline: timeline, source: source)
        #expect(named.segmentsDocument.segments.first?.speaker == "SPEAKER_00")

        let unnamed = try TimelineMerger(configuration: strict)
            .merge(chunks: chunks, timeline: timeline, source: source)
        #expect(unnamed.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        let attribution = try speakerAttribution(unnamed.conflicts)
        #expect(attribution.outcome == .noDominantSpeaker)
        #expect(attribution.thresholds.dominantSpeakerShare == 0.5)
        #expect(attribution.thresholds.minimumTimelineCoverage == 0.5)
        #expect(attribution.thresholds.overlapEpsilonS == 1.5)

        let data = try JSONEncoder().encode(unnamed.conflicts)
        let array = try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let serialized = try #require(
            (array.first?["speaker_attribution"] as? [String: Any])?["thresholds"]
                as? [String: Any]
        )
        #expect(serialized["overlap_epsilon_s"] as? Double == 1.5)
        let decoded = try JSONDecoder().decode([MergeConflict].self, from: data)
        #expect(decoded == unnamed.conflicts)
        #expect(
            decoded.first?.speakerAttribution?.thresholds.overlapEpsilonS == 1.5
        )
    }

    @Test func thresholdsWrittenBeforeTheEpsilonFieldReadAsUnrecorded() throws {
        // Conflict files sealed before 2026-09-02 do not carry the value, and
        // a reader must be able to tell that from a recorded one rather than
        // being handed today's default as though the run had used it.
        let legacy = Data(#"""
        {"dominant_speaker_share": 0.6, "minimum_timeline_coverage": 0.5}
        """#.utf8)
        let decoded = try JSONDecoder().decode(
            SpeakerAttributionThresholds.self,
            from: legacy
        )
        #expect(decoded.overlapEpsilonS == nil)
        let object = try #require(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(decoded)
        ) as? [String: Any])
        #expect(object["overlap_epsilon_s"] == nil)
    }

    @Test func candidatesAreOrderedByOverlapAndTheirSharesSumToOne() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_02", startS: 0, endS: 2),
            TimelineSegment(speaker: "SPEAKER_00", startS: 2, endS: 5),
            TimelineSegment(speaker: "SPEAKER_01", startS: 5, endS: 10),
        ])
        let chunks = singleChunk([
            Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "three speakers"),
        ])

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let attribution = try speakerAttribution(result.conflicts)

        #expect(attribution.candidates.map(\.speaker) == [
            "SPEAKER_01", "SPEAKER_00", "SPEAKER_02",
        ])
        #expect(attribution.candidates.map(\.overlapS) == [5, 3, 2])
        #expect(abs(attribution.candidates.reduce(0) { $0 + $1.share } - 1) < 1e-12)
        #expect(attribution.candidates.first?.share == 0.5)
    }

    @Test func theThreeCollapseSitesAreDistinguishableInTheOutput() throws {
        let noOverlap = try TimelineMerger().merge(
            chunks: singleChunk([
                Segment(speaker: "UNASSIGNED", startS: 10, endS: 12, text: "silence gap"),
            ]),
            timeline: Timeline(segments: [
                TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 4),
            ]),
            source: source
        )
        let lowCoverage = try TimelineMerger().merge(
            chunks: singleChunk([
                Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "mostly silence"),
            ]),
            timeline: Timeline(segments: [
                TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 4),
            ]),
            source: source
        )
        let noDominant = try TimelineMerger().merge(
            chunks: singleChunk([
                Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "shared"),
            ]),
            timeline: Timeline(segments: [
                TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 5.5),
                TimelineSegment(speaker: "SPEAKER_01", startS: 5.5, endS: 10),
            ]),
            source: source
        )

        let first = try speakerAttribution(noOverlap.conflicts)
        let second = try speakerAttribution(lowCoverage.conflicts)
        let third = try speakerAttribution(noDominant.conflicts)

        #expect(first.outcome == .noOverlappingTurn)
        #expect(first.candidates.isEmpty)
        #expect(first.timelineCoverage == 0)
        #expect(second.outcome == .coverageBelowThreshold)
        #expect(second.candidates.map(\.speaker) == ["SPEAKER_00"])
        #expect(second.timelineCoverage == 0.4)
        #expect(third.outcome == .noDominantSpeaker)
        #expect(third.timelineCoverage == 1)
        #expect(third.candidates.map(\.overlapS) == [5.5, 4.5])
        #expect(third.candidates.first?.share == 0.55)
        #expect([noOverlap, lowCoverage, noDominant].allSatisfy {
            $0.segmentsDocument.segments.first?.speaker == "UNKNOWN"
        })
    }

    @Test func attributedSegmentsRecordTheOutcomeThatChoseTheirSpeaker() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 10),
            TimelineSegment(speaker: "SPEAKER_01", startS: 8, endS: 10),
        ])
        let chunks = singleChunk([
            Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "interjection"),
        ])

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let attribution = try speakerAttribution(result.conflicts, kind: .overlappingSpeech)

        #expect(result.segmentsDocument.segments.first?.speaker == "SPEAKER_00")
        #expect(attribution.outcome == .attributed)
        #expect(attribution.candidates.map(\.overlapS) == [10, 2])
        #expect(attribution.candidates.first?.share == 10.0 / 12.0)
    }

    @Test func measuredNearMissBelowTheDominantShareThresholdIsDisclosed() throws {
        // Reproduces the 2026-09-01 baseline run's 20.35 s segment: 17.28 s of
        // one speaker against 12.877 s of the other, share 0.573, just under
        // the 0.60 bar. Timings only; no transcript text from that recording.
        let longSource = SourceAudio(
            fileName: "synthetic.wav",
            sha256: String(repeating: "a", count: 64),
            durationS: 60
        )
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "0", startS: 22.2, endS: 39.48),
            TimelineSegment(speaker: "1", startS: 29.673, endS: 42.55),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 60,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 22.2, endS: 42.55, text: "near miss"),
            ])
        )]

        let result = try TimelineMerger().merge(
            chunks: chunks,
            timeline: timeline,
            source: longSource
        )
        let attribution = try speakerAttribution(result.conflicts)
        let leading = try #require(attribution.candidates.first)
        let runnerUp = try #require(attribution.candidates.last)

        #expect(result.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        #expect(attribution.outcome == .noDominantSpeaker)
        #expect(abs(leading.overlapS - 17.28) < 1e-9)
        #expect(abs(runnerUp.overlapS - 12.877) < 1e-9)
        #expect(abs(leading.share - 0.573001) < 1e-6)
        #expect(leading.share < attribution.thresholds.dominantSpeakerShare)
        #expect(attribution.timelineCoverage == 1)
    }

    @Test func serializedConflictNamesTheEvidenceFieldsAndKeepsCandidates() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 6),
            TimelineSegment(speaker: "SPEAKER_01", startS: 2, endS: 8),
        ])
        let chunks = singleChunk([
            Segment(speaker: "UNASSIGNED", startS: 0, endS: 8, text: "overlapped"),
        ])

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let data = try JSONEncoder().encode(result.conflicts)
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let record = try #require(array.first)
        let attribution = try #require(record["speaker_attribution"] as? [String: Any])
        let candidates = try #require(attribution["candidates"] as? [[String: Any]])
        let thresholds = try #require(attribution["thresholds"] as? [String: Any])

        #expect(record["candidates"] as? [String] == ["SPEAKER_00", "SPEAKER_01"])
        #expect(attribution["outcome"] as? String == "no_dominant_speaker")
        #expect(attribution["timeline_coverage"] as? Double == 1)
        #expect(candidates.map { $0["speaker"] as? String } == ["SPEAKER_00", "SPEAKER_01"])
        #expect(candidates.map { $0["overlap_s"] as? Double } == [6, 6])
        #expect(candidates.map { $0["share"] as? Double } == [0.5, 0.5])
        #expect(thresholds["dominant_speaker_share"] as? Double == 0.60)
        #expect(thresholds["minimum_timeline_coverage"] as? Double == 0.50)
    }

    @Test func conflictFilesWrittenBeforeTheEvidenceFieldStillDecode() throws {
        let legacy = Data("""
        [{"segment_index": 0, "kind": "ambiguous_speaker",
          "candidates": ["SPEAKER_00", "SPEAKER_01"],
          "reason": "No diarization speaker has a dominant overlap with this ASR interval."}]
        """.utf8)

        let decoded = try JSONDecoder().decode([MergeConflict].self, from: legacy)
        let conflict = try #require(decoded.first)

        #expect(conflict.candidates == ["SPEAKER_00", "SPEAKER_01"])
        #expect(conflict.speakerAttribution == nil)
    }

    @Test func asrDisagreementCarriesNoSpeakerAttribution() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: hypothesis("vibevoice", [
                Segment(speaker: "UNASSIGNED", startS: 2, endS: 4, text: "ready"),
            ]),
            comparisons: [hypothesis("qwen3", [
                Segment(speaker: "UNASSIGNED", startS: 2, endS: 4, text: "not ready"),
            ])]
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let conflict = try #require(result.conflicts.first)
        let data = try JSONEncoder().encode(result.conflicts)
        let array = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(conflict.kind == .asrDisagreement)
        #expect(conflict.speakerAttribution == nil)
        #expect(array.first?["speaker_attribution"] == nil)
    }

    // MARK: - The 2026-09-02 threshold decision
    //
    // `dominantSpeakerShare` 0.60 and `minimumTimelineCoverage` 0.50 were
    // measured against the 43.4 % overlap recording and kept. The measurement,
    // its error estimate, what it could not measure, and what would falsify it
    // are in `docs/engineering-constraint-policy.md`, section "2026-09-02 Merge
    // Speaker-Assignment Thresholds". These tests pin both values and the three
    // properties the decision rests on, so a later change has to restate the
    // decision rather than drift past it.

    @Test func theShippedThresholdsAreTheExaminedDefaults() throws {
        let configuration = TimelineMergeConfiguration.default

        #expect(configuration.dominantSpeakerShare == 0.60)
        #expect(configuration.minimumTimelineCoverage == 0.50)
    }

    @Test func dominantShareThresholdRefusesBelowAndAttributesAtAndAbove() throws {
        // ε is 1 ms of turn duration on a 10-second segment: it moves the share
        // by 1e-4, far above double rounding and far below anything diarization
        // resolves.
        func merged(leadingTurnEndsAt end: Double) throws -> TimelineMergeResult {
            try TimelineMerger().merge(
                chunks: singleChunk([
                    Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "at the bar"),
                ]),
                timeline: Timeline(segments: [
                    TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: end),
                    TimelineSegment(speaker: "SPEAKER_01", startS: end, endS: 10),
                ]),
                source: source
            )
        }

        let below = try merged(leadingTurnEndsAt: 5.999)
        let at = try merged(leadingTurnEndsAt: 6)
        let above = try merged(leadingTurnEndsAt: 6.001)
        let refused = try speakerAttribution(below.conflicts)

        #expect(below.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        #expect(refused.outcome == .noDominantSpeaker)
        #expect(abs((refused.candidates.first?.share ?? 0) - 0.5999) < 1e-12)
        #expect(at.segmentsDocument.segments.first?.speaker == "SPEAKER_00")
        #expect(above.segmentsDocument.segments.first?.speaker == "SPEAKER_00")
        #expect(at.conflicts.isEmpty)
        #expect(above.conflicts.isEmpty)
    }

    @Test func coverageThresholdRefusesBelowAndAttributesAtAndAbove() throws {
        func merged(turnCovers covered: Double) throws -> TimelineMergeResult {
            try TimelineMerger().merge(
                chunks: singleChunk([
                    Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "sparse turn"),
                ]),
                timeline: Timeline(segments: [
                    TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: covered),
                ]),
                source: source
            )
        }

        let below = try merged(turnCovers: 4.999)
        let at = try merged(turnCovers: 5)
        let above = try merged(turnCovers: 5.001)
        let refused = try speakerAttribution(below.conflicts)

        #expect(below.segmentsDocument.segments.first?.speaker == "UNKNOWN")
        #expect(refused.outcome == .coverageBelowThreshold)
        #expect(abs(refused.timelineCoverage - 0.4999) < 1e-12)
        #expect(refused.candidates.map(\.share) == [1])
        #expect(at.segmentsDocument.segments.first?.speaker == "SPEAKER_00")
        #expect(above.segmentsDocument.segments.first?.speaker == "SPEAKER_00")
    }

    @Test func anExactTieIsRefusedAtEveryConfigurableDominantShare() throws {
        // 23 of the 110 unattributed segments on the 2026-09-01 full-file run
        // are exact 50/50 ties. The margin rule refuses them at 0.50, the
        // lowest share the configuration accepts, so no threshold change can
        // reach them and lowering the bar must not be sold as if it could.
        for bar in [0.50, 0.55, 0.60] {
            let result = try TimelineMerger(
                configuration: TimelineMergeConfiguration(dominantSpeakerShare: bar)
            ).merge(
                chunks: singleChunk([
                    Segment(speaker: "UNASSIGNED", startS: 0, endS: 10, text: "split evenly"),
                ]),
                timeline: Timeline(segments: [
                    TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 5),
                    TimelineSegment(speaker: "SPEAKER_01", startS: 5, endS: 10),
                ]),
                source: source
            )
            let attribution = try speakerAttribution(result.conflicts)

            #expect(result.segmentsDocument.segments.first?.speaker == "UNKNOWN")
            #expect(attribution.outcome == .noDominantSpeaker)
            #expect(attribution.candidates.map(\.share) == [0.5, 0.5])
            #expect(attribution.thresholds.dominantSpeakerShare == bar)
        }
    }

    @Test func loweringTheBarNamesMoreSpeakersAndNeverChangesAChosenOne() throws {
        // The error estimate behind keeping 0.60 rests on this property: a
        // threshold decides whether a speaker is named, never which one. The
        // chosen speaker is always the top-ranked candidate and the ranking
        // reads neither threshold, so a sweep can count what a different bar
        // would attribute without re-running the merge.
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 3),
            TimelineSegment(speaker: "SPEAKER_00", startS: 4, endS: 6.8),
            TimelineSegment(speaker: "SPEAKER_01", startS: 6.8, endS: 9),
            TimelineSegment(speaker: "SPEAKER_01", startS: 10, endS: 13.7),
            TimelineSegment(speaker: "SPEAKER_00", startS: 13.7, endS: 15),
        ])
        let chunks = singleChunk([
            Segment(speaker: "UNASSIGNED", startS: 0, endS: 3, text: "one speaker"),
            Segment(speaker: "UNASSIGNED", startS: 4, endS: 9, text: "just under the bar"),
            Segment(speaker: "UNASSIGNED", startS: 10, endS: 15, text: "over the bar"),
        ])

        let shipped = try TimelineMerger().merge(
            chunks: chunks,
            timeline: timeline,
            source: source
        )
        let relaxed = try TimelineMerger(
            configuration: TimelineMergeConfiguration(dominantSpeakerShare: 0.50)
        ).merge(chunks: chunks, timeline: timeline, source: source)
        let shippedSpeakers = shipped.segmentsDocument.segments.map(\.speaker)
        let relaxedSpeakers = relaxed.segmentsDocument.segments.map(\.speaker)
        let refused = try #require(
            shipped.conflicts.first { $0.segmentIndex == 1 }?.speakerAttribution
        )

        #expect(shippedSpeakers == ["SPEAKER_00", "UNKNOWN", "SPEAKER_01"])
        #expect(relaxedSpeakers == ["SPEAKER_00", "SPEAKER_00", "SPEAKER_01"])
        #expect(zip(shippedSpeakers, relaxedSpeakers).allSatisfy { $0 == "UNKNOWN" || $0 == $1 })
        #expect(refused.candidates.first?.speaker == relaxedSpeakers[1])
        #expect(abs((refused.candidates.first?.share ?? 0) - 0.56) < 1e-12)
    }

    @Test func rejectsSegmentsOutsideTheirChunkInsteadOfClampingTimestamps() throws {
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 5,
            primary: hypothesis("primary", [
                Segment(speaker: "UNASSIGNED", startS: 4, endS: 6, text: "outside"),
            ])
        )]

        #expect(throws: TimelineMergeError.invalidPrimarySegment(chunk: 0, segment: 0)) {
            _ = try TimelineMerger().merge(
                chunks: chunks,
                timeline: Timeline(segments: []),
                source: source
            )
        }
    }
}
