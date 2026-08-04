@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import MaccheroniASR
import MaccheroniCore
import MaccheroniDiarize
import MaccheroniMerge
import MaccheroniPostprocess
import MaccheroniPreprocess
import Testing
@testable import MaccheroniCLI

@Suite(.serialized)
struct MaccheroniCLITests {
    @Test
    func runCreatesVerifiedTwoChunkLayoutAndPreservesInput() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let inputHash = try AudioPreprocessor.sha256(of: input)
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            glossaryPath: "terms.txt"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: "success")

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])
        let run = URL(fileURLWithPath: runPath, isDirectory: true)

        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
        let required = [
            "manifest.json",
            "primary/raw.txt",
            "primary/segments.json",
            "diarization/timeline.json",
            "diarization/backend.raw.json",
            "diarization/normalization-warnings.json",
            "merged/segments.json",
            "merged/conflicts.json",
            "primary/chunks/0/audio.wav",
            "primary/chunks/0/backend.raw",
            "primary/chunks/1/audio.wav",
            "primary/chunks/1/backend.raw",
            "preprocess/asr-constraints.json",
            "primary/attempts/chunk-0000-root/request.json",
            "primary/attempts/chunk-0000-root/outcome.json",
            "primary/attempts/chunk-0000-root/result.json",
            "primary/attempts/chunk-0001-root/request.json",
            "primary/attempts/chunk-0001-root/outcome.json",
            "primary/attempts/chunk-0001-root/result.json",
        ]
        for path in required {
            #expect(FileManager.default.fileExists(
                atPath: run.appendingPathComponent(path).path
            ))
        }

        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .succeeded)
        #expect(manifest.failure == nil)
        #expect(manifest.input.fileName == "input.wav")
        #expect(manifest.input.sha256 == inputHash)
        #expect(manifest.models == [
            SelectedASRBackend.vibeVoice.model,
            SileroVADProvenance().model,
            Community1Diarizer().model,
        ])
        #expect(manifest.glossary.provided)
        #expect(manifest.glossary.applied)
        #expect(manifest.glossary.itemCount == 1)
        #expect(manifest.glossary.injectionMode == .freeTextContext)
        #expect(manifest.coverage.chunksPlanned == 2)
        #expect(manifest.coverage.chunksCompleted == 2)
        #expect(!manifest.coverage.truncated)
        #expect(abs(manifest.coverage.inputDurationS - 2) < 0.01)
        #expect(abs(manifest.coverage.processedDurationS - 2) < 0.01)
        #expect(manifest.chunkBoundaries.map(\.status) == [.succeeded, .succeeded])

        let artifactPaths = Set(manifest.artifacts.map(\.path))
        #expect(artifactPaths == (try regularRelativePaths(in: run)).subtracting([
            "manifest.json",
        ]))
        #expect(manifest.artifacts.allSatisfy {
            !$0.path.hasPrefix("/") && !$0.path.split(separator: "/").contains("..")
        })
        for artifact in manifest.artifacts {
            #expect(try AudioPreprocessor.sha256(
                of: run.appendingPathComponent(artifact.path)
            ) == artifact.sha256)
        }

        let expectedSource = SourceAudio(
            fileName: "input.wav",
            sha256: inputHash,
            durationS: 2
        )
        let primary: SegmentsDocument = try decode("primary/segments.json", in: run)
        let merged: SegmentsDocument = try decode("merged/segments.json", in: run)
        let timeline: [TimelineSegment] = try decode(
            "diarization/timeline.json",
            in: run
        )
        let conflicts: [MergeConflict] = try decode(
            "merged/conflicts.json",
            in: run
        )
        #expect(primary.source == expectedSource)
        #expect(merged.source == expectedSource)
        #expect(primary.segments.map(\.speaker) == ["UNASSIGNED", "UNASSIGNED"])
        #expect(timeline.map(\.speaker) == ["S0", "S0"])
        #expect(merged.segments.map(\.speaker) == ["S0", "S0"])
        #expect(conflicts.isEmpty)
        #expect(abs(try audioDuration(
            run.appendingPathComponent("primary/chunks/0/audio.wav")
        ) - 1) < 0.01)
        #expect(abs(try audioDuration(
            run.appendingPathComponent("primary/chunks/1/audio.wav")
        ) - 1) < 0.01)
        #expect(try AVAudioFile(
            forReading: run.appendingPathComponent("primary/chunks/0/audio.wav")
        ).fileFormat.commonFormat == .pcmFormatInt16)
        #expect(try AVAudioFile(
            forReading: run.appendingPathComponent("primary/chunks/1/audio.wav")
        ).fileFormat.commonFormat == .pcmFormatInt16)
    }

    @Test
    func secondChunkFailureLeavesAuditablePartialRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let inputHash = try AudioPreprocessor.sha256(of: input)
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(
            runID: "partial",
            dependencies: testDependencies(failASRAtOrAfterS: 1)
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected the second ASR chunk to fail")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }

        let run = outputRoot.appendingPathComponent("partial", isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .partial)
        #expect(manifest.failure?.code == "RUN_ERROR")
        #expect(manifest.coverage.truncated)
        #expect(abs(manifest.coverage.processedDurationS - 1) < 0.01)
        #expect(manifest.chunkBoundaries.map(\.status) == [.succeeded, .failed])
        #expect(manifest.artifacts.contains {
            $0.path == "primary/chunks/0/backend.raw"
        })
        #expect(manifest.artifacts.contains {
            $0.path == "primary/chunks/1/audio.wav"
        })
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/raw.txt").path
        ))
        #expect(Set(manifest.artifacts.map(\.path)) ==
            (try regularRelativePaths(in: run)).subtracting(["manifest.json"]))
        for artifact in manifest.artifacts {
            #expect(try AudioPreprocessor.sha256(
                of: run.appendingPathComponent(artifact.path)
            ) == artifact.sha256)
        }
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
    }

    @Test
    func inputHashChangeAtCanonicalSealCannotCreatePromotionRecord() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "promotion-race.wav")
        let inputHash = try AudioPreprocessor.sha256(of: input)
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let hashProbe = PromotionHashProbe(actualSHA256: inputHash)
        let app = testApplication(
            runID: "promotion-race",
            dependencies: testDependencies(inputSHA256: { url in
                try hashProbe.sha256(of: url)
            })
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected the promotion hash guard to fail")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }

        let run = outputRoot.appendingPathComponent(
            "promotion-race",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "INPUT_MUTATED")
        #expect(hashProbe.callCount >= 4)
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/promotion.json").path
        ))
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
    }

    @Test
    func runDirectoriesAreCreateOnlyAndDoctorIsRecursivelyReadOnly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: "same")
        let arguments = [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ]
        _ = try await app.execute(arguments: arguments)
        do {
            _ = try await app.execute(arguments: arguments)
            Issue.record("expected a create-only run directory collision")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: outputRoot.path
        ).sorted() == ["same"])

        let before = try recursiveSnapshot(of: root)
        let doctor = try await app.execute(arguments: [
            "doctor",
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
        ])
        #expect(doctor.contains("profile=ko-meeting"))
        #expect(doctor.contains(SelectedASRBackend.vibeVoice.model.revision))
        #expect(doctor.contains(SelectedASRBackend.vibeVoice.model.quantization))
        #expect(doctor.contains("check.disk=true"))
        #expect(doctor.contains("check.asr_doctor=true"))
        #expect(try recursiveSnapshot(of: root) == before)

        let bundled = try await app.execute(arguments: [
            "doctor", "--profile", "it-dialogue",
        ])
        #expect(bundled.contains("profile=it-dialogue"))
        #expect(bundled.contains(SelectedASRBackend.moss.model.hfModelID))
    }

    @Test
    func registryValidationAndCodexPostprocessAreSupported() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: "never-created")

        let duplicate = try profileFile(
            in: root,
            fileName: "duplicates.json",
            duplicate: true
        )
        do {
            _ = try await app.execute(arguments: [
                "doctor", "--profiles", duplicate.path,
            ])
            Issue.record("expected duplicate profiles to be rejected")
        } catch let error as CLIError {
            #expect(error.code == "PROFILE_ERROR")
        }

        let codex = try profileFile(
            in: root,
            fileName: "codex.json",
            postprocess: "codex"
        )
        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", codex.path,
            "--output-root", outputRoot.path,
        ])
        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        let merged: SegmentsDocument = try decode("merged/segments.json", in: run)
        let corrected: SegmentsDocument = try decode(
            "postprocess/segments.json",
            in: run
        )
        let conflicts: [PostprocessConflict] = try decode(
            "postprocess/conflicts.json",
            in: run
        )
        #expect(manifest.status == .succeeded)
        #expect(manifest.postprocess?.backend.name == "codex-app-server")
        #expect(manifest.postprocess?.modelID == CodexPostprocessBackend.modelName)
        #expect(manifest.postprocess?.modelRevision == nil)
        #expect(manifest.postprocess?.quantization == nil)
        #expect(manifest.postprocess?.inputMode == .textOnly)
        #expect(manifest.postprocess?.mode == .correction)
        #expect(manifest.postprocess?.targetLanguage == nil)
        let codexBatching = try #require(manifest.postprocess?.batching)
        #expect(codexBatching.maximumPromptUTF8Bytes
            == CodexPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes)
        #expect(codexBatching.batchesPlanned == 1)
        #expect(codexBatching.maximumObservedPromptUTF8Bytes == 100)
        #expect(codexBatching.maximumObservedResponseUTF8Bytes
            >= codexBatching.maximumObservedOutputTextUTF8Bytes)
        #expect(codexBatching.maximumObservedAcceptedOutputTokenUpperBound
            <= codexBatching.outputTokenPlanningBudget)
        #expect(!manifest.models.contains { $0.role == .postprocess })
        #expect(Set(manifest.artifacts.map(\.kind)).isSuperset(of: [
            "postprocess_segments", "postprocess_conflicts",
        ]))
        #expect(corrected.segments.map(\.speaker) == merged.segments.map(\.speaker))
        #expect(corrected.segments.map(\.startS) == merged.segments.map(\.startS))
        #expect(corrected.segments.map(\.endS) == merged.segments.map(\.endS))
        #expect(corrected.segments[0].text == "Maccheroni corrected")
        #expect(corrected.segments[1].text == merged.segments[1].text)
        #expect(corrected.segments[1].flags == ["uncertain", "conflict"])
        #expect(conflicts.count == 1)

        do {
            _ = try await app.execute(arguments: ["doctor", "--bogus", "value"])
            Issue.record("expected an unknown option to be rejected")
        } catch let error as CLIError {
            #expect(error.code == "USAGE_ERROR")
        }
    }

    @Test
    func localPostprocessRecordsPinnedModelAndPreservesMergedArtifacts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(
            in: root,
            fileName: "local.json",
            postprocess: "local"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: "local")

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])
        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        let mergedURL = run.appendingPathComponent("merged/segments.json")
        let rawURL = run.appendingPathComponent("primary/raw.txt")
        let mergedHash = try AudioPreprocessor.sha256(of: mergedURL)
        let rawHash = try AudioPreprocessor.sha256(of: rawURL)
        let pinned = LocalPostprocessBackend.pinnedModel

        #expect(manifest.postprocess?.backend == LocalPostprocessBackend.descriptor)
        #expect(manifest.postprocess?.modelID == pinned.hfModelID)
        #expect(manifest.postprocess?.modelRevision == pinned.revision)
        #expect(manifest.postprocess?.quantization == pinned.quantization)
        let localBatching = try #require(manifest.postprocess?.batching)
        #expect(localBatching.maximumPromptUTF8Bytes
            == LocalPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes)
        #expect(localBatching.maximumOutputTokens == 1_024)
        #expect(localBatching.outputTokenPlanningBudget == 768)
        #expect(localBatching.batchesPlanned == 1)
        #expect(localBatching.maximumObservedResponseUTF8Bytes
            >= localBatching.maximumObservedOutputTextUTF8Bytes)
        #expect(manifest.models.contains(pinned))
        #expect(manifest.artifacts.first {
            $0.kind == "merged_segments"
        }?.sha256 == mergedHash)
        #expect(manifest.artifacts.first {
            $0.kind == "primary_raw"
        }?.sha256 == rawHash)

        let beforeDoctor = try recursiveSnapshot(of: root)
        let doctor = try await app.execute(arguments: [
            "doctor",
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
        ])
        #expect(doctor.contains("postprocess=local"))
        #expect(doctor.contains("check.postprocess=true"))
        #expect(try recursiveSnapshot(of: root) == beforeDoctor)
    }

    @Test
    func codexTranslationCreatesIndexedArtifactAndPreservesCanonicalBytes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "translation-input.wav")
        let inputHash = try AudioPreprocessor.sha256(of: input)
        let profiles = try profileFile(
            in: root,
            fileName: "translation.json",
            postprocess: "codex",
            postprocessMode: .translation,
            targetLanguage: "en"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: "translation")

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])
        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        let translation: TranslationDocument = try decode(
            "postprocess/translation.json",
            in: run
        )
        let translationObject = try jsonObject(
            "postprocess/translation.json",
            in: run
        )
        let promotion = try jsonObject("primary/promotion.json", in: run)
        let canonicalHashes = try #require(
            promotion["canonical_artifact_sha256"] as? [String: String]
        )
        let mergedURL = run.appendingPathComponent("merged/segments.json")
        let rawURL = run.appendingPathComponent("primary/raw.txt")
        let mergedHash = try AudioPreprocessor.sha256(of: mergedURL)
        let rawHash = try AudioPreprocessor.sha256(of: rawURL)

        #expect(manifest.status == .succeeded)
        #expect(manifest.postprocess?.mode == .translation)
        #expect(manifest.postprocess?.targetLanguage == "en")
        #expect(manifest.postprocess?.sourceSegmentsSHA256 == mergedHash)
        #expect(manifest.postprocess?.backend
            == BackendDescriptor(name: "codex-app-server", version: "codex-cli test"))
        #expect(manifest.postprocess?.modelID == CodexPostprocessBackend.modelName)
        let translationBatching = try #require(manifest.postprocess?.batching)
        #expect(translationBatching.maximumPromptUTF8Bytes
            == CodexPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes)
        #expect(translationBatching.batchesPlanned == translation.batches.count)
        #expect(translationBatching.maximumObservedPromptUTF8Bytes
            == translation.batches.map(\.promptUTF8Bytes).max())
        #expect(translationBatching.maximumObservedResponseUTF8Bytes
            == translation.batches.map(\.responseUTF8Bytes).max())
        #expect(translationBatching.maximumObservedAcceptedOutputTokenUpperBound
            == translation.batches.map(\.acceptedOutputTokenUpperBound).max())
        #expect(manifest.artifacts.contains {
            $0.kind == "postprocess_translation"
                && $0.path == "postprocess/translation.json"
        })
        #expect(!manifest.artifacts.contains {
            ["postprocess_segments", "postprocess_conflicts"].contains($0.kind)
        })
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("postprocess/segments.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("postprocess/conflicts.json").path
        ))

        #expect(translation.targetLanguage == "en")
        #expect(translation.sourceSegmentsSHA256 == mergedHash)
        #expect(translation.translations.map(\.segmentIndex) == [0, 1])
        #expect(translation.batches.map(\.segmentIndices) == [[0, 1]])
        #expect(Set(translationObject.keys) == Set([
            "schema_version", "target_language", "source_segments_sha256",
            "batches", "translations",
        ]))
        let translationRows = try #require(
            translationObject["translations"] as? [[String: Any]]
        )
        #expect(translationRows.allSatisfy {
            Set($0.keys) == Set(["segment_index", "translated_text"])
        })
        let batchRows = try #require(
            translationObject["batches"] as? [[String: Any]]
        )
        #expect(batchRows.allSatisfy {
            Set($0.keys) == Set([
                "batch_index", "segment_indices", "prompt_utf8_bytes",
                "input_text_utf8_bytes", "estimated_output_tokens",
                "output_text_utf8_bytes", "response_utf8_bytes",
                "accepted_output_token_upper_bound",
            ])
        })

        #expect(canonicalHashes["merged/segments.json"] == mergedHash)
        #expect(canonicalHashes["primary/raw.txt"] == rawHash)
        #expect(manifest.artifacts.first {
            $0.kind == "merged_segments"
        }?.sha256 == mergedHash)
        #expect(manifest.artifacts.first {
            $0.kind == "primary_raw"
        }?.sha256 == rawHash)
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
    }

    @Test
    func translationProfileRequiresTargetAndCorrectionRejectsOne() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = testApplication(runID: "unused")
        let missing = try profileFile(
            in: root,
            fileName: "missing-target.json",
            postprocess: "codex",
            postprocessMode: .translation
        )
        let correction = try profileFile(
            in: root,
            fileName: "correction-target.json",
            postprocess: "codex",
            postprocessMode: .correction,
            targetLanguage: "en"
        )

        for url in [missing, correction] {
            do {
                _ = try await app.execute(arguments: [
                    "doctor", "--profile", "ko-meeting", "--profiles", url.path,
                ])
                Issue.record("expected invalid postprocess profile")
            } catch let error as CLIError {
                #expect(error.code == "PROFILE_ERROR")
            }
        }
    }

    @Test
    func postprocessFailurePreservesFullRawAndMergedRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(
            in: root,
            fileName: "local-failure.json",
            postprocess: "local"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(
            runID: "postprocess-failure",
            dependencies: testDependencies(postprocessFailure: true)
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected postprocess failure")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }

        let run = outputRoot.appendingPathComponent(
            "postprocess-failure",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .partial)
        #expect(manifest.failure?.code == "POSTPROCESS_ERROR")
        #expect(!manifest.coverage.truncated)
        #expect(abs(manifest.coverage.processedDurationS - 2) < 0.01)
        #expect(manifest.chunkBoundaries.map(\.status) == [.succeeded, .succeeded])
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/raw.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("merged/segments.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("postprocess/segments.json").path
        ))
    }

    @Test
    func nineteenMinuteMOSSRunBoundsCallsAndPromotesOnlyEOSLeaves() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "nineteen-minutes.wav",
            durationS: 19 * 60
        )
        let inputHash = try AudioPreprocessor.sha256(of: input)
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            fileName: "moss.json",
            glossaryPath: "terms.txt",
            asrBackend: "moss",
            languagePin: "it"
        )
        let outputRoot = root.appendingPathComponent(
            "runs",
            isDirectory: true
        )
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "moss-recovery",
            dependencies: mossTestDependencies(
                recorder: recorder,
                shouldLimit: { startS, endS in
                    abs(startS) < 0.000_001
                        && abs(endS - 120) < 0.000_001
                }
            )
        )

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])
        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        let calls = recorder.calls

        #expect(manifest.status == .succeeded)
        #expect(manifest.failure == nil)
        #expect(manifest.coverage.chunksPlanned == 10)
        #expect(manifest.coverage.chunksCompleted == 10)
        #expect(abs(manifest.coverage.processedDurationS - 19 * 60) < 0.01)
        #expect(manifest.chunkBoundaries.allSatisfy {
            $0.endS - $0.startS <= 120
        })
        #expect(calls.count == 12)
        #expect(calls.allSatisfy { $0.endS - $0.startS <= 120 })
        #expect(recorder.diarizationCalls == 1)
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
        #expect(manifest.glossary.provided)
        #expect(manifest.glossary.applied)
        #expect(manifest.glossary.injectionMode == .hotwordInstruction)

        let raw = try String(
            contentsOf: run.appendingPathComponent("primary/raw.txt"),
            encoding: .utf8
        )
        let mergedData = try Data(
            contentsOf: run.appendingPathComponent("merged/segments.json")
        )
        #expect(!raw.contains("PARENT_PARTIAL_SENTINEL"))
        #expect(!String(decoding: mergedData, as: UTF8.self)
            .contains("PARENT_PARTIAL_SENTINEL"))
        let merged: SegmentsDocument = try decode(
            "merged/segments.json",
            in: run
        )
        #expect(merged.segments.count == 11)
        #expect(merged.segments.allSatisfy { $0.speaker == "S0" })

        let parent = try jsonObject(
            "primary/attempts/chunk-0000-root/outcome.json",
            in: run
        )
        #expect(parent["status"] as? String == "limit_isolated")
        #expect(parent["canonical_promoted"] as? Bool == false)
        #expect(parent["result_path"] == nil)
        #expect(parent["child_attempt_ids"] as? [String] == [
            "chunk-0000-root-l", "chunk-0000-root-r",
        ])
        for child in ["chunk-0000-root-l", "chunk-0000-root-r"] {
            let outcome = try jsonObject(
                "primary/attempts/\(child)/outcome.json",
                in: run
            )
            #expect(outcome["status"] as? String == "eos_complete")
            #expect(outcome["stop_reason"] as? String == "endOfSequence")
            #expect(outcome["canonical_promoted"] as? Bool == false)
        }

        let requestPaths = try regularRelativePaths(in: run).filter {
            $0.hasPrefix("primary/attempts/")
                && $0.hasSuffix("/request.json")
        }
        #expect(requestPaths.count == calls.count)
        for path in requestPaths {
            let request = try jsonObject(path, in: run)
            #expect(request["backend"] as? String == "moss")
            #expect(request["language"] as? String == "it")
            #expect(request["maximum_tokens"] as? Int == 5_120)
            #expect((request["prompt_tokens"] as? Int ?? 0) > 0)
            #expect((request["audio_tokens"] as? Int ?? 0) > 0)
            #expect((request["context_upper_bound_tokens"] as? Int ?? 0)
                < 131_072)
            let model = request["model"] as? [String: Any]
            let modelID = model?["hf_model_id"] as? String
            #expect(modelID == SelectedASRBackend.moss.model.hfModelID)
            let helper = request["helper_fingerprint"] as? [String: Any]
            let contractVersion = helper?["contract_version"] as? String
            #expect(contractVersion == "moss-harness-v2")
        }
        let constraints = try jsonObject(
            "preprocess/asr-constraints.json",
            in: run
        )
        #expect(constraints["maximum_attempt_count"] as? Int == 150)
        #expect(constraints["sequential_concurrency"] as? Int == 1)
        #expect((constraints["retained_pcm_bytes_upper_bound"] as? Int ?? 0)
            == 19 * 60 * 16_000 * 5 * 2)
        let contextPlan = constraints["moss_context_plan"] as? [String: Any]
        #expect((contextPlan?["prompt_tokens"] as? Int ?? 0) > 0)
        let promotion = try jsonObject("primary/promotion.json", in: run)
        let promotedIDs = promotion["eos_leaf_attempt_ids"] as? [String]
        #expect(promotedIDs?.count == 11)
        #expect(promotedIDs?.contains("chunk-0000-root") == false)
        let canonicalHashes = promotion["canonical_artifact_sha256"]
            as? [String: String]
        let canonicalRawSHA256 = try AudioPreprocessor.sha256(
            of: run.appendingPathComponent("primary/raw.txt")
        )
        #expect(canonicalHashes?["primary/raw.txt"] == canonicalRawSHA256)
        #expect(Set(manifest.artifacts.map(\.path)) ==
            (try regularRelativePaths(in: run)).subtracting(["manifest.json"]))
        for artifact in manifest.artifacts {
            #expect(try AudioPreprocessor.sha256(
                of: run.appendingPathComponent(artifact.path)
            ) == artifact.sha256)
        }
    }

    @Test
    func MOSSDepthExhaustionFailsExplicitlyAndPreservesSuccessfulSiblings() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "depth-exhaustion.wav",
            durationS: 240
        )
        let inputHash = try AudioPreprocessor.sha256(of: input)
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            fileName: "moss-depth.json",
            glossaryPath: "terms.txt",
            asrBackend: "moss",
            languagePin: "it"
        )
        let outputRoot = root.appendingPathComponent(
            "runs",
            isDirectory: true
        )
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "moss-depth",
            dependencies: mossTestDependencies(
                recorder: recorder,
                shouldLimit: { startS, _ in
                    abs(startS) < 0.000_001
                }
            )
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected bounded MOSS recovery to exhaust")
        } catch let error as CLIError {
            #expect(error.code == "MOSS_LIMIT_EXHAUSTED")
        }

        let run = outputRoot.appendingPathComponent(
            "moss-depth",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "MOSS_LIMIT_EXHAUSTED")
        #expect(manifest.coverage.chunksCompleted == 0)
        #expect(manifest.coverage.truncated)
        #expect(recorder.calls.count == 5)
        #expect(recorder.calls.allSatisfy { $0.endS - $0.startS <= 120 })
        #expect(recorder.diarizationCalls == 1)
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/raw.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("merged/segments.json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent(
                "primary/attempts/chunk-0000-root-r/result.json"
            ).path
        ))
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent(
                "primary/attempts/chunk-0000-root-l-l/outcome.json"
            ).path
        ))
        let exhausted = try jsonObject(
            "primary/attempts/chunk-0000-root-l-l/outcome.json",
            in: run
        )
        #expect(exhausted["status"] as? String == "limit_exhausted")
        #expect(exhausted["canonical_promoted"] as? Bool == false)
        #expect(exhausted["result_path"] == nil)
        #expect(Set(manifest.artifacts.map(\.path)) ==
            (try regularRelativePaths(in: run)).subtracting(["manifest.json"]))
    }

    @Test
    func MOSSCancellationClosesReferencedUnstartedSibling() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "canceled-recovery.wav",
            durationS: 240
        )
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            fileName: "moss-canceled.json",
            glossaryPath: "terms.txt",
            asrBackend: "moss",
            languagePin: "it"
        )
        let outputRoot = root.appendingPathComponent(
            "runs",
            isDirectory: true
        )
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "moss-canceled",
            dependencies: mossTestDependencies(
                recorder: recorder,
                shouldLimit: { startS, endS in
                    abs(startS) < 0.000_001 && abs(endS - 120) < 0.000_001
                },
                shouldCancel: { startS, endS in
                    abs(startS) < 0.000_001 && abs(endS - 60) < 0.000_001
                }
            )
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected cancellation")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }

        let run = outputRoot.appendingPathComponent(
            "moss-canceled",
            isDirectory: true
        )
        let parent = try jsonObject(
            "primary/attempts/chunk-0000-root/outcome.json",
            in: run
        )
        let left = try jsonObject(
            "primary/attempts/chunk-0000-root-l/outcome.json",
            in: run
        )
        let right = try jsonObject(
            "primary/attempts/chunk-0000-root-r/outcome.json",
            in: run
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(parent["status"] as? String == "limit_isolated")
        #expect(left["status"] as? String == "canceled")
        #expect(right["status"] as? String == "canceled")
        #expect(right["request_sha256"] == nil)
        // An in-progress cancellation and an unstarted sibling must persist the
        // same code; the presentation error stays the generic run failure.
        #expect(left["error_code"] as? String == "CANCELED")
        #expect(right["error_code"] as? String == "CANCELED")
        #expect(manifest.failure?.code == "CANCELED")
        #expect(recorder.calls.count == 2)
        #expect(Set(try regularRelativePaths(in: run)).contains(
            "primary/attempts/chunk-0000-root-r/outcome.json"
        ))
    }

    @Test
    func invalidEOSOutputFailsWithoutRecoveryOrPromotion() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "invalid-eos.wav")
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            fileName: "invalid-eos.json",
            glossaryPath: "terms.txt",
            asrBackend: "moss",
            languagePin: "it"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let recorder = MOSSAttemptRecorder()
        var dependencies = mossTestDependencies(
            recorder: recorder,
            shouldLimit: { _, _ in false }
        )
        dependencies.asr = { _, _, _, _ in
            throw ASRAdapterError.invalidEOSOutput(
                "MOSS EOS output has no validated segments"
            )
        }
        let app = testApplication(
            runID: "invalid-eos",
            dependencies: dependencies
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected invalid EOS output to fail the run")
        } catch {
            // The stable persisted code, not the presentation error, is the contract.
        }

        let run = outputRoot.appendingPathComponent(
            "invalid-eos",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        let outcome = try jsonObject(
            "primary/attempts/chunk-0000-root/outcome.json",
            in: run
        )
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "invalid_eos_output")
        #expect(outcome["status"] as? String == "invalid_eos_output")
        #expect(outcome["error_code"] as? String == "invalid_eos_output")
        #expect(outcome["child_attempt_ids"] as? [String] == [])
        #expect(outcome["canonical_promoted"] as? Bool == false)
        #expect(outcome["result_path"] == nil)
        #expect(recorder.calls.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/raw.txt").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/segments.json").path
        ))
    }

    @Test
    func typedASRFailuresKeepDistinctPersistedCodes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "typed-failures.wav")
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            fileName: "typed-failures.json",
            glossaryPath: "terms.txt",
            asrBackend: "moss",
            languagePin: "it"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let cases: [(
            runID: String,
            error: ASRAdapterError,
            status: String,
            code: String
        )] = [
            (
                "asr-timed-out",
                .timedOut(900),
                "asr_timeout",
                "asr_timeout"
            ),
            (
                "asr-malformed",
                .malformedOutput("synthetic malformed output"),
                "asr_malformed_output",
                "asr_malformed_output"
            ),
            (
                "asr-coverage",
                .coverageShortfall("synthetic coverage shortfall"),
                "asr_coverage_shortfall",
                "asr_coverage_shortfall"
            ),
            (
                "asr-identity",
                .modelIdentityMismatch,
                "asr_model_identity_mismatch",
                "asr_model_identity_mismatch"
            ),
            (
                "asr-unclassified",
                .launchFailed("synthetic launch failure"),
                "backend_failed",
                "ASR_ERROR"
            ),
        ]
        var observed: [String: (status: String, code: String)] = [:]

        for testCase in cases {
            let recorder = MOSSAttemptRecorder()
            var dependencies = mossTestDependencies(
                recorder: recorder,
                shouldLimit: { _, _ in false }
            )
            let failure = testCase.error
            dependencies.asr = { _, _, _, _ in throw failure }
            let app = testApplication(
                runID: testCase.runID,
                dependencies: dependencies
            )

            do {
                _ = try await app.execute(arguments: [
                    "run", input.path,
                    "--profile", "ko-meeting",
                    "--profiles", profiles.path,
                    "--output-root", outputRoot.path,
                ])
                Issue.record("expected \(testCase.runID) to fail the run")
            } catch {
                // The stable persisted codes below are the contract.
            }

            let run = outputRoot.appendingPathComponent(
                testCase.runID,
                isDirectory: true
            )
            let manifest: Manifest = try decode("manifest.json", in: run)
            let outcome = try jsonObject(
                "primary/attempts/chunk-0000-root/outcome.json",
                in: run
            )
            #expect(manifest.status == .failed)
            #expect(manifest.failure?.code == testCase.code)
            #expect(outcome["status"] as? String == testCase.status)
            #expect(outcome["error_code"] as? String == testCase.code)
            #expect(outcome["child_attempt_ids"] as? [String] == [])
            #expect(outcome["canonical_promoted"] as? Bool == false)
            #expect(outcome["result_path"] == nil)
            observed[testCase.runID] = (
                status: (outcome["status"] as? String) ?? "",
                code: (outcome["error_code"] as? String) ?? ""
            )
        }

        let statuses = Set(observed.values.map { $0.status })
        let codes = Set(observed.values.map { $0.code })
        #expect(observed.count == cases.count)
        #expect(statuses.count == cases.count)
        #expect(codes.count == cases.count)
        #expect(observed["asr-timed-out"]?.status
            != observed["asr-malformed"]?.status)
        #expect(observed["asr-timed-out"]?.code
            != observed["asr-malformed"]?.code)
    }

    @Test
    func MOSSContextPreflightRejectsBeforeDiarizationOrInference() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "context-overflow.wav")
        let inputHash = try AudioPreprocessor.sha256(of: input)
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            fileName: "moss-context.json",
            glossaryPath: "terms.txt",
            asrBackend: "moss",
            languagePin: "it"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "moss-context",
            dependencies: mossTestDependencies(
                recorder: recorder,
                contextPlanFailure: true,
                shouldLimit: { _, _ in false }
            )
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected MOSS context preflight rejection")
        } catch {
            #expect(recorder.calls.isEmpty)
        }

        let run = outputRoot.appendingPathComponent(
            "moss-context",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        let constraints = try jsonObject(
            "preprocess/asr-constraints.json",
            in: run
        )
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "ASR_ERROR")
        #expect(recorder.calls.isEmpty)
        #expect(recorder.diarizationCalls == 0)
        #expect(constraints["moss_context_plan"] == nil)
        #expect((constraints["preflight_failure"] as? String)?
            .contains("synthetic context overflow") == true)
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/attempts").path
        ))
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
    }

    @Test
    func benchmarkPolicyOverridesAreExplicitBoundedAndRecorded() throws {
        let defaults = try CLIASRInferencePolicy.resolvedPolicy(
            for: .moss,
            environment: [:]
        )
        #expect(defaults.source == "production-default")
        #expect(defaults.minimumInitialDurationS == 60)
        #expect(defaults.preferredInitialDurationS == 120)
        #expect(defaults.maximumInitialDurationS == 120)
        #expect(defaults.minimumRecoveryDurationS == 30)
        #expect(defaults.maximumRecoveryDepth == 3)
        #expect(defaults.maximumTokens == 5_120)

        #expect(throws: CLIError.self) {
            _ = try CLIASRInferencePolicy.resolvedPolicy(
                for: .moss,
                environment: ["MACCHERONI_MOSS_EVAL_LEAF_SECONDS": "120"]
            )
        }

        let activity = try VoiceActivityMap(
            durationS: 600,
            regions: [
                VoiceActivityRegion(startS: 0, endS: 600, kind: .speech),
            ]
        )
        let expectedDurations = [
            120.0: [120.0, 120.0, 120.0, 120.0, 120.0],
            240.0: [240.0, 240.0, 120.0],
            300.0: [300.0, 300.0],
        ]
        for (leafSeconds, durations) in expectedDurations {
            let policy = try CLIASRInferencePolicy.resolvedPolicy(
                for: .moss,
                environment: [
                    "MACCHERONI_ENABLE_BENCHMARK_OVERRIDES": "1",
                    "MACCHERONI_MOSS_EVAL_LEAF_SECONDS": String(Int(leafSeconds)),
                ]
            )
            #expect(policy.source == "benchmark-evaluation")
            #expect(policy.minimumInitialDurationS == 120)
            #expect(policy.preferredInitialDurationS == leafSeconds)
            #expect(policy.maximumInitialDurationS == leafSeconds)
            #expect(policy.maximumTokens == 5_120)
            let leaves = try InferenceLeafPlanner().proposeInitialLeaves(
                totalSamples: 600 * 16_000,
                activityMap: activity,
                configuration: policy.planningConfiguration
            )
            #expect(leaves.map {
                Double($0.sampleCount) / 16_000
            } == durations)
        }

        let forced = try CLIASRInferencePolicy.resolvedPolicy(
            for: .moss,
            environment: [
                "MACCHERONI_ENABLE_BENCHMARK_OVERRIDES": "1",
                "MACCHERONI_MOSS_EVAL_LEAF_SECONDS": "240",
                "MACCHERONI_MOSS_EVAL_MAX_TOKENS": "1024",
            ]
        )
        #expect(forced.source == "benchmark-evaluation")
        #expect(forced.maximumTokens == 1_024)
    }

    private func testApplication(
        runID: String,
        dependencies: CLIDependencies? = nil
    ) -> CLIApplication {
        CLIApplication(
            dependencies: dependencies ?? testDependencies(),
            now: { Date(timeIntervalSince1970: 1_786_000_000) },
            runID: { _ in runID }
        )
    }
}

