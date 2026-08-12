import AVFoundation
import CryptoKit
import Foundation
import MaccheroniCore

public enum PreprocessError: Error, Equatable, Sendable {
    case unsupportedInputType(String)
    case outputDirectoryIsInput(URL)
    case conversionFailed(String)
    case enhancementUnavailable(String)
    case inputMutated(
        inputURL: URL,
        hashBefore: String,
        hashAfter: String,
        preservedArtifactURL: URL
    )
}

public enum EnhancementBackend: String, Codable, Equatable, Sendable {
    case deepFilterNet3 = "deepfilternet3"
}

public struct EnhancementConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var backend: EnhancementBackend?

    public init(enabled: Bool = false, backend: EnhancementBackend? = nil) {
        self.enabled = enabled
        self.backend = backend
    }

    public static let disabled = EnhancementConfiguration()

    public static let deepFilterNet3 = EnhancementConfiguration(
        enabled: true,
        backend: .deepFilterNet3
    )
}

public struct PreprocessingSettings: Equatable, Sendable {
    public var peakNormalization: Bool
    public var targetPeak: Float
    public var enhancement: EnhancementConfiguration

    public init(
        peakNormalization: Bool = true,
        targetPeak: Float = 0.95,
        enhancement: EnhancementConfiguration = .disabled
    ) {
        self.peakNormalization = peakNormalization
        self.targetPeak = targetPeak
        self.enhancement = enhancement
    }

    public static let `default` = PreprocessingSettings()

    public func manifestConfiguration(vadBackend: String = "silero") -> PreprocessingConfiguration {
        PreprocessingConfiguration(
            sampleRateHz: 16_000,
            channels: 1,
            peakNormalization: peakNormalization,
            vad: ProcessingSwitch(enabled: true, backend: vadBackend),
            enhancement: ProcessingSwitch(
                enabled: enhancement.enabled,
                backend: enhancement.backend?.rawValue
            )
        )
    }
}

public struct PreprocessedAudio: Equatable, Sendable {
    public var artifactURL: URL
    public var inputSHA256: String
    public var artifactSHA256: String
    public var durationS: Double
    public var sampleRateHz: Double
    public var channels: Int
    public var peak: Float
    public var normalizationGain: Float
    public var settings: PreprocessingSettings

    public init(
        artifactURL: URL,
        inputSHA256: String,
        artifactSHA256: String,
        durationS: Double,
        sampleRateHz: Double,
        channels: Int,
        peak: Float,
        normalizationGain: Float,
        settings: PreprocessingSettings
    ) {
        self.artifactURL = artifactURL
        self.inputSHA256 = inputSHA256
        self.artifactSHA256 = artifactSHA256
        self.durationS = durationS
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.peak = peak
        self.normalizationGain = normalizationGain
        self.settings = settings
    }
}

/// Converts a supported source into a new PCM WAV artifact. The source URL is only opened for reading.
public struct AudioPreprocessor: Sendable {
    private enum InputContainer: String {
        case m4a, mp3, wav
    }

    public static let supportedInputExtensions: Set<String> = ["m4a", "wav", "mp3"]
    public static let supportedExtensions = supportedInputExtensions
    public static let targetSampleRate: Double = 16_000
    public static let targetChannels: AVAudioChannelCount = 1

    public init() {}

