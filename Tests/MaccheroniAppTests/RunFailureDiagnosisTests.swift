import Foundation
import MaccheroniCore
import Testing
@testable import MaccheroniApp

/// The failure screen's contract: a finished run states which stage stopped it
/// and why, a promoted prefix reads as partial rather than failed, and the
/// coverage it reports never comes from the chunk counts.
struct RunFailureDiagnosisTests {
    @Test
    func aSpentLimitOutcomeNamesTheTranscriptionStageAndItsOwnReason() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runURL = try writeRunFixture(
            in: root,
            name: "limit",
            status: .failed,
            failure: Failure(
                code: "RUN_ERROR",
                message: "backend emitted an unsupported limit outcome"
            ),
            coverage: Coverage(
                inputDurationS: 1243.08,
                processedDurationS: 0,
                truncated: true,
                strategy: .chunked,
                chunksPlanned: 2,
                chunksCompleted: 0,
                message: "backend emitted an unsupported limit outcome"
            ),
            artifactKinds: [
                "preprocessed_audio", "vad_map", "chunk_plan",
                "diarization_timeline", "asr_attempt_evidence",
            ]
        )

        let outcome = LibraryRepository(root: root).runOutcome(
            at: runURL,
            recordState: .failed
        )

        #expect(outcome.disposition == .failed)
        #expect(outcome.cause == .asrLimitExhausted)
        #expect(outcome.failedStage == .asr)
        #expect(outcome.status(of: .preprocessing) == .finished)
        #expect(outcome.status(of: .diarization) == .finished)
        #expect(outcome.status(of: .asr) == .failed)
        #expect(outcome.status(of: .merge) == .notReached)
        #expect(outcome.coverage?.processedDurationS == 0)
        #expect(outcome.coverage?.inputDurationS == 1243.08)
    }

    @Test
    func aRejectedSpeakerTimelineStopsAtDiarizationAndReadsDifferently() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runURL = try writeRunFixture(
            in: root,
            name: "diarization",
            status: .failed,
            failure: Failure(
                code: "DIARIZATION_ERROR",
                message: "diarization output is invalid: segment 1 is not ordered after segment 0"
            ),
            coverage: Coverage(
                inputDurationS: 420.048,
                processedDurationS: 0,
                truncated: true,
                strategy: .full,
                chunksPlanned: 1,
                chunksCompleted: 0
            ),
            artifactKinds: [
                "asr_constraint_snapshot", "chunk_plan", "preprocessed_audio",
                "vad_map",
            ]
        )

        let outcome = LibraryRepository(root: root).runOutcome(
            at: runURL,
            recordState: .failed
        )

        #expect(outcome.disposition == .failed)
        #expect(outcome.cause == .diarizationRejectedTimeline)
        #expect(outcome.failedStage == .diarization)
        #expect(outcome.status(of: .preprocessing) == .finished)
        #expect(outcome.status(of: .diarization) == .failed)
        #expect(outcome.status(of: .asr) == .notReached)
        #expect(
            RunFailureCause.diarizationRejectedTimeline.sentenceText()
                != RunFailureCause.asrLimitExhausted.sentenceText()
        )
    }

    @Test
    func aPromotedPrefixReadsAsPartialWithItsCoveredDuration() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The trap: every planned chunk is recorded `succeeded` and
        // chunks_completed equals chunks_planned, yet the run covered a third
        // of its input. Only the durations say so.
        let runURL = try writeRunFixture(
            in: root,
            name: "partial",
            status: .partial,
            failure: Failure(
                code: "ASR_REPETITION_DEGENERATION",
                message: """
                promoted 235.11 s of 641.66 s; 1 range(s) produced no transcript \
                after repetition degeneration exhausted recovery: \
                [235.11, 641.66) s
                """
            ),
            coverage: Coverage(
                inputDurationS: 641.66,
                processedDurationS: 235.11,
                truncated: true,
                strategy: .backendTruncated,
                chunksPlanned: 1,
                chunksCompleted: 1
            ),
            chunkBoundaries: [
                ChunkBoundary(index: 0, startS: 0, endS: 641.66, status: .succeeded),
            ],
            artifactKinds: [
                "preprocessed_audio", "vad_map", "chunk_plan",
                "diarization_timeline", "primary_segments", "merged_segments",
                "partial_coverage",
            ],
            partialCoverage: """
            {
              "schema_version": "1.0.0",
              "input_duration_s": 641.66,
              "promoted_duration_s": 235.11,
              "missing_duration_s": 406.55,
              "missing": [
                {
                  "start_s": 235.11,
                  "end_s": 641.66,
                  "attempt_id": "a0",
                  "stop_reason": "repetitionDegeneration"
                }
              ],
              "partial_attempt_ids": ["a0"]
            }
            """
        )

        let outcome = LibraryRepository(root: root).runOutcome(
            at: runURL,
            recordState: .failed
        )

        #expect(outcome.disposition == .partial)
        #expect(outcome.cause == .repetitionDegeneration)
        let coverage = try #require(outcome.coverage)
        #expect(coverage.processedDurationS == 235.11)
        #expect(coverage.inputDurationS == 641.66)
        #expect(coverage.isShortOfInput)
        #expect(coverage.isBackendTruncated)
        #expect(abs(coverage.coveredFraction - 0.3664) < 0.001)
        #expect(coverage.missingRanges.count == 1)
        #expect(coverage.missingDurationS == 406.55)
        #expect(outcome.status(of: .asr) == .incomplete)
        #expect(coverage.missingRangeLabel() == "3:55–10:42")
        // Nothing above came from chunks_completed, which equals
        // chunks_planned on this very run.
        let manifest = try #require(LibraryRepository.readManifest(at: runURL))
        #expect(manifest.coverage.chunksCompleted == manifest.coverage.chunksPlanned)
    }

    @Test
    func degenerationWithNothingPromotedStaysAFailureNotAPartial() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runURL = try writeRunFixture(
            in: root,
            name: "collapsed",
            status: .failed,
            failure: Failure(
                code: "ASR_REPETITION_DEGENERATION",
                message: "generation collapsed into a repeated token"
            ),
            coverage: Coverage(
                inputDurationS: 641.66,
                processedDurationS: 0,
                truncated: true,
                strategy: .chunked,
                chunksPlanned: 1,
                chunksCompleted: 0
            ),
            artifactKinds: [
                "preprocessed_audio", "vad_map", "chunk_plan",
                "diarization_timeline",
            ]
        )

        let outcome = LibraryRepository(root: root).runOutcome(
            at: runURL,
            recordState: .failed
        )

        #expect(outcome.disposition == .failed)
        #expect(outcome.cause == .repetitionDegeneration)
        #expect(outcome.status(of: .asr) == .failed)
        #expect(outcome.coverage?.promotedAnyAudio == false)
    }

    @Test
    func aCorruptedManifestReadsDifferentlyFromAMissingDependency() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupted = root.appendingPathComponent("corrupted", isDirectory: true)
        try FileManager.default.createDirectory(
            at: corrupted,
            withIntermediateDirectories: true
        )
        try Data("{ \"schema_version\": \"1.".utf8).write(
            to: corrupted.appendingPathComponent("manifest.json")
        )
        let dependency = try writeRunFixture(
            in: root,
            name: "dependency",
            status: .failed,
            failure: Failure(
                code: "PROFILE_ERROR",
                message: "required exact model snapshot is missing: models/vibevoice"
            ),
            coverage: Coverage(
                inputDurationS: 120,
                processedDurationS: 0,
                truncated: true,
                strategy: .full,
                chunksPlanned: 1,
                chunksCompleted: 0
            ),
            artifactKinds: []
        )
        let repository = LibraryRepository(root: root)

        let corruptedOutcome = repository.runOutcome(
            at: corrupted,
            recordState: .failed
        )
        let dependencyOutcome = repository.runOutcome(
            at: dependency,
            recordState: .failed
        )

        #expect(corruptedOutcome.disposition == .unreadable)
        #expect(corruptedOutcome.cause == .unreadableRunRecord)
        #expect(dependencyOutcome.disposition == .failed)
        #expect(dependencyOutcome.cause == .missingDependency)
        #expect(
            RunFailureCause.unreadableRunRecord.sentenceText()
                != RunFailureCause.missingDependency.sentenceText()
        )
    }

    @Test
    func aHashMismatchAMissingFileAndADependencyAllReadApart() throws {
        #expect(
            RunFailureCause.classify(
                code: "SOURCE_INTEGRITY_ERROR",
                message: "A run artifact failed its integrity check: merged/segments.json"
            ) == .integrityMismatch
        )
        #expect(
            RunFailureCause.classify(
                code: "DIARIZATION_ERROR",
                message: "input audio is missing: /tmp/gone.wav"
            ) == .missingFile
        )
        #expect(
            RunFailureCause.classify(
                code: "DIARIZATION_ERROR",
                message: "diarization executable is missing or not executable: helper"
            ) == .missingDependency
        )
        #expect(
            RunFailureCause.classify(
                code: "asr_model_identity_mismatch",
                message: "ASR backend output did not prove the pinned model identity"
            ) == .modelIdentityMismatch
        )
        #expect(
            RunFailureCause.classify(code: "MOSS_LIMIT_EXHAUSTED", message: "")
                == .mossLimitExhausted
        )
        #expect(
            RunFailureCause.classify(code: "ASR_LIMIT_EXHAUSTED", message: "")
                == .asrLimitExhausted
        )
        let sentences = [
            RunFailureCause.integrityMismatch, .missingFile, .missingDependency,
            .modelIdentityMismatch, .mossLimitExhausted, .asrLimitExhausted,
            .repetitionDegeneration, .diarizationRejectedTimeline,
        ].map { $0.sentenceText() }
        #expect(Set(sentences).count == sentences.count)
    }

    @Test
    func everyCauseHasItsOwnSentenceInEveryLocale() {
        let locales = [
            "de", "en", "es", "fr", "it", "ja", "ko", "pt", "ru", "zh-Hans",
        ]
        for identifier in locales {
            let locale = Locale(identifier: identifier)
            let sentences = RunFailureCause.allCases.map {
                $0.sentenceText(locale: locale)
            }
            #expect(
                Set(sentences).count == sentences.count,
                "duplicate cause sentence in \(identifier)"
            )
            for sentence in sentences {
                #expect(!sentence.isEmpty)
            }
        }
    }

    @Test
    func theFailureDetailNeverCarriesARunIDAPathOrAFingerprint() {
        let detail = RunOutcome.sanitizedDetail(
            """
            backend emitted an unsupported limit outcome \
            [run: /Users/someone/Runs/20260831T182603Z-8fc7c0]
            """
        )
        #expect(detail?.contains("20260831T182603Z-8fc7c0") == false)
        #expect(detail?.contains("[run:") == false)
        #expect(detail == "backend emitted an unsupported limit outcome")

        let hashed = RunOutcome.sanitizedDetail(
            "artifact 725c72e54d6ef875472c27fbc50fab470a960940 failed its check"
        )
        #expect(hashed?.contains("725c72e5") == false)
    }

    @Test
    func aSucceededRunHasNoFailureToExplain() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runURL = try writeRunFixture(
            in: root,
            name: "succeeded",
            status: .succeeded,
            failure: nil,
            coverage: Coverage(
                inputDurationS: 120.024,
                processedDurationS: 120.024,
                truncated: false,
                strategy: .full,
                chunksPlanned: 1,
                chunksCompleted: 1
            ),
            artifactKinds: [
                "preprocessed_audio", "vad_map", "chunk_plan",
                "diarization_timeline", "primary_segments", "merged_segments",
            ]
        )

        let outcome = LibraryRepository(root: root).runOutcome(
            at: runURL,
            recordState: .done
        )

        #expect(outcome.disposition == .succeeded)
        #expect(outcome.cause == nil)
        #expect(outcome.failedStage == nil)
        #expect(!outcome.isFailureLike)
        #expect(outcome.coverage?.isShortOfInput == false)
        #expect(outcome.status(of: .merge) == .finished)
    }

    @Test
    func aRunDirectoryThatIsGoneReadsAsAMissingFile() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = LibraryRepository(root: root).runOutcome(
            at: root.appendingPathComponent("never-written", isDirectory: true),
            recordState: .failed
        )

        #expect(outcome.disposition == .failed)
        #expect(outcome.cause == .missingFile)
        #expect(outcome.failedStage == .preparing)
        #expect(outcome.status(of: .preparing) == .failed)
    }

    @Test
    func aLeadingCollapseWithTheRestPromotedReadsAsPartialFromTheStart() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The shape a real 20.7-minute run has today: the first leaf collapses
        // and every later leaf comes back clean, so the gap is at the start
        // and most of the recording is promoted.
        let runURL = try writeRunFixture(
            in: root,
            name: "leading-gap",
            status: .partial,
            failure: Failure(
                code: "ASR_REPETITION_DEGENERATION",
                message: """
                promoted 1135.50 s of 1243.08 s; 1 range(s) produced no \
                transcript after repetition degeneration exhausted recovery: \
                [0.00, 107.58) s
                """
            ),
            coverage: Coverage(
                inputDurationS: 1243.08,
                processedDurationS: 1135.50,
                truncated: true,
                strategy: .backendTruncated,
                chunksPlanned: 2,
                chunksCompleted: 2
            ),
            chunkBoundaries: [
                ChunkBoundary(index: 0, startS: 0, endS: 641.664, status: .succeeded),
                ChunkBoundary(index: 1, startS: 641.664, endS: 1243.08, status: .succeeded),
            ],
            artifactKinds: [
                "preprocessed_audio", "vad_map", "chunk_plan",
                "diarization_timeline", "primary_segments", "merged_segments",
                "partial_coverage",
            ],
            partialCoverage: """
            {
              "schema_version": "1.0.0",
              "input_duration_s": 1243.08,
              "promoted_duration_s": 1135.50,
              "missing_duration_s": 107.58,
              "missing": [
                {
                  "start_s": 0,
                  "end_s": 107.584,
                  "attempt_id": "a0",
                  "stop_reason": "repetitionDegeneration"
                }
              ],
              "partial_attempt_ids": ["a0"]
            }
            """
        )

        let outcome = LibraryRepository(root: root).runOutcome(
            at: runURL,
            recordState: .failed
        )

        #expect(outcome.disposition == .partial)
        #expect(outcome.cause == .repetitionDegeneration)
        let coverage = try #require(outcome.coverage)
        #expect(coverage.isShortOfInput)
        #expect(coverage.promotedAnyAudio)
        #expect(abs(coverage.coveredFraction - 0.9134) < 0.001)
        #expect(coverage.missingRangeLabel() == "0:00–1:48")
        #expect(outcome.status(of: .asr) == .incomplete)
        #expect(outcome.status(of: .merge) == .finished)
        // Both planned chunks are `succeeded` and chunks_completed equals
        // chunks_planned, yet 107.58 s produced no transcript.
        let manifest = try #require(LibraryRepository.readManifest(at: runURL))
        #expect(manifest.chunkBoundaries.allSatisfy { $0.status == .succeeded })
        #expect(manifest.coverage.chunksCompleted == manifest.coverage.chunksPlanned)
    }

    @Test
    func moreMissingRangesThanFitAreCappedRatherThanTruncatedSilently() {
        let coverage = RunCoverageSummary(
            inputDurationS: 600,
            processedDurationS: 400,
            truncated: true,
            isBackendTruncated: true,
            missingRanges: (0 ..< 4).map {
                RunMissingRange(
                    startS: Double($0) * 100,
                    endS: Double($0) * 100 + 50,
                    stopReason: "repetitionDegeneration"
                )
            },
            missingDurationS: 200
        )

        #expect(coverage.missingRangeLabel() == "0:00–0:50, 1:40–2:30, 3:20–4:10, \u{2026}")
        #expect(coverage.missingRangeLabel(limit: 4) == "0:00–0:50, 1:40–2:30, 3:20–4:10, 5:00–5:50")
    }

    @Test
    func aCancelledOrInterruptedRunIsNotDressedUpAsAFailure() throws {
        let root = try diagnosisTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runURL = root.appendingPathComponent("stopped", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runURL,
            withIntermediateDirectories: true
        )
        let repository = LibraryRepository(root: root)

        for state in [LibraryItemState.cancelled, .interrupted] {
            let outcome = repository.runOutcome(
                at: runURL,
                recordState: state,
                recordFailureMessage: "Interrupted"
            )
            #expect(outcome.disposition == .canceled)
            #expect(outcome.cause == nil)
            #expect(outcome.failedStage == nil)
            #expect(!outcome.isFailureLike)
            #expect(outcome.detail == nil)
        }
    }

    @Test
    func theStageChecklistCoversPostProcessingOnlyWhenItWasAskedFor() {
        #expect(RunOutcome.stageOrder(includesPostprocess: false) == [
            .preparing, .preprocessing, .diarization, .asr, .merge,
        ])
        #expect(RunOutcome.stageOrder(includesPostprocess: true).last == .postprocess)
    }
}

