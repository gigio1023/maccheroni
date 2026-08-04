import Foundation
import MaccheroniCore

private let postprocessResourcesBundle = PackagedResourceBundle.resolve(
    named: "Maccheroni_MaccheroniPostprocess"
) { Bundle.module }

public enum CodexAvailability: Equatable, Sendable {
    case unavailable
    case unauthenticated(version: String)
    case authenticationUnknown(version: String)
    case authenticated(version: String)

    public var version: String {
        switch self {
        case .unavailable: "unavailable"
        case let .unauthenticated(version),
             let .authenticationUnknown(version),
             let .authenticated(version):
            version
        }
    }

    public var isInstalled: Bool {
        self != .unavailable
    }

    public var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }

    public var authenticationCheckFailed: Bool {
        if case .authenticationUnknown = self { return true }
        return false
    }
}

public struct CodexPostprocessBackend: PostprocessBackend, TranslationBackend, Sendable {
    public static let modelName = "gpt-5.6-sol"
    public static let defaultBatchPolicy = PostprocessBatchPolicy(
        maximumPromptUTF8Bytes: 16_384,
        maximumSegmentsPerBatch: 32,
        maximumOutputTokens: nil,
        outputTokenLimitStatus: .serviceManagedUnavailable,
        outputTokenPlanningBudget: 4_096,
        outputTokensPerInputUTF8BytePermille: 2_000,
        baseOutputTokenReserve: 32,
        perSegmentOutputTokenReserve: 96
    )

    public let codexExecutableURL: URL?
    public let codexVersion: String
    public let selectedModelName: String
    public let availability: CodexAvailability
    public let schemaURL: URL
    public let appServerExecutor: any CodexAppServerExecuting
    public let batchPolicy: PostprocessBatchPolicy
    private let temporaryDirectory: URL

