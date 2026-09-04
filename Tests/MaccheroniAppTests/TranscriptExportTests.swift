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
    func translationAcknowledgementClearsOnlyTheExactCurrentResultAndText() throws {
        var fixture = exportFixture()
        fixture.run.manifest.postprocess = ManifestPostprocess(
            backend: BackendDescriptor(name: "codex-app-server", version: "fixture"),
            modelID: "gpt-5.6-sol",
            mode: .translation,
            targetLanguage: "en"
        )
        fixture.run.resultID = "derived-current"
        fixture.record.translationReviewAcknowledgements = [
            TranslationReviewAcknowledgement(
                resultID: "derived-earlier",
                segmentIndex: 0,
                translatedText: "Original text"
            ),
            TranslationReviewAcknowledgement(
                resultID: "derived-current",
                segmentIndex: 0,
                translatedText: "Earlier translated text"
            ),
        ]

        #expect(fixture.run.requiresReview(for: fixture.record))
        #expect(try TranscriptExporter.markdown(
            run: fixture.run,
            record: fixture.record
        ).contains("Original text [UNCERTAIN]"))

        fixture.record.translationReviewAcknowledgements?.append(
            TranslationReviewAcknowledgement(
                resultID: "derived-current",
                segmentIndex: 0,
                translatedText: "Original text"
            )
        )

        #expect(!fixture.run.requiresReview(for: fixture.record))
        let acceptedMarkdown = try TranscriptExporter.markdown(
            run: fixture.run,
            record: fixture.record
        )
        #expect(!acceptedMarkdown.contains("[UNCERTAIN]"))
    }

    @Test
    func derivedCorrectionDoesNotReuseAResolutionFromAnotherResult() throws {
        var fixture = exportFixture()
        fixture.run.resultID = "derived-current"
        fixture.record.conflictResolutions[1] = "Legacy source resolution"
        fixture.record.derivedCorrectionResolutions = [
            DerivedCorrectionResolution(
                resultID: "derived-earlier",
                segmentIndex: 1,
                resolvedText: "Earlier derived resolution"
            ),
        ]

        let unresolved = try TranscriptExporter.correctedSegmentsDocument(
            run: fixture.run,
            record: fixture.record
        )
        #expect(unresolved.segments[1].text == "Unresolved wording")
        #expect(fixture.run.requiresReview(for: fixture.record))

        fixture.record.derivedCorrectionResolutions?.append(
            DerivedCorrectionResolution(
                resultID: "derived-current",
                segmentIndex: 1,
                resolvedText: "Current derived resolution"
            )
        )
        let resolved = try TranscriptExporter.correctedSegmentsDocument(
            run: fixture.run,
            record: fixture.record
        )
        #expect(resolved.segments[1].text == "Current derived resolution")
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

    @Test
    func copyPayloadNamesTheExactDisplayedLayer() throws {
        var fixture = exportFixture()

        #expect(
            try TranscriptExporter.copyText(
                run: fixture.run,
                record: fixture.record,
                selectedSegmentIndices: []
            ).hasPrefix("Transcript layer: Speaker-labelled\n\n")
        )

        fixture.run.manifest.postprocess = postprocessFixture(mode: .correction)
        #expect(
            try TranscriptExporter.copyText(
                run: fixture.run,
                record: fixture.record,
                selectedSegmentIndices: []
            ).hasPrefix("Transcript layer: Corrected\n\n")
        )

        fixture.run.resultID = "derived-translation"
        fixture.run.resultPostprocess = postprocessFixture(mode: .translation)
        fixture.run.resultOperation = derivedOperationFixture(mode: .translation)
        #expect(
            try TranscriptExporter.copyText(
                run: fixture.run,
                record: fixture.record,
                selectedSegmentIndices: []
            ).hasPrefix("Transcript layer: Translated\n\n")
        )
    }

    @Test
    func copySelectionUsesOriginalIndicesAndEmptySelectionCopiesEverything() throws {
        var fixture = exportFixture()
        fixture.record.conflictResolutions.removeValue(forKey: 1)

        let selection = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: [1]
        )

        #expect(!selection.contains("Original text"))
        #expect(selection.contains("Speaker 2:** Unresolved wording [CONFLICT]"))
        #expect(!selection.contains("[UNCERTAIN]"))

        let wholeTranscript = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: []
        )
        #expect(wholeTranscript.contains("Jina:** Original text [UNCERTAIN]"))
        #expect(wholeTranscript.contains("Speaker 2:** Unresolved wording [CONFLICT]"))
    }

    @Test
    func copyPayloadPreservesMarkersWithoutMutatingInputs() throws {
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
        let originalRun = fixture.run
        let originalRecord = fixture.record

        let payload = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: []
        )

        #expect(payload.contains("Original text [CONFLICT] [UNCERTAIN]"))
        #expect(fixture.run == originalRun)
        #expect(fixture.record == originalRecord)
    }

    /// The copy rule for a segment that holds no speech: the engine's marker,
    /// verbatim, in the text position, with the speaker the acoustics gave the
    /// interval. Brackets are the caption convention for a non-speech event
    /// in plain text, and the clipboard is the data surface, so it carries
    /// what the run recorded rather than the reader's-language label the row
    /// prints. Every row, speech or event, is byte-exact.
    @Test
    func aNonSpeechEventRowCopiesTheEnginesMarkerVerbatimAndSpeechRowsStayByteExact() throws {
        var fixture = exportFixture()
        fixture.run.transcript.segments.insert(
            Segment(
                speaker: "UNKNOWN",
                startS: 2,
                endS: 3.5,
                text: "[Silence]",
                flags: ["non_speech_event", "conflict", "uncertain"]
            ),
            at: 1
        )
        fixture.run.transcript.segments.insert(
            Segment(
                speaker: "SPEAKER_00",
                startS: 3.5,
                endS: 5,
                text: "we heard a [Buzzer] just then"
            ),
            at: 2
        )
        fixture.run.segments = fixture.run.transcript.segments.enumerated().map { index, segment in
            TranscriptSegment(
                id: TranscriptSegmentID(runID: "run-001", index: index),
                index: index,
                segment: segment,
                conflict: nil
            )
        }
        fixture.run.conflicts = []
        fixture.record.conflictResolutions = [:]

        let payload = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: [],
            locale: Locale(identifier: "en"),
            layer: .speakerLabelled
        )

        #expect(payload == """
        Transcript layer: Speaker-labelled

        [00:00:00.000 – 00:00:01.235] **Jina:** Original text [UNCERTAIN]

        [00:00:02.000 – 00:00:03.500] **UNKNOWN:** [Silence] [UNCERTAIN]

        [00:00:03.500 – 00:00:05.000] **Jina:** we heard a [Buzzer] just then

        [01:01:01.006 – 01:01:03.500] **Speaker 2:** Unresolved wording

        """)
        let srt = try TranscriptExporter.srt(run: fixture.run, record: fixture.record)
        #expect(srt.contains("00:00:02,000 --> 00:00:03,500\nUNKNOWN: [Silence] [UNCERTAIN]\n"))
        let json = try TranscriptExporter.data(format: .segmentsJSON, run: fixture.run, record: fixture.record)
        let exported = try JSONDecoder().decode(SegmentsDocument.self, from: json)
        #expect(exported.segments[1].text == "[Silence]")
        #expect(exported.segments[1].flags == ["non_speech_event", "conflict", "uncertain"])
    }

    /// A partial run's hole is named in every text export: under the layer
    /// header, and at its place among the rows on a whole-transcript copy, in
    /// the Markdown file, and as its own subtitle in the SRT. Speech rows are
    /// byte-exact around it, and a selection copy names it under the header
    /// only.
    @Test
    func aPartialRunExportNamesItsMissingRangeAndKeepsSpeechRowsByteExact() throws {
        let english = Locale(identifier: "en")
        let root = try derivedLayerTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try derivedLayerRunFixture(in: root, complete: false)
        let run = try LibraryRepository(root: root).loadRun(at: fixture.runURL)
        let record = TranscriptFixtures.record(runURL: fixture.runURL)
        let sentence = "2.0 sec of this recording produced no transcript, from 00:06 to 00:08. The transcript covers 00:06 of 00:08."
        let gapLine = "[00:00:06.000 – 00:00:08.000] No transcript for 2.0 sec of the recording."

        let whole = try TranscriptExporter.copyText(
            run: run,
            record: record,
            selectedSegmentIndices: [],
            locale: english,
            layer: .speakerLabelled
        )
        let lines = whole.components(separatedBy: "\n")
        #expect(lines[0] == "Transcript layer: Speaker-labelled")
        #expect(lines[1] == sentence)
        #expect(lines[2] == "")
        let rows = lines.filter { $0.hasPrefix("[") }
        #expect(rows == [
            "[00:00:00.000 – 00:00:02.000] **SPEAKER_00:** Zero",
            "[00:00:02.000 – 00:00:04.000] **UNKNOWN:** One [CONFLICT]",
            "[00:00:04.000 – 00:00:06.000] **UNKNOWN:** Two [CONFLICT]",
            gapLine,
            "[00:00:06.000 – 00:00:08.000] **SPEAKER_01:** Three",
        ])

        // The same rows, byte for byte, when the run has no hole to name: the
        // gap line and the sentence are the only difference.
        let complete = try derivedLayerRunFixture(in: root, runID: "complete-run")
        let completeCopy = try TranscriptExporter.copyText(
            run: try LibraryRepository(root: root).loadRun(at: complete.runURL),
            record: TranscriptFixtures.record(runURL: complete.runURL),
            selectedSegmentIndices: [],
            locale: english,
            layer: .speakerLabelled
        )
        #expect(completeCopy.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
            == rows.filter { $0 != gapLine })
        #expect(!completeCopy.contains("produced no transcript"))

        // A selection names the hole under the header only.
        let selection = try TranscriptExporter.copyText(
            run: run,
            record: record,
            selectedSegmentIndices: [1, 3],
            locale: english,
            layer: .speakerLabelled
        )
        #expect(selection.components(separatedBy: "\n")[1] == sentence)
        #expect(!selection.contains(gapLine))
        #expect(selection.contains("**UNKNOWN:** One [CONFLICT]"))
        #expect(selection.contains("**SPEAKER_01:** Three"))

        let markdown = try TranscriptExporter.markdown(run: run, record: record)
        #expect(markdown.hasPrefix(sentence + "\n\n[00:00:00.000 – 00:00:02.000] **SPEAKER_00:** Zero\n\n"))
        #expect(markdown.contains("\n\n" + gapLine + "\n\n[00:00:06.000 – 00:00:08.000] **SPEAKER_01:** Three\n"))

        let srt = try TranscriptExporter.srt(run: run, record: record)
        #expect(srt.contains("3\n00:00:04,000 --> 00:00:06,000\nUNKNOWN: Two [CONFLICT]\n\n4\n00:00:06,000 --> 00:00:08,000\nNo transcript for 2.0 sec of the recording.\n\n5\n00:00:06,000 --> 00:00:08,000\nSPEAKER_01: Three\n"))
    }

    @Test @MainActor
    func copyCommandWritesOnceAndReportsLayerAndScope() throws {
        let fixture = exportFixture()
        let selectionClipboard = TranscriptClipboardSpy()
        let selectionCommand = TranscriptCopyCommand(clipboard: selectionClipboard)

        let selectionConfirmation = try selectionCommand.perform(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIDs: [fixture.run.segments[1].id]
        )

        #expect(selectionClipboard.writeCount == 1)
        let expectedSelection = try TranscriptExporter.copyText(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIndices: [1]
        )
        #expect(selectionClipboard.writtenText == expectedSelection)
        #expect(selectionConfirmation.layer == .speakerLabelled)
        #expect(selectionConfirmation.scope == .selection(segmentCount: 1))
        #expect(selectionConfirmation.message(locale: Locale(identifier: "en")) == "Copied the speaker-labelled selection.")

        let staleClipboard = TranscriptClipboardSpy()
        #expect(throws: TranscriptCopyError.staleSelection) {
            try TranscriptCopyCommand(clipboard: staleClipboard).perform(
                run: fixture.run,
                record: fixture.record,
                selectedSegmentIDs: [
                    TranscriptSegmentID(runID: "another-result", index: 1),
                ]
            )
        }
        #expect(staleClipboard.writeCount == 0)

        let transcriptClipboard = TranscriptClipboardSpy()
        let transcriptConfirmation = try TranscriptCopyCommand(
            clipboard: transcriptClipboard
        ).perform(
            run: fixture.run,
            record: fixture.record,
            selectedSegmentIDs: []
        )

        #expect(transcriptClipboard.writeCount == 1)
        #expect(transcriptConfirmation.scope == .transcript)
        #expect(transcriptConfirmation.message(locale: Locale(identifier: "en")) == "Copied the speaker-labelled transcript.")
    }
}

@MainActor
private final class TranscriptClipboardSpy: TranscriptClipboardWriting {
    private(set) var writeCount = 0
    private(set) var writtenText: String?

    func write(_ text: String) -> Bool {
        writeCount += 1
        writtenText = text
        return true
    }
}

private func postprocessFixture(mode: PostprocessMode) -> ManifestPostprocess {
    ManifestPostprocess(
        backend: BackendDescriptor(name: "fixture", version: "1"),
        modelID: "fixture-model",
        mode: mode,
        targetLanguage: mode == .translation ? "en" : nil
    )
}

private func derivedOperationFixture(mode: PostprocessMode) -> DerivedOperation {
    DerivedOperation(
        profileName: "ko-it-meeting",
        mode: mode,
        targetLanguage: mode == .translation ? "en" : nil,
        glossarySemantics: .currentProfile,
        glossaryItemCount: 0
    )
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
