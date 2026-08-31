import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import MaccheroniDiarize
import MaccheroniCore

@Suite(.serialized) struct MaccheroniDiarizeTests {
    private func repositoryURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

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
        let fixture = try fixtureURL("community1-valid.json")
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
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")
        ))
        #expect(timeline.segments.count == 2)
    }

    @Test func processAndCoverageFailuresAreExplicit() async throws {
        let audio = repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")

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
            guard case .outputOutOfRange = error else {
                Issue.record("expected outputOutOfRange, got \(error)")
                return
            }
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
        let fixture = try fixtureURL("fluid-valid.json")
        let script = try writeFluidHarnessCopying(fixture, in: directory)
        let backend: any DiarizerBackend = FluidAudioDiarizer(configuration: .init(
            executableURL: script,
            modelsRootURL: FluidAudioDiarizerConfiguration.defaultModelsRootURL,
            outputRootURL: directory.appendingPathComponent("outputs", isDirectory: true),
            timeoutS: 5,
            validatesPinnedModel: true
        ))
        #expect(backend.model.hfModelID == "FluidInference/speaker-diarization-coreml")
        #expect(backend.model.revision.count == 40)
        #expect(backend.model.revision == "1ed7a662fdc7109e36d822db793ee6eebdaf8594")
        #expect(backend.model.quantization == "coreml-fp32+fp16")

        let timeline = try await backend.diarize(DiarizationRequest(
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav")
        ))
        #expect(timeline.segments.map(\.speaker) == ["S2", "S1"])
        #expect(timeline.segments.allSatisfy { $0.endS > $0.startS })
    }

    @Test func fluidAudioRejectsUnsupportedSpeakerCountHint() async throws {
        let backend = FluidAudioDiarizer(configuration: .init(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            modelsRootURL: try temporaryDirectory(),
            outputRootURL: try temporaryDirectory(),
            timeoutS: 5,
            validatesPinnedModel: false
        ))
        do {
            _ = try await backend.diarize(DiarizationRequest(
                audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav"),
                speakerCountHint: 2...3
            ))
            Issue.record("expected unsupported speaker count hint")
        } catch let error as DiarizationError {
            #expect(error == .unsupportedSpeakerCountHint)
        }
    }

    @Test func community1RunsPinnedTwoSpeakerFixture() async throws {
        let backend = Community1Diarizer()
        let result = try await backend.diarizeWithEvidence(DiarizationRequest(
            audioURL: repositoryURL("benchmarks/runs/diarization/fixtures/it-dialogue/input.wav"),
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
