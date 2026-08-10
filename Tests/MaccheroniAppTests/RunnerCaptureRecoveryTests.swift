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

    func manifestPayload(runID: String, inputData: Data? = nil) throws -> Data {
        let data = inputData ?? sourceData
        return try JSONEncoder().encode(Manifest(
            runID: runID,
            status: .succeeded,
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
            coverage: Coverage(
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
            failure: nil
        ))
    }

    func script(creating runs: [(String, Data)], printing path: String?) throws -> URL {
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