    /// Bypassing the GUI PATH requires an absolute executable path, so a failed lookup means not installed, with no fallback.
    public static var defaultExecutableURL: URL? {
        CodexExecutableLocator.resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fallbackDirectories: CodexExecutableLocator.standardFallbackDirectories
        )
    }

    public init(
        codexExecutableURL: URL? = CodexPostprocessBackend.defaultExecutableURL,
        codexVersion: String? = nil,
        selectedModelName: String = Self.modelName,
        availability: CodexAvailability? = nil,
        schemaURL: URL? = nil,
        batchPolicy: PostprocessBatchPolicy = Self.defaultBatchPolicy,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        appServerExecutor: any CodexAppServerExecuting = FoundationCodexAppServerExecutor()
    ) {
        self.codexExecutableURL = codexExecutableURL
        let resolvedAvailability = availability
            ?? codexVersion.map(CodexAvailability.authenticated(version:))
            ?? codexExecutableURL.map {
                CodexAvailability.unauthenticated(
                    version: Self.detectVersion(executableURL: $0)
                )
            }
            ?? .unavailable
        self.availability = resolvedAvailability
        self.codexVersion = codexVersion
            ?? resolvedAvailability.version
        self.selectedModelName = selectedModelName
        self.schemaURL = schemaURL ?? postprocessResourcesBundle.url(
            forResource: "postprocess-output.schema", withExtension: "json"
        ) ?? temporaryDirectory.appendingPathComponent("missing-postprocess-output.schema.json")
        self.batchPolicy = batchPolicy
        self.temporaryDirectory = temporaryDirectory
        self.appServerExecutor = appServerExecutor
    }

    /// Detects installation/version and ChatGPT subscription authentication through app-server.
    public static func detectAvailability(
        executableURL: URL? = CodexPostprocessBackend.defaultExecutableURL,
        timeoutS: TimeInterval = 5,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        appServerExecutor: any CodexAppServerExecuting = FoundationCodexAppServerExecutor()
    ) async -> CodexAvailability {
        guard let executableURL else { return .unavailable }
        let version = detectVersion(
            executableURL: executableURL,
            timeoutS: timeoutS
        )
        guard version != "unavailable" else { return .unavailable }
        let workspace: URL
        do {
            workspace = try makeEmptyDirectory(
                in: temporaryDirectory,
                prefix: "maccheroni-codex-auth-"
            )
        } catch {
            return .authenticationUnknown(version: version)
        }
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            let state = try await appServerExecutor.accountState(
                executableURL: executableURL,
                workspaceURL: workspace,
                timeoutS: timeoutS
            )
            return state == .chatGPT
                ? .authenticated(version: version)
                : .unauthenticated(version: version)
        } catch {
            return .authenticationUnknown(version: version)
        }
    }

    /// Allows the production caller to record the installed CLI version while tests inject a value.
    public static func detectVersion(
        executableURL: URL,
        timeoutS: TimeInterval = 5
    ) -> String {
        guard let result = runCommand(
            executableURL: executableURL,
            arguments: ["--version"],
            timeoutS: timeoutS
        ), result.status == 0 else {
            return "unavailable"
        }
        let value = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unavailable" : value
    }

    public var id: PostprocessBackendID { .codex }
    public var model: ModelDescriptor? { nil }
    public var manifestPostprocess: ManifestPostprocess {
        ManifestPostprocess(
            backend: BackendDescriptor(name: "codex-app-server", version: codexVersion),
            modelID: selectedModelName
        )
    }

    public func propose(prompt: String) async throws -> PostprocessBackendResponse {
        let data = try await execute(
            prompt: prompt,
            schema: .packaged(schemaURL)
        )
        return PostprocessBackendResponse(
            proposals: try decodeProposals(data: data, backend: "codex"),
            responseUTF8Bytes: data.count
        )
    }

    public func translate(prompt: String) async throws -> TranslationBackendResponse {
        let data = try await execute(
            prompt: prompt,
            schema: .generated(
                name: "translation-output.schema.json",
                data: Self.translationSchema
            )
        )
        return TranslationBackendResponse(
            translations: try decodeTranslations(data: data, backend: "codex"),
            responseUTF8Bytes: data.count
        )
    }

    private enum SchemaSource {
        case packaged(URL)
        case generated(name: String, data: Data)
    }

    private func execute(prompt: String, schema: SchemaSource) async throws -> Data {
        guard let codexExecutableURL else {
            throw PostprocessError.launchFailed("codex CLI executable was not found")
        }
        let workspace = try makeEmptyDirectory(prefix: "maccheroni-codex-")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let schemaData: Data
        switch schema {
        case let .packaged(url):
            do {
                schemaData = try Data(contentsOf: url)
            } catch {
                throw PostprocessError.malformedOutput(
                    "Codex output schema could not be read"
                )
            }
        case let .generated(name, data):
            _ = name
            schemaData = data
        }
        return try await appServerExecutor.run(CodexAppServerInvocation(
            executableURL: codexExecutableURL,
            model: selectedModelName,
            prompt: prompt,
            outputSchema: schemaData,
            workspaceURL: workspace
        ))
    }

    private func makeEmptyDirectory(prefix: String) throws -> URL {
        do {
            return try Self.makeEmptyDirectory(in: temporaryDirectory, prefix: prefix)
        } catch {
            throw PostprocessError.launchFailed("cannot create isolated Codex workspace")
        }
    }

    private static func makeEmptyDirectory(in root: URL, prefix: String) throws -> URL {
        let path = root.appendingPathComponent(
            "\(prefix)\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: false
        )
        return path
    }

    private struct CommandResult {
        var status: Int32
        var standardOutput: Data
    }

    private final class CommandLiveness: @unchecked Sendable {
        let process: Process

        init(_ process: Process) {
            self.process = process
        }
    }

    private static func runCommand(
        executableURL: URL,
        arguments: [String],
        timeoutS: TimeInterval
    ) -> CommandResult? {
        guard timeoutS > 0 else { return nil }
        let process = Process()
        let output = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
            let liveness = CommandLiveness(process)
            let milliseconds = Int((timeoutS * 1_000).rounded(.up))
            guard completion.wait(
                timeout: .now() + .milliseconds(milliseconds)
            ) == .success else {
                let terminated = DispatchSemaphore(value: 0)
                let processID = process.processIdentifier
                Task.detached(priority: .userInitiated) {
                    _ = await ProcessTerminator.terminate(
                        processID: processID,
                        isRunning: { liveness.process.isRunning },
                        timing: ProcessTerminationTiming(
                            gracePeriodS: 0.1,
                            pollIntervalS: 0.01,
                            exitWaitS: 0.5
                        )
                    )
                    terminated.signal()
                }
                _ = terminated.wait(timeout: .now() + .seconds(2))
                return nil
            }
            return CommandResult(
                status: process.terminationStatus,
                standardOutput: output.fileHandleForReading.readDataToEndOfFile()
            )
        } catch {
            return nil
        }
    }

    private static let translationSchema = Data(#"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "Maccheroni translation output",
      "type": "object",
      "additionalProperties": false,
      "required": ["translations"],
      "properties": {
        "translations": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["segment_index", "translated_text"],
            "properties": {
              "segment_index": { "type": "integer", "minimum": 0 },
              "translated_text": { "type": "string", "minLength": 1 }
            }
          }
        }
      }
    }
    """#.utf8)
}

/// Per the run-layout contract, manifests keep no personal absolute paths and cap failure-message length.
enum SubprocessFailureMessage {
    static let maximumUTF8Bytes = 512
    static let truncationMarker = "...(truncated)"
    static let redactedPathMarker = "<redacted-path>"

    static func sanitized(standardError: Data) -> String {
        let text = String(decoding: standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(redactingAbsolutePaths(text))
    }

    private static func redactingAbsolutePaths(_ text: String) -> String {
        var result = ""
        var token = ""
        for character in text {
            if character.isWhitespace {
                result += redacted(token)
                result.append(character)
                token = ""
            } else {
                token.append(character)
            }
        }
        return result + redacted(token)
    }

    private static func redacted(_ token: String) -> String {
        token.hasPrefix("/") ? redactedPathMarker : token
    }

    private static func truncated(_ text: String) -> String {
        guard text.utf8.count > maximumUTF8Bytes else { return text }
        let budget = maximumUTF8Bytes - truncationMarker.utf8.count
        var head = ""
        var usedBytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard usedBytes + size <= budget else { break }
            head.append(character)
            usedBytes += size
        }
        return head + truncationMarker
    }
}

enum CodexExecutableLocator {
    static let standardFallbackDirectories = [
        URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
    ]

    static func resolve(
        environment: [String: String],
        homeDirectory: URL,
        fallbackDirectories: [URL]
    ) -> URL? {
        let pathDirectories = environment["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        let homeDirectories = [
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".bun/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".volta/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".npm-global/bin", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/pnpm", isDirectory: true),
        ]
        var seen = Set<String>()
        for directory in pathDirectories + fallbackDirectories + homeDirectories {
            let candidate = directory
                .appendingPathComponent("codex", isDirectory: false)
                .standardizedFileURL
            guard seen.insert(candidate.path).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

public struct LocalPostprocessRuntime: Sendable {
    public var pythonExecutableURL: URL
    public var runnerURL: URL
    public var modelSnapshotURL: URL

    public init(pythonExecutableURL: URL, runnerURL: URL, modelSnapshotURL: URL) {
        self.pythonExecutableURL = pythonExecutableURL
        self.runnerURL = runnerURL
        self.modelSnapshotURL = modelSnapshotURL
    }

    public static var local: LocalPostprocessRuntime {
        localRuntime(
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func localRuntime(environment: [String: String], home: URL) -> LocalPostprocessRuntime {
        let benchmarkCache = environment["MACCHERONI_BENCHMARK_CACHE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(
            "Library/Caches/Maccheroni/benchmarks",
            isDirectory: true
        )
        let huggingFaceHome = environment["HF_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? home.appendingPathComponent(".cache/huggingface", isDirectory: true)
        let cache = environment["MACCHERONI_POSTPROCESS_MODEL_PATH"].map(URL.init(fileURLWithPath:))
            ?? huggingFaceHome.appendingPathComponent(
                "hub/models--mlx-community--gemma-4-12B-it-qat-4bit/snapshots/e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6",
                isDirectory: true
            )
        let runner = environment["MACCHERONI_POSTPROCESS_RUNNER"].map(URL.init(fileURLWithPath:))
            ?? postprocessResourcesBundle.url(
                forResource: "maccheroni_postprocess_runner",
                withExtension: "py"
            )
            ?? cache.appendingPathComponent("missing-maccheroni-postprocess-runner.py")
        let python = environment["MACCHERONI_POSTPROCESS_PYTHON"].map(URL.init(fileURLWithPath:))
            ?? benchmarkCache.appendingPathComponent("venvs/mlx-vlm/bin/python")
        return LocalPostprocessRuntime(pythonExecutableURL: python, runnerURL: runner, modelSnapshotURL: cache)
    }
}

public struct LocalPostprocessBackend: PostprocessBackend, TranslationBackend, Sendable {
    public static let descriptor = BackendDescriptor(name: "mlx-vlm", version: "0.6.6")
    public static let pinnedModel = ModelDescriptor(
        role: .postprocess,
        hfModelID: "mlx-community/gemma-4-12B-it-qat-4bit",
        revision: "e70c6b3ba0979b3357dcd2f223ad8bde7787a6b6",
        quantization: "qat-int4"
    )
    public static let defaultBatchPolicy = PostprocessBatchPolicy(
        maximumPromptUTF8Bytes: 2_048,
        maximumSegmentsPerBatch: 8,
        maximumOutputTokens: 1_024,
        outputTokenLimitStatus: .configured,
        outputTokenPlanningBudget: 768,
        outputTokensPerInputUTF8BytePermille: 2_000,
        baseOutputTokenReserve: 32,
        perSegmentOutputTokenReserve: 96
    )

    public let runtime: LocalPostprocessRuntime
    public let executor: any SubprocessExecuting
    public let batchPolicy: PostprocessBatchPolicy

    public init(
        runtime: LocalPostprocessRuntime = .local,
        batchPolicy: PostprocessBatchPolicy = Self.defaultBatchPolicy,
        executor: any SubprocessExecuting = FoundationSubprocessExecutor()
    ) {
        precondition(batchPolicy.maximumOutputTokens != nil)
        self.runtime = runtime
        self.batchPolicy = batchPolicy
        self.executor = executor
    }

    public var id: PostprocessBackendID { .local }
    public var model: ModelDescriptor? { Self.pinnedModel }
    public var manifestPostprocess: ManifestPostprocess {
        ManifestPostprocess(
            backend: Self.descriptor,
            modelID: Self.pinnedModel.hfModelID,
            modelRevision: Self.pinnedModel.revision,
            quantization: Self.pinnedModel.quantization
        )
    }

    public func propose(prompt: String) async throws -> PostprocessBackendResponse {
        let data = try await execute(prompt: prompt, mode: "correction")
        return PostprocessBackendResponse(
            proposals: try decodeProposals(data: data, backend: "local"),
            responseUTF8Bytes: data.count
        )
    }

    public func translate(prompt: String) async throws -> TranslationBackendResponse {
        let data = try await execute(prompt: prompt, mode: "translation")
        return TranslationBackendResponse(
            translations: try decodeTranslations(data: data, backend: "local"),
            responseUTF8Bytes: data.count
        )
    }

    private func execute(prompt: String, mode: String) async throws -> Data {
        let maximumOutputTokens = batchPolicy.maximumOutputTokens ?? 0
        let result = try await executor.run(SubprocessInvocation(
            executableURL: runtime.pythonExecutableURL,
            arguments: [
                runtime.runnerURL.path,
                "--model-path", runtime.modelSnapshotURL.path,
                "--mode", mode,
                "--max-tokens", String(maximumOutputTokens),
            ],
            standardInput: Data(prompt.utf8),
            environment: ["HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"],
            timeoutS: 900
        ))
        guard result.exitStatus == 0 else {
            throw PostprocessError.backendFailed(
                "local postprocess runner exited \(result.exitStatus): "
                    + SubprocessFailureMessage.sanitized(standardError: result.standardError)
            )
        }
        return result.standardOutput
    }
}

private struct ProposalEnvelope: Codable {
    var proposals: [PostprocessProposal]
}

private struct TranslationEnvelope: Codable {
    var translations: [SegmentTranslation]
}

private func decodeProposals(data: Data, backend: String) throws -> [PostprocessProposal] {
    do {
        try validateProposalEnvelope(data)
        return try JSONDecoder().decode(ProposalEnvelope.self, from: data).proposals
    } catch let error as PostprocessError {
        throw error
    } catch {
        throw PostprocessError.malformedOutput("\(backend) backend output is not schema-compatible JSON: \(error.localizedDescription)")
    }
}

private func decodeTranslations(data: Data, backend: String) throws -> [SegmentTranslation] {
    do {
        try validateTranslationEnvelope(data)
        return try JSONDecoder().decode(TranslationEnvelope.self, from: data).translations
    } catch let error as PostprocessError {
        throw error
    } catch {
        throw PostprocessError.malformedOutput("\(backend) backend output is not schema-compatible JSON: \(error.localizedDescription)")
    }
}

private func validateProposalEnvelope(_ data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let envelope = object as? [String: Any], Set(envelope.keys) == ["proposals"],
          let proposals = envelope["proposals"] as? [[String: Any]]
    else {
        throw PostprocessError.malformedOutput("output must contain only a proposals array")
    }
    let requiredKeys: Set<String> = ["segment_index", "replacement_text", "disposition", "reason"]
    for proposal in proposals where Set(proposal.keys) != requiredKeys {
        throw PostprocessError.malformedOutput("each proposal must contain only schema fields")
    }
}

private func validateTranslationEnvelope(_ data: Data) throws {
    let object = try JSONSerialization.jsonObject(with: data)
    guard let envelope = object as? [String: Any], Set(envelope.keys) == ["translations"],
          let translations = envelope["translations"] as? [[String: Any]]
    else {
        throw PostprocessError.malformedOutput("output must contain only a translations array")
    }
    let requiredKeys: Set<String> = ["segment_index", "translated_text"]
    for translation in translations where Set(translation.keys) != requiredKeys {
        throw PostprocessError.malformedOutput("each translation must contain only schema fields")
    }
}
