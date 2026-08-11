@preconcurrency import AVFAudio
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit
import Foundation

enum RecordingError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case noDisplayAvailable
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            appString("A recording is already in progress.")
        case .notRecording:
            appString("There is no active recording.")
        case .noDisplayAvailable:
            appString("Maccheroni could not find a display whose system audio can be captured.")
        case let .captureFailed(message):
            appString("Recording failed: \(message)")
        }
    }
}

struct RecordingFinalizationError: Error, LocalizedError {
    var artifacts: PreservedRecordingArtifacts
    var message: String

    var errorDescription: String? {
        appString("Recording failed: \(message)")
    }
}

@MainActor
final class DualChannelRecorder: NSObject, RecordingControlling, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: CaptureWriter?
    private var inProgress: InProgress?
    private var captureFailure: Error?
    private var meterHandler: (@MainActor (CaptureMeters) -> Void)?

    private(set) var meters = CaptureMeters.silent

    func setMeterHandler(_ handler: (@MainActor (CaptureMeters) -> Void)?) {
        meterHandler = handler
        handler?(meters)
    }

    func start(in outputRoot: URL) async throws -> RecordingSessionMetadata {
        guard stream == nil else { throw RecordingError.alreadyRecording }
        meters = .silent
        captureFailure = nil

        let directory = try RecordingStorage.createSessionDirectory(in: outputRoot)
        let (microphoneURL, microphoneFile) = try RecordingStorage.createAudioFile(
            named: "microphone.caf",
            in: directory
        )
        let (systemAudioURL, systemAudioFile) = try RecordingStorage.createAudioFile(
            named: "system-audio.caf",
            in: directory
        )
        let startedAt = Date()
        let newWriter = CaptureWriter(
            microphoneFile: microphoneFile,
            systemAudioFile: systemAudioFile,
            meterSink: { [weak self] newMeters in
                Task { @MainActor [weak self] in
                    self?.receiveMeters(newMeters)
                }
            }
        )
        writer = newWriter
        inProgress = InProgress(
            directory: directory,
            microphoneURL: microphoneURL,
            systemAudioURL: systemAudioURL,
            startedAt: startedAt
        )

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else {
                throw RecordingError.noDisplayAvailable
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.sampleRate = Int(RecordingStorage.sampleRate)
            configuration.channelCount = Int(RecordingStorage.channelCount)
            configuration.captureMicrophone = true
            configuration.excludesCurrentProcessAudio = true

            let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
            if let synchronizationClock = newStream.synchronizationClock {
                newWriter.setTimelineOrigin(CMClockGetTime(synchronizationClock))
            }
            try newStream.addStreamOutput(
                newWriter,
                type: .audio,
                sampleHandlerQueue: newWriter.queue
            )
            try newStream.addStreamOutput(
                newWriter,
                type: .microphone,
                sampleHandlerQueue: newWriter.queue
            )
            stream = newStream
            try await newStream.startCapture()
            return RecordingSessionMetadata(
                directory: directory,
                microphoneURL: microphoneURL,
                systemAudioURL: systemAudioURL,
                startedAt: startedAt
            )
        } catch {
            newWriter.finishRetainingArtifacts()
            stream = nil
            writer = nil
            inProgress = nil
            throw error
        }
    }

    func stop() async throws -> RecordingArtifacts {
        guard let stream, let writer, let inProgress else {
            throw RecordingError.notRecording
        }
        let stoppedAt = Date()
        let preserved = PreservedRecordingArtifacts(
            directory: inProgress.directory,
            microphoneURL: inProgress.microphoneURL,
            systemAudioURL: inProgress.systemAudioURL,
            startedAt: inProgress.startedAt,
            stoppedAt: stoppedAt
        )
        do {
            try await stream.stopCapture()
        } catch {
            writer.finishRetainingArtifacts()
            self.stream = nil
            self.writer = nil
            self.inProgress = nil
            throw RecordingFinalizationError(
                artifacts: preserved,
                message: error.localizedDescription
            )
        }
        self.stream = nil
        writer.finishRetainingArtifacts()
        self.writer = nil
        self.inProgress = nil

        if let captureFailure {
            throw RecordingFinalizationError(
                artifacts: preserved,
                message: captureFailure.localizedDescription
            )
        }
        if let failure = writer.failure {
            throw RecordingFinalizationError(
                artifacts: preserved,
                message: failure.localizedDescription
            )
        }

        let combinedURL: URL
        do {
            combinedURL = inProgress.directory.appendingPathComponent(
                RecordingStorage.transcriptionFileName
            )
            try RecordingMixer.mix(
                microphoneURL: inProgress.microphoneURL,
                systemAudioURL: inProgress.systemAudioURL,
                outputURL: combinedURL
            )
        } catch {
            throw RecordingFinalizationError(
                artifacts: preserved,
                message: error.localizedDescription
            )
        }
        return RecordingArtifacts(
            directory: inProgress.directory,
            microphoneURL: inProgress.microphoneURL,
            systemAudioURL: inProgress.systemAudioURL,
            combinedURL: combinedURL,
            startedAt: inProgress.startedAt,
            stoppedAt: stoppedAt
        )
    }

    func cancel() async {
        if let stream {
            try? await stream.stopCapture()
        }
        writer?.finishRetainingArtifacts()
        stream = nil
        writer = nil
        inProgress = nil
        captureFailure = nil
        meters = .silent
        meterHandler?(meters)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.captureFailure = error
        }
    }

    private func receiveMeters(_ newMeters: CaptureMeters) {
        meters = newMeters
        meterHandler?(newMeters)
    }
}

