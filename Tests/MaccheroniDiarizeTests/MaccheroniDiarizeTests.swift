import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import MaccheroniDiarize
import MaccheroniCore

@Suite(.serialized) struct MaccheroniDiarizeTests {
    private func fixtureURL(_ name: String) throws -> URL {
        guard let fixture = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missing(name)
        }
        return fixture
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaccheroniDiarizeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeExecutable(_ contents: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fixture-command.sh")
        try Data(contents.utf8).write(to: executable, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func writeFile(_ contents: String, named name: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
        return file
    }

    private func processCaptureNames() throws -> Set<String> {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Maccheroni/diarization/process", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    @Test func community1StandaloneDefaultsRemainPinnedToLegacySpeechCLI() {
        let configuration = Community1DiarizerConfiguration()

        #expect(configuration.executableURL.path == "/opt/homebrew/bin/speech")
        #expect(configuration.harnessModelRepositoryURL == nil)
        #expect(configuration.timeoutS == 3_600)
        #expect(configuration.timestampRoundingToleranceS == 0.1)
        #expect(configuration.validatesPinnedModel)
        #expect(Community1Diarizer().descriptor == BackendDescriptor(
            name: "speech-swift-cli",
            version: "0.0.23"
        ))
    }

    @Test func community1OfflineHarnessReceivesExactRepositoryAndRangeHint() async throws {
        let directory = try temporaryDirectory()
        let argumentsURL = directory.appendingPathComponent("arguments.txt")
        let modelRepositoryURL = directory.appendingPathComponent("community1-repository", isDirectory: true)
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 30)
        let fixture = try fixtureURL("community1-valid.json")
        let runtimePayload = try writeRuntimePayload(
            at: modelRepositoryURL,
            relativePaths: community1RuntimeRelativePaths
        )
        let script = try writeExecutable(
            """
            #!/bin/sh
            printf '%s\\n' \"$@\" > '\(argumentsURL.path)'
            cat '\(fixture.path)'
            """,
            in: directory
        )
        let configuration = Community1DiarizerConfiguration(
            executableURL: script,
            hfHomeURL: directory,
            harnessModelRepositoryURL: modelRepositoryURL,
            timeoutS: 5,
            environment: [:],
            validatesPinnedModel: false
        )
        let backend = Community1Diarizer(
            testing: configuration,
            harnessRuntimePayload: runtimePayload
        )
        let result = try await backend.diarizeWithEvidence(DiarizationRequest(
            audioURL: audioURL,
            speakerCountHint: 2...3
        ))
        let timeline = result.timeline

