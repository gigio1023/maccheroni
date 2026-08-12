import CryptoKit
import Foundation
import MaccheroniCore

private struct TranscriptionInputIdentity {
    let fileName: String
    let sizeBytes: Int
    let sha256: String
}

enum TranscriptionRunnerError: Error, LocalizedError {
    case executableMissing
    case launchFailed(String)
    case pipelineFailed(String)
    case resultMissing
    case resultInvalid
    case resultAmbiguous
    case existingRunPostprocessUnavailable

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            appString("The Maccheroni command-line engine is missing.")
        case let .launchFailed(message):
            appString("The transcription engine could not start: \(message)")
        case let .pipelineFailed(message):
            message
        case .resultMissing, .resultInvalid, .resultAmbiguous:
            appString("The transcription engine finished without a run directory.")
        case .existingRunPostprocessUnavailable:
            appString("Post-processing could not start for this completed run.")
        }
    }
}

@MainActor
final class ProcessTranscriptionRunner: TranscriptionRunning {
    private let executableURL: URL
    private let requestsRoot: URL
    private let terminationTiming: ProcessTerminationTiming
    private let pollWait: @Sendable () async throws -> Void
    private var process: Process?
    private var cancelRequested = false

    init(
        executableURL: URL? = nil,
        requestsRoot: URL = LibraryRepository.local.requestsRoot,
        terminationTiming: ProcessTerminationTiming = .default,
        pollWait: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(250))
        }
    ) throws {
        guard let resolved = executableURL ?? Self.resolveExecutable(),
              FileManager.default.isExecutableFile(atPath: resolved.path)
        else {
            throw TranscriptionRunnerError.executableMissing
        }
        self.executableURL = resolved
        self.requestsRoot = requestsRoot
        self.terminationTiming = terminationTiming
        self.pollWait = pollWait
    }

    func run(
        _ request: TranscriptionRequest,
        progress: @escaping @MainActor (RunProgressSnapshot) -> Void
    ) async throws -> URL {
        guard process == nil else {
            throw TranscriptionRunnerError.launchFailed("another run is active")
        }
        let launchInput = try inputIdentity(at: request.sourceURL)
        cancelRequested = false
        let requestDirectory = try createRequestDirectory()
        let profileURL = requestDirectory.appendingPathComponent("profiles.json")
        try writeProfile(for: request, to: profileURL)
        let stdoutURL = requestDirectory.appendingPathComponent("stdout.log")
        let stderrURL = requestDirectory.appendingPathComponent("stderr.log")
        try Data().write(to: stdoutURL, options: .withoutOverwriting)
        try Data().write(to: stderrURL, options: .withoutOverwriting)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            process = nil
        }

        try FileManager.default.createDirectory(
            at: request.outputRoot,
            withIntermediateDirectories: true
        )
        let directoriesBefore = try childDirectories(of: request.outputRoot)
        let launchedAt = Date()
        let task = Process()
        task.executableURL = executableURL
        task.arguments = arguments(for: request, profileURL: profileURL)
        task.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_OFFLINE": "1",
        ]) { current, _ in current }
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            throw TranscriptionRunnerError.launchFailed(error.localizedDescription)
        }
        process = task
        let liveness = TranscriptionProcessLiveness(task)
        var runURL: URL?
        var progressAccumulator = RunProgressAccumulator()
        progress(RunProgressSnapshot(
            stage: .preparing,
            completedChunks: 0,
            plannedChunks: 0,
            elapsedS: 0,
            stageElapsedS: progressAccumulator.observe(stage: .preparing, atElapsedS: 0),
            modelID: nil,
            message: nil,
            runURL: nil
        ))

        while task.isRunning {
            if cancelRequested || Task.isCancelled {
                cancelRequested = true
                await terminate(task, liveness: liveness)
                break
            }
            // A directory appearing under the shared root is not proof that this
            // process created it. Only trust a path reported by the CLI while it
            // is running; directory discovery is a post-exit fallback.
            if runURL == nil,
               let reported = try? reportedRunURL(from: stdoutURL),
               let validated = try? validate(
                   reported,
                   for: request,
                   launchInput: launchInput
               ) {
                runURL = validated
            }
            if let runURL, let manifest = try? readManifest(at: runURL) {
                progress(snapshot(
                    for: manifest,
                    runURL: runURL,
                    launchedAt: launchedAt,
                    requestedPostprocessModelID: request.postprocess.requestedModelID,
                    accumulator: &progressAccumulator
                ))
            }
            do {
                try await pollWait()
            } catch {
                cancelRequested = true
                await terminate(task, liveness: liveness)
                break
            }
        }
        if !cancelRequested, !Task.isCancelled {
            task.waitUntilExit()
        }
        stdout.synchronizeFile()
        stderr.synchronizeFile()
        var runResolutionError: Error?
        do {
            runURL = try resolveRunURL(
                for: request,
                launchInput: launchInput,
                stdoutURL: stdoutURL,
                directoriesBefore: directoriesBefore
            )
        } catch {
            runResolutionError = error
        }
        if let runURL, let manifest = try? readManifest(at: runURL) {
            progress(snapshot(
                for: manifest,
                runURL: runURL,
                launchedAt: launchedAt,
                requestedPostprocessModelID: request.postprocess.requestedModelID,
                accumulator: &progressAccumulator
            ))
        }
        if cancelRequested || Task.isCancelled {
            throw CancellationError()
        }
        guard task.terminationStatus == 0 else {
            let message = try String(contentsOf: stderrURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionRunnerError.pipelineFailed(
                message.isEmpty
                    ? appString("The transcription engine exited with status \(task.terminationStatus).")
                    : message
            )
        }
        if let runResolutionError { throw runResolutionError }
        guard let runURL else { throw TranscriptionRunnerError.resultMissing }
        let manifest = try readManifest(at: runURL)
        progress(snapshot(
            for: manifest,
            runURL: runURL,
            launchedAt: launchedAt,
            requestedPostprocessModelID: request.postprocess.requestedModelID,
            accumulator: &progressAccumulator
        ))
        guard manifest.status == .succeeded else {
            throw TranscriptionRunnerError.pipelineFailed(
                manifest.failure?.message ?? appString("The run did not succeed.")
            )
        }
        return runURL
    }

    func postprocess(
        _ request: ExistingRunPostprocessRequest,
        progress: @escaping @MainActor (ExistingRunPostprocessProgress) -> Void
    ) async throws -> URL {
        guard process == nil else {
            throw TranscriptionRunnerError.launchFailed("another run is active")
        }
        _ = try RunIntegrityVerifier.verifyCompletedRun(at: request.sourceRunURL)
        cancelRequested = false
        let requestDirectory = try createRequestDirectory()
        let profileURL = requestDirectory.appendingPathComponent("profiles.json")
        try writeProfile(for: request, to: profileURL)
        let stdoutURL = requestDirectory.appendingPathComponent("stdout.log")
        let stderrURL = requestDirectory.appendingPathComponent("stderr.log")
        try Data().write(to: stdoutURL, options: .withoutOverwriting)
        try Data().write(to: stderrURL, options: .withoutOverwriting)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            process = nil
        }

        let launchedAt = Date()
        let task = Process()
        task.executableURL = executableURL
        task.arguments = postprocessArguments(for: request, profileURL: profileURL)
        task.environment = ProcessInfo.processInfo.environment.merging([
            "HF_HUB_OFFLINE": "1",
        ]) { current, _ in current }
        task.standardOutput = stdout
        task.standardError = stderr
        do {
            try task.run()
        } catch {
            throw TranscriptionRunnerError.launchFailed(error.localizedDescription)
        }
        process = task
        let liveness = TranscriptionProcessLiveness(task)
        progress(ExistingRunPostprocessProgress(
            operation: request.operation,
            elapsedS: 0,
            modelID: request.postprocess.requestedModelID,
            message: nil
        ))

        var cancellationInterruptedChild = false
        while task.isRunning {
            if cancelRequested || Task.isCancelled {
                cancelRequested = true
                cancellationInterruptedChild = true
                await terminate(task, liveness: liveness)
                break
            }
            progress(ExistingRunPostprocessProgress(
                operation: request.operation,
                elapsedS: max(0, Date().timeIntervalSince(launchedAt)),
                modelID: request.postprocess.requestedModelID,
                message: nil
            ))
            do {
                try await pollWait()
            } catch {
                cancelRequested = true
                if task.isRunning {
                    cancellationInterruptedChild = true
                    await terminate(task, liveness: liveness)
                }
                break
            }
        }
        if !cancellationInterruptedChild { task.waitUntilExit() }
        stdout.synchronizeFile()
        stderr.synchronizeFile()
        if cancellationInterruptedChild { throw CancellationError() }
        guard task.terminationStatus == 0 else {
            let message = try String(contentsOf: stderrURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionRunnerError.pipelineFailed(
                message.isEmpty
                    ? appString("The transcription engine exited with status \(task.terminationStatus).")
                    : message
            )
        }
        let output = try String(contentsOf: stdoutURL, encoding: .utf8)
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard lines.count == 1, lines[0].hasPrefix("/") else {
            throw TranscriptionRunnerError.resultInvalid
        }
        let derivedURL = URL(
            fileURLWithPath: lines[0],
            isDirectory: true
        ).standardizedFileURL
        let derivedRoot = request.sourceRunURL.appendingPathComponent(
            "derived",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let resolvedDerived = derivedURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = derivedRoot.path.hasSuffix("/")
            ? derivedRoot.path
            : derivedRoot.path + "/"
        guard resolvedDerived.path.hasPrefix(rootPrefix) else {
            throw TranscriptionRunnerError.resultInvalid
        }
        let manifest: DerivedManifest
        do {
            manifest = try JSONDecoder().decode(
                DerivedManifest.self,
                from: Data(contentsOf: derivedURL.appendingPathComponent("manifest.json"))
            )
        } catch {
            throw TranscriptionRunnerError.resultInvalid
        }
        guard manifest.derivedID == derivedURL.lastPathComponent,
              manifest.status == .succeeded,
              manifest.failure == nil,
              manifest.source.runID == request.sourceRunURL.lastPathComponent,
              manifest.operation.profileName == request.profile.cliProfile,
              manifest.operation.mode == request.operation,
              manifest.operation.targetLanguage == request.translationTargetLanguage
        else {
            throw TranscriptionRunnerError.resultInvalid
        }
        progress(ExistingRunPostprocessProgress(
            operation: request.operation,
            elapsedS: max(0, Date().timeIntervalSince(launchedAt)),
            modelID: manifest.postprocess?.modelID,
            message: nil
        ))
        return derivedURL
    }

    func cancel() {
        cancelRequested = true
    }

    private func terminate(_ task: Process, liveness: TranscriptionProcessLiveness) async {
        _ = await ProcessTerminator.terminate(
            processID: task.processIdentifier,
            isRunning: { liveness.process.isRunning },
            timing: terminationTiming
        )
    }

    private func arguments(
        for request: TranscriptionRequest,
        profileURL: URL
    ) -> [String] {
        var values = [
            "run",
            request.sourceURL.path,
            "--profile", request.profile.cliProfile,
            "--profiles", profileURL.path,
            "--output-root", request.outputRoot.path,
        ]
        if let glossaryURL = request.glossaryURL {
            values += ["--glossary", glossaryURL.path]
        }
        return values
    }

    private func postprocessArguments(
        for request: ExistingRunPostprocessRequest,
        profileURL: URL
    ) -> [String] {
        var values = [
            "postprocess",
            request.sourceRunURL.path,
            "--profile", request.profile.cliProfile,
            "--profiles", profileURL.path,
        ]
        if let glossaryURL = request.glossaryURL {
            values += ["--glossary", glossaryURL.path]
        }
        return values
    }

    private func createRequestDirectory() throws -> URL {
        try FileManager.default.createDirectory(
            at: requestsRoot,
            withIntermediateDirectories: true
        )
        let directory = requestsRoot.appendingPathComponent(
            "request-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }

    private func writeProfile(
        for request: TranscriptionRequest,
        to url: URL
    ) throws {
        struct Diarization: Encodable {
            var enabled = true
            var backend: String
        }
        struct Profile: Encodable {
            var name: String
            var asrBackend: String
            var languagePin: String
            var diarization: Diarization
            var postprocess: String
            var postprocessMode: String
            var targetLanguage: String?

            enum CodingKeys: String, CodingKey {
                case name, diarization, postprocess
                case asrBackend = "asr_backend"
                case languagePin = "language_pin"
                case postprocessMode = "postprocess_mode"
                case targetLanguage = "target_language"
            }
        }
        struct Document: Encodable {
            var schemaVersion = "1.0.0"
            var profiles: [Profile]

            enum CodingKeys: String, CodingKey {
                case profiles
                case schemaVersion = "schema_version"
            }
        }
        let profile = Profile(
            name: request.profile.cliProfile,
            asrBackend: request.profile.asrBackend,
            languagePin: request.profile.languagePin,
            diarization: Diarization(backend: request.profile.diarizationBackend),
            postprocess: request.postprocess.rawValue,
            postprocessMode: request.postprocessMode.rawValue,
            targetLanguage: request.postprocess == .none
                || request.postprocessMode == .correction
                ? nil
                : request.translationTargetLanguage
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(profiles: [profile]))
            .write(to: url, options: .withoutOverwriting)
    }

    private func writeProfile(
        for request: ExistingRunPostprocessRequest,
        to url: URL
    ) throws {
        struct Diarization: Encodable {
            var enabled = true
            var backend: String
        }
        struct Profile: Encodable {
            var name: String
            var asrBackend: String
            var languagePin: String
            var diarization: Diarization
            var postprocess: String
            var postprocessMode: String
            var targetLanguage: String?

            enum CodingKeys: String, CodingKey {
                case name, diarization, postprocess
                case asrBackend = "asr_backend"
                case languagePin = "language_pin"
                case postprocessMode = "postprocess_mode"
                case targetLanguage = "target_language"
            }
        }
        struct Document: Encodable {
            var schemaVersion = "1.0.0"
            var profiles: [Profile]

            enum CodingKeys: String, CodingKey {
                case profiles
                case schemaVersion = "schema_version"
            }
        }
        let profile = Profile(
            name: request.profile.cliProfile,
            asrBackend: request.profile.asrBackend,
            languagePin: request.profile.languagePin,
            diarization: Diarization(backend: request.profile.diarizationBackend),
            postprocess: request.postprocess.rawValue,
            postprocessMode: request.operation.rawValue,
            targetLanguage: request.operation == .translation
                ? request.translationTargetLanguage
                : nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(profiles: [profile]))
            .write(to: url, options: .withoutOverwriting)
    }

    private func childDirectories(of root: URL) throws -> Set<URL> {
        let values = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return Set(try values.filter {
            try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.map(\.standardizedFileURL))
    }

    private func readManifest(at runURL: URL) throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: runURL.appendingPathComponent("manifest.json"))
        )
    }

    private func resolveRunURL(
        for request: TranscriptionRequest,
        launchInput: TranscriptionInputIdentity,
        stdoutURL: URL,
        directoriesBefore: Set<URL>
    ) throws -> URL {
        if let reported = try reportedRunURL(from: stdoutURL) {
            return try validate(reported, for: request, launchInput: launchInput)
        }

        let current = try childDirectories(of: request.outputRoot)
        let candidates = current.subtracting(directoriesBefore)
        guard !candidates.isEmpty else {
            throw TranscriptionRunnerError.resultMissing
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            throw TranscriptionRunnerError.resultAmbiguous
        }
        return try validate(candidate, for: request, launchInput: launchInput)
    }

    private func reportedRunURL(from stdoutURL: URL) throws -> URL? {
        let output = try String(contentsOf: stdoutURL, encoding: .utf8)
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        guard lines.count == 1, lines[0].hasPrefix("/") else {
            throw TranscriptionRunnerError.resultInvalid
        }
        return URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL
    }

    @discardableResult
    private func validate(
        _ candidate: URL,
        for request: TranscriptionRequest,
        launchInput: TranscriptionInputIdentity
    ) throws -> URL {
        let root = request.outputRoot.standardizedFileURL.resolvingSymlinksInPath()
        let runURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard runURL.path.hasPrefix(rootPrefix) else {
            throw TranscriptionRunnerError.resultInvalid
        }

        let manifest: Manifest
        do {
            manifest = try readManifest(at: runURL)
        } catch {
            throw TranscriptionRunnerError.resultInvalid
        }
        guard manifest.input.fileName == launchInput.fileName,
              manifest.runID == runURL.lastPathComponent,
              manifest.input.sizeBytes == launchInput.sizeBytes,
              manifest.input.sha256 == launchInput.sha256
        else {
            throw TranscriptionRunnerError.resultInvalid
        }
        return runURL
    }

    private func inputIdentity(at url: URL) throws -> TranscriptionInputIdentity {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var sizeBytes = 0
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            sizeBytes += data.count
            digest.update(data: data)
        }
        return TranscriptionInputIdentity(
            fileName: url.lastPathComponent,
            sizeBytes: sizeBytes,
            sha256: digest.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func snapshot(
        for manifest: Manifest,
        runURL: URL,
        launchedAt: Date,
        requestedPostprocessModelID: String?,
        accumulator: inout RunProgressAccumulator
    ) -> RunProgressSnapshot {
        let message = manifest.coverage.message ?? manifest.failure?.message
        let stage: PipelineStage
        if manifest.status == .succeeded {
            stage = .complete
        } else if manifest.failure?.code != "RUN_INCOMPLETE" {
            stage = .failed
        } else if message?.contains("preprocessing") == true
                    || message?.contains("chunk plan") == true {
            stage = .preprocessing
        } else if message?.contains("diarization") == true {
            stage = .diarization
        } else if message?.contains("ASR chunk") == true {
            stage = manifest.coverage.chunksCompleted == manifest.coverage.chunksPlanned
                ? .merge
                : .asr
        } else if message?.contains("postprocess") == true {
            stage = .postprocess
        } else {
            stage = .preparing
        }
        let elapsedS = RunProgressAccumulator.sanitizedElapsed(
            Date().timeIntervalSince(launchedAt)
        ) ?? 0
        let projection = RunProgressSnapshot.modelProjection(
            for: stage,
            models: manifest.models,
            postprocess: manifest.postprocess,
            requestedPostprocessModelID: requestedPostprocessModelID
        )
        return RunProgressSnapshot(
            stage: stage,
            completedChunks: manifest.coverage.chunksCompleted,
            plannedChunks: manifest.coverage.chunksPlanned,
            elapsedS: elapsedS,
            stageElapsedS: accumulator.observe(stage: stage, atElapsedS: elapsedS),
            modelID: projection.modelID,
            modelIDIsProvisional: projection.isProvisional,
            message: message,
            runURL: runURL
        )
    }

    private static func resolveExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MACCHERONI_CLI_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let current = Bundle.main.executableURL {
            let sibling = current.deletingLastPathComponent().appendingPathComponent("maccheroni")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [".build/release/maccheroni", ".build/debug/maccheroni"] {
            let candidate = repository.appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

struct RunProgressAccumulator: Sendable {
    private(set) var stageElapsedS: [PipelineStage: Double] = [:]
    private var currentStage: PipelineStage?
    private var lastElapsedS: Double?

    mutating func observe(
        stage: PipelineStage,
        atElapsedS elapsedS: Double
    ) -> [PipelineStage: Double] {
        let currentElapsedS = Self.sanitizedElapsed(elapsedS)
        if currentStage != stage {
            advanceCurrentStage(to: currentElapsedS)
            currentStage = stage
            lastElapsedS = currentElapsedS
            stageElapsedS[stage, default: 0] += 0
        } else {
            advanceCurrentStage(to: currentElapsedS)
        }
        return stageElapsedS
    }

    static func sanitizedElapsed(_ elapsedS: Double) -> Double? {
        guard elapsedS.isFinite else { return nil }
        return max(0, elapsedS)
    }

    private mutating func advanceCurrentStage(to currentElapsedS: Double?) {
        guard let stage = currentStage,
              let previousElapsedS = lastElapsedS,
              let currentElapsedS
        else { return }

        stageElapsedS[stage, default: 0] += max(0, currentElapsedS - previousElapsedS)
        lastElapsedS = max(previousElapsedS, currentElapsedS)
    }
}

private final class TranscriptionProcessLiveness: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}