private func testDependencies(
    failASRAtOrAfterS: Double? = nil,
    postprocessFailure: Bool = false,
    inputSHA256: @escaping @Sendable (URL) throws -> String = {
        try AudioPreprocessor.sha256(of: $0)
    }
) -> CLIDependencies {
    CLIDependencies(
        inputSHA256: inputSHA256,
        inferencePolicy: { CLIASRInferencePolicy.policy(for: $0) },
        preprocess: { input, directory in
            try AudioPreprocessor().preprocess(
                inputURL: input,
                outputDirectory: directory
            )
        },
        vad: { url in
            let duration = try audioDuration(url)
            return try VoiceActivityMap(
                durationS: duration,
                regions: [
                    VoiceActivityRegion(
                        startS: 0,
                        endS: duration,
                        kind: .silence
                    ),
                ]
            )
        },
        plan: { _, _, _ in
            [
                InferenceLeaf(
                    startSample: 0,
                    endSample: 16_000,
                    depth: 0,
                    boundarySource: .silence
                ),
                InferenceLeaf(
                    startSample: 16_000,
                    endSample: 32_000,
                    depth: 0,
                    boundarySource: .inputEnd
                ),
            ]
        },
        expectedHelperFingerprint: { _ in nil },
        mossContextPlan: { _, _, _, _, _ in nil },
        diarize: { _, _ in
            let segments = [
                TimelineSegment(speaker: "S0", startS: 0, endS: 1),
                TimelineSegment(speaker: "S0", startS: 1, endS: 2),
            ]
            return DiarizationTimelineResult(
                timeline: Timeline(segments: segments),
                rawJSON: try JSONEncoder().encode(segments),
                normalizationWarnings: []
            )
        },
        asr: { _, request, _, _ in
            if let failASRAtOrAfterS,
               request.startS >= failASRAtOrAfterS
            {
                throw CLIError.run("synthetic ASR failure")
            }
            let duration = try audioDuration(request.audioURL)
            guard abs(duration - (request.endS - request.startS)) < 0.01 else {
                throw CLIError.run("ASR received a non-physical chunk")
            }
            let file = try AVAudioFile(forReading: request.audioURL)
            guard file.processingFormat.channelCount == 1,
                  abs(file.processingFormat.sampleRate - 16_000) < 0.5
            else {
                throw CLIError.run("ASR received the wrong audio format")
            }
            let index = Int(request.startS.rounded())
            let glossary = request.glossary.map {
                ManifestGlossary(
                    provided: true,
                    sha256: $0.sha256,
                    itemCount: $0.entries.count,
                    injectionMode: request.injectionMode,
                    applied: true
                )
            } ?? .absent
            let attemptAudioSHA256 = try AudioPreprocessor.sha256(
                of: request.audioURL
            )
            let result = ASRResult(
                    rawText: "raw\(index)",
                    segments: [
                        Segment(
                            speaker: "UNASSIGNED",
                            startS: request.startS + 0.1,
                            endS: request.startS + 0.9,
                            text: "text\(index)",
                            language: "ko"
                        ),
                    ],
                    glossaryApplied: request.glossary != nil
                )
            return .complete(CLIASRExecution(
                result: result,
                evidence: CLIASRAttemptEvidence(
                    glossary: glossary,
                    rawEvidence: Data("backend raw \(index)".utf8),
                    runnerRecordEvidence: try JSONEncoder().encode(result),
                    glossaryPayloadSHA256: request.glossary == nil
                        ? nil
                        : attemptAudioSHA256,
                    glossaryPayloadEntryCount: request.glossary?.entries.count ?? 0,
                    inputSHA256: attemptAudioSHA256
                )
            ))
        },
        postprocess: { backend, request in
            if postprocessFailure {
                throw PostprocessError.backendFailed(
                    "synthetic postprocess failure"
                )
            }
            var document = request.document
            document.segments[0].text = "Maccheroni corrected"
            document.segments[1].flags = ["uncertain", "conflict"]
            let inputTextUTF8Bytes = request.document.segments.reduce(0) {
                $0 + $1.text.utf8.count
            }
            let outputTextUTF8Bytes = "Maccheroni corrected".utf8.count
                + "candidate".utf8.count
                + "needs review".utf8.count
            let responseUTF8Bytes = outputTextUTF8Bytes + 64
            let promptUTF8Bytes = 100
            let provenance: ManifestPostprocess
            switch backend {
            case .codex:
                let policy = CodexPostprocessBackend.defaultBatchPolicy
                provenance = ManifestPostprocess(
                    backend: BackendDescriptor(
                        name: "codex-app-server",
                        version: "codex-cli test"
                    ),
                    modelID: CodexPostprocessBackend.modelName,
                    glossarySHA256: request.glossary?.sha256,
                    batching: policy.manifest(
                        batchesPlanned: 1,
                        maximumObservedPromptUTF8Bytes: promptUTF8Bytes,
                        maximumObservedInputTextUTF8Bytes: inputTextUTF8Bytes,
                        maximumObservedEstimatedOutputTokens:
                            policy.estimatedOutputTokens(
                                inputTextUTF8Bytes: inputTextUTF8Bytes,
                                segmentCount: request.document.segments.count
                            ),
                        maximumObservedOutputTextUTF8Bytes: outputTextUTF8Bytes,
                        maximumObservedResponseUTF8Bytes: responseUTF8Bytes,
                        maximumObservedAcceptedOutputTokenUpperBound:
                            policy.acceptedOutputTokenUpperBound(
                                responseUTF8Bytes: responseUTF8Bytes,
                                segmentCount: request.document.segments.count
                            )
                    )
                )
            case .local:
                let pinned = LocalPostprocessBackend.pinnedModel
                let policy = LocalPostprocessBackend.defaultBatchPolicy
                provenance = ManifestPostprocess(
                    backend: LocalPostprocessBackend.descriptor,
                    modelID: pinned.hfModelID,
                    modelRevision: pinned.revision,
                    quantization: pinned.quantization,
                    glossarySHA256: request.glossary?.sha256,
                    batching: policy.manifest(
                        batchesPlanned: 1,
                        maximumObservedPromptUTF8Bytes: promptUTF8Bytes,
                        maximumObservedInputTextUTF8Bytes: inputTextUTF8Bytes,
                        maximumObservedEstimatedOutputTokens:
                            policy.estimatedOutputTokens(
                                inputTextUTF8Bytes: inputTextUTF8Bytes,
                                segmentCount: request.document.segments.count
                            ),
                        maximumObservedOutputTextUTF8Bytes: outputTextUTF8Bytes,
                        maximumObservedResponseUTF8Bytes: responseUTF8Bytes,
                        maximumObservedAcceptedOutputTokenUpperBound:
                            policy.acceptedOutputTokenUpperBound(
                                responseUTF8Bytes: responseUTF8Bytes,
                                segmentCount: request.document.segments.count
                            )
                    )
                )
            }
            return PostprocessResult(
                document: document,
                conflicts: [
                    PostprocessConflict(
                        segmentIndex: 1,
                        originalText: request.document.segments[1].text,
                        candidateText: "candidate",
                        reason: "needs review"
                    ),
                ],
                manifestPostprocess: provenance
            )
        },
        translate: { backend, request in
            if postprocessFailure {
                throw PostprocessError.backendFailed(
                    "synthetic translation failure"
                )
            }
            let translations = request.document.segments.indices.map {
                SegmentTranslation(
                    segmentIndex: $0,
                    translatedText: "translated-\($0)"
                )
            }
            let policy = switch backend {
            case .codex: CodexPostprocessBackend.defaultBatchPolicy
            case .local: LocalPostprocessBackend.defaultBatchPolicy
            }
            let inputTextUTF8Bytes = request.document.segments.reduce(0) {
                $0 + $1.text.utf8.count
            }
            let outputTextUTF8Bytes = translations.reduce(0) {
                $0 + $1.translatedText.utf8.count
            }
            let responseUTF8Bytes = try JSONEncoder().encode([
                "translations": translations,
            ]).count
            let estimatedOutputTokens = policy.estimatedOutputTokens(
                inputTextUTF8Bytes: inputTextUTF8Bytes,
                segmentCount: request.document.segments.count
            )
            let acceptedOutputTokenUpperBound =
                policy.acceptedOutputTokenUpperBound(
                    responseUTF8Bytes: responseUTF8Bytes,
                    segmentCount: translations.count
                )
            let batching = policy.manifest(
                batchesPlanned: 1,
                maximumObservedPromptUTF8Bytes: 100,
                maximumObservedInputTextUTF8Bytes: inputTextUTF8Bytes,
                maximumObservedEstimatedOutputTokens: estimatedOutputTokens,
                maximumObservedOutputTextUTF8Bytes: outputTextUTF8Bytes,
                maximumObservedResponseUTF8Bytes: responseUTF8Bytes,
                maximumObservedAcceptedOutputTokenUpperBound:
                    acceptedOutputTokenUpperBound
            )
            let provenance: ManifestPostprocess
            switch backend {
            case .codex:
                provenance = ManifestPostprocess(
                    backend: BackendDescriptor(
                        name: "codex-app-server",
                        version: "codex-cli test"
                    ),
                    modelID: CodexPostprocessBackend.modelName,
                    glossarySHA256: request.glossary?.sha256,
                    mode: .translation,
                    targetLanguage: request.targetLanguage,
                    sourceSegmentsSHA256: request.sourceSegmentsSHA256,
                    batching: batching
                )
            case .local:
                let pinned = LocalPostprocessBackend.pinnedModel
                provenance = ManifestPostprocess(
                    backend: LocalPostprocessBackend.descriptor,
                    modelID: pinned.hfModelID,
                    modelRevision: pinned.revision,
                    quantization: pinned.quantization,
                    glossarySHA256: request.glossary?.sha256,
                    mode: .translation,
                    targetLanguage: request.targetLanguage,
                    sourceSegmentsSHA256: request.sourceSegmentsSHA256,
                    batching: batching
                )
            }
            return TranslationResult(
                document: TranslationDocument(
                    targetLanguage: request.targetLanguage,
                    sourceSegmentsSHA256: request.sourceSegmentsSHA256,
                    batches: [TranslationBatchRecord(
                        batchIndex: 0,
                        segmentIndices: Array(request.document.segments.indices),
                        promptUTF8Bytes: min(100, policy.maximumPromptUTF8Bytes),
                        inputTextUTF8Bytes: request.document.segments.reduce(0) {
                            $0 + $1.text.utf8.count
                        },
                        estimatedOutputTokens: policy.estimatedOutputTokens(
                            inputTextUTF8Bytes: request.document.segments.reduce(0) {
                                $0 + $1.text.utf8.count
                            },
                            segmentCount: request.document.segments.count
                        ),
                        outputTextUTF8Bytes: outputTextUTF8Bytes,
                        responseUTF8Bytes: responseUTF8Bytes,
                        acceptedOutputTokenUpperBound:
                            acceptedOutputTokenUpperBound
                    )],
                    translations: translations
                ),
                manifestPostprocess: provenance
            )
        },
        postprocessDoctor: { backend in
            [
                "postprocess_backend=\(backend.rawValue)-fixture",
                "check.postprocess=true",
            ]
        },
        doctor: { _, _ in
            [
                "check.asr_doctor=true",
                "check.vad_executable=true",
                "check.vad_model_cache=true",
                "check.diarization_executable=true",
                "check.diarization_model_cache=true",
            ]
        }
    )
}