        #expect(timeline.segments.map(\.speaker) == ["0", "1"])
        #expect(timeline.segments.map(\.startS) == [0, 3])
        let fixtureData = try Data(contentsOf: fixture)
        #expect(result.rawJSON == fixtureData)
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        #expect(arguments.contains("--cache-dir\n\(modelRepositoryURL.path)\n"))
        #expect(!arguments.contains("--engine"))
        #expect(arguments.contains("--min-speakers\n2\n"))
        #expect(arguments.contains("--max-speakers\n3\n"))
    }

    @Test func community1HarnessRejectsSameSizePayloadCorruptionBeforeLaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelRepositoryURL = directory.appendingPathComponent(
            "community1-repository",
            isDirectory: true
        )
        let runtimePayload = try writeRuntimePayload(
            at: modelRepositoryURL,
            relativePaths: community1RuntimeRelativePaths
        )
        let corruptedURL = modelRepositoryURL.appendingPathComponent(
            "embedding.mlmodelc/weights/weight.bin"
        )
        var corrupted = try Data(contentsOf: corruptedURL)
        let originalSize = corrupted.count
        corrupted[corrupted.startIndex] ^= 0x01
        try corrupted.write(to: corruptedURL)
        #expect(try Data(contentsOf: corruptedURL).count == originalSize)

        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 1)
        let launchMarkerURL = directory.appendingPathComponent("launched")
        let script = try writeExecutable(
            "#!/bin/sh\nprintf launched > '\(launchMarkerURL.path)'\nprintf '{ \\\"segments\\\": [] }\\n'\n",
            in: directory
        )
        let configuration = Community1DiarizerConfiguration(
            executableURL: script,
            hfHomeURL: directory,
            harnessModelRepositoryURL: modelRepositoryURL,
            timeoutS: 5,
            environment: [:],
            validatesPinnedModel: false
        )
        let backend = Community1Diarizer(
            testing: configuration,
            harnessRuntimePayload: runtimePayload
        )

        await #expect(throws: DiarizationError.modelMismatch(
            expected: "aufklarer/Pyannote-Community-1-CoreML@a14e6c420d56e8472850649b016a486fd0acbe81",
            actual: "local runtime payload"
        )) {
            try await backend.diarize(DiarizationRequest(audioURL: audioURL))
        }
        #expect(!FileManager.default.fileExists(atPath: launchMarkerURL.path))
    }

    @Test func community1PromotesMalformedOutputAndProcessFailure() async throws {
        let directory = try temporaryDirectory()
        let audioURL = directory.appendingPathComponent("private-input.wav")
        try writeSilentWAV(to: audioURL, durationS: 1)
        let privateOutput = "{\\\"transcript\\\":\\\"sensitive-transcript-payload synthetic-secret\"}"
        let malformed = try writeExecutable(
            "#!/bin/sh\nprintf '%s' '\(privateOutput)'\n",
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: malformed,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await backend.diarize(DiarizationRequest(
                audioURL: audioURL
            ))
            Issue.record("expected invalid JSON")
        } catch let error as DiarizationError {
            guard case .invalidJSON = error else {
                Issue.record("expected invalidJSON, got \(error)")
                return
            }
            #expect(!(error.errorDescription ?? "").contains("sensitive-transcript-payload"))
            #expect(!(error.errorDescription ?? "").contains("synthetic-secret"))
        }

        let privateInput = audioURL.path
        let secret = "Bearer synthetic-secret sensitive-transcript-payload \(privateInput)"
        let failure = try writeExecutable(
            "#!/bin/sh\nprintf '%s' '\(secret)' >&2\nexit 19\n",
            in: try temporaryDirectory()
        )
        let failingBackend = Community1Diarizer(configuration: .init(
            executableURL: failure,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await failingBackend.diarize(DiarizationRequest(
                audioURL: audioURL
            ))
            Issue.record("expected process failure")
        } catch let error as DiarizationError {
            guard case let .processFailed(exitCode, standardError) = error else {
                Issue.record("expected processFailed, got \(error)")
                return
            }
            #expect(exitCode == 19)
            #expect(standardError == "diagnostic unavailable")
            #expect(!standardError.contains(secret))
            #expect(!standardError.contains(privateInput))
            #expect(!(error.errorDescription ?? "").contains(secret))
        }
    }

    @Test func community1DrainsLargeProcessOutputBeforeParsingJSON() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try fixtureURL("community1-valid.json")
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 30)
        let script = try writeExecutable(
            """
            #!/bin/sh
            dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\000' x
            cat '\(fixture.path)'
            """,
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: script,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        let timeline = try await backend.diarize(DiarizationRequest(
            audioURL: audioURL
        ))
        #expect(timeline.segments.count == 2)
    }

    @Test func processAndCoverageFailuresAreExplicit() async throws {
        let audioDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }
        let audio = audioDirectory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audio, durationS: 28.8898125)

        let noOutputDirectory = try temporaryDirectory()
        let noOutput = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable("#!/bin/sh\nexit 0\n", in: noOutputDirectory),
            hfHomeURL: noOutputDirectory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await noOutput.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected missing output")
        } catch let error as DiarizationError {
            #expect(error == .missingOutput)
        }

        let timeoutDirectory = try temporaryDirectory()
        let capturesBeforeTimeout = try processCaptureNames()
        let timeout = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n",
                in: timeoutDirectory
            ),
            hfHomeURL: timeoutDirectory,
            timeoutS: 0.05,
            validatesPinnedModel: false
        ))
        let timeoutStarted = Date()
        do {
            _ = try await timeout.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected timeout")
        } catch let error as DiarizationError {
            guard case .timedOut = error else {
                Issue.record("expected timedOut, got \(error)")
                return
            }
        }
        #expect(Date().timeIntervalSince(timeoutStarted) < 1)
        #expect(try processCaptureNames() == capturesBeforeTimeout)

        let outOfRangeDirectory = try temporaryDirectory()
        let outOfRangeJSON = try writeFile(
            "{ \"segments\": [{ \"speaker\": 0, \"start\": 0, \"end\": 30 }] }\n",
            named: "out-of-range.json",
            in: outOfRangeDirectory
        )
        let outOfRange = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable("#!/bin/sh\ncat '\(outOfRangeJSON.path)'\n", in: outOfRangeDirectory),
            hfHomeURL: outOfRangeDirectory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await outOfRange.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected out-of-range failure")
        } catch let error as DiarizationError {
            guard case let .rejectedOutput(reason, rawOutputPath) = error,
                  case .outputOutOfRange = reason
            else {
                Issue.record("expected a preserved outputOutOfRange rejection, got \(error)")
                return
            }
            #expect(try Data(contentsOf: URL(fileURLWithPath: rawOutputPath))
                == Data(contentsOf: outOfRangeJSON))
        }

        let truncatedDirectory = try temporaryDirectory()
        let truncatedJSON = try writeFile(
            """
            {
              "model": {
                "hf_id": "FluidInference/speaker-diarization-coreml",
                "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
                "quantization": "CoreML storage Float32 Float16"
              },
              "audio": { "duration_s": 10 },
              "segments": [{ "speaker": "S1", "start_s": 0, "end_s": 1 }]
            }

            """,
            named: "truncated.json",
            in: truncatedDirectory
        )
        let truncated = FluidAudioDiarizer(configuration: .init(
            executableURL: try writeFluidHarnessCopying(truncatedJSON, in: truncatedDirectory),
            modelsRootURL: truncatedDirectory,
            outputRootURL: truncatedDirectory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await truncated.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected truncated coverage")
        } catch let error as DiarizationError {
            guard case .truncatedCoverage = error else {
                Issue.record("expected truncatedCoverage, got \(error)")
                return
            }
        }

        let mismatchDirectory = try temporaryDirectory()
        let mismatchJSON = try writeFile(
            """
            {
              "model": {
                "hf_id": "FluidInference/speaker-diarization-coreml",
                "revision": "0000000000000000000000000000000000000000",
                "quantization": "CoreML storage Float32 Float16"
              },
              "audio": { "duration_s": 28.8898125 },
              "segments": [{ "speaker": "S1", "start_s": 0, "end_s": 1 }]
            }

            """,
            named: "mismatch.json",
            in: mismatchDirectory
        )
        let mismatch = FluidAudioDiarizer(configuration: .init(
            executableURL: try writeFluidHarnessCopying(mismatchJSON, in: mismatchDirectory),
            modelsRootURL: mismatchDirectory,
            outputRootURL: mismatchDirectory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await mismatch.diarize(DiarizationRequest(audioURL: audio))
            Issue.record("expected model mismatch")
        } catch let error as DiarizationError {
            guard case .modelMismatch = error else {
                Issue.record("expected modelMismatch, got \(error)")
                return
            }
        }
    }

    @Test func fluidAudioCanBeSelectedThroughDiarizerProtocolWithPinnedProvenance() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try fixtureURL("fluid-valid.json")
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)
        let script = try writeFluidHarnessCopying(fixture, in: directory)
        let backend: any DiarizerBackend = FluidAudioDiarizer(configuration: .init(
            executableURL: script,
            modelsRootURL: directory,
            outputRootURL: directory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        #expect(backend.model.hfModelID == "FluidInference/speaker-diarization-coreml")
        #expect(backend.model.revision.count == 40)
        #expect(backend.model.revision == "1ed7a662fdc7109e36d822db793ee6eebdaf8594")
        #expect(backend.model.quantization == "coreml-fp32+fp16")

        let timeline = try await backend.diarize(DiarizationRequest(
            audioURL: audioURL
        ))
        #expect(timeline.segments.map(\.speaker) == ["S2", "S1"])
        #expect(timeline.segments.allSatisfy { $0.endS > $0.startS })
    }

    @Test func fluidAudioRejectsUnsupportedSpeakerCountHint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 1)
        let backend = FluidAudioDiarizer(configuration: .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            modelsRootURL: directory,
            outputRootURL: directory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await backend.diarize(DiarizationRequest(
                audioURL: audioURL,
                speakerCountHint: 2...3
            ))
            Issue.record("expected unsupported speaker count hint")
        } catch let error as DiarizationError {
            #expect(error == .unsupportedSpeakerCountHint)
        }
    }

    @Test func community1NormalizesBoundedTerminalRoundingFromFixtureOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)
        let rawOutputURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 0.0, "end": 3.2, "duration": 3.2 },
                { "speaker": 1, "start": 3.7, "end": 28.972, "duration": 25.272 }
              ],
              "num_speakers": 2
            }

            """,
            named: "community1-rounded.json",
            in: directory
        )
        let script = try writeExecutable(
            "#!/bin/sh\ncat '\(rawOutputURL.path)'\n",
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: script,
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        let result = try await backend.diarizeWithEvidence(DiarizationRequest(
            audioURL: audioURL,
            speakerCountHint: 2...2
        ))
        let timeline = result.timeline
        let speakers = Set(timeline.segments.map(\.speaker))

        #expect(speakers.count == 2)
        #expect(timeline.segments.count > 0)
        #expect(timeline.segments == timeline.segments.sorted {
            if $0.startS != $1.startS { return $0.startS < $1.startS }
            if $0.endS != $1.endS { return $0.endS < $1.endS }
            return $0.speaker < $1.speaker
        })
        #expect(timeline.segments.allSatisfy { $0.startS >= 0 && $0.endS > $0.startS })
        #expect(result.rawJSON.starts(with: Data("{\n".utf8)))
        #expect(result.normalizationWarnings.count == 1)
        let warning = try #require(result.normalizationWarnings.first)
        #expect(warning.rawEndS == 28.972)
        #expect(warning.normalizedEndS == 28.8898125)
        #expect(abs(warning.deltaS - 0.0821875) < 0.000_001)
        let rawObject = try #require(JSONSerialization.jsonObject(with: result.rawJSON) as? [String: Any])
        let rawSegments = try #require(rawObject["segments"] as? [[String: Any]])
        let rawLast = try #require(rawSegments.last)
        #expect(rawLast["end"] as? Double == warning.rawEndS)
    }

    @Test func community1KeepsOverlappingTurnsFromSeparateSpeakers() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)
        // Two speakers talking over each other: every turn starts after the one
        // before it, and each one ends after the next has already begun.
        let rawOutputURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 0.031, "end": 6.4, "duration": 6.369 },
                { "speaker": 1, "start": 5.2, "end": 9.8, "duration": 4.6 },
                { "speaker": 0, "start": 9.1, "end": 12.75, "duration": 3.65 }
              ],
              "num_speakers": 2
            }

            """,
            named: "community1-overlapping.json",
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ncat '\(rawOutputURL.path)'\n",
                in: directory
            ),
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))

        let timeline = try await backend.diarize(DiarizationRequest(audioURL: audioURL))

        #expect(timeline.segments.map(\.speaker) == ["0", "1", "0"])
        #expect(timeline.segments.map(\.startS) == [0.031, 5.2, 9.1])
        #expect(timeline.segments.map(\.endS) == [6.4, 9.8, 12.75])
    }

    @Test func community1OrdersSimultaneousOnsetsIntoContractOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)

        // The 2026-09-01 offset-600 timeline, first two turns verbatim: a clip
        // cut into the middle of a conversation begins with both speakers
        // already talking, so Community-1 starts both in the first frame at the
        // same timestamp and breaks the tie by speaker id. The run artifact
        // wants the earlier end point first, which is the writer's tie-break to
        // apply, not something the backend can deliver.
        let rawOutputURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 0.031, "end": 2.039, "duration": 2.008 },
                { "speaker": 1, "start": 0.031, "end": 2.005, "duration": 1.974 },
                { "speaker": 1, "start": 2.039, "end": 2.883, "duration": 0.844 }
              ],
              "num_speakers": 2
            }

            """,
            named: "community1-simultaneous-onset.json",
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ncat '\(rawOutputURL.path)'\n",
                in: directory
            ),
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))

        let result = try await backend.diarizeWithEvidence(
            DiarizationRequest(audioURL: audioURL)
        )

        // Both turns survive with their own speaker and their own timestamps.
        #expect(result.timeline.segments == [
            TimelineSegment(speaker: "1", startS: 0.031, endS: 2.005),
            TimelineSegment(speaker: "0", startS: 0.031, endS: 2.039),
            TimelineSegment(speaker: "1", startS: 2.039, endS: 2.883),
        ])
        // The move is stated rather than applied quietly, and the emitted order
        // stays byte-exact in the raw evidence.
        #expect(result.orderNormalizations == [
            DiarizationOrderNormalization(
                emittedIndex: 1,
                normalizedIndex: 0,
                speaker: "1",
                startS: 0.031,
                endS: 2.005
            ),
            DiarizationOrderNormalization(
                emittedIndex: 0,
                normalizedIndex: 1,
                speaker: "0",
                startS: 0.031,
                endS: 2.039
            ),
        ])
        #expect(result.rawJSON == (try Data(contentsOf: rawOutputURL)))
    }

    @Test func community1OrdersASimultaneousOnsetAwayFromTheClipEdge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)

        // The offset-300 timeline failed at index 257, not at the clip edge: a
        // speaker resolved only within that clip contributed a single-frame turn
        // starting on the same frame as a real one. The tie-break must be a
        // property of the tie, not of the first pair.
        let rawOutputURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 0.031, "end": 3.4, "duration": 3.369 },
                { "speaker": 1, "start": 4.2, "end": 5.399, "duration": 1.199 },
                { "speaker": 2, "start": 4.2, "end": 4.217, "duration": 0.017 },
                { "speaker": 0, "start": 6.1, "end": 7.4, "duration": 1.3 }
              ],
              "num_speakers": 3
            }

            """,
            named: "community1-mid-timeline-onset.json",
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ncat '\(rawOutputURL.path)'\n",
                in: directory
            ),
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))

        let result = try await backend.diarizeWithEvidence(
            DiarizationRequest(audioURL: audioURL)
        )

        #expect(result.timeline.segments.map(\.speaker) == ["0", "2", "1", "0"])
        #expect(result.timeline.segments.map(\.startS) == [0.031, 4.2, 4.2, 6.1])
        #expect(result.timeline.segments.map(\.endS) == [3.4, 4.217, 5.399, 7.4])
        // Only the tied pair moves; turns with different starts keep their
        // emitted position.
        #expect(result.orderNormalizations.map(\.emittedIndex) == [2, 1])
        #expect(result.orderNormalizations.map(\.normalizedIndex) == [1, 2])
    }

    @Test func community1RejectsTimeThatRunsBackwardsAndOneSpeakerStartingTwice() async throws {
        let audioDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: audioDirectory) }
        let audioURL = audioDirectory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)

        let unorderedDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: unorderedDirectory) }
        let unorderedURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 3.2, "end": 5.475, "duration": 2.275 },
                { "speaker": 1, "start": 1.4, "end": 2.9, "duration": 1.5 }
              ],
              "num_speakers": 2
            }

            """,
            named: "community1-unordered.json",
            in: unorderedDirectory
        )
        let unordered = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ncat '\(unorderedURL.path)'\n",
                in: unorderedDirectory
            ),
            hfHomeURL: unorderedDirectory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await unordered.diarize(DiarizationRequest(audioURL: audioURL))
            Issue.record("expected an unordered timeline rejection")
        } catch let error as DiarizationError {
            guard case let .rejectedOutput(reason, rawOutputPath) = error else {
                Issue.record("expected a preserved rejection, got \(error)")
                return
            }
            // Time running backwards is a real ordering defect and stays fatal.
            #expect(reason == .outputUnordered(
                segment: 1,
                startS: 1.4,
                previousStartS: 3.2
            ))
            #expect(try Data(contentsOf: URL(fileURLWithPath: rawOutputPath))
                == Data(contentsOf: unorderedURL))
        }

        let duplicateDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: duplicateDirectory) }
        let duplicateURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 1.4, "end": 5.475, "duration": 4.075 },
                { "speaker": 0, "start": 1.4, "end": 2.9, "duration": 1.5 }
              ],
              "num_speakers": 1
            }

            """,
            named: "community1-duplicate-onset.json",
            in: duplicateDirectory
        )
        let duplicate = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ncat '\(duplicateURL.path)'\n",
                in: duplicateDirectory
            ),
            hfHomeURL: duplicateDirectory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await duplicate.diarize(DiarizationRequest(audioURL: audioURL))
            Issue.record("expected a duplicate onset rejection")
        } catch let error as DiarizationError {
            guard case let .rejectedOutput(reason, _) = error else {
                Issue.record("expected a preserved rejection, got \(error)")
                return
            }
            // One speaker cannot open two turns on one frame, so no ordering of
            // the pair is correct and there is nothing to tie-break.
            #expect(reason == .duplicateOnset(segment: 1, speaker: "0", startS: 1.4))
        }
    }

    @Test func oneSpeakerStartingTwiceIsRejectedWhenAnotherTurnSitsBetween() async throws {
        // `contractOrdered` sorts a tied onset group by end point, so these
        // three turns come out as A(2.9), B(4.1), A(5.475): the two `A` turns
        // are never adjacent, in the emitted order or the canonical one, and
        // an adjacent-pair test sees nothing. The duplicate still changes
        // overlap totals and attribution downstream, so it is still fatal.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)

        let outputURL = try writeFile(
            """
            {
              "segments": [
                { "speaker": 0, "start": 1.4, "end": 5.475, "duration": 4.075 },
                { "speaker": 1, "start": 1.4, "end": 4.1, "duration": 2.7 },
                { "speaker": 0, "start": 1.4, "end": 2.9, "duration": 1.5 }
              ],
              "num_speakers": 2
            }

            """,
            named: "community1-nonadjacent-duplicate-onset.json",
            in: directory
        )
        let backend = Community1Diarizer(configuration: .init(
            executableURL: try writeExecutable(
                "#!/bin/sh\ncat '\(outputURL.path)'\n",
                in: directory
            ),
            hfHomeURL: directory,
            timeoutS: 5,
            validatesPinnedModel: false
        ))

        do {
            _ = try await backend.diarize(DiarizationRequest(audioURL: audioURL))
            Issue.record("expected a duplicate onset rejection")
        } catch let error as DiarizationError {
            guard case let .rejectedOutput(reason, _) = error else {
                Issue.record("expected a preserved rejection, got \(error)")
                return
            }
            // The rejection names the emitted index, not the canonical one.
            #expect(reason == .duplicateOnset(segment: 2, speaker: "0", startS: 1.4))
        }
    }

    @Test func fluidAudioRejectionNamesTheHarnessOutputItRejected() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audioURL = directory.appendingPathComponent("synthetic.wav")
        try writeSilentWAV(to: audioURL, durationS: 28.8898125)
        let rawOutputURL = try writeFile(
            """
            {
              "model": {
                "hf_id": "FluidInference/speaker-diarization-coreml",
                "revision": "1ed7a662fdc7109e36d822db793ee6eebdaf8594",
                "quantization": "CoreML storage Float32 Float16"
              },
              "audio": { "duration_s": 28.8898125 },
              "segments": [
                { "speaker": "S1", "start_s": 1.4, "end_s": 5.4, "quality_score": 1.0 },
                { "speaker": "S1", "start_s": 1.4, "end_s": 2.9, "quality_score": 0.9 }
              ]
            }

            """,
            named: "fluid-duplicate-onset.json",
            in: directory
        )
        let outputRootURL = directory.appendingPathComponent("outputs", isDirectory: true)
        let backend = FluidAudioDiarizer(configuration: .init(
            executableURL: try writeFluidHarnessCopying(rawOutputURL, in: directory),
            modelsRootURL: directory,
            outputRootURL: outputRootURL,
            timeoutS: 5,
            validatesPinnedModel: false
        ))

        do {
            _ = try await backend.diarize(DiarizationRequest(audioURL: audioURL))
            Issue.record("expected a duplicate onset rejection")
        } catch let error as DiarizationError {
            guard case let .rejectedOutput(reason, rawOutputPath) = error else {
                Issue.record("expected a preserved rejection, got \(error)")
                return
            }
            #expect(reason == .duplicateOnset(segment: 1, speaker: "S1", startS: 1.4))
            #expect(rawOutputPath.hasPrefix(outputRootURL.path))
            #expect(try Data(contentsOf: URL(fileURLWithPath: rawOutputPath))
                == Data(contentsOf: rawOutputURL))
        }
    }

    private var community1RuntimeRelativePaths: [String] {
        [
            "config.json",
            "embedding.mlmodelc/analytics/coremldata.bin",
            "embedding.mlmodelc/coremldata.bin",
            "embedding.mlmodelc/model.mil",
            "embedding.mlmodelc/weights/weight.bin",
            "plda.safetensors",
            "segmentation.mlmodelc/analytics/coremldata.bin",
            "segmentation.mlmodelc/coremldata.bin",
            "segmentation.mlmodelc/model.mil",
            "segmentation.mlmodelc/weights/weight.bin",
        ]
    }

    private func writeRuntimePayload(
        at root: URL,
        relativePaths: [String]
    ) throws -> RuntimePayloadPin {
        var files: [RuntimePayloadFile] = []
        var treeHasher = SHA256()
        for (index, relativePath) in relativePaths.enumerated() {
            let file = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data("fixture-payload-\(index)".utf8)
            try data.write(to: file)
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            files.append(RuntimePayloadFile(
                relativePath: relativePath,
                sha256: digest
            ))

            let name = Data(relativePath.utf8)
            var nameLength = UInt32(name.count).bigEndian
            withUnsafeBytes(of: &nameLength) {
                treeHasher.update(data: Data($0))
            }
            treeHasher.update(data: name)
            treeHasher.update(data: data)
        }
        let treeSHA256 = treeHasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        return RuntimePayloadPin(files: files, treeSHA256: treeSHA256)
    }
}

private func writeFluidHarnessCopying(_ fixture: URL, in directory: URL) throws -> URL {
    let executable = directory.appendingPathComponent("fluid-fixture-command.sh")
    let contents = """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '--output' ]; then
        cp '\(fixture.path)' "$2"
        exit 0
      fi
      shift
    done
    exit 64
    """
    try Data(contents.utf8).write(to: executable, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}

private func writeSilentWAV(to url: URL, durationS: Double) throws {
    let sampleRate = 16_000.0
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ), let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(sampleRate * durationS)
    ) else {
        throw FixtureError.couldNotCreateAudio
    }
    buffer.frameLength = buffer.frameCapacity
    if let samples = buffer.floatChannelData?[0] {
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
    }
    let output = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try output.write(from: buffer)
}

private enum FixtureError: Error {
    case missing(String)
    case couldNotCreateAudio
}
