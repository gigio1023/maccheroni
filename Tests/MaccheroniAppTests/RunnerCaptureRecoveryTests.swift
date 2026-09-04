import CryptoKit
import Foundation
import MaccheroniCore
import Testing
@testable import MaccheroniApp

@Suite(.serialized)
struct RunnerCaptureRecoveryTests {
    @Test
    func interruptedLibraryStateRoundTripsWithItsLocalizedTitle() throws {
        let encoded = try JSONEncoder().encode(LibraryItemState.interrupted)

        #expect(try JSONDecoder().decode(LibraryItemState.self, from: encoded) == .interrupted)
        #expect(LibraryItemState.interrupted.localizedTitle(locale: Locale(identifier: "en")) == "Interrupted")
    }

    @Test @MainActor
    func recordingControllerStartPublishesReservedOriginalsBeforeFinalization() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_722_686_400)
        let directory = URL(fileURLWithPath: "/fixture/recording", isDirectory: true)
        let expected = RecordingSessionMetadata(
            directory: directory,
            microphoneURL: directory.appendingPathComponent("microphone.caf"),
            systemAudioURL: directory.appendingPathComponent("system-audio.caf"),
            startedAt: startedAt
        )
        let recorder: any RecordingControlling = ProvisionalMetadataRecorder(metadata: expected)

        let metadata = try await recorder.start(in: URL(fileURLWithPath: "/fixture"))

        #expect(metadata == expected)
        #expect(metadata.microphoneURL.pathExtension == "caf")
        #expect(metadata.systemAudioURL.pathExtension == "caf")
    }

    @Test @MainActor
    func cliReportedRunWinsOverLexicographicallyLaterConcurrentDirectory() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let requested = try fixture.manifestPayload(runID: "a-requested")
        let unrelated = try fixture.manifestPayload(
            runID: "z-unrelated",
            inputData: Data("a different recording".utf8)
        )
        let script = try fixture.script(
            creating: [
                ("a-requested", requested),
                ("z-unrelated", unrelated),
            ],
            printing: fixture.outputRoot.appendingPathComponent("a-requested").path
        )
        let runner = try fixture.runner(executableURL: script)

        let result = try await runner.run(fixture.request) { _ in }

        #expect(result.standardizedFileURL == fixture.outputRoot
            .appendingPathComponent("a-requested")
            .standardizedFileURL)
    }

    @Test @MainActor
    func succeededRunLeavesNoRequestDirectoryBehind() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let runID = "sealed-and-tidy"
        let script = try fixture.script(
            creating: [(runID, try fixture.manifestPayload(runID: runID))],
            printing: fixture.outputRoot.appendingPathComponent(runID).path
        )
        let runner = try fixture.runner(executableURL: script)

        _ = try await runner.run(fixture.request) { _ in }

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.requestsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(leftovers.isEmpty, "a sealed run must not leave its request scratch behind")
    }

    @Test @MainActor
    func failedRunKeepsItsRequestDirectoryWithTheEngineStderr() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let script = fixture.root.appendingPathComponent("engine-refuses.sh")
        try Data("""
        #!/bin/sh
        printf 'engine refused the request\n' >&2
        exit 3

        """.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        let runner = try fixture.runner(executableURL: script)

        let error = await #expect(throws: TranscriptionRunnerError.self) {
            _ = try await runner.run(fixture.request) { _ in }
        }

        guard case let .pipelineFailed(message) = error else {
            Issue.record("Expected the engine's stderr to surface as pipelineFailed")
            return
        }
        #expect(message == "engine refused the request")
        let kept = try FileManager.default.contentsOfDirectory(
            at: fixture.requestsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(kept.count == 1, "a failed run keeps its request scratch for diagnosis")
        // Named after the request's own ID, so the library record that
        // launched it can find it without the runner reporting anything.
        #expect(
            kept.first?.lastPathComponent
                == EngineRequestScratch.directoryName(for: fixture.request.requestID)
        )
        #expect(kept.first?.lastPathComponent.hasPrefix("request-") == true)
        let stderrLog = try #require(kept.first).appendingPathComponent("stderr.log")
        #expect(try String(contentsOf: stderrLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "engine refused the request")
    }

    /// A partial run (D51) lost one named range and kept everything else, so
    /// it is a completed run to read, not a failure to file. Its scratch is
    /// kept like a failure's: the manifest names the loss, the engine's
    /// stderr is its only full account of the leaf that was lost, and the
    /// retention policy bounds a kept directory by the record's lifetime.
    @Test @MainActor
    func partialRunReturnsItsURLAndKeepsItsRequestScratch() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let runID = "partial-with-one-lost-range"
        let manifest = try fixture.manifestPayload(
            runID: runID,
            status: .partial,
            failure: Failure(
                code: "ASR_REPETITION_LOOPING",
                message: "promoted 1212.52 s of 1243.08 s; 1 range(s) produced no transcript: [871.552, 902.112) s"
            ),
            coverage: Coverage(
                inputDurationS: 1_243.08,
                processedDurationS: 1_212.52,
                truncated: true,
                strategy: .backendTruncated,
                chunksPlanned: 3,
                chunksCompleted: 3
            )
        )
        let expectedRunURL = fixture.outputRoot.appendingPathComponent(runID)
        let script = try fixture.script(
            creating: [(runID, manifest)],
            printing: expectedRunURL.path
        )
        let runner = try fixture.runner(executableURL: script)
        var lastSnapshot: RunProgressSnapshot?

        let result = try await runner.run(fixture.request) { lastSnapshot = $0 }

        #expect(result.standardizedFileURL == expectedRunURL.standardizedFileURL)
        // The last snapshot reads as complete: a partial run finished.
        #expect(lastSnapshot?.stage == .complete)
        #expect(lastSnapshot?.runURL?.standardizedFileURL == expectedRunURL.standardizedFileURL)
        // The failure record is still readable where it lives, in the manifest,
        // and says what was lost.
        let sealed = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: result.appendingPathComponent("manifest.json"))
        )
        #expect(sealed.status == .partial)
        #expect(sealed.failure?.code == "ASR_REPETITION_LOOPING")
        #expect(sealed.coverage.processedDurationS == 1_212.52)
        let kept = try FileManager.default.contentsOfDirectory(
            at: fixture.requestsRoot,
            includingPropertiesForKeys: nil
        )
        #expect(kept.map(\.lastPathComponent)
            == [EngineRequestScratch.directoryName(for: fixture.request.requestID)])
    }

    @Test @MainActor
    func authoritativeRunOutsideRequestedOutputRootIsRejected() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let outsideRun = fixture.root.appendingPathComponent("outside-run", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRun, withIntermediateDirectories: false)
        try fixture.manifestPayload(runID: "outside-run").write(
            to: outsideRun.appendingPathComponent("manifest.json")
        )
        let script = try fixture.script(creating: [], printing: outsideRun.path)
        let runner = try fixture.runner(executableURL: script)

        await #expect(throws: TranscriptionRunnerError.self) {
            _ = try await runner.run(fixture.request) { _ in }
        }
    }

    @Test @MainActor
    func authoritativeRunWithMismatchedInputIdentityIsRejected() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let mismatch = try fixture.manifestPayload(
            runID: "mismatched-run",
            inputData: Data("not the requested input".utf8)
        )
        let script = try fixture.script(
            creating: [("mismatched-run", mismatch)],
            printing: fixture.outputRoot.appendingPathComponent("mismatched-run").path
        )
        let runner = try fixture.runner(executableURL: script)

        await #expect(throws: TranscriptionRunnerError.self) {
            _ = try await runner.run(fixture.request) { _ in }
        }
    }

    @Test @MainActor
    func inputMutationFailureRunUsesThePrelaunchIdentityAndRemainsAttached() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let runID = "input-mutated"
        let manifest = try fixture.manifestPayload(
            runID: runID,
            status: .failed,
            failure: Failure(
                code: "INPUT_MUTATED",
                message: "The input changed after launch."
            )
        )
        let mutatedData = Data("mutated after manifest creation".utf8)
        let expectedRunURL = fixture.outputRoot.appendingPathComponent(runID)
        let script = try fixture.script(
            creating: [(runID, manifest)],
            printing: expectedRunURL.path,
            replacingSourceWith: mutatedData
        )
        let runner = try fixture.runner(executableURL: script)
        var attachedRunURL: URL?

        let error = await #expect(throws: TranscriptionRunnerError.self) {
            _ = try await runner.run(fixture.request) { snapshot in
                attachedRunURL = snapshot.runURL ?? attachedRunURL
            }
        }

        guard case .pipelineFailed = error else {
            Issue.record("Expected the preserved INPUT_MUTATED run to surface its failure")
            return
        }
        #expect(attachedRunURL?.standardizedFileURL == expectedRunURL.standardizedFileURL)
        #expect(try Data(contentsOf: fixture.sourceURL) == mutatedData)
    }

    @Test @MainActor
    func directoryFallbackRejectsAmbiguousNewRuns() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let first = try fixture.manifestPayload(runID: "first-run")
        let second = try fixture.manifestPayload(runID: "second-run")
        let script = try fixture.script(
            creating: [("first-run", first), ("second-run", second)],
            printing: nil
        )
        let runner = try fixture.runner(executableURL: script)

        await #expect(throws: TranscriptionRunnerError.self) {
            _ = try await runner.run(fixture.request) { _ in }
        }
    }

    @Test @MainActor
    func directoryFallbackAcceptsOneValidatedNewRunWhenCLIPrintsNothing() async throws {
        let fixture = try RunnerRecoveryFixture()
        defer { fixture.remove() }
        let manifest = try fixture.manifestPayload(runID: "only-run")
        let script = try fixture.script(
            creating: [("only-run", manifest)],
            printing: nil
        )
        let runner = try fixture.runner(executableURL: script)

        let result = try await runner.run(fixture.request) { _ in }

        #expect(result.lastPathComponent == "only-run")
    }
}