private struct InProgress {
    let directory: URL
    let microphoneURL: URL
    let systemAudioURL: URL
    let startedAt: Date
}

private final class CaptureWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "Maccheroni.DualChannelRecorder.capture")

    private var microphoneWriter: TimelineAudioWriter?
    private var systemAudioWriter: TimelineAudioWriter?
    private var microphoneConverter: AVAudioConverter?
    private var systemAudioConverter: AVAudioConverter?
    private var timelineOrigin: CMTime?
    private var microphoneMeter: Float = 0
    private var systemMeter: Float = 0
    private var storedFailure: Error?
    private let meterSink: @Sendable (CaptureMeters) -> Void

    init(
        microphoneFile: AVAudioFile,
        systemAudioFile: AVAudioFile,
        meterSink: @escaping @Sendable (CaptureMeters) -> Void
    ) {
        microphoneWriter = TimelineAudioWriter(file: microphoneFile)
        systemAudioWriter = TimelineAudioWriter(file: systemAudioFile)
        self.meterSink = meterSink
    }

    func setTimelineOrigin(_ origin: CMTime) {
        queue.sync {
            timelineOrigin = origin
        }
    }

    var failure: Error? {
        queue.sync { storedFailure }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }
        do {
            switch type {
            case .audio:
                try append(sampleBuffer, channel: .systemAudio)
            case .microphone:
                try append(sampleBuffer, channel: .microphone)
            default:
                break
            }
        } catch {
            if storedFailure == nil { storedFailure = error }
        }
    }

    func finishRetainingArtifacts() {
        queue.sync {
            microphoneWriter?.finish()
            systemAudioWriter?.finish()
            microphoneWriter = nil
            systemAudioWriter = nil
            microphoneConverter = nil
            systemAudioConverter = nil
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, channel: Channel) throws {
        let input = try pcmBuffer(from: sampleBuffer)
        let converted = try canonicalBuffer(
            from: input,
            converter: converter(for: input.format, channel: channel)
        )
        guard converted.frameLength > 0 else { return }
        let targetFrame = timelineFrame(
            for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            channel: channel
        )
        switch channel {
        case .microphone:
            try microphoneWriter?.append(converted, at: targetFrame)
            microphoneMeter = meter(of: converted)
        case .systemAudio:
            try systemAudioWriter?.append(converted, at: targetFrame)
            systemMeter = meter(of: converted)
        }
        meterSink(CaptureMeters(microphone: microphoneMeter, systemAudio: systemMeter))
    }

    private func timelineFrame(for presentationTime: CMTime, channel: Channel) -> AVAudioFramePosition {
        let fallback = switch channel {
        case .microphone: microphoneWriter?.framesWritten ?? 0
        case .systemAudio: systemAudioWriter?.framesWritten ?? 0
        }
        guard presentationTime.isValid, presentationTime.isNumeric else { return fallback }
        if timelineOrigin == nil {
            timelineOrigin = presentationTime
        }
        guard let timelineOrigin else { return fallback }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(presentationTime, timelineOrigin))
        guard seconds.isFinite, seconds >= -1, seconds <= 86_400 else { return fallback }
        return max(0, AVAudioFramePosition((seconds * RecordingStorage.sampleRate).rounded()))
    }

    private func converter(for inputFormat: AVAudioFormat, channel: Channel) throws -> AVAudioConverter {
        switch channel {
        case .microphone:
            if let microphoneConverter { return microphoneConverter }
            guard let converter = AVAudioConverter(from: inputFormat, to: RecordingStorage.canonicalFormat) else {
                throw RecordingError.captureFailed(appString("Could not convert microphone audio to canonical PCM."))
            }
            microphoneConverter = converter
            return converter
        case .systemAudio:
            if let systemAudioConverter { return systemAudioConverter }
            guard let converter = AVAudioConverter(from: inputFormat, to: RecordingStorage.canonicalFormat) else {
                throw RecordingError.captureFailed(appString("Could not convert system audio to canonical PCM."))
            }
            systemAudioConverter = converter
            return converter
        }
    }

    private func canonicalBuffer(
        from input: AVAudioPCMBuffer,
        converter: AVAudioConverter
    ) throws -> AVAudioPCMBuffer {
        let ratio = RecordingStorage.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(
            max(1, Int((Double(input.frameLength) * ratio).rounded(.up)) + 64)
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: RecordingStorage.canonicalFormat,
            frameCapacity: capacity
        ) else {
            throw RecordingError.captureFailed(appString("Could not allocate canonical PCM buffer."))
        }
        let inputBox = ConversionInputBox(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let source = inputBox.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        guard status == .haveData || status == .inputRanDry else {
            throw RecordingError.captureFailed(appString("Could not convert captured PCM (status \(status.rawValue))."))
        }
        return output
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd)
        else {
            throw RecordingError.captureFailed(appString("Captured audio has no readable format description."))
        }
        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr, requiredSize > 0 else {
            throw RecordingError.captureFailed(appString("Could not access captured audio samples (status \(status))."))
        }
        let rawList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else {
            rawList.deallocate()
            throw RecordingError.captureFailed(appString("Could not copy captured audio samples (status \(status))."))
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: list,
            deallocator: { _ in
                withExtendedLifetime(retainedBlockBuffer) {}
                rawList.deallocate()
            }
        ) else {
            rawList.deallocate()
            throw RecordingError.captureFailed(appString("Could not create a PCM buffer for captured audio."))
        }
        buffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        return buffer
    }

    private func meter(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sumOfSquares: Float = 0
        var peak: Float = 0
        for index in 0 ..< Int(buffer.frameLength) {
            let value = samples[index]
            sumOfSquares += value * value
            peak = max(peak, abs(value))
        }
        let rms = sqrt(sumOfSquares / Float(buffer.frameLength))
        // Keep the meter linear for SwiftUI; a short peak keeps speech transients visible.
        return min(1, max(rms, peak * 0.5))
    }

    private enum Channel {
        case microphone
        case systemAudio
    }
}