private final class MOSSAttemptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [(startS: Double, endS: Double)] = []
    private var storedDiarizationCalls = 0

    var calls: [(startS: Double, endS: Double)] {
        lock.withLock { storedCalls }
    }

    var diarizationCalls: Int {
        lock.withLock { storedDiarizationCalls }
    }

    func record(startS: Double, endS: Double) {
        lock.withLock {
            storedCalls.append((startS, endS))
        }
    }

    func recordDiarization() {
        lock.withLock {
            storedDiarizationCalls += 1
        }
    }
}

private final class PromotionHashProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let actualSHA256: String
    private var storedCallCount = 0

    init(actualSHA256: String) {
        self.actualSHA256 = actualSHA256
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func sha256(of _: URL) throws -> String {
        lock.withLock {
            storedCallCount += 1
            return storedCallCount >= 3
                ? String(repeating: "f", count: 64)
                : actualSHA256
        }
    }
}

private func mossTestDependencies(
    recorder: MOSSAttemptRecorder,
    contextPlanFailure: Bool = false,
    shouldLimit: @escaping @Sendable (Double, Double) -> Bool,
    shouldCancel: @escaping @Sendable (Double, Double) -> Bool = { _, _ in
        false
    }
) -> CLIDependencies {
    let fingerprint = testMOSSFingerprint()
    return CLIDependencies(
        inputSHA256: { try AudioPreprocessor.sha256(of: $0) },
        inferencePolicy: { CLIASRInferencePolicy.policy(for: $0) },
        preprocess: { input, directory in
            try AudioPreprocessor().preprocess(
                inputURL: input,
                outputDirectory: directory
            )
        },
        vad: { url in
            let duration = try audioDuration(url)
            return try VoiceActivityMap(
                durationS: duration,
                regions: [
                    VoiceActivityRegion(
                        startS: 0,
                        endS: duration,
                        kind: .silence
                    ),
                ]
            )
        },
        plan: { map, policy, totalSamples in
            return try InferenceLeafPlanner().proposeInitialLeaves(
                totalSamples: totalSamples,
                activityMap: map,
                configuration: InferenceLeafPlanningConfiguration(
                    sampleRateHz: policy.sampleRateHz,
                    preferredInitialDurationS: policy.preferredInitialDurationS,
                    minimumInitialDurationS: policy.minimumInitialDurationS,
                    maximumInitialDurationS: policy.maximumInitialDurationS,
                    minimumRecoveryDurationS: policy.minimumRecoveryDurationS,
                    maximumRecoveryDepth: policy.maximumRecoveryDepth
                )
            )
        },
        expectedHelperFingerprint: { selected in
            selected == .moss ? fingerprint : nil
        },
        mossContextPlan: { selected, samples, language, glossary, tokens in
            guard selected == .moss else { return nil }
            if contextPlanFailure {
                throw ASRAdapterError.invalidRequest(
                    "synthetic context overflow"
                )
            }
            return try syntheticMOSSContextPlan(
                sampleCount: samples,
                language: language,
                glossary: glossary,
                maximumTokens: tokens,
                fingerprint: fingerprint
            )
        },
        diarize: { _, request in
            recorder.recordDiarization()
            let duration = try audioDuration(request.audioURL)
            let segments = [
                TimelineSegment(speaker: "S0", startS: 0, endS: duration),
            ]
            return DiarizationTimelineResult(
                timeline: Timeline(segments: segments),
                rawJSON: try JSONEncoder().encode(segments),
                normalizationWarnings: []
            )
        },
        asr: { selected, request, _, maximumTokens in
            guard selected == .moss else {
                throw CLIError.run("synthetic dependency only supports MOSS")
            }
            recorder.record(startS: request.startS, endS: request.endS)
            if shouldCancel(request.startS, request.endS) {
                throw CancellationError()
            }
            let limit = shouldLimit(request.startS, request.endS)
            let file = try AVAudioFile(forReading: request.audioURL)
            let contextPlan = try syntheticMOSSContextPlan(
                sampleCount: Int64(file.length),
                language: request.language,
                glossary: request.glossary,
                maximumTokens: maximumTokens,
                fingerprint: fingerprint
            )
            let promptTokens = try contextPlan.attemptPlan(
                sampleCount: Int64(file.length)
            ).promptTokens
            let evidence = try mossAttemptEvidence(
                request: request,
                maximumTokens: maximumTokens,
                promptTokens: promptTokens,
                fingerprint: fingerprint,
                limit: limit
            )
            if limit {
                return .limit(CLIASRLimit(
                    stopReason: .maximumTokens,
                    evidence: evidence
                ))
            }
            let result = ASRResult(
                rawText: "EOS-\(request.startS)-\(request.endS)",
                segments: [
                    Segment(
                        speaker: "UNASSIGNED",
                        startS: request.startS + 0.1,
                        endS: request.endS - 0.1,
                        text: "Maccheroni \(request.startS)",
                        language: "it"
                    ),
                ],
                glossaryApplied: request.glossary != nil
            )
            return .complete(CLIASRExecution(
                result: result,
                evidence: evidence
            ))
        },
        postprocess: { _, _ in
            throw CLIError.run("synthetic MOSS postprocess was not expected")
        },
        translate: { _, _ in
            throw CLIError.run("synthetic MOSS translation was not expected")
        },
        postprocessDoctor: { _ in ["check.postprocess=true"] },
        doctor: { _, _ in ["check.asr_doctor=true"] }
    )
}