@MainActor
private final class ProvisionalMetadataRecorder: RecordingControlling {
    var meters = CaptureMeters.silent
    let metadata: RecordingSessionMetadata

    init(metadata: RecordingSessionMetadata) {
        self.metadata = metadata
    }

    func setMeterHandler(_: (@MainActor (CaptureMeters) -> Void)?) {}

    func start(in _: URL) async throws -> RecordingSessionMetadata {
        metadata
    }

    func stop() async throws -> RecordingArtifacts {
        throw RecordingError.notRecording
    }

    func cancel() async {}
}

private struct RunnerRecoveryFixture {
    let root: URL
    let outputRoot: URL
    let requestsRoot: URL
    let sourceURL: URL
    let sourceData = Data("requested recording bytes".utf8)
    let request: TranscriptionRequest

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniRunnerCaptureRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let sourceURL = root.appendingPathComponent("requested.wav")
        let sourceData = Data("requested recording bytes".utf8)
        try sourceData.write(to: sourceURL)
        let profile = try #require(AppProfileRegistry.load().first)
        self.root = root
        self.outputRoot = outputRoot
        requestsRoot = root.appendingPathComponent("requests", isDirectory: true)
        self.sourceURL = sourceURL
        request = TranscriptionRequest(
            sourceURL: sourceURL,
            outputRoot: outputRoot,
            profile: profile,
            postprocess: .none,
            glossaryURL: nil
        )
    }

    @MainActor
    func runner(executableURL: URL) throws -> ProcessTranscriptionRunner {
        try ProcessTranscriptionRunner(
            executableURL: executableURL,
            requestsRoot: requestsRoot
        )
    }

    func manifestPayload(
        runID: String,
        inputData: Data? = nil,
        status: RunStatus = .succeeded,
        failure: Failure? = nil,
        coverage: Coverage? = nil
    ) throws -> Data {
        let data = inputData ?? sourceData
        return try JSONEncoder().encode(Manifest(
            runID: runID,
            status: status,
            input: InputAudio(
                fileName: inputData == nil ? sourceURL.lastPathComponent : "other.wav",
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                sizeBytes: data.count
            ),
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
            coverage: coverage ?? Coverage(
                inputDurationS: 1,
                processedDurationS: 1,
                truncated: false,
                strategy: .full,
                chunksPlanned: 1,
                chunksCompleted: 1
            ),
            chunkBoundaries: [],
            timing: RunTiming(
                startedAt: "2026-08-10T00:00:00Z",
                finishedAt: "2026-08-10T00:00:01Z",
                wallTimeS: 1
            ),
            artifacts: [],
            failure: failure
        ))
    }

    func script(
        creating runs: [(String, Data)],
        printing path: String?,
        replacingSourceWith replacement: Data? = nil
    ) throws -> URL {
        let payloadRoot = root.appendingPathComponent("payloads", isDirectory: true)
        try FileManager.default.createDirectory(
            at: payloadRoot,
            withIntermediateDirectories: true
        )
        var commands: [String] = [
            "#!/bin/sh",
            "set -eu",
            "output_root=''",
            "while [ \"$#\" -gt 0 ]; do",
            "  if [ \"$1\" = '--output-root' ]; then output_root=\"$2\"; break; fi",
            "  shift",
            "done",
        ]
        for (index, run) in runs.enumerated() {
            let payload = payloadRoot.appendingPathComponent("manifest-\(index).json")
            try run.1.write(to: payload)
            commands.append("mkdir -p \"$output_root/\(run.0)\"")
            commands.append("cp \"\(payload.path)\" \"$output_root/\(run.0)/manifest.json\"")
        }
        if let replacement {
            let mutation = payloadRoot.appendingPathComponent("mutated-input.bin")
            try replacement.write(to: mutation)
            commands.append("cp \"\(mutation.path)\" \"\(sourceURL.path)\"")
        }
        if let path {
            commands.append("printf '%s\\n' \"\(path)\"")
        }
        let url = root.appendingPathComponent("fixture-\(UUID().uuidString).sh")
        try Data((commands.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
