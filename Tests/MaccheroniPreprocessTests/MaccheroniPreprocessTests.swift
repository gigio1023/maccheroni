import AVFoundation
import CryptoKit
import Foundation
import Testing
import MaccheroniCore
@testable import MaccheroniPreprocess

@Suite(.serialized) struct MaccheroniPreprocessTests {
    @Test func supportedInputContractMatchesDetectedPreprocessorContainers() throws {
        #expect(AudioPreprocessor.supportedInputExtensions == ["m4a", "mp3", "wav"])
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let canonicalWAVURL = directory.appendingPathComponent("recording.wav")
        let wavURL = directory.appendingPathComponent("recording.Wav")
        try writeSineWAV(to: canonicalWAVURL, amplitude: 0.2)
        try Data(contentsOf: canonicalWAVURL).write(to: wavURL)
        let mp3URL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic-tone.mp3")
        let cafURL = directory.appendingPathComponent("source.caf")
        let disguisedCAFURL = directory.appendingPathComponent("disguised.wav")
        try writeSineWAV(to: cafURL, amplitude: 0.2)
        try Data(contentsOf: cafURL).write(to: disguisedCAFURL)

        #expect(AudioPreprocessor.supportsInputFile(wavURL))
        #expect(AudioPreprocessor.supportsInputFile(mp3URL))
        #expect(!AudioPreprocessor.supportsInputFile(disguisedCAFURL))
        for name in ["recording", "recording.aiff", "recording.CAF", "missing.wav"] {
            #expect(!AudioPreprocessor.supportsInputFile(
                directory.appendingPathComponent(name)
            ))
        }
        #expect(!AudioPreprocessor.supportsInputFile(
            URL(string: "https://example.test/recording.wav")!
        ))
        #expect(throws: PreprocessError.unsupportedInputType("wav")) {
            try AudioPreprocessor().preprocess(
                inputURL: disguisedCAFURL,
                outputDirectory: directory.appendingPathComponent("unused")
            )
        }
    }

    @Test func convertsAndNormalizesWAVWithoutChangingSourceBytes() throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let sourceHash = try AudioPreprocessor.sha256(of: sourceURL)

        let result = try AudioPreprocessor().preprocess(
            inputURL: sourceURL,
            outputDirectory: directory.appendingPathComponent("artifacts")
        )

        #expect(try AudioPreprocessor.sha256(of: sourceURL) == sourceHash)
        #expect(result.inputSHA256 == sourceHash)
        #expect(FileManager.default.fileExists(atPath: result.artifactURL.path))
        #expect(result.artifactURL.pathExtension == "wav")
        #expect(result.sampleRateHz == 16_000)
        #expect(result.channels == 1)
        #expect(result.peak > 0.94 && result.peak <= 0.951)
        #expect(result.normalizationGain > 1)

        let output = try AVAudioFile(forReading: result.artifactURL)
        #expect(output.processingFormat.sampleRate == 16_000)
        #expect(output.processingFormat.channelCount == 1)
    }

    @Test func readsCompressedM4AAndCreatesPCMWAV() throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wavURL = directory.appendingPathComponent("fixture.wav")
        let m4aURL = directory.appendingPathComponent("fixture.m4a")
        try writeSineWAV(to: wavURL, amplitude: 0.3)
        try convertToM4A(input: wavURL, output: m4aURL)
        let sourceHash = try AudioPreprocessor.sha256(of: m4aURL)

        let result = try AudioPreprocessor().preprocess(
            inputURL: m4aURL,
            outputDirectory: directory.appendingPathComponent("artifacts")
        )

        #expect(try AudioPreprocessor.sha256(of: m4aURL) == sourceHash)
        #expect(result.artifactURL.pathExtension == "wav")
        #expect(result.durationS > 0.9)
        #expect(try AVAudioFile(forReading: result.artifactURL).processingFormat.sampleRate == 16_000)
    }

    @Test func readsBundledSyntheticMP3AndCreates16kHzMonoWAV() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/synthetic-tone.mp3")
        #expect(FileManager.default.fileExists(atPath: fixtureURL.path))

        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceHash = try AudioPreprocessor.sha256(of: fixtureURL)

        let result = try AudioPreprocessor().preprocess(
            inputURL: fixtureURL,
            outputDirectory: directory.appendingPathComponent("artifacts")
        )

        #expect(try AudioPreprocessor.sha256(of: fixtureURL) == sourceHash)
        #expect(result.inputSHA256 == sourceHash)
        #expect(result.artifactURL.pathExtension == "wav")
        #expect(result.sampleRateHz == 16_000)
        #expect(result.channels == 1)

        let output = try AVAudioFile(forReading: result.artifactURL)
        #expect(output.processingFormat.sampleRate == 16_000)
        #expect(output.processingFormat.channelCount == 1)
    }

    @Test func speechSileroAdapterFailsExplicitlyWhenPinnedRuntimeOrModelIsMissing() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("missing-speech")
        let modelURL = directory.appendingPathComponent("silero_vad.mlmodelc")
        let revisionURL = directory.appendingPathComponent("refs/main")
        let adapter = SpeechSileroVADAdapter(
            executableURL: executableURL,
            modelCacheURL: modelURL,
            revisionMarkerURL: revisionURL
        )

        await #expect(throws: VoiceActivityError.speechSileroUnavailable(
            executableURL: executableURL,
            modelCacheURL: modelURL
        )) {
            try await adapter.detect(audioURL: directory.appendingPathComponent("synthetic.wav"))
        }
    }

    @Test func speechSileroStandaloneDefaultsRemainPinnedToTheLegacyLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let adapter = SpeechSileroVADAdapter()

        #expect(adapter.executableURL.path == "/opt/homebrew/bin/speech")
        #expect(adapter.modelCacheURL == home
            .appendingPathComponent("Library/Caches/qwen3-speech/models/aufklarer")
            .appendingPathComponent("Silero-VAD-v6.2.1-CoreML/silero_vad.mlmodelc"))
        #expect(adapter.revisionMarkerURL == home
            .appendingPathComponent(".cache/huggingface/hub/models--aufklarer--Silero-VAD-v6.2.1-CoreML")
            .appendingPathComponent("refs/main"))
        #expect(adapter.harnessModelRepositoryURL == nil)
        #expect(adapter.runtime == BackendDescriptor(name: "speech", version: "0.0.23"))
        #expect(adapter.timeoutS == 300)
        #expect(adapter.provenance.model == ModelDescriptor(
            role: .vad,
            hfModelID: "aufklarer/Silero-VAD-v6.2.1-CoreML",
            revision: "523876545a57961474fee9df913e833e130560b8",
            quantization: "coreml-float16"
        ))
    }

    @Test func speechSileroAdapterUsesInjectedOfflineHarnessAndExactRepositoryRoot() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("synthetic.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let executableURL = directory.appendingPathComponent("speech")
        let argumentsURL = directory.appendingPathComponent("arguments.txt")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        printf '[\\n]\\n'
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let repositoryURL = directory.appendingPathComponent("Silero-VAD-v6.2.1-CoreML", isDirectory: true)
        let modelURL = repositoryURL.appendingPathComponent("silero_vad.mlmodelc", isDirectory: true)
        let runtimePayload = try writeRuntimePayload(
            at: repositoryURL,
            relativePaths: sileroRuntimeRelativePaths
        )
        let revisionURL = directory.appendingPathComponent(
            "cache/models/huggingface/hub/models--aufklarer--Silero-VAD-v6.2.1-CoreML/refs/main"
        )
        try FileManager.default.createDirectory(
            at: revisionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("523876545a57961474fee9df913e833e130560b8\n".utf8)
            .write(to: revisionURL)
        let configuredAdapter = SpeechSileroVADAdapter(
            executableURL: executableURL,
            modelCacheURL: modelURL,
            revisionMarkerURL: revisionURL,
            harnessModelRepositoryURL: repositoryURL
        )
        let adapter = SpeechSileroVADAdapter(
            testing: configuredAdapter,
            harnessRuntimePayload: runtimePayload
        )

        let map = try await adapter.detect(audioURL: sourceURL)

        #expect(map.regions.count == 1)
        #expect(map.regions[0].kind == .silence)
        #expect(adapter.runtime == BackendDescriptor(name: "speech", version: "0.0.23"))
        #expect(adapter.timeoutS == 300)
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(arguments == [
            "vad-stream",
            sourceURL.path,
            "--cache-dir",
            repositoryURL.path,
            "--json",
        ])
    }

    @Test func speechSileroHarnessRejectsSameSizePayloadCorruptionBeforeLaunch() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executableURL = directory.appendingPathComponent("speech")
        let launchMarkerURL = directory.appendingPathComponent("launched")
        let script = "#!/bin/sh\nprintf launched > '\(launchMarkerURL.path)'\nprintf '[\\n]\\n'\n"
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let repositoryURL = directory.appendingPathComponent("Silero-VAD-v6.2.1-CoreML", isDirectory: true)
        let modelURL = repositoryURL.appendingPathComponent("silero_vad.mlmodelc", isDirectory: true)
        let runtimePayload = try writeRuntimePayload(
            at: repositoryURL,
            relativePaths: sileroRuntimeRelativePaths
        )
        let revisionURL = directory.appendingPathComponent("refs/main")
        try FileManager.default.createDirectory(
            at: revisionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("523876545a57961474fee9df913e833e130560b8\n".utf8)
            .write(to: revisionURL)

        let corruptedURL = repositoryURL.appendingPathComponent(
            "silero_vad.mlmodelc/weights/weight.bin"
        )
        var corrupted = try Data(contentsOf: corruptedURL)
        let originalSize = corrupted.count
        corrupted[corrupted.startIndex] ^= 0x01
        try corrupted.write(to: corruptedURL)
        #expect(try Data(contentsOf: corruptedURL).count == originalSize)

        let configuredAdapter = SpeechSileroVADAdapter(
            executableURL: executableURL,
            modelCacheURL: modelURL,
            revisionMarkerURL: revisionURL,
            harnessModelRepositoryURL: repositoryURL
        )
        let adapter = SpeechSileroVADAdapter(
            testing: configuredAdapter,
            harnessRuntimePayload: runtimePayload
        )

        await #expect(throws: VoiceActivityError.speechSileroUnavailable(
            executableURL: executableURL,
            modelCacheURL: modelURL
        )) {
            try await adapter.detect(
                audioURL: directory.appendingPathComponent("synthetic.wav")
            )
        }
        #expect(!FileManager.default.fileExists(atPath: launchMarkerURL.path))
    }

    @Test func speechSileroAdapterDoesNotPromoteArbitraryStandardError() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("private-input.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let secret = "Bearer synthetic-secret sensitive-transcript-payload \(sourceURL.path)"
        let adapter = try fixtureAdapter(
            in: directory,
            script: "#!/bin/sh\nprintf '%s' '\(secret)' >&2\nexit 19\n",
            timeoutS: 5
        )

        do {
            _ = try await adapter.detect(audioURL: sourceURL)
            Issue.record("expected process failure")
        } catch let error as VoiceActivityError {
            guard case let .executionFailed(exitCode, message) = error else {
                Issue.record("expected executionFailed, got \(error)")
                return
            }
            #expect(exitCode == 19)
            #expect(message == "diagnostic unavailable")
            #expect(!message.contains(secret))
            #expect(!message.contains(sourceURL.path))
        }
    }

    @Test func stockSpeechSileroAdapterForcesHuggingFaceOfflineMode() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("synthetic.wav")
        let environmentURL = directory.appendingPathComponent("environment.txt")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let adapter = try fixtureAdapter(
            in: directory,
            script: "#!/bin/sh\nprintf '%s' \"$HF_HUB_OFFLINE\" > '\(environmentURL.path)'\nprintf '[\\n]\\n'\n",
            timeoutS: 5
        )

        _ = try await adapter.detect(audioURL: sourceURL)

        #expect(try String(contentsOf: environmentURL, encoding: .utf8) == "1")
    }

    @Test func speechSileroAdapterRunsOnSyntheticWAVAndReturnsCompleteMap() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("synthetic.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)

        let adapter = SpeechSileroVADAdapter()
        let map = try await adapter.detect(audioURL: sourceURL)

        #expect(adapter.provenance.model.hfModelID == "aufklarer/Silero-VAD-v6.2.1-CoreML")
        #expect(adapter.provenance.model.revision == "523876545a57961474fee9df913e833e130560b8")
        #expect(adapter.provenance.model.quantization == "coreml-float16")
        #expect(adapter.runtime == BackendDescriptor(name: "speech", version: "0.0.23"))
        #expect(map.durationS > 0.99 && map.durationS < 1.01)
        #expect(!map.regions.isEmpty)
        #expect(abs(map.regions.first!.startS) < 0.000_001)
        #expect(abs(map.regions.last!.endS - map.durationS) < 0.000_001)
        #expect(zip(map.regions, map.regions.dropFirst()).allSatisfy {
            abs($0.endS - $1.startS) < 0.000_001
        })
    }

    @Test func speechSileroAdapterCapturesLargeOutputWithoutPipeDeadlock() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("synthetic.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let adapter = try fixtureAdapter(
            in: directory,
            script: "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c 300000\nprintf '\\n[\\n]\\n'\n",
            timeoutS: 10
        )

        let map = try await adapter.detect(audioURL: sourceURL)

        #expect(map.regions.count == 1)
        #expect(map.regions[0].kind == .silence)
        #expect(abs(map.regions[0].startS) < 0.000_001)
        #expect(abs(map.regions[0].endS - map.durationS) < 0.000_001)
    }

    @Test func speechSileroAdapterTerminatesTimedOutProcess() async throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("synthetic.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let adapter = try fixtureAdapter(
            in: directory,
            script: "#!/bin/sh\nsleep 5\nprintf '[]\\n'\n",
            timeoutS: 0.05
        )

        await #expect(throws: VoiceActivityError.timedOut(timeoutS: 0.05)) {
            try await adapter.detect(audioURL: sourceURL)
        }
    }

    @Test func injectedFixtureMapChoosesSilenceAndFallbackDeterministically() throws {
        let map = try VoiceActivityMap(durationS: 2_650, regions: [
            VoiceActivityRegion(startS: 0, endS: 890, kind: .speech),
            VoiceActivityRegion(startS: 890, endS: 920, kind: .silence),
            VoiceActivityRegion(startS: 920, endS: 2_650, kind: .speech),
        ])
        let planner = SilenceAwareChunkPlanner()
        let silenceChunks = try planner.propose(activityMap: map)
        #expect(silenceChunks.count == 3)
        #expect(silenceChunks[0].endS == 900)
        #expect(silenceChunks[0].boundarySource == .silence)
        #expect(silenceChunks[1].boundarySource == .deterministicFallback)
        #expect(silenceChunks.map(\.index) == [0, 1, 2])

        let noSilence = try VoiceActivityMap(durationS: 2_650, regions: [
            VoiceActivityRegion(startS: 0, endS: 2_650, kind: .speech),
        ])
        let first = try planner.propose(activityMap: noSilence)
        let second = try planner.propose(activityMap: noSilence)
        #expect(first == second)
        #expect(first.map(\.endS) == [900, 1_800, 2_650])
        #expect(first.dropLast().allSatisfy { $0.boundarySource == .deterministicFallback })
    }

    @Test func inferenceLeavesCoverTheObservedNineteenMinuteDurationExactly() throws {
        let configuration = mossLeafConfiguration()
        let totalSamples = InferenceLeafPlanner.sampleIndex(
            seconds: 1_148.670_666_7,
            sampleRateHz: configuration.sampleRateHz
        )
        let map = try fullSpeechMap(totalSamples: totalSamples, sampleRateHz: configuration.sampleRateHz)

        let leaves = try InferenceLeafPlanner().proposeInitialLeaves(
            totalSamples: totalSamples,
            activityMap: map,
            configuration: configuration
        )

        let minimum = samples(seconds: 120, configuration: configuration)
        let maximum = samples(seconds: 300, configuration: configuration)
        #expect(leaves.count == 5)
        #expect(leaves.allSatisfy { $0.sampleCount >= minimum && $0.sampleCount <= maximum })
        #expect(leaves.allSatisfy { $0.depth == 0 })
        assertExactCoverage(leaves, totalSamples: totalSamples)
    }

    @Test func inferenceLeafBoundaryTestsAvoidAShortTailAndUseExactSamples() throws {
        let configuration = mossLeafConfiguration()
        let planner = InferenceLeafPlanner()
        let maximum = samples(seconds: 300, configuration: configuration)
        let minimum = samples(seconds: 120, configuration: configuration)

        let exactlyMaximum = try planner.proposeInitialLeaves(
            totalSamples: maximum,
            activityMap: try fullSpeechMap(totalSamples: maximum, sampleRateHz: configuration.sampleRateHz),
            configuration: configuration
        )
        #expect(exactlyMaximum.count == 1)
        #expect(exactlyMaximum[0].sampleCount == maximum)
        assertExactCoverage(exactlyMaximum, totalSamples: maximum)

        let oneSampleOver = maximum + 1
        let overMaximumLeaves = try planner.proposeInitialLeaves(
            totalSamples: oneSampleOver,
            activityMap: try fullSpeechMap(totalSamples: oneSampleOver, sampleRateHz: configuration.sampleRateHz),
            configuration: configuration
        )
        #expect(overMaximumLeaves.count == 2)
        #expect(overMaximumLeaves.allSatisfy { $0.sampleCount >= minimum && $0.sampleCount <= maximum })
        assertExactCoverage(overMaximumLeaves, totalSamples: oneSampleOver)

        let shortTailCandidate = samples(seconds: 421, configuration: configuration)
        let shortTailLeaves = try planner.proposeInitialLeaves(
            totalSamples: shortTailCandidate,
            activityMap: try fullSpeechMap(totalSamples: shortTailCandidate, sampleRateHz: configuration.sampleRateHz),
            configuration: configuration
        )
        #expect(shortTailLeaves.allSatisfy { $0.sampleCount >= minimum })
        assertExactCoverage(shortTailLeaves, totalSamples: shortTailCandidate)
    }

    @Test func inferenceLeavesPreferNearestSilenceAndFallbackWithoutSilence() throws {
        let configuration = mossLeafConfiguration()
        let sampleRate = configuration.sampleRateHz
        let totalSamples = samples(seconds: 540, configuration: configuration)
        let map = try VoiceActivityMap(durationS: Double(totalSamples) / Double(sampleRate), regions: [
            VoiceActivityRegion(startS: 0, endS: 230, kind: .speech),
            VoiceActivityRegion(startS: 230, endS: 231, kind: .silence),
            VoiceActivityRegion(startS: 231, endS: 245, kind: .speech),
            VoiceActivityRegion(startS: 245, endS: 246, kind: .silence),
            VoiceActivityRegion(startS: 246, endS: Double(totalSamples) / Double(sampleRate), kind: .speech),
        ])

        let silenceLeaves = try InferenceLeafPlanner().proposeInitialLeaves(
            totalSamples: totalSamples,
            activityMap: map,
            configuration: configuration
        )
        #expect(silenceLeaves[0].endSample == samples(seconds: 245, configuration: configuration))
        #expect(silenceLeaves[0].boundarySource == .silence)

        let noSilenceMap = try fullSpeechMap(totalSamples: totalSamples, sampleRateHz: sampleRate)
        let first = try InferenceLeafPlanner().proposeInitialLeaves(
            totalSamples: totalSamples,
            activityMap: noSilenceMap,
            configuration: configuration
        )
        let second = try InferenceLeafPlanner().proposeInitialLeaves(
            totalSamples: totalSamples,
            activityMap: noSilenceMap,
            configuration: configuration
        )
        #expect(first == second)
        #expect(first[0].endSample == samples(seconds: 240, configuration: configuration))
        #expect(first[0].boundarySource == .deterministicFallback)
        assertExactCoverage(first, totalSamples: totalSamples)
    }

    @Test func limitRecoveryUsesMidpointSilenceAndStopsAtDepthAndMinimum() throws {
        let configuration = mossLeafConfiguration()
        let sampleRate = configuration.sampleRateHz
        let parentSamples = samples(seconds: 240, configuration: configuration)
        let map = try VoiceActivityMap(durationS: 240, regions: [
            VoiceActivityRegion(startS: 0, endS: 119, kind: .speech),
            VoiceActivityRegion(startS: 119, endS: 121, kind: .silence),
            VoiceActivityRegion(startS: 121, endS: 240, kind: .speech),
        ])
        let planner = InferenceLeafPlanner()
        let children = try planner.splitForLimitRecovery(
            leaf: InferenceLeaf(
                startSample: 0,
                endSample: parentSamples,
                depth: 2,
                boundarySource: .inputEnd
            ),
            activityMap: map,
            configuration: configuration
        )
        #expect(children.map(\.depth) == [3, 3])
        #expect(children[0].endSample == samples(seconds: 120, configuration: configuration))
        #expect(children[0].boundarySource == .silence)
        assertExactCoverage(children, totalSamples: parentSamples)

        #expect(throws: InferenceLeafPlanningError.recoveryDepthExhausted(depth: 3, maximumDepth: 3)) {
            _ = try planner.splitForLimitRecovery(
                leaf: children[0],
                activityMap: map,
                configuration: configuration
            )
        }

        let minimumRecovery = samples(seconds: 30, configuration: configuration)
        #expect(throws: InferenceLeafPlanningError.recoveryLeafTooShort(
            sampleCount: minimumRecovery,
            minimumChildSamples: minimumRecovery
        )) {
            _ = try planner.splitForLimitRecovery(
                leaf: InferenceLeaf(
                    startSample: 0,
                    endSample: minimumRecovery,
                    depth: 0,
                    boundarySource: .inputEnd
                ),
                activityMap: try fullSpeechMap(
                    totalSamples: minimumRecovery,
                    sampleRateHz: sampleRate
                ),
                configuration: configuration
            )
        }

        let twoMinimumChildren = minimumRecovery * 2
        let fallbackChildren = try planner.splitForLimitRecovery(
            leaf: InferenceLeaf(
                startSample: 0,
                endSample: twoMinimumChildren,
                depth: 0,
                boundarySource: .inputEnd
            ),
            activityMap: try fullSpeechMap(totalSamples: twoMinimumChildren, sampleRateHz: sampleRate),
            configuration: configuration
        )
        #expect(fallbackChildren.map(\.sampleCount) == [minimumRecovery, minimumRecovery])
        #expect(fallbackChildren[0].boundarySource == .deterministicFallback)
    }

    @Test func enhancementDefaultsOffAndCarriesManifestState() {
        let defaults = PreprocessingSettings.default
        let manifest = defaults.manifestConfiguration()
        #expect(!defaults.enhancement.enabled)
        #expect(manifest.enhancement.enabled == false)
        #expect(manifest.enhancement.backend == nil)

        let enabled = PreprocessingSettings(enhancement: .deepFilterNet3)
        let enabledManifest = enabled.manifestConfiguration()
        #expect(enabledManifest.enhancement.enabled)
        #expect(enabledManifest.enhancement.backend == "deepfilternet3")
    }

    @Test func integrityFailurePreservesArtifactReference() throws {
        let directory = try freshTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.wav")
        let artifactURL = directory.appendingPathComponent("artifacts/preprocessed.wav")
        try writeSineWAV(to: sourceURL, amplitude: 0.2)
        let originalHash = try AudioPreprocessor.sha256(of: sourceURL)
        try FileManager.default.createDirectory(at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preserved artifact".utf8).write(to: artifactURL)
        try Data("changed input".utf8).write(to: sourceURL)

        #expect(throws: PreprocessError.inputMutated(
            inputURL: sourceURL,
            hashBefore: originalHash,
            hashAfter: try AudioPreprocessor.sha256(of: sourceURL),
            preservedArtifactURL: artifactURL
        )) {
            try AudioPreprocessor.verifyInputIntegrity(
                inputURL: sourceURL,
                hashBefore: originalHash,
                preservedArtifactURL: artifactURL
            )
        }
        #expect(FileManager.default.fileExists(atPath: artifactURL.path))
    }

    private func freshTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaccheroniPreprocessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func mossLeafConfiguration() -> InferenceLeafPlanningConfiguration {
        InferenceLeafPlanningConfiguration(
            preferredInitialDurationS: 240,
            minimumInitialDurationS: 120,
            maximumInitialDurationS: 300,
            minimumRecoveryDurationS: 30,
            maximumRecoveryDepth: 3
        )
    }

    private func samples(
        seconds: Double,
        configuration: InferenceLeafPlanningConfiguration
    ) -> Int64 {
        InferenceLeafPlanner.sampleIndex(seconds: seconds, sampleRateHz: configuration.sampleRateHz)
    }

    private func fullSpeechMap(totalSamples: Int64, sampleRateHz: Int) throws -> VoiceActivityMap {
        let durationS = Double(totalSamples) / Double(sampleRateHz)
        return try VoiceActivityMap(durationS: durationS, regions: [
            VoiceActivityRegion(startS: 0, endS: durationS, kind: .speech),
        ])
    }

    private func assertExactCoverage(_ leaves: [InferenceLeaf], totalSamples: Int64) {
        #expect(!leaves.isEmpty)
        #expect(leaves.first?.startSample == 0)
        #expect(leaves.last?.endSample == totalSamples)
        #expect(leaves.allSatisfy { $0.endSample > $0.startSample })
        #expect(zip(leaves, leaves.dropFirst()).allSatisfy { $0.endSample == $1.startSample })
    }

    private func writeSineWAV(to url: URL, amplitude: Float) throws {
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)) else {
            Issue.record("Could not allocate synthetic WAV fixture.")
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleRate)
        let channel = try #require(buffer.floatChannelData?[0])
        for frame in 0 ..< Int(buffer.frameLength) {
            channel[frame] = amplitude * sin(Float(frame) * 2 * .pi * 440 / Float(sampleRate))
        }
        let output = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try output.write(from: buffer)
    }

    private func convertToM4A(input: URL, output: URL) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac", input.path, output.path]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw TestAudioError.compressionFailed(message)
        }
    }

    private func fixtureAdapter(
        in directory: URL,
        script: String,
        timeoutS: TimeInterval
    ) throws -> SpeechSileroVADAdapter {
        let executableURL = directory.appendingPathComponent("fixture-vad.sh")
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let modelURL = directory.appendingPathComponent("model/silero_vad.mlmodelc")
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        let revisionURL = directory.appendingPathComponent("refs/main")
        try FileManager.default.createDirectory(at: revisionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("523876545a57961474fee9df913e833e130560b8\n".utf8).write(to: revisionURL)
        return SpeechSileroVADAdapter(
            executableURL: executableURL,
            modelCacheURL: modelURL,
            revisionMarkerURL: revisionURL,
            timeoutS: timeoutS
        )
    }

    private var sileroRuntimeRelativePaths: [String] {
        [
            "config.json",
            "silero_vad.mlmodelc/analytics/coremldata.bin",
            "silero_vad.mlmodelc/coremldata.bin",
            "silero_vad.mlmodelc/metadata.json",
            "silero_vad.mlmodelc/model.mil",
            "silero_vad.mlmodelc/weights/weight.bin",
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

private enum TestAudioError: Error {
    case compressionFailed(String)
}