// MARK: - Fixtures

private func diagnosisTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("maccheroni-diagnosis-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func writeRunFixture(
    in root: URL,
    name: String,
    status: RunStatus,
    failure: Failure?,
    coverage: Coverage,
    chunkBoundaries: [ChunkBoundary] = [],
    artifactKinds: [String],
    partialCoverage: String? = nil
) throws -> URL {
    let runURL = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
        at: runURL,
        withIntermediateDirectories: true
    )
    let manifest = Manifest(
        runID: name,
        status: status,
        input: InputAudio(fileName: "input.wav", sha256: String(repeating: "0", count: 64), sizeBytes: 1),
        backend: BackendDescriptor(name: "fixture", version: "1"),
        models: [],
        glossary: .absent,
        preprocessing: PreprocessingConfiguration(
            sampleRateHz: 16_000,
            channels: 1,
            peakNormalization: true,
            vad: ProcessingSwitch(enabled: true, backend: "fixture"),
            enhancement: ProcessingSwitch(enabled: false, backend: nil)
        ),
        coverage: coverage,
        chunkBoundaries: chunkBoundaries,
        timing: RunTiming(
            startedAt: "2026-09-01T00:00:00Z",
            finishedAt: "2026-09-01T00:00:01Z",
            wallTimeS: 1
        ),
        artifacts: artifactKinds.map {
            Artifact(kind: $0, path: "\($0).json", sha256: String(repeating: "0", count: 64))
        },
        failure: failure
    )
    try JSONEncoder().encode(manifest).write(
        to: runURL.appendingPathComponent("manifest.json")
    )
    if let partialCoverage {
        let primary = runURL.appendingPathComponent("primary", isDirectory: true)
        try FileManager.default.createDirectory(
            at: primary,
            withIntermediateDirectories: true
        )
        try Data(partialCoverage.utf8).write(
            to: primary.appendingPathComponent("partial-coverage.json")
        )
    }
    return runURL
}
