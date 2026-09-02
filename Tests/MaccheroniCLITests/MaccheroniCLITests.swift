@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import MaccheroniASR
@testable import MaccheroniCore
import MaccheroniDiarize
import MaccheroniMerge
import MaccheroniPostprocess
import MaccheroniPreprocess
import MaccheroniStorage
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
            "diarization/order-normalizations.json",
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
        #expect(try jsonArray(
            "diarization/order-normalizations.json",
            in: run
        ).isEmpty)
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
    func diarizationOrderTieBreakIsWrittenAndRegistered() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        _ = try glossaryFile(in: root)
        let profiles = try profileFile(
            in: root,
            glossaryPath: "terms.txt"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        var dependencies = testDependencies()
        dependencies.diarize = { _, _ in
            let emitted = [
                TimelineSegment(speaker: "S0", startS: 0.031, endS: 2.005),
                TimelineSegment(speaker: "S1", startS: 0.031, endS: 1.005),
            ]
            return DiarizationTimelineResult(
                timeline: Timeline(segments: [emitted[1], emitted[0]]),
                rawJSON: try JSONEncoder().encode(emitted),
                normalizationWarnings: [],
                orderNormalizations: [
                    DiarizationOrderNormalization(
                        emittedIndex: 1,
                        normalizedIndex: 0,
                        speaker: "S1",
                        startS: 0.031,
                        endS: 1.005
                    ),
                    DiarizationOrderNormalization(
                        emittedIndex: 0,
                        normalizedIndex: 1,
                        speaker: "S0",
                        startS: 0.031,
                        endS: 2.005
                    ),
                ]
            )
        }
        let app = testApplication(runID: "order", dependencies: dependencies)

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])
        let run = URL(fileURLWithPath: runPath, isDirectory: true)

        let records = try jsonArray(
            "diarization/order-normalizations.json",
            in: run
        )
        #expect(records.count == 2)
        #expect(records.allSatisfy {
            Set($0.keys) == [
                "emitted_index",
                "normalized_index",
                "speaker",
                "start_s",
                "end_s",
            ]
        })
        #expect(records.map { $0["emitted_index"] as? Int } == [1, 0])
        #expect(records.map { $0["normalized_index"] as? Int } == [0, 1])
        #expect(records.map { $0["speaker"] as? String } == ["S1", "S0"])
        #expect(records.map { $0["start_s"] as? Double } == [0.031, 0.031])
        #expect(records.map { $0["end_s"] as? Double } == [1.005, 2.005])

        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .succeeded)
        let artifact = try #require(manifest.artifacts.first {
            $0.path == "diarization/order-normalizations.json"
        })
        #expect(artifact.kind == "diarization_order_normalizations")
        #expect(try AudioPreprocessor.sha256(
            of: run.appendingPathComponent(artifact.path)
        ) == artifact.sha256)
    }

    @Test
    func rejectedDiarizationTimelineIsPreservedInTheRunAndRegistered() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        // Stands in for the adapter's quarantine file under
        // `$TMPDIR/Maccheroni/diarization/rejected/`, which the OS may sweep
        // before anyone reads it.
        let quarantine = root.appendingPathComponent("quarantined.json")
        let emitted = Data(
            #"{"segments":[{"speaker":"S0","start":1.5,"end":2.0}],"num_speakers":1}"#
                .utf8
        )
        try emitted.write(to: quarantine)
        var dependencies = testDependencies()
        dependencies.diarize = { _, _ in
            throw DiarizationError.rejectedOutput(
                reason: .outputUnordered(
                    segment: 1,
                    startS: 0.5,
                    previousStartS: 1.5
                ),
                rawOutputPath: quarantine.path
            )
        }
        let app = testApplication(runID: "rejected", dependencies: dependencies)

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected the rejected timeline to fail the run")
        } catch let error as CLIError {
            let message = try #require(error.errorDescription)
            // The failure names the copy the run owns, not the temporary file
            // that may already be gone by the time anyone reads it.
            #expect(message.contains("diarization/rejected-backend.raw.json"))
            #expect(!message.contains(quarantine.path))
            #expect(message.contains("segment 1 starts at 0.5 seconds"))
        }

        let run = outputRoot.appendingPathComponent("rejected", isDirectory: true)
        let preserved = run.appendingPathComponent(
            "diarization/rejected-backend.raw.json"
        )
        #expect(try Data(contentsOf: preserved) == emitted)
        // The temporary copy is free to stay; what the acceptance requires is
        // that the run directory alone is enough.
        #expect(try Data(contentsOf: quarantine) == emitted)

        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "DIARIZATION_ERROR")
        let failureMessage = try #require(manifest.failure?.message)
        #expect(failureMessage.contains("diarization/rejected-backend.raw.json"))
        let artifact = try #require(manifest.artifacts.first {
            $0.path == "diarization/rejected-backend.raw.json"
        })
        #expect(artifact.kind == "diarization_rejected_backend_raw")
        #expect(try AudioPreprocessor.sha256(of: preserved) == artifact.sha256)
        // The run stopped at diarization, so the accepted-path artifacts must
        // not exist to be confused with the rejected bytes.
        #expect(!manifest.artifacts.contains {
            $0.path == "diarization/backend.raw.json"
                || $0.path == "diarization/timeline.json"
        })
        #expect(Set(manifest.artifacts.map(\.path)) ==
            (try regularRelativePaths(in: run)).subtracting(["manifest.json"]))
    }

    @Test
    func realBackendRejectionLandsInTheRunDirectoryAndTheManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        // A backend that emits its second turn before its first. This is the
        // whole rejection path as it really runs: the adapter quarantines the
        // bytes under `$TMPDIR` and names them in the error, and the run
        // directory is what has to end up carrying them.
        let emitted = #"{"segments":[{"speaker":"S0","start":1.0,"end":1.5},"#
            + #"{"speaker":"S1","start":0.2,"end":0.9}]}"#
        let stub = try writeExecutable(
            "#!/bin/sh\nprintf '%s' '\(emitted)'\n",
            in: root
        )
        let quarantineRoot = DiarizationWorkspace.rejectedOutputRootURL()
        let before = quarantinedFileNames(in: quarantineRoot)
        var dependencies = testDependencies()
        dependencies.diarize = { _, request in
            try await Community1Diarizer(configuration: .init(
                executableURL: stub,
                hfHomeURL: root,
                timeoutS: 30,
                validatesPinnedModel: false
            )).diarizeWithEvidence(request)
        }
        let app = testApplication(runID: "backend", dependencies: dependencies)

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected the out-of-order timeline to fail the run")
        } catch let error as CLIError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("diarization/rejected-backend.raw.json"))
            #expect(!message.contains(quarantineRoot.path))
        }
        let quarantined = quarantinedFileNames(in: quarantineRoot)
            .subtracting(before)
        defer {
            for name in quarantined {
                try? FileManager.default.removeItem(
                    at: quarantineRoot.appendingPathComponent(name)
                )
            }
        }

        let run = outputRoot.appendingPathComponent("backend", isDirectory: true)
        let preserved = run.appendingPathComponent(
            "diarization/rejected-backend.raw.json"
        )
        #expect(try String(contentsOf: preserved, encoding: .utf8) == emitted)
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.failure?.code == "DIARIZATION_ERROR")
        let artifact = try #require(manifest.artifacts.first {
            $0.path == "diarization/rejected-backend.raw.json"
        })
        #expect(artifact.kind == "diarization_rejected_backend_raw")
        #expect(try AudioPreprocessor.sha256(of: preserved) == artifact.sha256)
    }

    @Test
    func rejectedDiarizationWithoutSurvivingBytesKeepsItsOriginalDiagnosis() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        // The sweep already happened: there is nothing left to copy.
        let swept = root.appendingPathComponent("swept.json")
        var dependencies = testDependencies()
        dependencies.diarize = { _, _ in
            throw DiarizationError.rejectedOutput(
                reason: .duplicateOnset(
                    segment: 3,
                    speaker: "S1",
                    startS: 4.25
                ),
                rawOutputPath: swept.path
            )
        }
        let app = testApplication(runID: "swept", dependencies: dependencies)

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected the rejected timeline to fail the run")
        } catch let error as CLIError {
            let message = try #require(error.errorDescription)
            // Losing the bytes must not lose the diagnosis with them.
            #expect(message.contains(
                "segments 2 and 3 both start speaker S1 at 4.25 seconds"
            ))
            #expect(!message.contains("diarization/rejected-backend.raw.json"))
        }

        let run = outputRoot.appendingPathComponent("swept", isDirectory: true)
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent(
                "diarization/rejected-backend.raw.json"
            ).path
        ))
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.failure?.code == "DIARIZATION_ERROR")
        #expect(!manifest.artifacts.contains {
            $0.path == "diarization/rejected-backend.raw.json"
        })
    }

    @Test
    func secondChunkFailureLeavesAnAuditableFailedRunWithNoFalseCoverage() async throws {
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
        // The run aborted before promotion, so no transcript exists anywhere.
        // `partial` would claim one second was transcribed when nothing was.
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "RUN_ERROR")
        #expect(manifest.coverage.truncated)
        #expect(manifest.coverage.processedDurationS == 0)
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
    func cancellationBeforeAnyChunkPersistsCanceledStatusAndZeroCoverage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "canceled-before-first.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(
            runID: "canceled-before-first",
            dependencies: testDependencies(cancelASRAtOrAfterS: 0)
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected cancellation before the first ASR chunk")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }

        let run = outputRoot.appendingPathComponent(
            "canceled-before-first",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .canceled)
        #expect(manifest.failure?.code == "CANCELED")
        #expect(manifest.coverage.chunksPlanned == 2)
        #expect(manifest.coverage.chunksCompleted == 0)
        #expect(abs(manifest.coverage.processedDurationS) < 0.01)
        #expect(manifest.coverage.truncated)
        #expect(manifest.chunkBoundaries.map(\.status) == [.failed, .skipped])
    }

    @Test
    func cancellationAfterOneChunkPersistsCanceledStatusAndCompletedCoverage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "canceled-after-first.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(
            runID: "canceled-after-first",
            dependencies: testDependencies(cancelASRAtOrAfterS: 1)
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected cancellation after the first ASR chunk")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
        }

        let run = outputRoot.appendingPathComponent(
            "canceled-after-first",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .canceled)
        #expect(manifest.failure?.code == "CANCELED")
        #expect(manifest.coverage.chunksPlanned == 2)
        #expect(manifest.coverage.chunksCompleted == 1)
        #expect(abs(manifest.coverage.processedDurationS - 1) < 0.01)
        #expect(manifest.coverage.truncated)
        #expect(manifest.chunkBoundaries.map(\.status) == [.succeeded, .failed])
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
        #expect(doctor.contains("check.storage=true"))
        #expect(doctor.contains("storage.volume.0.name=Fixture Volume"))
        #expect(doctor.contains("storage.volume.0.roles=recordings,runs"))
        #expect(doctor.contains("storage.volume.0.available_bytes=0"))
        #expect(doctor.contains("check.asr_doctor=true"))
        #expect(try recursiveSnapshot(of: root) == before)

        let bundled = try await app.execute(arguments: [
            "doctor", "--profile", "it-dialogue",
        ])
        #expect(bundled.contains("profile=it-dialogue"))
        #expect(bundled.contains(SelectedASRBackend.moss.model.hfModelID))

        var privacyDependencies = testDependencies()
        privacyDependencies.doctor = { _, _ in
            [
                "asr_error=missing \(root.path)/private model/file.bin",
                "check.asr_doctor=true",
            ]
        }
        let privacyApp = testApplication(
            runID: "doctor-privacy",
            dependencies: privacyDependencies
        )
        let privacyBoundDoctor = try await privacyApp.execute(arguments: [
            "doctor",
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
        ])
        #expect(!privacyBoundDoctor.contains(root.path))
        #expect(privacyBoundDoctor.contains("asr_error=missing <redacted-path>"))

        privacyDependencies.doctor = { _, _ in
            [
                "asr_error=missing \(root.path)/private model/file.bin",
                "check.asr_doctor=false",
            ]
        }
        let failingPrivacyApp = testApplication(
            runID: "doctor-privacy-failure",
            dependencies: privacyDependencies
        )
        do {
            _ = try await failingPrivacyApp.execute(arguments: [
                "doctor",
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
            ])
            Issue.record("expected failed doctor diagnostics")
        } catch let error as CLIError {
            let description = try #require(error.errorDescription)
            #expect(!description.contains(root.path))
            #expect(description.contains("asr_error=missing <redacted-path>"))
        }
    }

    @Test
    func doctorTextAndJSONPreserveUnavailableStorageFactsWithoutAByteThreshold() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = try profileFile(in: root)
        let storage = StorageReport(
            volumes: [StorageVolume(
                id: "archive",
                name: "Archive",
                roles: [.recordings],
                availableBytes: nil
            )],
            roots: [
                StorageRootObservation(
                    id: "recordings",
                    role: .recordings,
                    status: .notCreated,
                    bookmarkStatus: .stale,
                    volumeID: "archive"
                ),
                StorageRootObservation(
                    id: "runs",
                    role: .runs,
                    status: .unreadable,
                    bookmarkStatus: .none,
                    volumeID: nil
                ),
            ]
        )
        let app = testApplication(
            runID: "doctor-storage",
            storageReport: { _, _ in storage }
        )

        let report = try await app.inspectDoctor(
            profileName: "ko-meeting",
            profilesPath: profiles.path
        )

        #expect(!report.isReady)
        #expect(report.diagnostics.contains("storage.volume.0.name=Archive"))
        #expect(report.diagnostics.contains("storage.volume.0.roles=recordings"))
        #expect(report.diagnostics.contains("storage.volume.0.available_bytes=unavailable"))
        #expect(report.diagnostics.contains("storage.root.0.status=not_created"))
        #expect(report.diagnostics.contains("storage.root.0.bookmark_status=stale"))
        #expect(report.diagnostics.contains("storage.root.1.status=unreadable"))

        let json = try CLIOutput.doctorJSON(
            diagnostics: report.diagnosticValues,
            storage: report.storage,
            ready: report.isReady
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let jsonStorage = try #require(object["storage"] as? [String: Any])
        let volumes = try #require(jsonStorage["volumes"] as? [[String: Any]])
        let roots = try #require(jsonStorage["roots"] as? [[String: Any]])

        #expect(object["ready"] as? Bool == false)
        #expect(volumes[0]["available_bytes"] is NSNull)
        #expect(volumes[0]["capacity_status"] as? String == "unavailable")
        #expect(roots[0]["status"] as? String == "not_created")
        #expect(roots[0]["bookmark_status"] as? String == "stale")
        #expect(roots[1]["status"] as? String == "unreadable")
    }

    @Test
    func doctorRejectsFalsePinnedSpeechAndIndirectASRDependencyChecksInJSON() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = try profileFile(in: root)
        var dependencies = testDependencies()
        dependencies.doctor = { _, _ in
            [
                "speech_runtime=speech@0.0.23",
                "check.speech_runtime=false",
                "check.asr_doctor=false",
                "check.asr.tokenizer_ref=false",
            ]
        }
        let app = testApplication(
            runID: "doctor-runtime-dependencies",
            dependencies: dependencies
        )

        let report = try await app.inspectDoctor(
            profileName: "ko-meeting",
            profilesPath: profiles.path
        )

        #expect(!report.isReady)
        #expect(report.diagnosticValues.contains("speech_runtime=speech@0.0.23"))
        #expect(report.diagnosticValues.contains("check.speech_runtime=false"))
        #expect(report.diagnosticValues.contains("check.asr_doctor=false"))
        #expect(report.diagnosticValues.contains("check.asr.tokenizer_ref=false"))

        let json = try CLIOutput.doctorJSON(
            diagnostics: report.diagnosticValues,
            storage: report.storage,
            ready: report.isReady
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let values = try #require(object["values"] as? [String: String])
        #expect(object["ready"] as? Bool == false)
        #expect(values["speech_runtime"] == "speech@0.0.23")
        #expect(values["check.speech_runtime"] == "false")
        #expect(values["check.asr_doctor"] == "false")
        #expect(values["check.asr.tokenizer_ref"] == "false")

        do {
            _ = try await app.execute(arguments: [
                "doctor",
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
            ])
            Issue.record("expected failed runtime and indirect dependency checks")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
            let description = try #require(error.errorDescription)
            #expect(description.contains("check.speech_runtime=false"))
            #expect(description.contains("check.asr.tokenizer_ref=false"))
        }
    }

    @Test
    func productionSpeechFactoriesUseThePinnedDefaultCacheAndExplicitOverride() {
        let home = URL(fileURLWithPath: "/private/tmp/maccheroni-test-home")
        let defaultCache = home.appendingPathComponent(
            "Library/Caches/Maccheroni/benchmarks",
            isDirectory: true
        )
        let vad = productionVADAdapter(environment: [:], home: home)
        let diarization = productionCommunity1Configuration(
            environment: [:],
            home: home
        )
        let defaultExecutable = defaultCache.appendingPathComponent(
            "tools/offline-speech-runtime/bin/maccheroni-offline-speech-runtime"
        )

        #expect(vad.executableURL == defaultExecutable)
        #expect(diarization.executableURL == defaultExecutable)
        #expect(vad.modelCacheURL.path.hasPrefix(defaultCache.path + "/"))
        #expect(vad.revisionMarkerURL.path.hasPrefix(defaultCache.path + "/"))
        #expect(
            vad.harnessModelRepositoryURL?.path.hasPrefix(
                defaultCache.path + "/"
            ) == true
        )
        #expect(
            diarization.hfHomeURL
                == defaultCache.appendingPathComponent(
                    "models/huggingface",
                    isDirectory: true
                )
        )
        #expect(
            diarization.harnessModelRepositoryURL?.path.hasPrefix(
                defaultCache.path + "/"
            ) == true
        )
        #expect(
            productionVADAdapter(
                environment: ["MACCHERONI_BENCHMARK_CACHE": ""],
                home: home
            ).executableURL == defaultExecutable
        )

        let cache = "/private/tmp/maccheroni-explicit-cache"
        let cachedVAD = productionVADAdapter(environment: [
            "MACCHERONI_BENCHMARK_CACHE": cache,
        ], home: home)
        let cachedDiarization = productionCommunity1Configuration(environment: [
            "MACCHERONI_BENCHMARK_CACHE": cache,
        ], home: home)
        let expectedExecutable = URL(fileURLWithPath: cache)
            .appendingPathComponent(
                "tools/offline-speech-runtime/bin/maccheroni-offline-speech-runtime"
            )
        #expect(cachedVAD.executableURL == expectedExecutable)
        #expect(cachedDiarization.executableURL == expectedExecutable)
        #expect(
            cachedVAD.harnessModelRepositoryURL?.lastPathComponent
                == "Silero-VAD-v6.2.1-CoreML"
        )
        #expect(
            cachedDiarization.harnessModelRepositoryURL?.lastPathComponent
                == "Pyannote-Community-1-CoreML"
        )
    }

    @Test
    func runtimePayloadEvidenceIdentifiesTheExactCorruptOrMissingFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(
            at: model,
            withIntermediateDirectories: true
        )
        let config = root.appendingPathComponent("config.json")
        let weights = model.appendingPathComponent("weights.bin")
        try Data("{}".utf8).write(to: config)
        try Data("payload".utf8).write(to: weights)
        let expected = [
            RuntimePayloadFile(
                relativePath: "config.json",
                sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
            ),
            RuntimePayloadFile(
                relativePath: "model/weights.bin",
                sha256: "239f59ed55e737c77147cf55ad0c1b030b6d7ee748a7426952f9b852d5a935e5"
            ),
        ]
        let treeSHA256 =
            "e60a86c6477522bfd0c0c5930ffffb89a68175500bd61b0953bf9c152016346f"

        let valid = runtimePayloadEvidence(
            at: root,
            expectedFiles: expected,
            expectedTreeSHA256: treeSHA256
        )
        #expect(valid.treeIsPinned)
        #expect(valid.files.map { $0.isPinned } == [true, true])

        try Data("tampered".utf8).write(to: weights)
        let corrupt = runtimePayloadEvidence(
            at: root,
            expectedFiles: expected,
            expectedTreeSHA256: treeSHA256
        )
        #expect(!corrupt.treeIsPinned)
        #expect(corrupt.files.map { $0.isPinned } == [true, false])

        try FileManager.default.removeItem(at: weights)
        let missing = runtimePayloadEvidence(
            at: root,
            expectedFiles: expected,
            expectedTreeSHA256: treeSHA256
        )
        #expect(!missing.treeIsPinned)
        #expect(missing.files.map { $0.isPinned } == [true, false])
    }

    @Test
    func offlineSpeechRuntimeEvidenceBindsSidecarInputsAndExecutableBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let toolRoot = root.appendingPathComponent(
            "tools/offline-speech-runtime",
            isDirectory: true
        )
        let binaryDirectory = toolRoot.appendingPathComponent(
            "bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: binaryDirectory,
            withIntermediateDirectories: true
        )
        let binary = binaryDirectory.appendingPathComponent(
            "maccheroni-offline-speech-runtime"
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: binary.path
        )
        let executableSHA256 = try AudioPreprocessor.sha256(of: binary)
        let sidecar: [String: String] = [
            "contract_version": "offline-speech-runtime-v1",
            "speech_revision": "c1aa219bc2284239ff6917d675a3e1978c840260",
            "package_manifest_sha256": String(repeating: "a", count: 64),
            "package_resolved_sha256": String(repeating: "b", count: 64),
            "harness_source_sha256": String(repeating: "c", count: 64),
            "executable_sha256": executableSHA256,
            "swift_version": "Apple Swift version 6.3",
        ]
        let sidecarURL = toolRoot.appendingPathComponent("provenance.json")
        try JSONSerialization.data(withJSONObject: sidecar).write(to: sidecarURL)
        let expected = OfflineSpeechRuntimePin(
            speechRevision: sidecar["speech_revision"]!,
            packageManifestSHA256: sidecar["package_manifest_sha256"]!,
            packageResolvedSHA256: sidecar["package_resolved_sha256"]!,
            harnessSourceSHA256: sidecar["harness_source_sha256"]!,
            executableSHA256: nil,
            swiftVersionMarker: "Apple Swift version 6."
        )

        let valid = offlineSpeechRuntimeEvidence(
            cacheRoot: root,
            expected: expected
        )
        #expect(valid.executableIsUsable)
        #expect(valid.executableMatchesSidecar)
        #expect(valid.sidecarIsPinned)
        #expect(valid.isPinned)

        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: binary)
        let tampered = offlineSpeechRuntimeEvidence(
            cacheRoot: root,
            expected: expected
        )
        #expect(tampered.executableIsUsable)
        #expect(!tampered.executableMatchesSidecar)
        #expect(tampered.sidecarIsPinned)
        #expect(!tampered.isPinned)

        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        var wrongInputs = sidecar
        wrongInputs["harness_source_sha256"] = String(
            repeating: "d",
            count: 64
        )
        try JSONSerialization.data(withJSONObject: wrongInputs).write(
            to: sidecarURL
        )
        let mismatchedInputs = offlineSpeechRuntimeEvidence(
            cacheRoot: root,
            expected: expected
        )
        #expect(mismatchedInputs.executableIsUsable)
        #expect(mismatchedInputs.executableMatchesSidecar)
        #expect(!mismatchedInputs.sidecarIsPinned)
        #expect(!mismatchedInputs.isPinned)
    }

    @Test
    func runDefaultAndDoctorInventoryUseTheSameConfiguredRunsRoot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "storage-input.wav")
        let profiles = try profileFile(in: root)
        let configuredRuns = root.appendingPathComponent("ConfiguredRuns", isDirectory: true)
        let explicitRuns = root.appendingPathComponent("ExplicitRuns", isDirectory: true)
        let library = LibraryStorageConfiguration(
            root: root.appendingPathComponent("Library", isDirectory: true),
            recordingsURL: root.appendingPathComponent("Recordings", isDirectory: true),
            runsURL: configuredRuns
        )
        let observed = CLIStorageConfigurationRecorder()
        let app = testApplication(
            runID: "storage-agreement",
            libraryStorageConfiguration: { library },
            storageReport: { _, configuration in
                observed.record(configuration)
                return fixtureStorageReport()
            }
        )

        _ = try await app.inspectDoctor(
            profileName: "ko-meeting",
            profilesPath: profiles.path
        )
        let defaultRunPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
        ])
        let explicitRunPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", explicitRuns.path,
        ])

        #expect(observed.runsURL == configuredRuns)
        #expect(URL(fileURLWithPath: defaultRunPath).deletingLastPathComponent()
            == configuredRuns)
        #expect(URL(fileURLWithPath: explicitRunPath).deletingLastPathComponent()
            == explicitRuns)
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
    func completedCodexTurnsValidateWhenCLIVersionIsUnavailable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)

        for (mode, targetLanguage) in [
            (PostprocessMode.correction, nil),
            (PostprocessMode.translation, "en"),
        ] {
            let profiles = try profileFile(
                in: root,
                fileName: "codex-\(mode.rawValue).json",
                postprocess: "codex",
                postprocessMode: mode,
                targetLanguage: targetLanguage
            )
            let app = testApplication(
                runID: "codex-\(mode.rawValue)",
                dependencies: testDependencies(codexVersion: "unavailable")
            )

            let runPath = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            let manifest: Manifest = try decode(
                "manifest.json",
                in: URL(fileURLWithPath: runPath, isDirectory: true)
            )
            #expect(manifest.status == .succeeded)
            #expect(manifest.postprocess?.backend
                == BackendDescriptor(name: "codex-app-server", version: "unavailable"))
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
    func existingRunCorrectionsCreateVerifiedSiblingsWithCurrentGlossariesAndNoASR() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let runsRoot = root.appendingPathComponent("runs", isDirectory: true)
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", runsRoot.path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let sourceManifestBefore = try AudioPreprocessor.sha256(
            of: sourceRun.appendingPathComponent("manifest.json")
        )
        let mergedBefore = try AudioPreprocessor.sha256(
            of: sourceRun.appendingPathComponent("merged/segments.json")
        )
        let rawBefore = try AudioPreprocessor.sha256(
            of: sourceRun.appendingPathComponent("primary/raw.txt")
        )
        let profiles = try profileFile(
            in: root,
            fileName: "correction.json",
            postprocess: "codex",
            postprocessMode: .correction
        )
        let firstGlossary = root.appendingPathComponent("terms-v1.txt")
        let secondGlossary = root.appendingPathComponent("terms-v2.txt")
        try Data("Maccheroni v1\n".utf8).write(
            to: firstGlossary,
            options: .withoutOverwriting
        )
        try Data("Maccheroni v2\n".utf8).write(
            to: secondGlossary,
            options: .withoutOverwriting
        )
        let stages = StageInvocationRecorder()
        let dependencies = postprocessOnlyDependencies(recorder: stages)

        let firstPath = try await testApplication(
            runID: "derived-one",
            dependencies: dependencies
        ).execute(arguments: [
            "postprocess", sourceRun.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--glossary", firstGlossary.path,
        ])
        let first = URL(fileURLWithPath: firstPath, isDirectory: true)
        let firstSnapshot = try recursiveSnapshot(of: first)
        let secondPath = try await testApplication(
            runID: "derived-two",
            dependencies: dependencies
        ).execute(arguments: [
            "postprocess", sourceRun.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--glossary", secondGlossary.path,
        ])
        let second = URL(fileURLWithPath: secondPath, isDirectory: true)

        #expect(try recursiveSnapshot(of: first) == firstSnapshot)
        #expect(first != second)
        let firstManifest: DerivedManifest = try decode("manifest.json", in: first)
        let secondManifest: DerivedManifest = try decode("manifest.json", in: second)
        let firstOptional = try Glossary.parseOptional(
            data: Data(contentsOf: firstGlossary)
        )
        let secondOptional = try Glossary.parseOptional(
            data: Data(contentsOf: secondGlossary)
        )
        let firstParsed = try #require(firstOptional)
        let secondParsed = try #require(secondOptional)
        #expect(firstManifest.status == .succeeded)
        #expect(secondManifest.status == .succeeded)
        #expect(firstManifest.operation.glossarySHA256 == firstParsed.sha256)
        #expect(secondManifest.operation.glossarySHA256 == secondParsed.sha256)
        #expect(secondManifest.operation.glossarySemantics == .currentProfile)
        #expect(secondManifest.source.runID == "source-run")
        #expect(secondManifest.source.manifestSHA256 == sourceManifestBefore)
        #expect(secondManifest.source.segmentsSHA256 == mergedBefore)
        #expect(secondManifest.postprocess?.batching?.maximumPromptUTF8Bytes
            == CodexPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes)
        #expect(secondManifest.artifacts.map(\.kind).sorted() == [
            "postprocess_conflicts", "postprocess_segments",
        ])
        #expect(FileManager.default.fileExists(
            atPath: second.appendingPathComponent("postprocess/segments.json").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: second.appendingPathComponent("postprocess/translation.json").path
        ))
        #expect(try AudioPreprocessor.sha256(
            of: sourceRun.appendingPathComponent("manifest.json")
        ) == sourceManifestBefore)
        #expect(try AudioPreprocessor.sha256(
            of: sourceRun.appendingPathComponent("merged/segments.json")
        ) == mergedBefore)
        #expect(try AudioPreprocessor.sha256(
            of: sourceRun.appendingPathComponent("primary/raw.txt")
        ) == rawBefore)
        #expect(stages.stages == ["postprocess", "postprocess"])
    }

    @Test
    func existingRunTranslationTreatsCommentOnlyOverrideAsAbsent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let profiles = try profileFile(
            in: root,
            fileName: "translation.json",
            glossaryPath: "profile-terms.txt",
            postprocess: "local",
            postprocessMode: .translation,
            targetLanguage: "en"
        )
        try Data("profile term\n".utf8).write(
            to: root.appendingPathComponent("profile-terms.txt"),
            options: .withoutOverwriting
        )
        let comments = root.appendingPathComponent("comments.txt")
        try Data("# no active entries\r\n\r\n".utf8).write(
            to: comments,
            options: .withoutOverwriting
        )
        let stages = StageInvocationRecorder()
        let derivedPath = try await testApplication(
            runID: "translated",
            dependencies: postprocessOnlyDependencies(recorder: stages)
        ).execute(arguments: [
            "postprocess", sourcePath,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--glossary", comments.path,
        ])
        let derived = URL(fileURLWithPath: derivedPath, isDirectory: true)
        let manifest: DerivedManifest = try decode("manifest.json", in: derived)
        let translation: TranslationDocument = try decode(
            "postprocess/translation.json",
            in: derived
        )

        #expect(manifest.status == .succeeded)
        #expect(manifest.operation.mode == .translation)
        #expect(manifest.operation.targetLanguage == "en")
        #expect(manifest.operation.glossarySHA256 == nil)
        #expect(manifest.operation.glossaryItemCount == 0)
        #expect(manifest.postprocess?.glossarySHA256 == nil)
        #expect(manifest.postprocess?.batching?.maximumPromptUTF8Bytes
            == LocalPostprocessBackend.defaultBatchPolicy.maximumPromptUTF8Bytes)
        #expect(translation.sourceSegmentsSHA256
            == manifest.source.segmentsSHA256)
        #expect(translation.translations.map(\.segmentIndex) == [0, 1])
        #expect(manifest.artifacts.map(\.kind) == ["postprocess_translation"])
        #expect(!FileManager.default.fileExists(
            atPath: derived.appendingPathComponent("postprocess/segments.json").path
        ))
        #expect(stages.stages == ["translate"])
    }

    @Test
    func existingRunCanChooseItsArchivedGlossaryWhileCurrentProfileRemainsDefault() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let revisions = root.appendingPathComponent(
            "library/Glossaries/Revisions",
            isDirectory: true
        )
        var sourceDependencies = testDependencies()
        sourceDependencies.glossaryRevisionStoreRoot = { revisions }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceGlossary = root.appendingPathComponent("source-terms.txt")
        let sourceData = Data("\u{FEFF}# original\r\nMaccheroni v1\r\n".utf8)
        try sourceData.write(to: sourceGlossary, options: .withoutOverwriting)
        let parsedSource = try #require(try Glossary.parseOptional(data: sourceData))
        let sourceProfiles = try profileFile(
            in: root,
            fileName: "source.json"
        )
        let sourcePath = try await testApplication(
            runID: "source-run",
            dependencies: sourceDependencies
        ).execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", sourceProfiles.path,
            "--output-root", root.appendingPathComponent("runs").path,
            "--glossary", sourceGlossary.path,
        ])
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        #expect(try Data(contentsOf: revisions.appendingPathComponent(
            "\(parsedSource.sha256).txt"
        )) == sourceData)

        let currentGlossary = root.appendingPathComponent("current-terms.txt")
        let currentData = Data("Maccheroni v2\n".utf8)
        try currentData.write(to: currentGlossary, options: .withoutOverwriting)
        let parsedCurrent = try #require(try Glossary.parseOptional(data: currentData))
        let derivedProfiles = try profileFile(
            in: root,
            fileName: "derived.json",
            glossaryPath: currentGlossary.lastPathComponent,
            postprocess: "codex",
            postprocessMode: .correction
        )
        let stages = StageInvocationRecorder()
        var derivedDependencies = postprocessOnlyDependencies(recorder: stages)
        derivedDependencies.glossaryRevisionStoreRoot = { revisions }
        let app = testApplication(
            runID: "derived-current",
            dependencies: derivedDependencies
        )

        let currentPath = try await app.execute(arguments: [
            "postprocess", sourceRun.path,
            "--profile", "ko-meeting",
            "--profiles", derivedProfiles.path,
        ])
        let currentManifest: DerivedManifest = try decode(
            "manifest.json",
            in: URL(fileURLWithPath: currentPath, isDirectory: true)
        )
        #expect(currentManifest.operation.glossarySemantics == .currentProfile)
        #expect(currentManifest.operation.glossarySHA256 == parsedCurrent.sha256)

        let sourceApp = testApplication(
            runID: "derived-source",
            dependencies: derivedDependencies
        )
        let archivedPath = try await sourceApp.execute(arguments: [
            "postprocess", sourceRun.path,
            "--profile", "ko-meeting",
            "--profiles", derivedProfiles.path,
            "--glossary-semantics", "source-run",
        ])
        let archivedManifest: DerivedManifest = try decode(
            "manifest.json",
            in: URL(fileURLWithPath: archivedPath, isDirectory: true)
        )
        #expect(archivedManifest.operation.glossarySemantics == .sourceRun)
        #expect(archivedManifest.operation.glossarySHA256 == parsedSource.sha256)
        #expect(archivedManifest.operation.glossaryItemCount == 1)
        #expect(archivedManifest.postprocess?.glossarySHA256 == parsedSource.sha256)

        let translationProfiles = try profileFile(
            in: root,
            fileName: "translation.json",
            glossaryPath: currentGlossary.lastPathComponent,
            postprocess: "local",
            postprocessMode: .translation,
            targetLanguage: "en"
        )
        let translationPath = try await testApplication(
            runID: "translated-source",
            dependencies: derivedDependencies
        ).execute(arguments: [
            "postprocess", sourceRun.path,
            "--profile", "ko-meeting",
            "--profiles", translationProfiles.path,
            "--glossary-semantics", "source-run",
        ])
        let translationManifest: DerivedManifest = try decode(
            "manifest.json",
            in: URL(fileURLWithPath: translationPath, isDirectory: true)
        )
        #expect(translationManifest.operation.mode == .translation)
        #expect(translationManifest.operation.glossarySemantics == .sourceRun)
        #expect(translationManifest.operation.glossarySHA256 == parsedSource.sha256)
        #expect(translationManifest.postprocess?.glossarySHA256 == parsedSource.sha256)
        #expect(stages.stages == ["postprocess", "postprocess", "translate"])
    }

    @Test
    func unavailableSourceRevisionFailsBeforeDerivedCreationOrBackendCall() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let revisions = root.appendingPathComponent(
            "library/Glossaries/Revisions",
            isDirectory: true
        )
        var sourceDependencies = testDependencies()
        sourceDependencies.glossaryRevisionStoreRoot = { revisions }
        let input = try makeWAV(in: root, name: "source.wav")
        let glossary = root.appendingPathComponent("source-terms.txt")
        let data = Data("Legacy term\n".utf8)
        try data.write(to: glossary, options: .withoutOverwriting)
        let parsed = try #require(try Glossary.parseOptional(data: data))
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(
            runID: "legacy-source",
            dependencies: sourceDependencies
        ).execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", sourceProfiles.path,
            "--output-root", root.appendingPathComponent("runs").path,
            "--glossary", glossary.path,
        ])
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        try FileManager.default.removeItem(at: revisions.appendingPathComponent(
            "\(parsed.sha256).txt"
        ))
        let profiles = try profileFile(
            in: root,
            fileName: "derived.json",
            postprocess: "codex",
            postprocessMode: .correction
        )
        let stages = StageInvocationRecorder()
        var dependencies = postprocessOnlyDependencies(recorder: stages)
        dependencies.glossaryRevisionStoreRoot = { revisions }

        do {
            _ = try await testApplication(
                runID: "must-not-exist",
                dependencies: dependencies
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--glossary-semantics", "source-run",
            ])
            Issue.record("Expected a typed unavailable revision error")
        } catch let error as GlossaryRevisionError {
            #expect(error == .revisionUnavailable(
                sha256: parsed.sha256,
                reason: .missing
            ))
        }
        #expect(stages.stages.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: sourceRun.appendingPathComponent("derived").path
        ))
    }

    @Test
    func sourceRunSemanticsSupportsRecordedAbsenceAndRejectsExplicitOverride() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let revisions = root.appendingPathComponent(
            "library/Glossaries/Revisions",
            isDirectory: true
        )
        var sourceDependencies = testDependencies()
        sourceDependencies.glossaryRevisionStoreRoot = { revisions }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(
            runID: "no-glossary-source",
            dependencies: sourceDependencies
        ).execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", sourceProfiles.path,
            "--output-root", root.appendingPathComponent("runs").path,
        ])
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let profiles = try profileFile(
            in: root,
            fileName: "derived.json",
            postprocess: "local",
            postprocessMode: .translation,
            targetLanguage: "en"
        )
        let override = root.appendingPathComponent("override.txt")
        try Data("Current term\n".utf8).write(
            to: override,
            options: .withoutOverwriting
        )
        let stages = StageInvocationRecorder()
        var dependencies = postprocessOnlyDependencies(recorder: stages)
        dependencies.glossaryRevisionStoreRoot = { revisions }
        let app = testApplication(
            runID: "derived-absent",
            dependencies: dependencies
        )
        let derivedPath = try await app.execute(arguments: [
            "postprocess", sourceRun.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--glossary-semantics", "source-run",
        ])
        let manifest: DerivedManifest = try decode(
            "manifest.json",
            in: URL(fileURLWithPath: derivedPath, isDirectory: true)
        )
        #expect(manifest.operation.glossarySemantics == .sourceRun)
        #expect(manifest.operation.glossarySHA256 == nil)
        #expect(manifest.operation.glossaryItemCount == 0)

        do {
            _ = try await testApplication(
                runID: "contradictory",
                dependencies: dependencies
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--glossary", override.path,
                "--glossary-semantics", "source-run",
            ])
            Issue.record("Expected contradictory glossary options to fail")
        } catch let error as CLIError {
            #expect(error.code == "USAGE_ERROR")
        }
        #expect(stages.stages == ["translate"])
    }

    @Test
    func existingRunPostprocessRejectsAnySourceHashMismatchBeforeCreatingOrCallingBackend() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let profiles = try profileFile(
            in: root,
            fileName: "correction.json",
            postprocess: "codex"
        )
        let stages = StageInvocationRecorder()
        let manifestURL = sourceRun.appendingPathComponent("manifest.json")
        let originalManifestData = try Data(contentsOf: manifestURL)
        var invalidManifest = try JSONDecoder().decode(
            Manifest.self,
            from: originalManifestData
        )
        invalidManifest.chunkBoundaries[1].index = 3
        try JSONEncoder().encode(invalidManifest).write(to: manifestURL)
        do {
            _ = try await testApplication(
                runID: "must-not-exist",
                dependencies: postprocessOnlyDependencies(recorder: stages)
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
            ])
            Issue.record("expected source manifest semantic rejection")
        } catch let error as CLIError {
            guard case let .sourceIntegrity(integrity) = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
            #expect(integrity == .manifestInvalid)
        }
        #expect(!FileManager.default.fileExists(
            atPath: sourceRun.appendingPathComponent("derived").path
        ))
        #expect(stages.stages.isEmpty)

        try originalManifestData.write(to: manifestURL)
        try Data("tampered".utf8).write(
            to: sourceRun.appendingPathComponent("primary/raw.txt")
        )
        do {
            _ = try await testApplication(
                runID: "must-not-exist",
                dependencies: postprocessOnlyDependencies(recorder: stages)
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
            ])
            Issue.record("expected source integrity rejection")
        } catch let error as CLIError {
            guard case let .sourceIntegrity(integrity) = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
            #expect(integrity == .artifactHashMismatch("primary/raw.txt"))
        }
        #expect(!FileManager.default.fileExists(
            atPath: sourceRun.appendingPathComponent("derived").path
        ))
        #expect(stages.stages.isEmpty)
    }

    @Test
    func completedRunVerifierDecodesTheExactArtifactBytesItHashed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let profiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let segmentsURL = sourceRun.appendingPathComponent("merged/segments.json")
        let verifiedBytes = try Data(contentsOf: segmentsURL)
        let verifiedDocument = try JSONDecoder().decode(
            SegmentsDocument.self,
            from: verifiedBytes
        )
        var swappedDocument = verifiedDocument
        swappedDocument.segments[0].text = "bytes swapped after hashing"
        let swappedBytes = try JSONEncoder().encode(swappedDocument)
        defer { try? verifiedBytes.write(to: segmentsURL) }

        let verified = try RunIntegrityVerifier.verifyCompletedRun(
            at: sourceRun,
            onArtifactVerified: { artifact, url in
                if artifact.path == "merged/segments.json" {
                    try swappedBytes.write(to: url)
                }
            }
        )

        #expect(verified.document == verifiedDocument)
        #expect(try Data(contentsOf: segmentsURL) == swappedBytes)
    }

    @Test
    func existingRunPostprocessRejectsEmptyRejectedGappedAndShortCoverage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let manifestURL = sourceRun.appendingPathComponent("manifest.json")
        let original = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let postprocessProfiles = try profileFile(
            in: root,
            fileName: "correction.json",
            postprocess: "codex"
        )
        let recorder = StageInvocationRecorder()
        let cases: [(String, (inout Manifest) -> Void)] = [
            ("empty", { manifest in
                manifest.coverage.strategy = .rejected
                manifest.coverage.chunksPlanned = 0
                manifest.coverage.chunksCompleted = 0
                manifest.chunkBoundaries = []
            }),
            ("rejected", { manifest in
                manifest.coverage.strategy = .rejected
            }),
            ("gapped", { manifest in
                let duration = manifest.coverage.inputDurationS
                manifest.coverage.strategy = .chunked
                manifest.coverage.chunksPlanned = 2
                manifest.coverage.chunksCompleted = 2
                manifest.chunkBoundaries = [
                    ChunkBoundary(index: 0, startS: 0, endS: 0.5, status: .succeeded),
                    ChunkBoundary(index: 1, startS: 1, endS: duration, status: .succeeded),
                ]
            }),
            ("short", { manifest in
                manifest.coverage.strategy = .full
                manifest.coverage.chunksPlanned = 1
                manifest.coverage.chunksCompleted = 1
                manifest.chunkBoundaries = [
                    ChunkBoundary(index: 0, startS: 0, endS: 1, status: .succeeded),
                ]
            }),
        ]

        for (identifier, mutation) in cases {
            var manifest = original
            mutation(&manifest)
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            do {
                _ = try await testApplication(
                    runID: "invalid-coverage-\(identifier)",
                    dependencies: postprocessOnlyDependencies(recorder: recorder)
                ).execute(arguments: [
                    "postprocess", sourceRun.path,
                    "--profile", "ko-meeting",
                    "--profiles", postprocessProfiles.path,
                ])
                Issue.record("expected \(identifier) coverage rejection")
            } catch let error as CLIError {
                guard case .sourceIntegrity = error else {
                    Issue.record("unexpected CLI error for \(identifier): \(error)")
                    continue
                }
            }
            #expect(!FileManager.default.fileExists(
                atPath: sourceRun.appendingPathComponent(
                    "derived/invalid-coverage-\(identifier)"
                ).path
            ))
        }
        #expect(recorder.stages.isEmpty)
    }

    @Test
    func existingRunPostprocessRequiresCanonicalInventoryAndRejectsUnlistedMutation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let manifestURL = sourceRun.appendingPathComponent("manifest.json")
        let originalData = try Data(contentsOf: manifestURL)
        let original = try JSONDecoder().decode(Manifest.self, from: originalData)
        let postprocessProfiles = try profileFile(
            in: root,
            fileName: "correction.json",
            postprocess: "codex"
        )

        var missingCanonical = original
        let primarySegments = try #require(missingCanonical.artifacts.first {
            $0.kind == "primary_segments"
        })
        let primarySegmentsURL = sourceRun.appendingPathComponent(primarySegments.path)
        let primarySegmentsData = try Data(contentsOf: primarySegmentsURL)
        missingCanonical.artifacts.removeAll { $0.kind == "primary_segments" }
        try FileManager.default.removeItem(at: primarySegmentsURL)
        try JSONEncoder().encode(missingCanonical).write(to: manifestURL)
        do {
            _ = try await testApplication(runID: "missing-canonical").execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", postprocessProfiles.path,
            ])
            Issue.record("expected missing canonical artifact rejection")
        } catch let error as CLIError {
            guard case .sourceIntegrity = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
        }

        try originalData.write(to: manifestURL)
        try primarySegmentsData.write(to: primarySegmentsURL)
        var unlisted = original
        let evidence = try #require(unlisted.artifacts.first {
            $0.kind == "preprocessed_audio"
        })
        let evidenceURL = sourceRun.appendingPathComponent(evidence.path)
        let evidenceData = try Data(contentsOf: evidenceURL)
        unlisted.artifacts.removeAll { $0.path == evidence.path }
        try JSONEncoder().encode(unlisted).write(to: manifestURL)
        let recorder = StageInvocationRecorder()
        var dependencies = postprocessOnlyDependencies(recorder: recorder)
        let postprocess = dependencies.postprocess
        dependencies.postprocess = { backend, request in
            let result = try await postprocess(backend, request)
            try Data("mutated while postprocessing".utf8).write(
                to: evidenceURL
            )
            return result
        }
        do {
            _ = try await testApplication(
                runID: "unlisted-mutation",
                dependencies: dependencies
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", postprocessProfiles.path,
            ])
            Issue.record("expected unlisted artifact rejection")
        } catch let error as CLIError {
            guard case .sourceIntegrity = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
        }
        #expect(recorder.stages.isEmpty)

        try originalData.write(to: manifestURL)
        try evidenceData.write(to: evidenceURL)
        let addedDuringOperation = sourceRun.appendingPathComponent(
            "unlisted-during-operation.txt"
        )
        let secondRecorder = StageInvocationRecorder()
        var secondDependencies = postprocessOnlyDependencies(recorder: secondRecorder)
        let secondPostprocess = secondDependencies.postprocess
        secondDependencies.postprocess = { backend, request in
            let result = try await secondPostprocess(backend, request)
            try Data("new unlisted source evidence".utf8).write(
                to: addedDuringOperation,
                options: .withoutOverwriting
            )
            return result
        }
        do {
            _ = try await testApplication(
                runID: "unlisted-added-during-operation",
                dependencies: secondDependencies
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", postprocessProfiles.path,
            ])
            Issue.record("expected second-pass unlisted artifact rejection")
        } catch let error as CLIError {
            guard case .sourceIntegrity = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
        }
        #expect(secondRecorder.stages == ["postprocess"])
        let failed: DerivedManifest = try decode(
            "manifest.json",
            in: sourceRun.appendingPathComponent(
                "derived/unlisted-added-during-operation"
            )
        )
        #expect(failed.status == .failed)
        #expect(failed.failure?.code == "SOURCE_INTEGRITY_ERROR")
    }

    @Test
    func existingRunPostprocessRejectsUnappliedGlossaryAndInvalidSegmentMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let manifestURL = sourceRun.appendingPathComponent("manifest.json")
        let segmentsURL = sourceRun.appendingPathComponent("merged/segments.json")
        let originalManifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let originalSegments = try JSONDecoder().decode(
            SegmentsDocument.self,
            from: Data(contentsOf: segmentsURL)
        )
        let postprocessProfiles = try profileFile(
            in: root,
            fileName: "correction.json",
            postprocess: "codex"
        )

        var unapplied = originalManifest
        unapplied.glossary = ManifestGlossary(
            provided: true,
            sha256: String(repeating: "a", count: 64),
            itemCount: 1,
            injectionMode: .hotwordInstruction,
            applied: false
        )
        try JSONEncoder().encode(unapplied).write(to: manifestURL)
        do {
            _ = try await testApplication(runID: "unapplied-glossary").execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", postprocessProfiles.path,
            ])
            Issue.record("expected unapplied glossary rejection")
        } catch let error as CLIError {
            guard case .sourceIntegrity = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
        }

        let invalidDocuments: [(String, (inout Segment) -> Void)] = [
            ("confidence", { $0.confidence = 2 }),
            ("language", { $0.language = "not a language tag!" }),
            ("duplicate-flags", { $0.flags = ["uncertain", "uncertain"] }),
            ("invalid-flag", { $0.flags = ["Invalid Flag"] }),
        ]
        for (identifier, mutation) in invalidDocuments {
            var document = originalSegments
            mutation(&document.segments[0])
            let data = try JSONEncoder().encode(document)
            try data.write(to: segmentsURL)
            var manifest = originalManifest
            let index = try #require(manifest.artifacts.firstIndex {
                $0.kind == "merged_segments"
            })
            manifest.artifacts[index].sha256 = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            try JSONEncoder().encode(manifest).write(to: manifestURL)
            do {
                _ = try await testApplication(
                    runID: "invalid-segment-\(identifier)"
                ).execute(arguments: [
                    "postprocess", sourceRun.path,
                    "--profile", "ko-meeting",
                    "--profiles", postprocessProfiles.path,
                ])
                Issue.record("expected invalid \(identifier) rejection")
            } catch let error as CLIError {
                guard case .sourceIntegrity = error else {
                    Issue.record("unexpected CLI error for \(identifier): \(error)")
                    continue
                }
            }
        }

        var rawDocument = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(originalSegments)
            ) as? [String: Any]
        )
        var rawSegments = try #require(rawDocument["segments"] as? [[String: Any]])
        rawSegments[0]["extra_metadata"] = true
        rawDocument["segments"] = rawSegments
        let extraMetadataData = try JSONSerialization.data(withJSONObject: rawDocument)
        try extraMetadataData.write(to: segmentsURL)
        var extraMetadataManifest = originalManifest
        let extraMetadataIndex = try #require(
            extraMetadataManifest.artifacts.firstIndex {
                $0.kind == "merged_segments"
            }
        )
        extraMetadataManifest.artifacts[extraMetadataIndex].sha256 = SHA256.hash(
            data: extraMetadataData
        ).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(extraMetadataManifest).write(to: manifestURL)
        do {
            _ = try await testApplication(
                runID: "invalid-segment-extra-metadata"
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", postprocessProfiles.path,
            ])
            Issue.record("expected additional segment metadata rejection")
        } catch let error as CLIError {
            guard case .sourceIntegrity = error else {
                Issue.record("unexpected CLI error for extra metadata: \(error)")
                return
            }
        }
    }

    @Test
    func existingRunPostprocessReverifiesSourceBeforeSealingSuccess() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "source.wav")
        let sourceProfiles = try profileFile(in: root, fileName: "source.json")
        let sourcePath = try await testApplication(runID: "source-run").execute(
            arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", sourceProfiles.path,
                "--output-root", root.appendingPathComponent("runs").path,
            ]
        )
        let sourceRun = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let profiles = try profileFile(
            in: root,
            fileName: "correction.json",
            postprocess: "codex"
        )
        var dependencies = testDependencies()
        let postprocess = dependencies.postprocess
        dependencies.postprocess = { backend, request in
            let result = try await postprocess(backend, request)
            try Data("changed while backend was running".utf8).write(
                to: sourceRun.appendingPathComponent("primary/raw.txt")
            )
            return result
        }

        do {
            _ = try await testApplication(
                runID: "derived-failed",
                dependencies: dependencies
            ).execute(arguments: [
                "postprocess", sourceRun.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
            ])
            Issue.record("expected source mutation rejection")
        } catch let error as CLIError {
            guard case .sourceIntegrity = error else {
                Issue.record("unexpected CLI error: \(error)")
                return
            }
        }
        let failedRoot = sourceRun.appendingPathComponent(
            "derived/derived-failed",
            isDirectory: true
        )
        let manifest: DerivedManifest = try decode(
            "manifest.json",
            in: failedRoot
        )
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "SOURCE_INTEGRITY_ERROR")
        #expect(FileManager.default.fileExists(
            atPath: failedRoot.appendingPathComponent(
                "postprocess/segments.json"
            ).path
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
    func MOSSDepthExhaustionFailsExplicitlyAndPromotesSuccessfulSiblings() async throws {
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

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])

        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        // The depth-exhausted 0-30 s range still fails explicitly and still
        // carries the MOSS code.  What changed is that its successful siblings
        // are now promoted rather than merely left on disk: losing one leaf no
        // longer discards the transcript the run already has.
        #expect(manifest.status == .partial)
        #expect(manifest.failure?.code == "MOSS_LIMIT_EXHAUSTED")
        #expect(manifest.coverage.truncated)
        #expect(manifest.coverage.strategy == .backendTruncated)
        #expect(abs(manifest.coverage.processedDurationS - 210) < 0.01)
        #expect(manifest.failure?.message.contains("[0.000, 30.000) s") == true)
        #expect(recorder.calls.allSatisfy { $0.endS - $0.startS <= 120 })
        #expect(recorder.diarizationCalls == 1)
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/raw.txt").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("merged/segments.json").path
        ))
        let partial = try jsonObject("primary/partial-coverage.json", in: run)
        let missing = try #require(partial["missing"] as? [[String: Any]])
        #expect(missing.count == 1)
        #expect(missing[0]["attempt_id"] as? String == "chunk-0000-root-l-l")
        #expect(missing[0]["failure_code"] as? String == "MOSS_LIMIT_EXHAUSTED")
        #expect(missing[0]["stop_reason"] as? String == "maximumTokens")
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
        #expect(left["status"] as? String == "CANCELED")
        #expect(right["status"] as? String == "CANCELED")
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
                "asr-evidence-unavailable",
                .evidenceUnavailable("synthetic terminal evidence unavailable"),
                "asr_evidence_unavailable",
                "asr_evidence_unavailable"
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
        let schemaFailureCodes = try manifestSchemaFailureCodes()

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
            #expect(schemaFailureCodes.contains(testCase.code))
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

    @Test
    func runCompletesWhenTheOutputRootIsSpelledThroughPrivate() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateRoot = try privateSpellingTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: privateRoot) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outputRoot = privateRoot.appendingPathComponent(
            "runs",
            isDirectory: true
        )
        #expect(outputRoot.path.hasPrefix("/private/"))
        let app = testApplication(runID: "private-root")

        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])

        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .succeeded)
        #expect(manifest.failure == nil)
        #expect(!manifest.artifacts.isEmpty)
        for artifact in manifest.artifacts {
            #expect(!artifact.path.hasPrefix("/"))
            #expect(!artifact.path.contains("private"))
        }
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("merged/segments.json").path
        ))
    }

    @Test
    func runRejectsAPreprocessedArtifactOutsideTheRunDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        var dependencies = testDependencies()
        dependencies.preprocess = { audio, _ in
            try AudioPreprocessor().preprocess(
                inputURL: audio,
                outputDirectory: outside
            )
        }
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: "outside", dependencies: dependencies)

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected an artifact outside the run directory to fail")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
            let description = try #require(error.errorDescription)
            #expect(description.contains("artifact is outside the run directory"))
        }
        let manifest: Manifest = try decode(
            "manifest.json",
            in: outputRoot.appendingPathComponent("outside", isDirectory: true)
        )
        #expect(manifest.status == .failed)
    }

    @Test
    func runRejectsAnArtifactReachedThroughASymlinkOutOfTheRunDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(in: root)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        var dependencies = testDependencies()
        dependencies.preprocess = { audio, directory in
            let preprocessed = try AudioPreprocessor().preprocess(
                inputURL: audio,
                outputDirectory: outside
            )
            let escape = directory
                .deletingLastPathComponent()
                .appendingPathComponent("escape", isDirectory: true)
            try FileManager.default.createSymbolicLink(
                at: escape,
                withDestinationURL: outside
            )
            var relocated = preprocessed
            relocated.artifactURL = escape.appendingPathComponent(
                preprocessed.artifactURL.lastPathComponent
            )
            return relocated
        }
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let run = outputRoot.appendingPathComponent(
            "symlink-escape",
            isDirectory: true
        )
        let app = testApplication(
            runID: "symlink-escape",
            dependencies: dependencies
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected a symlinked artifact escape to be rejected")
        } catch let error as CLIError {
            #expect(error.code == "RUN_ERROR")
            let description = try #require(error.errorDescription)
            #expect(description.contains("artifact is outside the run directory"))
        }
        // The rejected artifact is spelled inside the run directory and only
        // resolves outside it, so the check has to resolve the path rather than
        // compare the two spellings.
        let escape = run.appendingPathComponent("escape", isDirectory: true)
        #expect(escape.path.hasPrefix(run.path + "/"))
        #expect(!escape.resolvingSymlinksInPath().path.hasPrefix(run.path + "/"))
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .failed)
    }

    @Test
    func vibeVoiceLeafPolicyIsBoundedBelowAtAndAboveItsMeasuredMaximum() throws {
        let policy = CLIASRInferencePolicy.policy(for: .vibeVoice)
        #expect(policy.minimumInitialDurationS == 60)
        #expect(policy.preferredInitialDurationS == 120)
        #expect(policy.maximumInitialDurationS == 120)
        #expect(policy.minimumRecoveryDurationS == 30)
        #expect(policy.maximumRecoveryDepth == 2)
        #expect(policy.maximumTokens == 5_120)
        #expect(policy.audioContextTokensPerSecond == 7.5)
        // Falsified at 7.61 by an accepted 31.87 s leaf carrying 22 segments.
        #expect(policy.observedGeneratedTokensPerSecond == 23.34)
        // The MOSS policy is untouched by the VibeVoice re-derivation.
        let moss = CLIASRInferencePolicy.policy(for: .moss)
        #expect(moss.maximumInitialDurationS == 120)
        #expect(moss.maximumRecoveryDepth == 3)
        #expect(moss.maximumTokens == 5_120)

        let rate = Double(policy.sampleRateHz)
        let planner = InferenceLeafPlanner()
        for (label, durationS, expectedLeaves) in [
            ("below", 120 - 1.0 / rate, 1),
            ("at", 120.0, 1),
            ("above", 120 + 1.0 / rate, 2),
        ] {
            let totalSamples = Int64((durationS * rate).rounded())
            let map = try VoiceActivityMap(
                durationS: durationS,
                regions: [
                    VoiceActivityRegion(
                        startS: 0,
                        endS: durationS,
                        kind: .speech
                    ),
                ]
            )
            let leaves = try planner.proposeInitialLeaves(
                totalSamples: totalSamples,
                activityMap: map,
                configuration: policy.planningConfiguration
            )
            #expect(leaves.count == expectedLeaves, "\(label) the maximum")
            #expect(leaves.allSatisfy {
                Double($0.sampleCount) / rate
                    <= policy.maximumInitialDurationS + 0.000_1
            })
            #expect(leaves.first?.startSample == 0)
            #expect(leaves.last?.endSample == totalSamples)
        }
    }

    @Test
    func vibeVoiceCollapseSplitsAndRecoversInsteadOfKillingTheRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "vibevoice-recovery.wav",
            durationS: 120
        )
        let profiles = try profileFile(
            in: root,
            fileName: "vibevoice.json",
            asrBackend: "vibevoice",
            languagePin: "ko"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "vibevoice-recovery",
            dependencies: vibeVoiceTestDependencies(
                recorder: recorder,
                // Only the whole 120 s leaf collapses; both halves are clean.
                collapseAt: { startS, endS in
                    abs(startS) < 0.000_001 && abs(endS - 120) < 0.000_001
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

        #expect(manifest.status == .succeeded)
        #expect(manifest.failure == nil)
        #expect(!manifest.coverage.truncated)
        #expect(abs(manifest.coverage.processedDurationS - 120) < 0.01)
        #expect(recorder.calls.count == 3)
        let parent = try jsonObject(
            "primary/attempts/chunk-0000-root/outcome.json",
            in: run
        )
        #expect(parent["status"] as? String == "limit_isolated")
        #expect(parent["stop_reason"] as? String == "repetitionLooping")
        #expect(parent["error_code"] == nil)
        for child in ["chunk-0000-root-l", "chunk-0000-root-r"] {
            let outcome = try jsonObject(
                "primary/attempts/\(child)/outcome.json",
                in: run
            )
            #expect(outcome["status"] as? String == "eos_complete")
        }
        let constraints = try jsonObject(
            "preprocess/asr-constraints.json",
            in: run
        )
        #expect(constraints["maximum_attempt_count"] as? Int == 7)
        #expect(!FileManager.default.fileExists(
            atPath: run.appendingPathComponent(
                "primary/partial-coverage.json"
            ).path
        ))
    }

    @Test
    func vibeVoiceCollapseAtTheRecoveryFloorPromotesTheValidPrefix() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "vibevoice-prefix.wav",
            durationS: 120
        )
        let inputHash = try AudioPreprocessor.sha256(of: input)
        let profiles = try profileFile(
            in: root,
            fileName: "vibevoice-prefix.json",
            asrBackend: "vibevoice",
            languagePin: "ko"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "vibevoice-prefix",
            dependencies: vibeVoiceTestDependencies(
                recorder: recorder,
                // Every leaf in the left half collapses, so recovery reaches
                // the 30 s floor and the prefix is all that is left.
                collapseAt: { startS, _ in startS < 60 },
                prefixShare: 0.75
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

        #expect(manifest.status == .partial)
        #expect(manifest.failure?.code == "ASR_REPETITION_LOOPING")
        #expect(manifest.failure?.code != "MOSS_LIMIT_EXHAUSTED")
        #expect(manifest.coverage.truncated)
        #expect(manifest.coverage.strategy == .backendTruncated)
        // 22.5 s promoted from each of the two 30 s floor leaves, plus the
        // clean 60 s second half.
        #expect(abs(manifest.coverage.processedDurationS - 105) < 0.01)
        #expect(manifest.failure?.message.contains("promoted") == true)
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)

        let promoted = try jsonObject(
            "primary/attempts/chunk-0000-root-l-l/outcome.json",
            in: run
        )
        #expect(promoted["status"] as? String == "partial_prefix_promoted")
        #expect(promoted["stop_reason"] as? String == "repetitionLooping")
        #expect(promoted["error_code"] as? String
            == "ASR_REPETITION_LOOPING")
        #expect(promoted["result_path"] as? String != nil)
        #expect(promoted["canonical_promoted"] as? Bool == false)

        let partial = try jsonObject("primary/partial-coverage.json", in: run)
        let missing = try #require(partial["missing"] as? [[String: Any]])
        #expect(missing.count == 2)
        #expect(missing.allSatisfy {
            $0["stop_reason"] as? String == "repetitionLooping"
        })
        #expect(missing.allSatisfy {
            ($0["end_s"] as? Double ?? 0) > ($0["start_s"] as? Double ?? 0)
        })
        let partialIDs = partial["partial_attempt_ids"] as? [String]
        #expect(partialIDs?.count == 2)
        let promotion = try jsonObject("primary/promotion.json", in: run)
        #expect((promotion["partial_prefix_attempt_ids"] as? [String])?.count
            == 2)
        #expect((promotion["eos_leaf_attempt_ids"] as? [String])?
            .contains("chunk-0000-root-l-l") == false)

        // The promoted prefix still reaches the canonical merged transcript.
        let merged: SegmentsDocument = try decode(
            "merged/segments.json",
            in: run
        )
        #expect(merged.segments.contains { $0.text.contains("prefix") })
        #expect(Set(manifest.artifacts.map(\.path)) ==
            (try regularRelativePaths(in: run)).subtracting(["manifest.json"]))
    }

    @Test
    func oneUnrecoverableChunkDoesNotDiscardTheChunksAroundIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "one-lost-chunk.wav",
            durationS: 360
        )
        let inputHash = try AudioPreprocessor.sha256(of: input)
        let profiles = try profileFile(
            in: root,
            fileName: "one-lost-chunk.json",
            asrBackend: "vibevoice",
            languagePin: "ko"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let recorder = MOSSAttemptRecorder()
        let app = testApplication(
            runID: "one-lost-chunk",
            dependencies: vibeVoiceTestDependencies(
                recorder: recorder,
                // The whole middle chunk collapses at every depth and recovers
                // nothing, so 120 s of 360 s is genuinely unrecoverable.
                collapseAt: { startS, _ in startS >= 120 && startS < 240 },
                prefixShare: 0
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

        // The run keeps everything it transcribed.
        #expect(manifest.status == .partial)
        #expect(manifest.failure?.code == "ASR_REPETITION_LOOPING")
        #expect(manifest.coverage.truncated)
        #expect(manifest.coverage.strategy == .backendTruncated)
        #expect(abs(manifest.coverage.processedDurationS - 240) < 0.01)
        #expect(manifest.chunkBoundaries.map(\.status)
            == [.succeeded, .failed, .succeeded])
        #expect(try AudioPreprocessor.sha256(of: input) == inputHash)

        // Canonical artifacts exist and carry the surviving chunks.
        let merged: SegmentsDocument = try decode("merged/segments.json", in: run)
        #expect(merged.segments.count == 2)
        #expect(merged.segments.contains { $0.startS < 120 })
        #expect(merged.segments.contains { $0.startS >= 240 })
        #expect(merged.segments.allSatisfy { !($0.startS >= 120 && $0.startS < 240) })
        #expect(FileManager.default.fileExists(
            atPath: run.appendingPathComponent("primary/raw.txt").path
        ))

        // The lost range is named rather than inferred from the shortfall.
        let partial = try jsonObject("primary/partial-coverage.json", in: run)
        #expect(abs((partial["promoted_duration_s"] as? Double ?? 0) - 240) < 0.01)
        #expect(abs((partial["missing_duration_s"] as? Double ?? 0) - 120) < 0.01)
        let missing = try #require(partial["missing"] as? [[String: Any]])
        #expect(missing.count == 4)
        #expect(missing.allSatisfy {
            $0["failure_code"] as? String == "ASR_REPETITION_LOOPING"
        })
        #expect(missing.allSatisfy {
            ($0["start_s"] as? Double ?? -1) >= 120
                && ($0["end_s"] as? Double ?? 0) <= 240.01
        })
        #expect(missing.map { $0["start_s"] as? Double ?? -1 }
            == [120, 150, 180, 210])

        // A promoted complete leaf stays distinguishable from a promoted
        // prefix, which the done criteria depend on.
        let promotion = try jsonObject("primary/promotion.json", in: run)
        #expect((promotion["eos_leaf_attempt_ids"] as? [String])?.count == 2)
        #expect((promotion["partial_prefix_attempt_ids"] as? [String])?.isEmpty
            == true)
        #expect(Set(manifest.artifacts.map(\.path)) ==
            (try regularRelativePaths(in: run)).subtracting(["manifest.json"]))
    }

    @Test
    func vibeVoiceCollapseWithNoPrefixFailsWithItsOwnCode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try makeWAV(
            in: root,
            name: "vibevoice-no-prefix.wav",
            durationS: 120
        )
        let profiles = try profileFile(
            in: root,
            fileName: "vibevoice-no-prefix.json",
            asrBackend: "vibevoice",
            languagePin: "ko"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(
            runID: "vibevoice-no-prefix",
            dependencies: vibeVoiceTestDependencies(
                recorder: MOSSAttemptRecorder(),
                collapseAt: { _, _ in true },
                prefixShare: 0
            )
        )

        do {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
            Issue.record("expected an unrecoverable looping failure")
        } catch let error as CLIError {
            #expect(error.code == "ASR_REPETITION_LOOPING")
        }

        let run = outputRoot.appendingPathComponent(
            "vibevoice-no-prefix",
            isDirectory: true
        )
        let manifest: Manifest = try decode("manifest.json", in: run)
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "ASR_REPETITION_LOOPING")
        let exhausted = try jsonObject(
            "primary/attempts/chunk-0000-root-l-l/outcome.json",
            in: run
        )
        #expect(exhausted["status"] as? String == "repetition_looping")
        #expect(exhausted["error_code"] as? String
            == "ASR_REPETITION_LOOPING")
        #expect(exhausted["result_path"] == nil)
    }

    // MARK: - Derived speaker proposal

    /// Produce a source run whose second segment two speakers hold in an exact
    /// tie, which is the shape the real recording is full of.
    private func speakerProposalSourceRun(
        in root: URL,
        runID: String,
        dependencies: CLIDependencies,
        postprocess: String = "none"
    ) async throws -> URL {
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(
            in: root,
            fileName: "speaker-proposal-profiles.json",
            postprocess: postprocess
        )
        // The proposal is a separate operation with its own profile: the source
        // run here was made without any post-processing backend at all.
        _ = try profileFile(
            in: root,
            fileName: "speaker-proposal-codex.json",
            postprocess: "codex"
        )
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let app = testApplication(runID: runID, dependencies: dependencies)
        let runPath = try await app.execute(arguments: [
            "run", input.path,
            "--profile", "ko-meeting",
            "--profiles", profiles.path,
            "--output-root", outputRoot.path,
        ])
        return URL(fileURLWithPath: runPath, isDirectory: true)
    }

    private func fileHashes(under root: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        let prefix = root.standardizedFileURL.path + "/"
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )!
        while let url = enumerator.nextObject() as? URL {
            guard try url.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile == true else { continue }
            let relative = String(
                url.standardizedFileURL.path.dropFirst(prefix.count)
            )
            guard !relative.hasPrefix("derived/") else { continue }
            hashes[relative] = try AudioPreprocessor.sha256(of: url)
        }
        return hashes
    }

    @Test
    func speakerProposalMarksItselfAndLeavesEverySourceByteAlone() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await speakerProposalSourceRun(
            in: root,
            runID: "proposal-source",
            dependencies: speakerProposalDependencies()
        )
        let before = try fileHashes(under: run)
        let merged: SegmentsDocument = try decode("merged/segments.json", in: run)
        let unattributed = merged.segments.indices.filter {
            UnattributedSpeaker.isUnattributed(merged.segments[$0].speaker)
        }
        #expect(unattributed == [1])

        let app = testApplication(
            runID: "proposal-derived",
            dependencies: speakerProposalDependencies()
        )
        let output = try await app.executeProposeSpeakers(
            runPath: run.path,
            profileName: "ko-meeting",
            profilesPath: root.appendingPathComponent(
                "speaker-proposal-codex.json"
            ).path
        )
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1] == "unattributed=1 proposed=1 declined=0")
        #expect(lines[2].hasPrefix("source_coverage=complete"))
        let derived = URL(fileURLWithPath: lines[0], isDirectory: true)

        #expect(try fileHashes(under: run) == before)

        let manifest: DerivedManifest = try decode("manifest.json", in: derived)
        #expect(manifest.status == .succeeded)
        #expect(manifest.failure == nil)
        #expect(manifest.operation.kind == .speakerProposal)
        #expect(manifest.operation.sourceCoverageComplete)
        #expect(manifest.operation.sourceCoverage?.missingDurationS == 0)
        #expect(manifest.source.segmentsPath == "merged/segments.json")
        #expect(manifest.source.segmentsSHA256 == before["merged/segments.json"])
        #expect(manifest.artifacts.map(\.kind) == ["speaker_proposals"])
        #expect(manifest.artifacts.map(\.path) == ["speaker/proposals.json"])
        // D25 and D29: the model that produced the proposal is named in the
        // manifest, and it received text only.
        #expect(manifest.postprocess?.inputMode == .textOnly)
        #expect(manifest.postprocess?.modelID == CodexPostprocessBackend.modelName)
        #expect(
            manifest.postprocess?.sourceSegmentsSHA256
                == manifest.source.segmentsSHA256
        )

        let document: SpeakerProposalDocument = try decode(
            "speaker/proposals.json",
            in: derived
        )
        #expect(document.layer == "speaker-proposal")
        #expect(document.sourceCoverage.complete)
        #expect(document.sourceCoverage.inputDurationS == 2)
        #expect(document.unattributedSpeakers == ["UNASSIGNED", "UNKNOWN"])
        #expect(document.proposals.map(\.segmentIndex) == [1])
        #expect(document.declined.isEmpty)
        let proposal = try #require(document.proposals.first)
        #expect(proposal.proposedSpeaker == "S0")
        #expect(proposal.acousticOutcome == "no_dominant_speaker")
        #expect(proposal.acousticCandidates.map(\.speaker) == ["S0", "S1"])
        #expect(proposal.acousticCandidates.allSatisfy { $0.share == 0.5 })
        #expect(proposal.acousticCandidates.allSatisfy { $0.overlapS > 0 })
        #expect(!proposal.reason.isEmpty)

        // The proposal is named as a proposal in the bytes themselves, and the
        // word "speaker" alone never carries it.
        let raw = try jsonObject("speaker/proposals.json", in: derived)
        let rawProposals = try #require(raw["proposals"] as? [[String: Any]])
        #expect(Set(rawProposals[0].keys) == [
            "segment_index",
            "proposed_speaker",
            "reason",
            "acoustic_outcome",
            "acoustic_timeline_coverage",
            "acoustic_candidates",
        ])
    }

    @Test
    func speakerProposalRefusesToTouchAnAcousticallyAssignedSegment() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await speakerProposalSourceRun(
            in: root,
            runID: "proposal-override-source",
            dependencies: speakerProposalDependencies()
        )
        let before = try fileHashes(under: run)
        // A proposer that answers about segment 0, which the acoustics assigned.
        let overriding = speakerProposalDependencies { backend, request in
            var result = try speakerProposalFixture(backend, request)
            result.document.proposals.append(SpeakerProposal(
                segmentIndex: 0,
                proposedSpeaker: "S1",
                reason: "invented",
                acousticOutcome: "attributed",
                acousticTimelineCoverage: 1,
                acousticCandidates: []
            ))
            return result
        }
        let app = testApplication(
            runID: "proposal-override",
            dependencies: overriding
        )
        await #expect(throws: CLIError.self) {
            _ = try await app.executeProposeSpeakers(
                runPath: run.path,
                profileName: "ko-meeting",
                profilesPath: root.appendingPathComponent(
                    "speaker-proposal-codex.json"
                ).path
            )
        }
        #expect(try fileHashes(under: run) == before)
        let derived = run.appendingPathComponent(
            "derived/proposal-override",
            isDirectory: true
        )
        let manifest: DerivedManifest = try decode("manifest.json", in: derived)
        #expect(manifest.status == .failed)
        #expect(manifest.failure?.code == "POSTPROCESS_ERROR")
        #expect(!FileManager.default.fileExists(
            atPath: derived.appendingPathComponent("speaker/proposals.json").path
        ))
    }

    @Test
    func speakerProposalRefusesASpeakerTheAcousticsNeverOffered() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await speakerProposalSourceRun(
            in: root,
            runID: "proposal-invented-source",
            dependencies: speakerProposalDependencies()
        )
        let inventing = speakerProposalDependencies { backend, request in
            try speakerProposalFixture(
                backend,
                request,
                override: [1: ("S9", "a speaker no turn ever held")]
            )
        }
        let app = testApplication(
            runID: "proposal-invented",
            dependencies: inventing
        )
        await #expect(throws: CLIError.self) {
            _ = try await app.executeProposeSpeakers(
                runPath: run.path,
                profileName: "ko-meeting",
                profilesPath: root.appendingPathComponent(
                    "speaker-proposal-codex.json"
                ).path
            )
        }
    }

    @Test
    func aSilentProposerStillAccountsForEveryUnattributedSegment() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try await speakerProposalSourceRun(
            in: root,
            runID: "proposal-silent-source",
            dependencies: speakerProposalDependencies()
        )
        let silent = speakerProposalDependencies { backend, request in
            try speakerProposalFixture(
                backend,
                request,
                dropDecisionsFor: Set(request.evidence.map(\.segmentIndex))
            )
        }
        let app = testApplication(runID: "proposal-silent", dependencies: silent)
        let output = try await app.executeProposeSpeakers(
            runPath: run.path,
            profileName: "ko-meeting",
            profilesPath: root.appendingPathComponent(
                "speaker-proposal-codex.json"
            ).path
        )
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines[1] == "unattributed=1 proposed=0 declined=1")
        let derived = URL(fileURLWithPath: lines[0], isDirectory: true)
        let document: SpeakerProposalDocument = try decode(
            "speaker/proposals.json",
            in: derived
        )
        #expect(document.proposals.isEmpty)
        #expect(document.declined.map(\.segmentIndex) == [1])
        // Nothing was proposed, and the file still says which segment was
        // looked at, what the acoustics held, and why it was left alone.
        #expect(!document.declined[0].reason.isEmpty)
        #expect(document.declined[0].acousticCandidates.count == 2)
    }

    @Test
    func speakerProposalDerivesFromAPartialRunThatCorrectionRefuses() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var dependencies = speakerProposalDependencies()
        dependencies.postprocess = { _, _ in
            throw PostprocessError.backendFailed("synthetic postprocess failure")
        }
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let input = try makeWAV(in: root, name: "input.wav")
        let profiles = try profileFile(
            in: root,
            fileName: "speaker-proposal-profiles.json",
            postprocess: "local"
        )
        let app = testApplication(
            runID: "proposal-partial-source",
            dependencies: dependencies
        )
        await #expect(throws: CLIError.self) {
            _ = try await app.execute(arguments: [
                "run", input.path,
                "--profile", "ko-meeting",
                "--profiles", profiles.path,
                "--output-root", outputRoot.path,
            ])
        }
        let run = outputRoot.appendingPathComponent(
            "proposal-partial-source",
            isDirectory: true
        )
        let sourceManifest: Manifest = try decode("manifest.json", in: run)
        #expect(sourceManifest.status == .partial)

        // Correction and translation still refuse a source that is not a
        // complete run; only the proposal path accepts it, and it records that
        // the source was partial.
        #expect(throws: RunIntegrityError.sourceRunNotComplete) {
            _ = try RunIntegrityVerifier.verifyCompletedRun(at: run)
        }
        let derivedApp = testApplication(
            runID: "proposal-partial",
            dependencies: speakerProposalDependencies()
        )
        await #expect(throws: CLIError.self) {
            _ = try await derivedApp.executePostprocess(
                runPath: run.path,
                profileName: "ko-meeting",
                profilesPath: profiles.path,
                glossaryPath: nil
            )
        }
        let output = try await derivedApp.executeProposeSpeakers(
            runPath: run.path,
            profileName: "ko-meeting",
            profilesPath: profiles.path
        )
        let derived = URL(
            fileURLWithPath: output.split(separator: "\n").map(String.init)[0],
            isDirectory: true
        )
        let manifest: DerivedManifest = try decode("manifest.json", in: derived)
        #expect(manifest.status == .succeeded)
        #expect(manifest.operation.kind == .speakerProposal)
        #expect(!manifest.operation.sourceCoverageComplete)
        let coverage = try #require(manifest.operation.sourceCoverage)
        #expect(coverage.inputDurationS == sourceManifest.coverage.inputDurationS)
        #expect(
            coverage.processedDurationS
                == sourceManifest.coverage.processedDurationS
        )
        // A proposal over an incomplete transcript says so in the artifact that
        // carries the proposals, not only in the manifest beside it.
        let document: SpeakerProposalDocument = try decode(
            "speaker/proposals.json",
            in: derived
        )
        #expect(document.sourceCoverage == coverage)
        #expect(!document.sourceCoverage.complete)
        #expect(output.split(separator: "\n").map(String.init)[2]
            .hasPrefix("source_coverage=partial"))
    }

    /// Drive the real proposal path, with the real backend, against a run this
    /// repository never sees. Opt-in, because it needs a model and a network,
    /// and because the only run worth pointing it at is private.
    ///
    ///     MACCHERONI_RUN_SPEAKER_PROPOSAL_INTEGRATION=1 \
    ///     MACCHERONI_SPEAKER_PROPOSAL_RUN=<run directory> \
    ///     MACCHERONI_SPEAKER_PROPOSAL_PROFILES=<profiles.json> \
    ///     swift test --filter actualSpeakerProposalDerivesFromAPreservedRun
    @Test(.enabled(if: ProcessInfo.processInfo.environment[
        "MACCHERONI_RUN_SPEAKER_PROPOSAL_INTEGRATION"
    ] == "1"))
    func actualSpeakerProposalDerivesFromAPreservedRun() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runPath = try #require(
            environment["MACCHERONI_SPEAKER_PROPOSAL_RUN"]
        )
        let profilesPath = try #require(
            environment["MACCHERONI_SPEAKER_PROPOSAL_PROFILES"]
        )
        let run = URL(fileURLWithPath: runPath, isDirectory: true)
        let before = try fileHashes(under: run)
        let merged: SegmentsDocument = try decode("merged/segments.json", in: run)
        let unattributed = merged.segments.indices.filter {
            UnattributedSpeaker.isUnattributed(merged.segments[$0].speaker)
        }

        let output = try await CLIApplication().executeProposeSpeakers(
            runPath: runPath,
            profileName: environment["MACCHERONI_SPEAKER_PROPOSAL_PROFILE"]
                ?? "ko-meeting",
            profilesPath: profilesPath
        )
        let lines = output.split(separator: "\n").map(String.init)
        print("[speaker-proposal] \(lines.joined(separator: " | "))")

        // The source run is byte-identical afterwards, including the manifest.
        #expect(try fileHashes(under: run) == before)

        let derived = URL(fileURLWithPath: lines[0], isDirectory: true)
        let manifest: DerivedManifest = try decode("manifest.json", in: derived)
        #expect(manifest.status == .succeeded)
        #expect(manifest.operation.kind == .speakerProposal)
        #expect(manifest.source.segmentsSHA256 == before["merged/segments.json"])
        #expect(manifest.artifacts.map(\.kind) == ["speaker_proposals"])
        let coverage = try #require(manifest.operation.sourceCoverage)
        print(
            "[speaker-proposal] source_coverage complete=\(coverage.complete)"
                + " processed_s=\(coverage.processedDurationS)"
                + " input_s=\(coverage.inputDurationS)"
                + " missing_s=\(coverage.missingDurationS)"
        )
        print(
            "[speaker-proposal] backend="
                + "\(manifest.postprocess?.backend.name ?? "?")"
                + "@\(manifest.postprocess?.backend.version ?? "?")"
                + " model=\(manifest.postprocess?.modelID ?? "?")"
                + " batches=\(manifest.postprocess?.batching?.batchesPlanned ?? -1)"
                + " source_coverage_complete="
                + "\(manifest.operation.sourceCoverageComplete)"
        )

        let document: SpeakerProposalDocument = try decode(
            "speaker/proposals.json",
            in: derived
        )
        #expect(document.sourceCoverage == coverage)
        let covered = Set(document.proposals.map(\.segmentIndex))
            .union(document.declined.map(\.segmentIndex))
        #expect(covered == Set(unattributed))
        #expect(
            document.proposals.count + document.declined.count
                == unattributed.count
        )
        for proposal in document.proposals {
            #expect(UnattributedSpeaker.isUnattributed(
                merged.segments[proposal.segmentIndex].speaker
            ))
            if !proposal.acousticCandidates.isEmpty {
                #expect(proposal.acousticCandidates.map(\.speaker)
                    .contains(proposal.proposedSpeaker))
            }
        }
        let withCandidates = document.proposals
            .filter { !$0.acousticCandidates.isEmpty }
        print(
            "[speaker-proposal] unattributed=\(unattributed.count)"
                + " proposed=\(document.proposals.count)"
                + " declined=\(document.declined.count)"
                + " proposals_with_candidates=\(withCandidates.count)"
        )
        var outcomes: [String: Int] = [:]
        for record in document.proposals { outcomes[record.acousticOutcome, default: 0] += 1 }
        var declinedOutcomes: [String: Int] = [:]
        for record in document.declined { declinedOutcomes[record.acousticOutcome, default: 0] += 1 }
        print("[speaker-proposal] proposed outcomes=\(outcomes.sorted { $0.key < $1.key })")
        print("[speaker-proposal] declined outcomes=\(declinedOutcomes.sorted { $0.key < $1.key })")
    }

    @Test
    func proposeSpeakersTakesNoGlossaryOptionsAndNeedsAProfile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = testApplication(runID: "proposal-usage")
        await #expect(throws: CLIError.self) {
            _ = try await app.execute(arguments: [
                "propose-speakers", root.path, "--profile", "ko-meeting",
                "--glossary", "terms.txt",
            ])
        }
        await #expect(throws: CLIError.self) {
            _ = try await app.execute(arguments: ["propose-speakers", root.path])
        }
    }

    private func testApplication(
        runID: String,
        dependencies: CLIDependencies? = nil,
        libraryStorageConfiguration: @escaping @Sendable () -> LibraryStorageConfiguration = CLIApplication.productionLibraryStorageConfiguration,
        storageReport: @escaping @Sendable (
            CLIProfile,
            LibraryStorageConfiguration
        ) -> StorageReport = { _, _ in
            fixtureStorageReport()
        }
    ) -> CLIApplication {
        CLIApplication(
            dependencies: dependencies ?? testDependencies(),
            now: { Date(timeIntervalSince1970: 1_786_000_000) },
            runID: { _ in runID },
            libraryStorageConfiguration: libraryStorageConfiguration,
            storageReport: storageReport
        )
    }
}

