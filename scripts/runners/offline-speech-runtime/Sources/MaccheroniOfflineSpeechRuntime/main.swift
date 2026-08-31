import AudioCommon
import AVFoundation
import Foundation
import SpeechVAD

#if canImport(CoreML)
import CoreML
#endif

private let sileroModelID = "aufklarer/Silero-VAD-v6.2.1-CoreML"
private let communityModelID = "aufklarer/Pyannote-Community-1-CoreML"
private let sampleRate = 16_000

private func roundedSeconds(_ value: Float) -> Double {
    (Double(value) * 1_000).rounded() / 1_000
}

private func validateRepositoryRoot(_ directory: URL, modelID: String) throws {
    var isDirectory: ObjCBool = false
    let expectedName = modelID.split(separator: "/").last.map(String.init)
    guard directory.lastPathComponent == expectedName,
          FileManager.default.fileExists(
              atPath: directory.path,
              isDirectory: &isDirectory
          ),
          isDirectory.boolValue
    else {
        throw RuntimeFailure.runtimeUnavailable
    }
}

private enum RuntimeFailure: Error {
    case invalidArguments
    case invalidSpeakerBounds
    case runtimeUnavailable
}

private struct VADInterval: Encodable {
    let start: Double
    let end: Double
    let duration: Double
}

private struct DiarizationInterval: Encodable {
    let start: Double
    let end: Double
    let duration: Double
    let speaker: Int
}

private struct DiarizationDocument: Encodable {
    let segments: [DiarizationInterval]
    let numSpeakers: Int

    enum CodingKeys: String, CodingKey {
        case segments
        case numSpeakers = "num_speakers"
    }
}

private struct Arguments {
    enum Command: String {
        case vadStream = "vad-stream"
        case diarize
    }

    let command: Command
    let audioURL: URL
    let cacheDirectory: URL
    let exactSpeakers: Int?
    let minimumSpeakers: Int
    let maximumSpeakers: Int?

    init(_ values: [String]) throws {
        guard values.count >= 6,
              let command = Command(rawValue: values[1]),
              !values[2].isEmpty
        else {
            throw RuntimeFailure.invalidArguments
        }

        var cacheDirectory: URL?
        var exactSpeakers: Int?
        var minimumSpeakers = 1
        var maximumSpeakers: Int?
        var sawJSON = false
        var index = 3
        while index < values.count {
            switch values[index] {
            case "--cache-dir":
                index += 1
                guard index < values.count, !values[index].isEmpty else {
                    throw RuntimeFailure.invalidArguments
                }
                cacheDirectory = URL(fileURLWithPath: values[index], isDirectory: true)
            case "--json":
                sawJSON = true
            case "--num-speakers":
                index += 1
                guard index < values.count, let count = Int(values[index]) else {
                    throw RuntimeFailure.invalidArguments
                }
                exactSpeakers = count
            case "--min-speakers":
                index += 1
                guard index < values.count, let count = Int(values[index]) else {
                    throw RuntimeFailure.invalidArguments
                }
                minimumSpeakers = count
            case "--max-speakers":
                index += 1
                guard index < values.count, let count = Int(values[index]) else {
                    throw RuntimeFailure.invalidArguments
                }
                maximumSpeakers = count
            default:
                throw RuntimeFailure.invalidArguments
            }
            index += 1
        }

        guard let cacheDirectory, sawJSON else {
            throw RuntimeFailure.invalidArguments
        }
        guard command == .diarize ||
                (exactSpeakers == nil && minimumSpeakers == 1 && maximumSpeakers == nil)
        else {
            throw RuntimeFailure.invalidArguments
        }
        guard exactSpeakers == nil || (minimumSpeakers == 1 && maximumSpeakers == nil),
              exactSpeakers.map({ $0 > 0 }) ?? true,
              minimumSpeakers > 0,
              maximumSpeakers.map({ $0 >= minimumSpeakers }) ?? true
        else {
            throw RuntimeFailure.invalidSpeakerBounds
        }

        self.command = command
        self.audioURL = URL(fileURLWithPath: values[2])
        self.cacheDirectory = cacheDirectory
        self.exactSpeakers = exactSpeakers
        self.minimumSpeakers = minimumSpeakers
        self.maximumSpeakers = maximumSpeakers
    }
}

@main
private struct MaccheroniOfflineSpeechRuntime {
    static func main() async {
        do {
            let arguments = try Arguments(CommandLine.arguments)
            switch arguments.command {
            case .vadStream:
                try await runVAD(arguments)
            case .diarize:
                try await runDiarization(arguments)
            }
        } catch RuntimeFailure.invalidArguments {
            writeDiagnostic("offline speech runtime received invalid arguments")
            exit(64)
        } catch RuntimeFailure.invalidSpeakerBounds {
            writeDiagnostic("offline speech runtime received invalid speaker bounds")
            exit(64)
        } catch {
            writeDiagnostic("offline speech runtime failed")
            exit(70)
        }
    }

    private static func runVAD(_ arguments: Arguments) async throws {
        try validateRepositoryRoot(arguments.cacheDirectory, modelID: sileroModelID)
        let audio = try AudioFileLoader.load(
            url: arguments.audioURL,
            targetSampleRate: sampleRate
        )
        let model = try await SileroVADModel.fromPretrained(
            modelId: sileroModelID,
            engine: .coreml,
            cacheDir: arguments.cacheDirectory,
            offlineMode: true,
            progressHandler: nil
        )
        let processor = StreamingVADProcessor(model: model, config: .sileroDefault)
        var events = [VADEvent]()
        var offset = 0
        while offset < audio.count {
            let end = min(offset + SileroVADModel.chunkSize, audio.count)
            events.append(contentsOf: processor.process(samples: Array(audio[offset..<end])))
            offset = end
        }
        events.append(contentsOf: processor.flush())

        let intervals = events.compactMap { event -> VADInterval? in
            guard case let .speechEnded(segment) = event else { return nil }
            return VADInterval(
                start: roundedSeconds(segment.startTime),
                end: roundedSeconds(segment.endTime),
                duration: roundedSeconds(segment.duration)
            )
        }
        try writeJSON(intervals)
    }

    private static func runDiarization(_ arguments: Arguments) async throws {
        #if canImport(CoreML)
        try validateRepositoryRoot(arguments.cacheDirectory, modelID: communityModelID)
        let audio = try AudioFileLoader.load(
            url: arguments.audioURL,
            targetSampleRate: sampleRate
        )
        let pipeline = try Community1DiarizationPipeline.fromLocal(
            directory: arguments.cacheDirectory,
            config: .default,
            computeUnits: .cpuAndNeuralEngine,
            progressHandler: nil
        )
        let result = try pipeline.diarize(
            audio: audio,
            sampleRate: sampleRate,
            speakerBounds: Community1SpeakerBounds(
                exact: arguments.exactSpeakers,
                minimum: arguments.minimumSpeakers,
                maximum: arguments.maximumSpeakers
            )
        )
        let segments = result.segments.map {
            DiarizationInterval(
                start: roundedSeconds($0.startTime),
                end: roundedSeconds($0.endTime),
                duration: roundedSeconds($0.duration),
                speaker: $0.speakerId
            )
        }
        try writeJSON(DiarizationDocument(
            segments: segments,
            numSpeakers: result.numSpeakers
        ))
        #else
        throw RuntimeFailure.runtimeUnavailable
        #endif
    }

    private static func writeJSON<Value: Encodable>(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func writeDiagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
    }
}
