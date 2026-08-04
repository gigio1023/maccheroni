import Foundation
import MaccheroniCore
import MaccheroniMerge
import Testing
@testable import MaccheroniApp

struct TranscriptExportTests {
    @Test
    func correctedSegmentsApplySidecarWithoutMutatingLoadedRun() throws {
        let fixture = exportFixture()
        let originalRun = fixture.run

        let corrected = try TranscriptExporter.correctedSegmentsDocument(
            run: fixture.run,
            record: fixture.record
        )

        #expect(corrected.schemaVersion == "1.0.0")
        #expect(corrected.numSpeakers == 2)
        #expect(corrected.source == fixture.run.transcript.source)
        #expect(corrected.segments[0].speaker == "Jina")
        #expect(corrected.segments[0].text == "Original text")
        #expect(corrected.segments[0].flags == ["uncertain"])
        #expect(corrected.segments[1].speaker == "Speaker 2")
        #expect(corrected.segments[1].text == "Resolved wording")
        #expect(fixture.run == originalRun)
    }

    @Test
    func segmentsJSONIsDeterministicAndContainsCorrections() throws {
        let fixture = exportFixture()

        let first = try TranscriptExporter.data(
            format: .segmentsJSON,
            run: fixture.run,
            record: fixture.record
        )
        let second = try TranscriptExporter.data(
            format: .segmentsJSON,
            run: fixture.run,
            record: fixture.record
        )
        let decoded = try JSONDecoder().decode(SegmentsDocument.self, from: first)

        #expect(first == second)
        #expect(decoded.segments[0].speaker == "Jina")
        #expect(decoded.segments[0].text == "Original text")
        #expect(decoded.segments[0].startS == 0)
        #expect(decoded.segments[0].endS == 1.2346)
        #expect(decoded.segments[1].text == "Resolved wording")
        let encoded = String(decoding: first, as: UTF8.self)
        #expect(encoded.contains("\"schema_version\" : \"1.0.0\""))
        #expect(!encoded.contains("[CONFLICT]"))
        #expect(!encoded.contains("[UNCERTAIN]"))
    }

    @Test
    func markdownAndSRTUseCorrectedContentAndCarryOnlyUnresolvedMarkers() throws {
        let fixture = exportFixture()

        let markdown = try TranscriptExporter.markdown(run: fixture.run, record: fixture.record)
        let srt = try TranscriptExporter.srt(run: fixture.run, record: fixture.record)

        #expect(markdown == "[00:00:00.000 – 00:00:01.235] **Jina:** Original text [UNCERTAIN]\n\n[01:01:01.006 – 01:01:03.500] **Speaker 2:** Resolved wording\n")
        #expect(srt == "1\n00:00:00,000 --> 00:00:01,235\nJina: Original text [UNCERTAIN]\n\n2\n01:01:01,006 --> 01:01:03,500\nSpeaker 2: Resolved wording\n")
    }

    @Test
    func unresolvedConflictAndUncertainFlagsExportAsStableASCII() throws {
        var fixture = exportFixture()
        fixture.run.transcript.segments[0].flags = ["conflict", "uncertain"]
        fixture.run.conflicts.append(
            MergeConflict(
                segmentIndex: 0,
                kind: .asrDisagreement,
                candidates: ["Original text", "Alternative text"],
                reason: "The comparison backend disagreed."
            )
        )
        fixture.record.conflictResolutions.removeValue(forKey: 1)

        let markdown = try TranscriptExporter.markdown(run: fixture.run, record: fixture.record)
        let srt = try TranscriptExporter.srt(run: fixture.run, record: fixture.record)

        #expect(markdown == "[00:00:00.000 – 00:00:01.235] **Jina:** Original text [CONFLICT] [UNCERTAIN]\n\n[01:01:01.006 – 01:01:03.500] **Speaker 2:** Unresolved wording [CONFLICT]\n")
        #expect(srt == "1\n00:00:00,000 --> 00:00:01,235\nJina: Original text [CONFLICT] [UNCERTAIN]\n\n2\n01:01:01,006 --> 01:01:03,500\nSpeaker 2: Unresolved wording [CONFLICT]\n")
    }