private final class CLIStorageConfigurationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRunsURL: URL?

    var runsURL: URL? { lock.withLock { storedRunsURL } }

    func record(_ configuration: LibraryStorageConfiguration) {
        lock.withLock { storedRunsURL = configuration.runsURL }
    }
}

private func fixtureStorageReport() -> StorageReport {
    StorageReport(
        volumes: [StorageVolume(
            id: "fixture-volume",
            name: "Fixture Volume",
            roles: [.recordings, .runs],
            availableBytes: 0
        )],
        roots: [
            StorageRootObservation(
                id: "recordings",
                role: .recordings,
                status: .available,
                bookmarkStatus: .none,
                volumeID: "fixture-volume"
            ),
            StorageRootObservation(
                id: "runs",
                role: .runs,
                status: .available,
                bookmarkStatus: .none,
                volumeID: "fixture-volume"
            ),
        ]
    )
}

private func cliTestGlossaryRevisionStoreRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "MaccheroniCLITests-GlossaryRevisions-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true
    )
}

private func testDependencies(
    failASRAtOrAfterS: Double? = nil,
    cancelASRAtOrAfterS: Double? = nil,
    postprocessFailure: Bool = false,
    codexVersion: String = "codex-cli test",
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
            if let cancelASRAtOrAfterS,
               request.startS >= cancelASRAtOrAfterS
            {
                throw CancellationError()
            }
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
                        version: codexVersion
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
                        version: codexVersion
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
        proposeSpeakers: { backend, request in
            if postprocessFailure {
                throw PostprocessError.backendFailed(
                    "synthetic speaker proposal failure"
                )
            }
            return try speakerProposalFixture(backend, request)
        },
        glossaryRevisionStoreRoot: cliTestGlossaryRevisionStoreRoot,
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

private final class StageInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStages: [String] = []

    var stages: [String] {
        lock.withLock { storedStages }
    }

    func record(_ stage: String) {
        lock.withLock { storedStages.append(stage) }
    }
}