private func mossAttemptEvidence(
    request: ASRRequest,
    maximumTokens: Int,
    promptTokens: Int,
    fingerprint: ASRHelperFingerprint,
    limit: Bool
) throws -> CLIASRAttemptEvidence {
    let instructionSHA256 = String(repeating: "b", count: 64)
    let inputSHA256 = try AudioPreprocessor.sha256(of: request.audioURL)
    let glossary = request.glossary.map {
        ManifestGlossary(
            provided: true,
            sha256: $0.sha256,
            itemCount: $0.entries.count,
            injectionMode: request.injectionMode,
            applied: true
        )
    } ?? .absent
    let language: String
    switch request.language {
    case .automatic: language = "auto"
    case let .fixed(value): language = value
    }
    let runner = Data(
        "{\"outcome\":\"\(limit ? "limit" : "complete")\"}\n".utf8
    )
    return CLIASRAttemptEvidence(
        glossary: glossary,
        rawEvidence: Data(
            (limit
                ? "PARENT_PARTIAL_SENTINEL \(request.startS)-\(request.endS)"
                : "complete backend \(request.startS)-\(request.endS)").utf8
        ),
        runnerRecordEvidence: runner,
        glossaryPayloadSHA256: request.glossary == nil
            ? nil
            : instructionSHA256,
        glossaryPayloadEntryCount: request.glossary?.entries.count ?? 0,
        metrics: ASRAttemptMetrics(
            preprocessingS: 0,
            audioEncoderS: 0,
            decoderPrefillS: 0,
            tokenDecodeS: 0,
            promptTokens: promptTokens,
            generatedTokens: limit ? maximumTokens : 128,
            maxTokens: maximumTokens,
            contextHardCapTokens: 131_072,
            audioDurationS: request.endS - request.startS,
            totalS: 0,
            modelLoadS: 0,
            runnerWallTimeS: 0,
            peakRSSBytes: 1
        ),
        language: ASRLanguageEvidence(
            requested: language,
            instructionSHA256: instructionSHA256,
            promptGuidanceApplied: language != "auto"
        ),
        helperFingerprint: fingerprint,
        inputSHA256: inputSHA256,
        command: [
            "synthetic-moss",
            "--audio", request.audioURL.path,
            "--max-tokens", String(maximumTokens),
            "--language", language,
        ] + (request.glossary == nil
            ? []
            : ["--glossary", "/synthetic/glossary.txt"])
    )
}