    @Test
    func translationKeepsUncertaintyMarkerDespiteStaleSourceResolution() throws {
        var fixture = exportFixture()
        fixture.run.manifest.postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "codex-app-server", version: "fixture"),
            modelID: "gpt-5.6-sol",
            mode: .translation,
            targetLanguage: "en"
        )
        fixture.record.conflictResolutions[0] = "Stale source-language resolution"

        let document = try TranscriptExporter.correctedSegmentsDocument(
            run: fixture.run,
            record: fixture.record
        )
        let markdown = try TranscriptExporter.markdown(
            run: fixture.run,
            record: fixture.record
        )

        #expect(document.segments[0].text == "Original text")
        #expect(markdown.contains("Original text [UNCERTAIN]"))
        #expect(!markdown.contains("Stale source-language resolution"))
    }

    @Test
    func srtRejectsInvalidIntervalsInsteadOfAlteringTimestamps() throws {
        var fixture = exportFixture()
        fixture.run.transcript.segments[0].endS = 0.0004

        #expect(throws: TranscriptExportError.invalidSRTTimestamp(segmentIndex: 0)) {
            try TranscriptExporter.srt(run: fixture.run, record: fixture.record)
        }
    }

    @Test
    func suggestedFilenamePreservesExtensionsAndAvoidsPathSeparators() {
        var fixture = exportFixture()
        fixture.record.displayName = "Team/Review: August"

        #expect(TranscriptExporter.suggestedFilename(format: .segmentsJSON, record: fixture.record) == "Team_Review_ August.segments.json")
        #expect(TranscriptExporter.suggestedFilename(format: .markdown, record: fixture.record) == "Team_Review_ August.md")
        #expect(TranscriptExporter.suggestedFilename(format: .srt, record: fixture.record) == "Team_Review_ August.srt")
    }
}

private func exportFixture() -> (run: LoadedRun, record: LibraryRecord) {
    let source = SourceAudio(
        fileName: "meeting.wav",
        sha256: String(repeating: "a", count: 64),
        durationS: 3_700
    )
    let transcript = SegmentsDocument(
        segments: [
            Segment(
                speaker: "SPEAKER_00",
                startS: 0,
                endS: 1.2346,
                text: "Original text",
                flags: ["uncertain"]
            ),
            Segment(
                speaker: "SPEAKER_01",
                startS: 3_661.0055,
                endS: 3_663.5,
                text: "Unresolved wording"
            ),
        ],
        numSpeakers: 2,
        source: source
    )
    let run = LoadedRun(
        manifest: Manifest(
            runID: "run-001",
            status: .succeeded,
            input: InputAudio(
                fileName: source.fileName,
                sha256: source.sha256,
                sizeBytes: 1
            ),
            backend: BackendDescriptor(name: "fixture", version: "1"),
            models: [],
            glossary: ManifestGlossary(
                provided: false,
                sha256: nil,
                itemCount: 0,
                injectionMode: .none,
                applied: false
            ),
            preprocessing: PreprocessingConfiguration(
                sampleRateHz: 16_000,
                channels: 1,
                peakNormalization: true,
                vad: ProcessingSwitch(enabled: true, backend: "fixture"),
                enhancement: ProcessingSwitch(enabled: false, backend: nil)
            ),
            coverage: Coverage(
                inputDurationS: source.durationS,
                processedDurationS: source.durationS,
                truncated: false,
                strategy: .full,
                chunksPlanned: 1,
                chunksCompleted: 1
            ),
            chunkBoundaries: [],
            timing: RunTiming(
                startedAt: "2026-08-03T00:00:00Z",
                finishedAt: "2026-08-03T00:00:01Z",
                wallTimeS: 1
            ),
            artifacts: [],
            failure: nil
        ),
        transcript: transcript,
        conflicts: [
            MergeConflict(
                segmentIndex: 1,
                kind: .asrDisagreement,
                candidates: ["Unresolved wording", "Resolved wording"],
                reason: "The comparison backend disagreed."
            ),
        ],
        segments: transcript.segments.enumerated().map { index, segment in
            TranscriptSegment(
                id: TranscriptSegmentID(runID: "run-001", index: index),
                index: index,
                segment: segment,
                conflict: nil
            )
        }
    )
    let record = LibraryRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        createdAt: Date(timeIntervalSince1970: 0),
        displayName: "Meeting",
        sourceKind: .importedFile,
        sourceURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
        securityScopedBookmark: nil,
        microphoneURL: nil,
        systemAudioURL: nil,
        runURL: URL(fileURLWithPath: "/tmp/run-001"),
        profileID: .koreanITMeeting,
        postprocess: .none,
        durationS: source.durationS,
        state: .hasConflicts,
        speakerNames: ["SPEAKER_00": "Jina", "SPEAKER_01": "Speaker 2"],
        conflictResolutions: [1: "Resolved wording"],
        failureMessage: nil
    )
    return (run, record)
}