private func postprocessOnlyDependencies(
    recorder: StageInvocationRecorder
) -> CLIDependencies {
    var dependencies = testDependencies()
    let postprocess = dependencies.postprocess
    let translate = dependencies.translate
    dependencies.preprocess = { _, _ in
        recorder.record("preprocess")
        throw CLIError.run("preprocessing must not run for an existing run")
    }
    dependencies.vad = { _ in
        recorder.record("vad")
        throw CLIError.run("VAD must not run for an existing run")
    }
    dependencies.diarize = { _, _ in
        recorder.record("diarization")
        throw CLIError.run("diarization must not run for an existing run")
    }
    dependencies.asr = { _, _, _, _ in
        recorder.record("asr")
        throw CLIError.run("ASR must not run for an existing run")
    }
    dependencies.postprocess = { backend, request in
        recorder.record("postprocess")
        return try await postprocess(backend, request)
    }
    dependencies.translate = { backend, request in
        recorder.record("translate")
        return try await translate(backend, request)
    }
    return dependencies
}

private func vibeVoiceTestDependencies(
    recorder: MOSSAttemptRecorder,
    collapseAt: @escaping @Sendable (Double, Double) -> Bool,
    prefixShare: Double = 0.75
) -> CLIDependencies {
    CLIDependencies(
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
            try InferenceLeafPlanner().proposeInitialLeaves(
                totalSamples: totalSamples,
                activityMap: map,
                configuration: policy.planningConfiguration
            )
        },
        expectedHelperFingerprint: { _ in nil },
        mossContextPlan: { _, _, _, _, _ in nil },
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
            guard selected == .vibeVoice else {
                throw CLIError.run(
                    "synthetic dependency only supports VibeVoice"
                )
            }
            recorder.record(startS: request.startS, endS: request.endS)
            let evidence = try vibeVoiceAttemptEvidence(
                request: request,
                maximumTokens: maximumTokens,
                collapsed: collapseAt(request.startS, request.endS)
            )
            guard collapseAt(request.startS, request.endS) else {
                return .complete(CLIASRExecution(
                    result: ASRResult(
                        rawText: "EOS-\(request.startS)-\(request.endS)",
                        segments: [
                            Segment(
                                speaker: "UNASSIGNED",
                                startS: request.startS + 0.1,
                                endS: request.endS - 0.1,
                                text: "complete \(request.startS)",
                                language: "ko"
                            ),
                        ],
                        glossaryApplied: request.glossary != nil
                    ),
                    evidence: evidence
                ))
            }
            let coverageS = (request.endS - request.startS) * prefixShare
            let prefix = coverageS <= 0 ? nil : ASRPartialPrefix(
                coverageS: coverageS,
                rawText: "[{\"prefix\":true}]",
                segments: [
                    Segment(
                        speaker: "UNASSIGNED",
                        startS: request.startS,
                        endS: request.startS + coverageS,
                        text: "recovered prefix \(request.startS)",
                        language: "ko",
                        flags: ["repetition_looping"]
                    ),
                ],
                completeObjectCount: 3,
                promotedObjectCount: 1,
                degenerateObjectCount: 2,
                repetitionRunThreshold: 12,
                repetitionRunMaximum: 2,
                tailRepetitionRun: 900,
                terminalCollapse: true
            )
            return .limit(CLIASRLimit(
                stopReason: .repetitionLooping,
                evidence: evidence,
                partialPrefix: prefix
            ))
        },
        postprocess: { _, _ in
            throw CLIError.run("synthetic VibeVoice postprocess was not expected")
        },
        translate: { _, _ in
            throw CLIError.run("synthetic VibeVoice translation was not expected")
        },
        proposeSpeakers: { _, _ in
            throw CLIError.run("synthetic VibeVoice speaker proposal was not expected")
        },
        glossaryRevisionStoreRoot: cliTestGlossaryRevisionStoreRoot,
        postprocessDoctor: { _ in ["check.postprocess=true"] },
        doctor: { _, _ in ["check.asr_doctor=true"] }
    )
}