final class TimelineAudioWriter {
    private var file: AVAudioFile?
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(file: AVAudioFile) {
        self.file = file
    }

    func finish() {
        file = nil
    }

    func append(_ buffer: AVAudioPCMBuffer, at targetFrame: AVAudioFramePosition) throws {
        guard let file else { return }
        let start = max(0, targetFrame)
        if start > framesWritten {
            try writeSilence(frameCount: start - framesWritten, to: file)
        }
        let overlap = max(0, framesWritten - start)
        guard overlap < AVAudioFramePosition(buffer.frameLength) else { return }

        if overlap == 0 {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            return
        }

        let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - overlap)
        guard let trimmed = AVAudioPCMBuffer(
            pcmFormat: RecordingStorage.canonicalFormat,
            frameCapacity: remaining
        ), let source = buffer.floatChannelData?[0], let destination = trimmed.floatChannelData?[0]
        else {
            throw RecordingError.captureFailed(appString("Could not allocate canonical PCM buffer."))
        }
        trimmed.frameLength = remaining
        destination.update(from: source.advanced(by: Int(overlap)), count: Int(remaining))
        try file.write(from: trimmed)
        framesWritten += AVAudioFramePosition(remaining)
    }

    private func writeSilence(frameCount: AVAudioFramePosition, to file: AVAudioFile) throws {
        var remaining = frameCount
        let blockSize: AVAudioFrameCount = 8_192
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(blockSize)))
            guard let silence = AVAudioPCMBuffer(
                pcmFormat: RecordingStorage.canonicalFormat,
                frameCapacity: count
            ), let samples = silence.floatChannelData?[0]
            else {
                throw RecordingError.captureFailed(appString("Could not allocate canonical PCM buffer."))
            }
            silence.frameLength = count
            samples.initialize(repeating: 0, count: Int(count))
            try file.write(from: silence)
            framesWritten += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }
}

private final class ConversionInputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var input: AVAudioPCMBuffer?

    init(_ input: AVAudioPCMBuffer) {
        self.input = input
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        defer { input = nil }
        return input
    }
}
