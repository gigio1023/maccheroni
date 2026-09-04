import Foundation
import Testing
@testable import MaccheroniCore
@testable import MaccheroniMerge

/// The engine's non-speech markers, `[Silence]` and the like, typed apart from
/// speech without touching the text they sit in.
@Suite struct NonSpeechEventTests {
    private let source = SourceAudio(
        fileName: "synthetic.wav",
        sha256: String(repeating: "a", count: 64),
        durationS: 20
    )

    @Test func aWholeTextMarkerIsAnEventAndKeepsItsMarkerVerbatim() {
        let observed: [(String, NonSpeechEvent.Kind)] = [
            ("[Silence]", .silence),
            ("[Human Sounds]", .humanSounds),
            ("[Environmental Sounds]", .environmentalSounds),
            ("[Music]", .music),
            ("[Noise]", .noise),
            ("[Speech]", .untranscribedSpeech),
        ]
        for (marker, kind) in observed {
            let event = NonSpeechEvent.classify(text: marker)
            #expect(event?.kind == kind, Comment(rawValue: marker))
            #expect(event?.marker == marker)
        }
        // Whitespace around the marker is not part of it; case inside it does
        // not change what it names.
        #expect(NonSpeechEvent.classify(text: "  [Silence]\n")?.marker == "[Silence]")
        #expect(NonSpeechEvent.classify(text: "[silence]")?.kind == .silence)
        // The vocabulary is observed, not published: a label outside it is
        // still an event, and its marker is the only record of what it was.
        let buzzer = NonSpeechEvent.classify(text: "[Buzzer]")
        #expect(buzzer?.kind == .other)
        #expect(buzzer?.marker == "[Buzzer]")
    }

    @Test func aMarkerInsideSpeechLeavesTheSegmentAsSpeech() {
        #expect(NonSpeechEvent.classify(text: "we heard a [Buzzer] just then") == nil)
        #expect(NonSpeechEvent.classify(text: "[Silence] and then words") == nil)
        #expect(NonSpeechEvent.classify(text: "[Silence] [Music]") == nil)
        #expect(NonSpeechEvent.classify(text: "plain words") == nil)
        #expect(NonSpeechEvent.classify(text: "[]") == nil)
        #expect(NonSpeechEvent.classify(text: "[12]") == nil)
        #expect(NonSpeechEvent.classify(text: "[not-a-label]") == nil)
        #expect(NonSpeechEvent.classify(text: "") == nil)
    }

    /// A run sealed before the flag existed is read through its text; a run
    /// that wrote the flag is read through the flag, even when a later layer
    /// rewrote the marker into something the pattern no longer recognises.
    @Test func aStoredSegmentIsReadThroughItsFlagOrElseItsText() {
        #expect(NonSpeechEvent.of(text: "[Silence]", flags: nil)?.kind == .silence)
        #expect(NonSpeechEvent.of(text: "[Silence]", flags: ["conflict"])?.kind == .silence)
        #expect(NonSpeechEvent.of(text: "words", flags: ["conflict"]) == nil)
        let flagged = NonSpeechEvent.of(text: "[Silence]", flags: [NonSpeechEvent.flag])
        #expect(flagged?.kind == .silence)
        let rewritten = NonSpeechEvent.of(text: "[침묵]", flags: [NonSpeechEvent.flag])
        #expect(rewritten?.kind == .other)
        #expect(rewritten?.marker == "[침묵]")
        #expect(NonSpeechEvent.flag == "non_speech_event")
        #expect(NonSpeechEvent.flag.range(
            of: "^[a-z][a-z0-9_-]*$", options: .regularExpression
        ) != nil)
    }

    /// Merge carries the flag beside the verbatim marker and still attributes
    /// the interval from the acoustics: the event says what the audio held,
    /// not who was active, and the timeline is the only thing that can say
    /// that. A mixed segment arrives unflagged and stays unflagged.
    @Test func mergeCarriesTheEventFlagBesideTheVerbatimMarker() throws {
        let timeline = Timeline(segments: [
            TimelineSegment(speaker: "SPEAKER_00", startS: 0, endS: 10),
            TimelineSegment(speaker: "SPEAKER_01", startS: 10, endS: 20),
        ])
        let chunks = [ChunkTranscript(
            index: 0,
            startS: 0,
            endS: 20,
            primary: ASRHypothesis(source: "primary", segments: [
                Segment(
                    speaker: "UNASSIGNED", startS: 0, endS: 2, text: "[Silence]",
                    flags: ["backend_speaker_evidence", NonSpeechEvent.flag]
                ),
                Segment(
                    speaker: "UNASSIGNED", startS: 2, endS: 6,
                    text: "we heard a [Buzzer] just then",
                    flags: ["backend_speaker_evidence"]
                ),
                Segment(
                    speaker: "UNASSIGNED", startS: 8, endS: 12, text: "[Human Sounds]",
                    flags: [NonSpeechEvent.flag]
                ),
            ])
        )]

        let result = try TimelineMerger().merge(chunks: chunks, timeline: timeline, source: source)
        let merged = result.segmentsDocument.segments

        #expect(merged.map(\.text) == ["[Silence]", "we heard a [Buzzer] just then", "[Human Sounds]"])
        #expect(merged[0].speaker == "SPEAKER_00")
        #expect(merged[0].flags == ["backend_speaker_evidence", NonSpeechEvent.flag])
        #expect(merged[1].flags == ["backend_speaker_evidence"])
        // The third straddles both speakers equally, so the acoustics refuse it
        // and the review flags land after the event flag rather than over it.
        #expect(merged[2].speaker == "UNKNOWN")
        #expect(merged[2].flags == [NonSpeechEvent.flag, "conflict", "uncertain"])
        #expect(merged.map { NonSpeechEvent.of(text: $0.text, flags: $0.flags)?.kind }
            == [.silence, nil, .humanSounds])
        // The merged document is still a valid segments document: the flag
        // satisfies the flag syntax the contract fixes.
        #expect(SegmentsDocumentContract.isValid(result.segmentsDocument))
    }
}