private func syntheticMOSSContextPlan(
    sampleCount: Int64,
    language: LanguagePin,
    glossary: Glossary?,
    maximumTokens: Int,
    fingerprint: ASRHelperFingerprint
) throws -> MOSSContextPlan {
    let languageValue: String
    switch language {
    case .automatic: languageValue = "auto"
    case let .fixed(value): languageValue = value.lowercased()
    }
    var plan = MOSSContextPlan(
        backend: "moss",
        model: SelectedASRBackend.moss.model,
        sampleCount: sampleCount,
        textTokens: 100,
        audioTokens: 0,
        audioSpanTokens: 0,
        promptTokens: 0,
        maximumTokens: maximumTokens,
        contextUpperBoundTokens: 0,
        contextHardCapTokens: 131_072,
        audioTokensPerSecond: 12.5,
        timeMarkerEverySeconds: 5,
        timeMarkersEnabled: true,
        language: languageValue,
        instructionSHA256: String(repeating: "b", count: 64),
        glossarySHA256: glossary?.sha256,
        glossaryPayloadSHA256: glossary.map {
            SHA256.hash(
                data: Data(($0.entries.joined(separator: "\n") + "\n").utf8)
            ).map { String(format: "%02x", $0) }.joined()
        },
        glossaryItemCount: glossary?.entries.count ?? 0,
        helperFingerprintSHA256: fingerprint.sha256
    )
    let attempt = try plan.attemptPlan(sampleCount: sampleCount)
    plan.audioTokens = attempt.audioTokens
    plan.audioSpanTokens = attempt.audioSpanTokens
    plan.promptTokens = attempt.promptTokens
    plan.contextUpperBoundTokens = attempt.contextUpperBoundTokens
    return plan
}