private func vibeVoiceAttemptEvidence(
    request: ASRRequest,
    maximumTokens: Int,
    collapsed: Bool
) throws -> CLIASRAttemptEvidence {
    let inputSHA256 = try AudioPreprocessor.sha256(of: request.audioURL)
    let instructionSHA256 = String(repeating: "c", count: 64)
    let language: String
    switch request.language {
    case .automatic: language = "auto"
    case let .fixed(value): language = value
    }
    return CLIASRAttemptEvidence(
        glossary: request.glossary.map {
            ManifestGlossary(
                provided: true,
                sha256: $0.sha256,
                itemCount: $0.entries.count,
                injectionMode: request.injectionMode,
                applied: true
            )
        } ?? .absent,
        rawEvidence: Data(
            "vibevoice raw \(request.startS)-\(request.endS)".utf8
        ),
        runnerRecordEvidence: Data(
            "{\"outcome\":\"\(collapsed ? "limit" : "complete")\"}\n".utf8
        ),
        glossaryPayloadSHA256: request.glossary == nil ? nil : instructionSHA256,
        glossaryPayloadEntryCount: request.glossary?.entries.count ?? 0,
        metrics: ASRAttemptMetrics(
            preprocessingS: nil,
            audioEncoderS: nil,
            decoderPrefillS: nil,
            tokenDecodeS: nil,
            promptTokens: 42,
            generatedTokens: collapsed ? maximumTokens : 128,
            maxTokens: maximumTokens,
            contextHardCapTokens: nil,
            audioDurationS: request.endS - request.startS,
            totalS: 0,
            modelLoadS: nil,
            runnerWallTimeS: 0,
            peakRSSBytes: nil,
            unavailable: ["context_hard_cap_tokens": "not exposed"]
        ),
        language: ASRLanguageEvidence(
            requested: language,
            instructionSHA256: instructionSHA256,
            promptGuidanceApplied: false
        ),
        helperFingerprint: nil,
        inputSHA256: inputSHA256,
        command: ["mlx_audio.stt.generate"]
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
        proposeSpeakers: { _, _ in
            throw CLIError.run("synthetic MOSS speaker proposal was not expected")
        },
        glossaryRevisionStoreRoot: cliTestGlossaryRevisionStoreRoot,
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

/// The system temporary directory reached through its `/private` spelling, the
/// shape a `--output-root` under `/private/tmp` hands the run writer.  The
/// directory is created because Foundation folds `/private` away only for a
/// path that already exists, which is exactly the asymmetry the containment
/// check has to survive.
private func privateSpellingTemporaryDirectory() throws -> URL {
    let system = FileManager.default.temporaryDirectory
    let spelled = system.path.hasPrefix("/private/")
        ? system
        : URL(fileURLWithPath: "/private" + system.path, isDirectory: true)
    let url = spelled.appendingPathComponent(
        "MaccheroniCLITests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false
    )
    guard url.standardizedFileURL.path != url.path else {
        throw CLIError.run(
            "the temporary directory does not fold through /private"
        )
    }
    return url
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

/// A stub backend executable, so a rejection can be reproduced through the real
/// adapter without a model.
private func writeExecutable(_ script: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("backend-stub.sh")
    try Data(script.utf8).write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
    return url
}

/// The adapter's quarantine directory is shared, so a test names only the files
/// its own run added there and leaves the rest alone.
private func quarantinedFileNames(in root: URL) -> Set<String> {
    Set(
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    )
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

private func jsonArray(
    _ path: String,
    in root: URL
) throws -> [[String: Any]] {
    let value = try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent(path))
    )
    guard let array = value as? [[String: Any]] else {
        throw CLIError.run("test JSON array is malformed: \(path)")
    }
    return array
}

private func manifestSchemaFailureCodes() throws -> Set<String> {
    let testFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(
        "docs/contracts/manifest.schema.json"
    ))
    let schema = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let definitions = try #require(schema["$defs"] as? [String: Any])
    let failure = try #require(definitions["failure"] as? [String: Any])
    let properties = try #require(failure["properties"] as? [String: Any])
    let code = try #require(properties["code"] as? [String: Any])
    return Set(try #require(code["enum"] as? [String]))
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

// MARK: - Speaker proposal fixtures

/// A proposer that names the leading acoustic candidate for the first
/// unattributed segment and declines the rest. Enough to exercise the derived
/// run without a model, and shaped so every unattributed segment is accounted
/// for the way the real proposer accounts for them.
func speakerProposalFixture(
    _ backend: PostprocessBackendID,
    _ request: SpeakerProposalRequest,
    override: [Int: (speaker: String?, reason: String)] = [:],
    dropDecisionsFor: Set<Int> = []
) throws -> SpeakerProposalResult {
    let policy = switch backend {
    case .codex: CodexPostprocessBackend.defaultBatchPolicy
    case .local: LocalPostprocessBackend.defaultBatchPolicy
    }
    var proposals: [SpeakerProposal] = []
    var declined: [SpeakerProposalDecline] = []
    for (offset, record) in request.evidence.enumerated() {
        if dropDecisionsFor.contains(record.segmentIndex) {
            declined.append(SpeakerProposalDecline(
                segmentIndex: record.segmentIndex,
                reason: "the proposer returned no decision for this segment",
                acousticOutcome: record.outcome,
                acousticTimelineCoverage: record.timelineCoverage,
                acousticCandidates: record.candidates
            ))
            continue
        }
        let chosen: String?
        let reason: String
        if let forced = override[record.segmentIndex] {
            chosen = forced.speaker
            reason = forced.reason
        } else if offset == 0 {
            chosen = record.candidates.first?.speaker
            reason = "the previous turn asks this speaker a direct question"
        } else {
            chosen = nil
            reason = "the surrounding turns do not prefer either candidate"
        }
        if let chosen {
            proposals.append(SpeakerProposal(
                segmentIndex: record.segmentIndex,
                proposedSpeaker: chosen,
                reason: reason,
                acousticOutcome: record.outcome,
                acousticTimelineCoverage: record.timelineCoverage,
                acousticCandidates: record.candidates
            ))
        } else {
            declined.append(SpeakerProposalDecline(
                segmentIndex: record.segmentIndex,
                reason: reason,
                acousticOutcome: record.outcome,
                acousticTimelineCoverage: record.timelineCoverage,
                acousticCandidates: record.candidates
            ))
        }
    }
    let outputTextUTF8Bytes = proposals.reduce(0) {
        $0 + $1.proposedSpeaker.utf8.count + $1.reason.utf8.count
    } + declined.reduce(0) { $0 + $1.reason.utf8.count }
    let responseUTF8Bytes = outputTextUTF8Bytes + 64
    let inputTextUTF8Bytes = request.document.segments.reduce(0) {
        $0 + $1.text.utf8.count
    }
    let batching = policy.manifest(
        batchesPlanned: 1,
        maximumObservedPromptUTF8Bytes: min(100, policy.maximumPromptUTF8Bytes),
        maximumObservedInputTextUTF8Bytes: inputTextUTF8Bytes,
        maximumObservedEstimatedOutputTokens: policy.estimatedOutputTokens(
            inputTextUTF8Bytes: inputTextUTF8Bytes,
            segmentCount: request.document.segments.count
        ),
        maximumObservedOutputTextUTF8Bytes: outputTextUTF8Bytes,
        maximumObservedResponseUTF8Bytes: responseUTF8Bytes,
        maximumObservedAcceptedOutputTokenUpperBound:
            policy.acceptedOutputTokenUpperBound(
                responseUTF8Bytes: responseUTF8Bytes,
                segmentCount: request.evidence.count
            )
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
            sourceSegmentsSHA256: request.sourceSegmentsSHA256,
            batching: batching
        )
    }
    return SpeakerProposalResult(
        document: SpeakerProposalDocument(
            sourceSegmentsSHA256: request.sourceSegmentsSHA256,
            sourceCoverage: request.sourceCoverage,
            proposals: proposals,
            declined: declined,
            batches: [TranslationBatchRecord(
                batchIndex: 0,
                segmentIndices: request.evidence.map(\.segmentIndex),
                promptUTF8Bytes: min(100, policy.maximumPromptUTF8Bytes),
                inputTextUTF8Bytes: inputTextUTF8Bytes,
                estimatedOutputTokens: policy.estimatedOutputTokens(
                    inputTextUTF8Bytes: inputTextUTF8Bytes,
                    segmentCount: request.document.segments.count
                ),
                outputTextUTF8Bytes: outputTextUTF8Bytes,
                responseUTF8Bytes: responseUTF8Bytes,
                acceptedOutputTokenUpperBound:
                    policy.acceptedOutputTokenUpperBound(
                        responseUTF8Bytes: responseUTF8Bytes,
                        segmentCount: request.evidence.count
                    )
            )]
        ),
        manifestPostprocess: provenance
    )
}

/// The stub run leaves one segment attributed and one unattributed: two
/// speakers hold the second segment in an exact tie, which is the case the real
/// 20.7-minute recording is full of.
func speakerProposalDependencies(
    proposal: @escaping @Sendable (
        PostprocessBackendID,
        SpeakerProposalRequest
    ) async throws -> SpeakerProposalResult = { try speakerProposalFixture($0, $1) }
) -> CLIDependencies {
    var dependencies = testDependencies()
    dependencies.diarize = { _, _ in
        let segments = [
            TimelineSegment(speaker: "S0", startS: 0, endS: 1),
            TimelineSegment(speaker: "S0", startS: 1, endS: 2),
            TimelineSegment(speaker: "S1", startS: 1, endS: 2),
        ]
        return DiarizationTimelineResult(
            timeline: Timeline(segments: segments),
            rawJSON: try JSONEncoder().encode(segments),
            normalizationWarnings: []
        )
    }
    dependencies.proposeSpeakers = proposal
    return dependencies
}