    public static func supportsInputFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let expected = InputContainer(rawValue: url.pathExtension.lowercased()),
              detectedContainer(at: url) == expected,
              let file = try? AVAudioFile(forReading: url)
        else {
            return false
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return false }
        let duration = Double(file.length) / sampleRate
        return duration.isFinite && duration > 0
    }

    private static func detectedContainer(at url: URL) -> InputContainer? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            return nil
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), !header.isEmpty else {
            return nil
        }
        let bytes = [UInt8](header)
        if bytes.count >= 12,
           bytes[0 ... 3] == ArraySlice("RIFF".utf8),
           bytes[8 ... 11] == ArraySlice("WAVE".utf8)
        {
            return .wav
        }
        if bytes.count >= 8,
           bytes[4 ... 7] == ArraySlice("ftyp".utf8)
        {
            return .m4a
        }
        if bytes.count >= 3, bytes[0 ... 2] == ArraySlice("ID3".utf8) {
            return .mp3
        }
        if bytes.count >= 2,
           bytes[0] == 0xFF,
           bytes[1] & 0xE0 == 0xE0
        {
            return .mp3
        }
        return nil
    }

    public func preprocess(
        inputURL: URL,
        outputDirectory: URL,
        settings: PreprocessingSettings = .default
    ) throws -> PreprocessedAudio {
        let sourceExtension = inputURL.pathExtension.lowercased()
        guard Self.supportsInputFile(inputURL) else {
            throw PreprocessError.unsupportedInputType(sourceExtension)
        }
        guard settings.targetPeak > 0, settings.targetPeak <= 1 else {
            throw PreprocessError.conversionFailed("targetPeak must be in (0, 1]")
        }
        guard !settings.enhancement.enabled else {
            let backend = settings.enhancement.backend?.rawValue ?? "unspecified"
            throw PreprocessError.enhancementUnavailable(
                "Enhancement is opt-in and requires an installed \(backend) adapter."
            )
        }

        let standardizedInput = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedOutputDirectory = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard standardizedInput != standardizedOutputDirectory else {
            throw PreprocessError.outputDirectoryIsInput(inputURL)
        }

        let inputHashBefore = try Self.sha256(of: inputURL)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let stem = inputURL.deletingPathExtension().lastPathComponent
        let artifactURL = outputDirectory.appendingPathComponent(
            "\(stem)-16khz-mono-\(UUID().uuidString.lowercased()).wav"
        )
        let temporaryStem = UUID().uuidString.lowercased()
        let firstTemporaryURL = outputDirectory.appendingPathComponent(
            ".\(temporaryStem).resampled.wav"
        )
        let secondTemporaryURL = outputDirectory.appendingPathComponent(
            ".\(temporaryStem).normalized.wav"
        )

        do {
            let durationS: Double
            do {
                durationS = try resample(inputURL: inputURL, outputURL: firstTemporaryURL)
            } catch {
                throw PreprocessError.conversionFailed("resample: \(error)")
            }
            let unnormalizedPeak: Float
            do {
                unnormalizedPeak = try peak(of: firstTemporaryURL)
            } catch {
                throw PreprocessError.conversionFailed("peak analysis: \(error)")
            }
            let gain: Float = settings.peakNormalization && unnormalizedPeak > 0
                ? min(settings.targetPeak / unnormalizedPeak, 16)
                : 1
            do {
                try normalize(
                    inputURL: firstTemporaryURL,
                    outputURL: secondTemporaryURL,
                    gain: gain
                )
            } catch {
                throw PreprocessError.conversionFailed("normalization: \(error)")
            }
            try FileManager.default.moveItem(at: secondTemporaryURL, to: artifactURL)
            try? FileManager.default.removeItem(at: firstTemporaryURL)

            try Self.verifyInputIntegrity(
                inputURL: inputURL,
                hashBefore: inputHashBefore,
                preservedArtifactURL: artifactURL
            )

            let finalPeak = try peak(of: artifactURL)
            return PreprocessedAudio(
                artifactURL: artifactURL,
                inputSHA256: inputHashBefore,
                artifactSHA256: try Self.sha256(of: artifactURL),
                durationS: durationS,
                sampleRateHz: Self.targetSampleRate,
                channels: Int(Self.targetChannels),
                peak: finalPeak,
                normalizationGain: gain,
                settings: settings
            )
        } catch {
            try? FileManager.default.removeItem(at: firstTemporaryURL)
            if FileManager.default.fileExists(atPath: secondTemporaryURL.path) {
                if !FileManager.default.fileExists(atPath: artifactURL.path) {
                    try? FileManager.default.moveItem(at: secondTemporaryURL, to: artifactURL)
                }
            }
            throw error
        }
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Checks the source after work has completed without removing the new artifact on failure.
    public static func verifyInputIntegrity(
        inputURL: URL,
        hashBefore: String,
        preservedArtifactURL: URL
    ) throws {
        let hashAfter = try sha256(of: inputURL)
        guard hashBefore == hashAfter else {
            throw PreprocessError.inputMutated(
                inputURL: inputURL,
                hashBefore: hashBefore,
                hashAfter: hashAfter,
                preservedArtifactURL: preservedArtifactURL
            )
        }
    }

    private func resample(inputURL: URL, outputURL: URL) throws -> Double {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            "-f", "WAVE",
            "-d", "LEF32@16000",
            "-c", "1",
            inputURL.path,
            outputURL.path,
        ]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PreprocessError.conversionFailed(
                "afconvert exited \(process.terminationStatus): \(stdout)\(stderr)"
            )
        }
        let converted = try AVAudioFile(forReading: outputURL)
        return Double(converted.length) / converted.processingFormat.sampleRate
    }

    private func peak(of url: URL) throws -> Float {
        let input = try AVAudioFile(forReading: url)
        let capacity: AVAudioFrameCount = 32_768
        var highest: Float = 0
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat,
                frameCapacity: capacity
            ) else {
                throw PreprocessError.conversionFailed("Could not allocate analysis buffer.")
            }
            let remaining = input.length - input.framePosition
            try input.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channel = buffer.floatChannelData?[0] else {
                throw PreprocessError.conversionFailed("Expected float PCM analysis buffer.")
            }
            for index in 0 ..< Int(buffer.frameLength) {
                highest = max(highest, abs(channel[index]))
            }
        }
        return highest
    }

    private func normalize(inputURL: URL, outputURL: URL, gain: Float) throws {
        let input = try AVAudioFile(forReading: inputURL)
        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: input.processingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let capacity: AVAudioFrameCount = 32_768
        while input.framePosition < input.length {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: input.processingFormat,
                frameCapacity: capacity
            ) else {
                throw PreprocessError.conversionFailed("Could not allocate normalization buffer.")
            }
            let remaining = input.length - input.framePosition
            try input.read(into: buffer, frameCount: min(capacity, AVAudioFrameCount(remaining)))
            guard let channels = buffer.floatChannelData else {
                throw PreprocessError.conversionFailed("Expected float PCM normalization buffer.")
            }
            for channelIndex in 0 ..< Int(buffer.format.channelCount) {
                let channel = channels[channelIndex]
                for frame in 0 ..< Int(buffer.frameLength) {
                    channel[frame] *= gain
                }
            }
            try output.write(from: buffer)
        }
    }
}