private func testMOSSFingerprint() -> ASRHelperFingerprint {
    let digest = String(repeating: "a", count: 64)
    let swiftVersion = "Apple Swift synthetic"
    return ASRHelperFingerprint(
        path: "/synthetic/MaccheroniMossHarness.fingerprint.json",
        sha256: digest,
        contractVersion: "moss-harness-v2",
        sourceTreeSHA256: digest,
        packageSwiftSHA256: digest,
        packageResolvedSHA256: digest,
        swiftVersion: swiftVersion,
        swiftVersionSHA256: digest,
        targetArchitecture: "arm64",
        configuration: "release",
        buildFlags: [
            "--configuration", "release", "--arch", "arm64",
            "--product", "MaccheroniMossHarness",
        ],
        executableSHA256: digest,
        metallibSHA256: digest
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "MaccheroniCLITests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    return url
}

private func makeWAV(
    in directory: URL,
    name: String,
    durationS: Double = 2
) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let format = AVAudioFormat(
        standardFormatWithSampleRate: 16_000,
        channels: 1
    )!
    let output = try AVAudioFile(forWriting: url, settings: format.settings)
    let totalFrames = Int64((durationS * 16_000).rounded())
    guard totalFrames > 0 else {
        throw CLIError.run("synthetic WAV duration must be positive")
    }
    var written: Int64 = 0
    while written < totalFrames {
        let frameCount = AVAudioFrameCount(
            min(Int64(32_000), totalFrames - written)
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let samples = buffer.floatChannelData?[0] else {
            throw CLIError.run("cannot allocate a synthetic WAV fixture")
        }
        buffer.frameLength = frameCount
        for index in 0 ..< Int(frameCount) {
            samples[index] = ((Int64(index) + written) / 80).isMultiple(of: 2)
                ? 0.05
                : -0.05
        }
        try output.write(from: buffer)
        written += Int64(frameCount)
    }
    return url
}

private func profileFile(
    in directory: URL,
    fileName: String = "profiles.json",
    glossaryPath: String? = nil,
    postprocess: String = "none",
    postprocessMode: PostprocessMode? = nil,
    targetLanguage: String? = nil,
    duplicate: Bool = false,
    asrBackend: String = "vibevoice",
    languagePin: String = "auto"
) throws -> URL {
    let glossary = glossaryPath.map { "\"\($0)\"" } ?? "null"
    let mode = postprocessMode.map { "\"\($0.rawValue)\"" } ?? "null"
    let target = targetLanguage.map { "\"\($0)\"" } ?? "null"
    let profile = """
    {"name":"ko-meeting","asr_backend":"\(asrBackend)","language_pin":"\(languagePin)","diarization":{"enabled":true,"backend":"community1"},"postprocess":"\(postprocess)","postprocess_mode":\(mode),"target_language":\(target),"glossary_path":\(glossary)}
    """
    let profiles = duplicate ? "\(profile),\(profile)" : profile
    let data = Data(
        "{\"schema_version\":\"1.0.0\",\"profiles\":[\(profiles)]}".utf8
    )
    let url = directory.appendingPathComponent(fileName)
    try data.write(to: url, options: .withoutOverwriting)
    return url
}

private func glossaryFile(in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("terms.txt")
    try Data("Maccheroni\n".utf8).write(to: url, options: .withoutOverwriting)
    return url
}

private func audioDuration(_ url: URL) throws -> Double {
    let audio = try AVAudioFile(forReading: url)
    return Double(audio.length) / audio.processingFormat.sampleRate
}

private func decode<T: Decodable>(_ path: String, in root: URL) throws -> T {
    try JSONDecoder().decode(
        T.self,
        from: Data(contentsOf: root.appendingPathComponent(path))
    )
}

private func jsonObject(
    _ path: String,
    in root: URL
) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent(path))
    )
    guard let object = value as? [String: Any] else {
        throw CLIError.run("test JSON object is malformed: \(path)")
    }
    return object
}

private func regularRelativePaths(in root: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else { return [] }
    var paths = Set<String>()
    for case let file as URL in enumerator {
        if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            paths.insert(try relativePath(of: file, in: root))
        }
    }
    return paths
}

private func recursiveSnapshot(of root: URL) throws -> [String: String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: []
    ) else { return [:] }
    var snapshot: [String: String] = [:]
    for case let entry as URL in enumerator {
        let relative = try relativePath(of: entry, in: root)
        let values = try entry.resourceValues(
            forKeys: [.isDirectoryKey, .isRegularFileKey]
        )
        if values.isDirectory == true {
            snapshot[relative] = "directory"
        } else if values.isRegularFile == true {
            snapshot[relative] = try AudioPreprocessor.sha256(of: entry)
        }
    }
    return snapshot
}

private func relativePath(of entry: URL, in root: URL) throws -> String {
    let base = root.standardizedFileURL.pathComponents
    let components = entry.standardizedFileURL.pathComponents
    guard components.count > base.count,
          Array(components.prefix(base.count)) == base
    else {
        throw CLIError.run("test artifact is outside its run root")
    }
    return components.dropFirst(base.count).joined(separator: "/")
}
