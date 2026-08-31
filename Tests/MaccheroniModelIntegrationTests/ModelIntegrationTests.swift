import CryptoKit
import Foundation
import Testing
import MaccheroniASR
@testable import MaccheroniCLI
import MaccheroniPreprocess

@Suite(.serialized) struct MaccheroniModelIntegrationTests {
    private static let enabled = ProcessInfo.processInfo.environment[
        "MACCHERONI_RUN_MODEL_INTEGRATION"
    ] == "1"

    @Test(.enabled(if: Self.enabled))
    func koMeetingRunsPinnedVibeVADAndCommunity1FromSelectedCache() async throws {
        let application = CLIApplication()
        let environment = ProcessInfo.processInfo.environment
        let cacheRoot = try selectedCacheRoot(environment: environment)
        try await requireReadyKoMeeting(
            application: application,
            cacheRoot: cacheRoot
        )

        // Nothing before this point launches a model backend. An opted-in run
        // with an empty or incomplete cache therefore fails at preflight.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MaccheroniModelIntegrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let audioURL = try generatedSpeechFixture(in: scratch)
        let inputSHA256 = try sha256(of: audioURL)
        let outputRoot = scratch.appendingPathComponent("runs", isDirectory: true)
        let runPath = try await application.executeRun(
            audioPath: audioURL.path,
            profileName: "ko-meeting",
            profilesPath: nil,
            outputRootPath: outputRoot.path,
            glossaryPath: nil
        )
        let runURL = URL(fileURLWithPath: runPath, isDirectory: true)
        let manifest = try JSONDecoder().decode(
            IntegrationManifest.self,
            from: Data(contentsOf: runURL.appendingPathComponent("manifest.json"))
        )

        #expect(manifest.status == "succeeded")
        #expect(manifest.failure == nil)
        #expect(manifest.input.sha256 == inputSHA256)
        #expect(try sha256(of: audioURL) == inputSHA256)
        #expect(manifest.backend == .init(
            name: "mlx-audio-vibevoice",
            version: "0.4.6"
        ))
        #expect(Set(manifest.models) == Set([
            .init(
                role: "asr",
                hfModelID: "mlx-community/VibeVoice-ASR-8bit",
                revision: "725c72e54d6ef875472c27fbc50fab470a960940",
                quantization: "int8"
            ),
            .init(
                role: "vad",
                hfModelID: "aufklarer/Silero-VAD-v6.2.1-CoreML",
                revision: "523876545a57961474fee9df913e833e130560b8",
                quantization: "coreml-float16"
            ),
            .init(
                role: "diarization",
                hfModelID: "aufklarer/Pyannote-Community-1-CoreML",
                revision: "a14e6c420d56e8472850649b016a486fd0acbe81",
                quantization: "coreml-fp32"
            ),
        ]))
        #expect(manifest.coverage.strategy == "full")
        #expect(manifest.coverage.chunksPlanned == 1)
        #expect(manifest.coverage.chunksCompleted == 1)
        #expect(manifest.coverage.truncated == false)
        #expect(manifest.coverage.inputDurationS > 0)
        #expect(abs(
            manifest.coverage.processedDurationS
                - manifest.coverage.inputDurationS
        ) < 0.001)
        #expect(manifest.artifacts.contains { $0.kind == "vad_map" })
        #expect(manifest.artifacts.contains {
            $0.kind == "diarization_timeline"
        })
        #expect(manifest.artifacts.contains { $0.kind == "primary_segments" })

        let runnerRecordURL = try onlyRunnerRecord(in: runURL)
        let runnerRecord = try JSONDecoder().decode(
            IntegrationRunnerRecord.self,
            from: Data(contentsOf: runnerRecordURL)
        )
        #expect(runnerRecord.outcome == "complete")
        #expect(runnerRecord.stopReason == "endOfSequence")
        #expect(runnerRecord.terminalEvidence == "observed")
        #expect(runnerRecord.timingGranularity == "segment")
    }

    private func selectedCacheRoot(
        environment: [String: String]
    ) throws -> URL {
        guard let value = environment["MACCHERONI_BENCHMARK_CACHE"],
              !value.isEmpty else {
            throw ModelIntegrationPreflightError(
                "MACCHERONI_BENCHMARK_CACHE must name a T1-provisioned cache"
            )
        }
        let root = URL(fileURLWithPath: value, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ModelIntegrationPreflightError(
                "selected benchmark cache is missing or is not a directory"
            )
        }
        return root
    }

    private func requireReadyKoMeeting(
        application: CLIApplication,
        cacheRoot: URL
    ) async throws {
        let resolved = ASRRuntime.resolveCacheRoot()
        guard resolved.standardizedFileURL == cacheRoot else {
            throw ModelIntegrationPreflightError(
                "production runtime did not resolve the selected benchmark cache"
            )
        }
        let report = try await application.inspectDoctor(
            profileName: "ko-meeting",
            profilesPath: nil
        )
        guard report.isReady else {
            let failedChecks = report.diagnosticValues
                .split(separator: "\n")
                .filter { $0.hasPrefix("check.") && $0.hasSuffix("=false") }
                .joined(separator: ", ")
            throw ModelIntegrationPreflightError(
                "ko-meeting preflight failed before backend launch: "
                    + (failedChecks.isEmpty ? "doctor reported not ready" : failedChecks)
            )
        }
    }

    private func generatedSpeechFixture(in directory: URL) throws -> URL {
        let aiff = directory.appendingPathComponent("generated-speech.aiff")
        let wav = directory.appendingPathComponent("generated-speech.wav")
        try runTool(
            "/usr/bin/say",
            arguments: [
                "-o", aiff.path,
                "-r", "165",
                "Maccheroni starts a local meeting. This generated sentence checks the speaker and transcription models.",
            ]
        )
        try runTool(
            "/usr/bin/afconvert",
            arguments: [
                "-f", "WAVE",
                "-d", "LEI16@16000",
                aiff.path,
                wav.path,
            ]
        )
        guard FileManager.default.isReadableFile(atPath: wav.path) else {
            throw ModelIntegrationFixtureError("generated WAV is unreadable")
        }
        return wav
    }

    private func runTool(_ path: String, arguments: [String]) throws {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ModelIntegrationFixtureError(
                "synthetic fixture tool failed with exit \(process.terminationStatus)"
            )
        }
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func onlyRunnerRecord(in runURL: URL) throws -> URL {
        let attempts = runURL.appendingPathComponent(
            "primary/attempts",
            isDirectory: true
        )
        guard let enumerator = FileManager.default.enumerator(
            at: attempts,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ModelIntegrationEvidenceError("attempt evidence is missing")
        }
        let records = enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  url.lastPathComponent == "runner-record.json",
                  (try? url.resourceValues(
                    forKeys: [.isRegularFileKey]
                  ).isRegularFile) == true else { return nil }
            return url
        }
        guard records.count == 1, let record = records.first else {
            throw ModelIntegrationEvidenceError(
                "expected one runner record, found \(records.count)"
            )
        }
        return record
    }
}

private struct ModelIntegrationPreflightError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct ModelIntegrationFixtureError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct ModelIntegrationEvidenceError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct IntegrationManifest: Decodable {
    var status: String
    var input: Input
    var backend: Backend
    var models: [Model]
    var coverage: Coverage
    var artifacts: [Artifact]
    var failure: Failure?

    struct Input: Decodable {
        var sha256: String
    }

    struct Backend: Decodable, Equatable {
        var name: String
        var version: String
    }

    struct Model: Decodable, Hashable {
        var role: String
        var hfModelID: String
        var revision: String
        var quantization: String

        enum CodingKeys: String, CodingKey {
            case role
            case hfModelID = "hf_model_id"
            case revision
            case quantization
        }
    }

    struct Coverage: Decodable {
        var strategy: String
        var inputDurationS: Double
        var processedDurationS: Double
        var chunksPlanned: Int
        var chunksCompleted: Int
        var truncated: Bool

        enum CodingKeys: String, CodingKey {
            case strategy
            case inputDurationS = "input_duration_s"
            case processedDurationS = "processed_duration_s"
            case chunksPlanned = "chunks_planned"
            case chunksCompleted = "chunks_completed"
            case truncated
        }
    }

    struct Artifact: Decodable {
        var kind: String
    }

    struct Failure: Decodable {}
}

private struct IntegrationRunnerRecord: Decodable {
    var outcome: String
    var stopReason: String
    var terminalEvidence: String
    var timingGranularity: String

    enum CodingKeys: String, CodingKey {
        case outcome
        case stopReason = "stop_reason"
        case terminalEvidence = "terminal_evidence"
        case timingGranularity = "timing_granularity"
    }
}
