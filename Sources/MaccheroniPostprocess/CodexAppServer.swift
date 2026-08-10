import Darwin
import Foundation
import MaccheroniCore

public enum CodexAppServerAccountState: Equatable, Sendable {
    case signedOut
    case chatGPT
    case unsupported
}

public struct CodexAppServerInvocation: Sendable {
    public var executableURL: URL
    public var model: String
    public var prompt: String
    public var outputSchema: Data
    public var workspaceURL: URL
    public var timeoutS: TimeInterval

    public init(
        executableURL: URL,
        model: String,
        prompt: String,
        outputSchema: Data,
        workspaceURL: URL,
        timeoutS: TimeInterval = 600
    ) {
        self.executableURL = executableURL
        self.model = model
        self.prompt = prompt
        self.outputSchema = outputSchema
        self.workspaceURL = workspaceURL
        self.timeoutS = timeoutS
    }
}

public protocol CodexAppServerExecuting: Sendable {
    func accountState(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval
    ) async throws -> CodexAppServerAccountState

    func run(_ invocation: CodexAppServerInvocation) async throws -> Data
}

public struct FoundationCodexAppServerExecutor: CodexAppServerExecuting {
    private let terminationTiming: ProcessTerminationTiming
    private let environment: [String: String]
    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let linkAuthenticationFile: @Sendable (URL, URL) throws -> Void

    public init(terminationTiming: ProcessTerminationTiming = .default) {
        self.terminationTiming = terminationTiming
        self.environment = ProcessInfo.processInfo.environment
        self.homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.temporaryDirectory = FileManager.default.temporaryDirectory
        self.linkAuthenticationFile = CodexAuthenticationBridge.createHardLink
    }

    init(
        terminationTiming: ProcessTerminationTiming = .default,
        environment: [String: String],
        homeDirectory: URL,
        temporaryDirectory: URL,
        linkAuthenticationFile: @escaping @Sendable (URL, URL) throws -> Void = CodexAuthenticationBridge.createHardLink
    ) {
        self.terminationTiming = terminationTiming
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.linkAuthenticationFile = linkAuthenticationFile
    }

    public func accountState(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval
    ) async throws -> CodexAppServerAccountState {
        let timing = terminationTiming
        let environment = environment
        let homeDirectory = homeDirectory
        let temporaryDirectory = temporaryDirectory
        let linkAuthenticationFile = linkAuthenticationFile
        let task = Task.detached {
            let session = try CodexAppServerSession(
                executableURL: executableURL,
                workspaceURL: workspaceURL,
                timeoutS: timeoutS,
                terminationTiming: timing,
                parentEnvironment: environment,
                parentHomeDirectory: homeDirectory,
                temporaryDirectory: temporaryDirectory,
                linkAuthenticationFile: linkAuthenticationFile
            )
            return try await session.perform {
                try session.initialize()
                return try session.readAccountState()
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func run(_ invocation: CodexAppServerInvocation) async throws -> Data {
        let timing = terminationTiming
        let environment = environment
        let homeDirectory = homeDirectory
        let temporaryDirectory = temporaryDirectory
        let linkAuthenticationFile = linkAuthenticationFile
        let task = Task.detached {
            let session = try CodexAppServerSession(
                executableURL: invocation.executableURL,
                workspaceURL: invocation.workspaceURL,
                timeoutS: invocation.timeoutS,
                terminationTiming: timing,
                parentEnvironment: environment,
                parentHomeDirectory: homeDirectory,
                temporaryDirectory: temporaryDirectory,
                linkAuthenticationFile: linkAuthenticationFile
            )
            return try await session.perform {
                try session.initialize()
                guard try session.readAccountState() == .chatGPT else {
                    throw PostprocessError.authenticationRequired(
                        "Codex requires a ChatGPT subscription sign-in. Run `codex login` in Terminal, then try again, or select Local."
                    )
                }
                return try session.runTurn(invocation)
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private final class CodexAppServerSession: @unchecked Sendable {
    private static let officialChatGPTBaseURL = "https://chatgpt.com/backend-api/"
    private static let strippedCredentialEnvironmentKeys = [
        "CODEX_ACCESS_TOKEN",
        "CODEX_API_KEY",
        "OPENAI_API_KEY",
    ]
    private let process: Process
    private let input: FileHandle
    private let output: FileHandle
    private let errorOutput: FileHandle
    private let errorURL: URL
    private let scratchURL: URL
    private let authenticationBridge: CodexAuthenticationBridge
    private let channel: CodexJSONLChannel
    private let deadline: Date
    private let timeoutS: TimeInterval
    private let terminationTiming: ProcessTerminationTiming
    private var nextRequestID = 1

    init(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval,
        terminationTiming: ProcessTerminationTiming,
        parentEnvironment: [String: String],
        parentHomeDirectory: URL,
        temporaryDirectory: URL,
        linkAuthenticationFile: @Sendable (URL, URL) throws -> Void
    ) throws {
        guard timeoutS > 0 else {
            throw PostprocessError.backendFailed("codex app server timeout must be positive")
        }
        self.timeoutS = timeoutS
        self.deadline = Date().addingTimeInterval(timeoutS)
        self.terminationTiming = terminationTiming
        self.scratchURL = temporaryDirectory.appendingPathComponent(
            "maccheroni-codex-app-server-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: scratchURL,
                withIntermediateDirectories: false
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scratchURL.path
            )
        } catch {
            try? FileManager.default.removeItem(at: scratchURL)
            throw PostprocessError.launchFailed(
                "cannot create Codex app server scratch directory"
            )
        }

        do {
            self.authenticationBridge = try CodexAuthenticationBridge.prepare(
                parentEnvironment: parentEnvironment,
                parentHomeDirectory: parentHomeDirectory,
                scratchURL: scratchURL,
                linkAuthenticationFile: linkAuthenticationFile
            )
        } catch {
            try? FileManager.default.removeItem(at: scratchURL)
            throw Self.authenticationIsolationFailure()
        }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        self.input = standardInput.fileHandleForWriting
        self.output = standardOutput.fileHandleForReading
        self.errorURL = scratchURL.appendingPathComponent("stderr")
        do {
            try Data().write(to: errorURL, options: .withoutOverwriting)
            self.errorOutput = try FileHandle(forWritingTo: errorURL)
        } catch {
            do {
                try FileManager.default.removeItem(at: scratchURL)
            } catch {
                throw Self.authenticationIsolationFailure()
            }
            throw PostprocessError.launchFailed(
                "cannot prepare Codex app server diagnostics"
            )
        }
        self.channel = CodexJSONLChannel(handle: output)
        self.process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "app-server",
            "-c", #"openai_base_url="""#,
            "-c", #"chatgpt_base_url="https://chatgpt.com/backend-api/""#,
            "-c", #"cli_auth_credentials_store="file""#,
            "--listen", "stdio://",
        ]
        var environment = parentEnvironment
        for key in Self.strippedCredentialEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = authenticationBridge.isolatedHomeURL.path
        process.environment = environment
        process.currentDirectoryURL = workspaceURL
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = errorOutput
        guard Darwin.fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            channel.finish()
            try? input.close()
            try? output.close()
            try? errorOutput.close()
            try? FileManager.default.removeItem(at: scratchURL)
            throw PostprocessError.launchFailed(
                "could not configure Codex app server input"
            )
        }
        do {
            try process.run()
        } catch {
            channel.finish()
            try? input.close()
            try? output.close()
            try? errorOutput.close()
            do {
                try FileManager.default.removeItem(at: scratchURL)
            } catch {
                throw Self.authenticationIsolationFailure()
            }
            throw PostprocessError.launchFailed(
                "could not launch codex app server"
            )
        }
    }

    func initialize() throws {
        _ = try request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "maccheroni",
                    "title": "Maccheroni",
                    "version": "1",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ]
        )
        try notify(method: "initialized", params: [:])
    }

    func readAccountState() throws -> CodexAppServerAccountState {
        let result = try request(
            method: "account/read",
            params: ["refreshToken": false]
        )
        guard let object = result as? [String: Any] else {
            throw protocolFailure("account/read returned no result object")
        }
        guard let account = object["account"] else { return .signedOut }
        if account is NSNull { return .signedOut }
        guard let accountObject = account as? [String: Any],
              let type = accountObject["type"] as? String else {
            throw protocolFailure("account/read returned an invalid account")
        }
        return type == "chatgpt" ? .chatGPT : .unsupported
    }

    func runTurn(_ invocation: CodexAppServerInvocation) throws -> Data {
        let schemaValue: Any
        do {
            schemaValue = try JSONSerialization.jsonObject(with: invocation.outputSchema)
        } catch {
            throw PostprocessError.malformedOutput("Codex output schema is invalid JSON")
        }
        guard schemaValue is [String: Any] else {
            throw PostprocessError.malformedOutput("Codex output schema must be a JSON object")
        }
        let inheritedMCPServerNames = try readInheritedMCPServerNames(
            workspaceURL: invocation.workspaceURL
        )
        try assertNoManagedToolRequirements()
        let defaultReasoningEffort = try readDefaultReasoningEffort(
            model: invocation.model
        )

        let threadResult = try request(
            method: "thread/start",
            params: [
                "model": invocation.model,
                "modelProvider": "openai",
                "cwd": invocation.workspaceURL.path,
                "approvalPolicy": "never",
                "sandbox": "read-only",
                "serviceName": "Maccheroni",
                "baseInstructions": "",
                "developerInstructions": Self.developerInstructions,
                "config": Self.boundedThreadConfig(
                    inheritedMCPServerNames: inheritedMCPServerNames,
                    reasoningEffort: defaultReasoningEffort
                ),
                "environments": [],
                "dynamicTools": [],
                "selectedCapabilityRoots": [],
                "ephemeral": true,
            ]
        )
        guard let threadObject = threadResult as? [String: Any],
              let thread = threadObject["thread"] as? [String: Any],
              let threadID = thread["id"] as? String,
              !threadID.isEmpty else {
            throw protocolFailure("thread/start returned no thread id")
        }
        try attestNoMCPServers(
            threadID: threadID,
            expectedDisabledNames: Set(inheritedMCPServerNames)
        )

        var collector = CodexTurnCollector(threadID: threadID)
        let turnResult = try request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": invocation.prompt]],
                "approvalPolicy": "never",
                "model": invocation.model,
                "effort": defaultReasoningEffort,
                "outputSchema": schemaValue,
            ],
            onNotification: { collector.consume($0) }
        )
        guard let turnObject = turnResult as? [String: Any],
              let turn = turnObject["turn"] as? [String: Any],
              let turnID = turn["id"] as? String,
              !turnID.isEmpty else {
            throw protocolFailure("turn/start returned no turn id")
        }
        collector.turnID = turnID
        collector.consumePending()
        do {
            while !collector.isTerminal {
                try pump(onNotification: { collector.consume($0) })
            }
        } catch {
            try? requestInterrupt(threadID: threadID, turnID: turnID)
            throw error
        }
        if collector.failure != nil {
            throw PostprocessError.backendFailed("codex app server turn failed")
        }
        guard let text = collector.finalText?.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines
        ),
              !text.isEmpty else {
            throw PostprocessError.missingOutput(
                "codex app server returned no schema-constrained final message"
            )
        }
        let data = Data(text.utf8)
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw PostprocessError.malformedOutput(
                "codex app server final message was not valid JSON"
            )
        }
        return data
    }

    private func readInheritedMCPServerNames(workspaceURL: URL) throws -> [String] {
        let result = try request(
            method: "config/read",
            params: ["cwd": workspaceURL.path, "includeLayers": true]
        )
        guard let object = result as? [String: Any],
              let config = object["config"] as? [String: Any],
              let layers = object["layers"] as? [[String: Any]] else {
            throw protocolFailure("config/read returned no effective config")
        }
        for layer in layers {
            guard let name = layer["name"] as? [String: Any],
                  let type = name["type"] as? String else {
                throw protocolFailure("config/read returned invalid effective config layers")
            }
            if Self.unoverridableConfigLayerTypes.contains(type) {
                throw protocolFailure("cannot override managed config layer \(type)")
            }
            guard Self.overridableConfigLayerTypes.contains(type) else {
                throw protocolFailure("unrecognized config layer \(type)")
            }
        }
        guard let servers = config["mcp_servers"] else { return [] }
        guard let serverObject = servers as? [String: Any] else {
            throw protocolFailure("config/read returned invalid mcp_servers")
        }
        return serverObject.keys.sorted()
    }

    private func assertNoManagedToolRequirements() throws {
        let result = try request(method: "configRequirements/read", params: nil)
        guard let object = result as? [String: Any],
              object.keys.contains("requirements") else {
            throw protocolFailure("configRequirements/read returned an invalid response")
        }
        guard let requirements = object["requirements"], !(requirements is NSNull) else {
            return
        }
        guard let requirementObject = requirements as? [String: Any] else {
            throw protocolFailure("configRequirements/read returned invalid requirements")
        }
        for key in ["hooks", "managedHooks", "managed_hooks"] {
            guard let hooks = requirementObject[key], !(hooks is NSNull) else { continue }
            guard let hookObject = hooks as? [String: Any] else {
                throw protocolFailure("configRequirements/read returned invalid managed hooks")
            }
            if Self.hasNonEmptyJSONValue(hookObject) {
                throw protocolFailure("cannot override managed hooks")
            }
        }
        if requirementObject["allowManagedHooksOnly"] as? Bool == true {
            throw protocolFailure("cannot override managed hooks")
        }
        if requirementObject["allowRemoteControl"] as? Bool == true {
            throw protocolFailure("cannot override managed remote control")
        }
        for key in ["computerUse", "browserUse", "network"] {
            guard let policy = requirementObject[key], !(policy is NSNull) else { continue }
            if Self.hasNonEmptyJSONValue(policy) {
                throw protocolFailure("cannot override managed \(key) policy")
            }
        }
        for key in ["featureRequirements", "feature_requirements"] {
            guard let features = requirementObject[key], !(features is NSNull) else { continue }
            guard let featureObject = features as? [String: Any] else {
                throw protocolFailure("configRequirements/read returned invalid feature requirements")
            }
            for (feature, rawValue) in featureObject {
                guard let enabled = rawValue as? Bool else {
                    throw protocolFailure("configRequirements/read returned invalid feature requirements")
                }
                if enabled, Self.restrictedFeatures.contains(feature) {
                    throw protocolFailure("cannot override required feature \(feature)")
                }
            }
        }
    }

    private func readDefaultReasoningEffort(model: String) throws -> String {
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            var params: [String: Any] = ["limit": 100, "includeHidden": true]
            if let cursor { params["cursor"] = cursor }
            let result = try request(method: "model/list", params: params)
            guard let object = result as? [String: Any],
                  let models = object["data"] as? [[String: Any]] else {
                throw protocolFailure("model/list returned an invalid response")
            }
            if let match = models.first(where: {
                $0["model"] as? String == model || $0["id"] as? String == model
            }) {
                guard let effort = match["defaultReasoningEffort"] as? String,
                      !effort.isEmpty else {
                    throw protocolFailure("model/list returned no default reasoning effort")
                }
                return effort
            }
            guard let next = object["nextCursor"], !(next is NSNull) else {
                throw protocolFailure("model/list did not contain the configured model")
            }
            guard let nextCursor = next as? String,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                throw protocolFailure("model/list returned an invalid cursor")
            }
            cursor = nextCursor
        }
    }

    private func attestNoMCPServers(
        threadID: String,
        expectedDisabledNames: Set<String>
    ) throws {
        var cursor: String?
        var seenCursors: Set<String> = []
        while true {
            var params: [String: Any] = [
                "threadId": threadID,
                "limit": 100,
                "detail": "toolsAndAuthOnly",
            ]
            if let cursor { params["cursor"] = cursor }
            let result = try request(method: "mcpServerStatus/list", params: params)
            guard let object = result as? [String: Any],
                  let data = object["data"] as? [Any] else {
                throw protocolFailure("mcpServerStatus/list returned an invalid attestation")
            }
            for rawEntry in data {
                guard let entry = rawEntry as? [String: Any],
                      let name = entry["name"] as? String,
                      expectedDisabledNames.contains(name),
                      entry.keys.contains("tools"),
                      entry.keys.contains("resources"),
                      entry.keys.contains("resourceTemplates"),
                      entry.keys.contains("serverInfo"),
                      Self.isEmptyOrMissing(entry["tools"]),
                      Self.isEmptyOrMissing(entry["resources"]),
                      Self.isEmptyOrMissing(entry["resourceTemplates"]),
                      Self.isEmptyOrMissing(entry["serverInfo"]) else {
                    throw protocolFailure(
                        "mcpServerStatus/list found an active or unexpected server"
                    )
                }
            }
            guard let next = object["nextCursor"], !(next is NSNull) else { return }
            guard let nextCursor = next as? String,
                  !nextCursor.isEmpty,
                  seenCursors.insert(nextCursor).inserted else {
                throw protocolFailure("mcpServerStatus/list returned an invalid cursor")
            }
            cursor = nextCursor
        }
    }

    private func requestInterrupt(threadID: String, turnID: String) throws {
        let requestID = nextRequestID
        nextRequestID += 1
        try write([
            "id": requestID,
            "method": "turn/interrupt",
            "params": ["threadId": threadID, "turnId": turnID],
        ])
        let interruptDeadline = min(deadline, Date().addingTimeInterval(0.25))
        while true {
            let message = try nextMessage(
                deadline: interruptDeadline,
                honorCancellation: false
            )
            if isResponse(message, matching: requestID) { return }
            try route(message, onNotification: nil)
        }
    }

    func perform<T>(_ operation: () throws -> T) async throws -> T {
        let result: Result<T, Error>
        do {
            result = .success(try operation())
        } catch {
            result = .failure(error)
        }
        try await shutdown()
        return try result.get()
    }

    private func shutdown() async throws {
        channel.stop()
        try? input.close()
        var terminationWasConfirmed = true
        if process.isRunning {
            let liveness = CodexProcessLiveness(process)
            let result = await ProcessTerminator.terminate(
                processID: process.processIdentifier,
                isRunning: { liveness.process.isRunning },
                timing: terminationTiming
            )
            switch result {
            case .alreadyExited, .terminatedAfterSIGTERM, .terminatedAfterSIGKILL:
                break
            case .signalFailed, .exitWaitTimedOut:
                terminationWasConfirmed = false
            }
        }
        try? output.close()
        try? errorOutput.close()

        var isolationFailure: PostprocessError?
        if terminationWasConfirmed {
            do {
                try authenticationBridge.verifyAfterChildExit()
            } catch {
                isolationFailure = Self.authenticationIsolationFailure()
            }
        } else {
            isolationFailure = Self.authenticationIsolationFailure()
        }
        do {
            try FileManager.default.removeItem(at: scratchURL)
        } catch {
            isolationFailure = Self.authenticationIsolationFailure()
        }
        if isolationFailure == nil {
            do {
                try authenticationBridge.verifySourceAfterCleanup()
            } catch {
                isolationFailure = Self.authenticationIsolationFailure()
            }
        }
        if let isolationFailure { throw isolationFailure }
    }

    private func request(
        method: String,
        params: [String: Any]?,
        onNotification: (([String: Any]) -> Void)? = nil
    ) throws -> Any {
        let requestID = nextRequestID
        nextRequestID += 1
        var request: [String: Any] = ["id": requestID, "method": method]
        if let params { request["params"] = params }
        try write(request)
        while true {
            let message = try nextMessage()
            if isResponse(message, matching: requestID) {
                if let error = message["error"] as? [String: Any] {
                    throw protocolFailure(
                        "\(method) failed with \(serverErrorDescription(error))"
                    )
                }
                guard let result = message["result"] else {
                    throw protocolFailure("\(method) returned neither result nor error")
                }
                return result
            }
            try route(message, onNotification: onNotification)
        }
    }

    private func pump(onNotification: @escaping ([String: Any]) -> Void) throws {
        try route(nextMessage(), onNotification: onNotification)
    }

    private func route(
        _ message: [String: Any],
        onNotification: (([String: Any]) -> Void)?
    ) throws {
        guard let method = message["method"] as? String else { return }
        if message["id"] != nil {
            try respondFailClosed(to: message, method: method)
        } else {
            onNotification?(message)
        }
    }

    private func respondFailClosed(to message: [String: Any], method: String) throws {
        guard let id = message["id"] else { return }
        let result: [String: Any]
        switch method {
        case "item/permissions/requestApproval":
            result = ["permissions": [:], "scope": "turn"]
        case "mcpServer/elicitation/request":
            result = ["action": "decline"]
        case "item/tool/requestUserInput":
            result = ["answers": [:]]
        default:
            result = [
                "decision": "decline",
                "reason": "Maccheroni post-processing does not allow Codex tools or approvals.",
            ]
        }
        try write(["id": id, "result": result])
    }

    private func notify(method: String, params: [String: Any]) throws {
        try write(["method": method, "params": params])
    }

    private func write(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw protocolFailure("could not encode an app server request")
        }
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.withoutEscapingSlashes]
        )
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            throw protocolFailure("could not write to the app server")
        }
    }

    private func nextMessage(
        deadline overrideDeadline: Date? = nil,
        honorCancellation: Bool = true
    ) throws -> [String: Any] {
        if honorCancellation, Task.isCancelled { throw CancellationError() }
        let line: Data
        do {
            line = try channel.nextLine(
                deadline: overrideDeadline ?? deadline,
                honorCancellation: honorCancellation
            )
        } catch CodexJSONLChannelError.timedOut {
            throw PostprocessError.backendFailed(
                "codex app server timed out after \(Int(timeoutS)) seconds"
            )
        } catch CodexJSONLChannelError.closed {
            throw exitedFailure()
        }
        if honorCancellation, Task.isCancelled { throw CancellationError() }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line)
        } catch {
            throw protocolFailure("app server emitted malformed JSON")
        }
        guard let message = object as? [String: Any] else {
            throw protocolFailure("app server emitted a non-object message")
        }
        return message
    }

    private func exitedFailure() -> PostprocessError {
        let status = process.isRunning ? "before completing the request" : "with status \(process.terminationStatus)"
        return .backendFailed(diagnosticMessage("codex app server exited \(status)"))
    }

    private func protocolFailure(_ message: String) -> PostprocessError {
        .backendFailed(diagnosticMessage("codex app server protocol error: \(message)"))
    }

    private func serverErrorDescription(_ error: [String: Any]) -> String {
        let code: String
        if let value = error["code"] as? String, !value.isEmpty {
            code = value
        } else if let value = error["code"] as? NSNumber {
            code = value.stringValue
        } else {
            code = "unknown"
        }
        let message = (error["message"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayedMessage: String
        if let message, !message.isEmpty {
            displayedMessage = message
        } else {
            displayedMessage = "message unavailable"
        }
        return "server error \(code): \(displayedMessage)"
    }

    private func diagnosticMessage(_ message: String) -> String {
        let sanitizedMessage = SubprocessFailureMessage.sanitized(
            standardError: Data(message.utf8)
        )
        let sanitizedStderrTail = SubprocessFailureMessage.sanitized(
            standardError: stderrTail(maximumBytes: 384)
        )
        guard !sanitizedStderrTail.isEmpty else { return sanitizedMessage }
        let primary = Self.boundedUTF8Prefix(sanitizedMessage, maximumBytes: 320)
        let stderr = Self.boundedUTF8Suffix(sanitizedStderrTail, maximumBytes: 160)
        return "\(primary); stderr tail: \(stderr)"
    }

    private func stderrTail(maximumBytes: UInt64) -> Data {
        try? errorOutput.synchronize()
        guard let reader = try? FileHandle(forReadingFrom: errorURL) else {
            return Data()
        }
        defer { try? reader.close() }
        guard let end = try? reader.seekToEnd() else { return Data() }
        let start = end > maximumBytes ? end - maximumBytes : 0
        let readStart = start > 0 ? start - 1 : 0
        do {
            try reader.seek(toOffset: readStart)
            var data = try reader.readToEnd() ?? Data()
            guard start > 0, let precedingByte = data.first else { return data }
            data.removeFirst()
            guard precedingByte != 10, precedingByte != 13 else { return data }
            while let byte = data.first {
                data.removeFirst()
                if byte == 10 || byte == 13 { break }
            }
            return data
        } catch {
            return Data()
        }
    }

    private static func boundedUTF8Prefix(
        _ text: String,
        maximumBytes: Int
    ) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let marker = SubprocessFailureMessage.truncationMarker
        let budget = maximumBytes - marker.utf8.count
        var result = ""
        var usedBytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard usedBytes + size <= budget else { break }
            result.append(character)
            usedBytes += size
        }
        return result + marker
    }

    private static func boundedUTF8Suffix(
        _ text: String,
        maximumBytes: Int
    ) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var usedBytes = 0
        for character in text.reversed() {
            let value = String(character)
            let size = value.utf8.count
            guard usedBytes + size <= maximumBytes else { break }
            result = value + result
            usedBytes += size
        }
        return result
    }

    private static func authenticationIsolationFailure() -> PostprocessError {
        .authenticationIsolationFailed(
            "Codex needs a private cached ChatGPT file sign-in. Run `codex -c 'cli_auth_credentials_store=\"file\"' login` in Terminal, stop other Codex activity, then try again, or select Local."
        )
    }

    private func rpcID(_ value: Any?) -> Int? {
        if let id = value as? Int { return id }
        return (value as? NSNumber)?.intValue
    }

    private func isResponse(_ message: [String: Any], matching requestID: Int) -> Bool {
        message["method"] == nil && rpcID(message["id"]) == requestID
    }

    private static let developerInstructions = """
    You are Maccheroni's bounded text post-processing worker. Transform only the supplied transcript text and return only the JSON required by the output schema. Do not call tools, inspect files, execute commands, edit anything, ask questions, or include secrets.
    """

    private static func boundedThreadConfig(
        inheritedMCPServerNames: [String],
        reasoningEffort: String
    ) -> [String: Any] {
        let disabledMCPServers = Dictionary(
            uniqueKeysWithValues: inheritedMCPServerNames.map {
                ($0, ["enabled": false] as [String: Any])
            }
        )
        return [
            "openai_base_url": "",
            "chatgpt_base_url": officialChatGPTBaseURL,
            "model_reasoning_effort": reasoningEffort,
            "agents.enabled": false,
            "features.multi_agent": false,
            "features.multi_agent_v2": false,
            "features.apps": false,
            "features.plugins": false,
            "features.image_generation": false,
            "features.standalone_web_search": false,
            "web_search": "disabled",
            "features.code_mode": false,
            "features.code_mode_only": false,
            "features.code_mode_buffered_exec": false,
            "features.code_mode_host": false,
            "features.js_repl": false,
            "features.js_repl_tools_only": false,
            "features.network_proxy": false,
            "features.auth_elicitation": false,
            "features.mcp_2026_07_28": false,
            "features.remote_control": false,
            "features.remote_plugin": false,
            "features.tool_suggest": false,
            "features.goals": false,
            "features.hooks": false,
            "features.memories": false,
            "features.current_time_reminder": false,
            "features.deferred_executor": false,
            "features.enable_fanout": false,
            "features.token_budget": false,
            "orchestrator.mcp.enabled": false,
            "orchestrator.skills.enabled": false,
            "tools.experimental_request_user_input.enabled": false,
            "tools.update_plan.enabled": false,
            "skills.include_instructions": false,
            "include_environment_context": false,
            "project_doc_max_bytes": 0,
            "notify": [],
            "hooks": [
                "PreToolUse": [],
                "PermissionRequest": [],
                "PostToolUse": [],
                "PreCompact": [],
                "PostCompact": [],
                "SessionStart": [],
                "UserPromptSubmit": [],
                "SubagentStart": [],
                "SubagentStop": [],
                "Stop": [],
            ],
            "mcp_servers": disabledMCPServers,
        ]
    }

    private static let overridableConfigLayerTypes: Set<String> = [
        "mdm",
        "system",
        "enterpriseManaged",
        "user",
        "project",
        "sessionFlags",
    ]

    private static let unoverridableConfigLayerTypes: Set<String> = [
        "legacyManagedConfigTomlFromFile",
        "legacyManagedConfigTomlFromMdm",
    ]

    private static let restrictedFeatures: Set<String> = [
        "apps",
        "auth_elicitation",
        "code_mode",
        "code_mode_buffered_exec",
        "code_mode_host",
        "code_mode_only",
        "current_time_reminder",
        "deferred_executor",
        "enable_fanout",
        "goals",
        "hooks",
        "image_generation",
        "js_repl",
        "js_repl_tools_only",
        "mcp_2026_07_28",
        "memories",
        "multi_agent",
        "multi_agent_v2",
        "plugins",
        "network_proxy",
        "remote_control",
        "remote_plugin",
        "standalone_web_search",
        "token_budget",
        "tool_suggest",
    ]

    private static func hasNonEmptyJSONValue(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return !string.isEmpty }
        if let array = value as? [Any] { return !array.isEmpty }
        if let object = value as? [String: Any] {
            return object.values.contains(where: hasNonEmptyJSONValue)
        }
        return true
    }

    private static func isEmptyOrMissing(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        if let array = value as? [Any] { return array.isEmpty }
        if let object = value as? [String: Any] { return object.isEmpty }
        return false
    }
}

private struct CodexAuthenticationBridge {
    struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    struct Metadata {
        let identity: Identity
        let owner: uid_t
        let permissions: mode_t
        let linkCount: nlink_t
    }

    private enum BridgeError: Error {
        case invalid
        case system(Int32)
    }

    let sourceAuthenticationURL: URL
    let isolatedHomeURL: URL
    let isolatedAuthenticationURL: URL
    let identity: Identity

    static func prepare(
        parentEnvironment: [String: String],
        parentHomeDirectory: URL,
        scratchURL: URL,
        linkAuthenticationFile: @Sendable (URL, URL) throws -> Void
    ) throws -> CodexAuthenticationBridge {
        let sourceHomeURL = try sourceHomeURL(
            parentEnvironment: parentEnvironment,
            parentHomeDirectory: parentHomeDirectory
        )
        let sourceAuthenticationURL = sourceHomeURL.appendingPathComponent(
            "auth.json",
            isDirectory: false
        )
        let sourceMetadata = try validatedAuthenticationMetadata(
            at: sourceAuthenticationURL,
            expectedIdentity: nil,
            expectedLinkCount: 1
        )
        let isolatedHomeURL = scratchURL.appendingPathComponent(
            "codex-home",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: isolatedHomeURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: isolatedHomeURL.path
        )
        try validatePrivateDirectory(at: isolatedHomeURL)

        let isolatedAuthenticationURL = isolatedHomeURL.appendingPathComponent(
            "auth.json",
            isDirectory: false
        )
        try linkAuthenticationFile(sourceAuthenticationURL, isolatedAuthenticationURL)
        _ = try validatedAuthenticationMetadata(
            at: sourceAuthenticationURL,
            expectedIdentity: sourceMetadata.identity,
            expectedLinkCount: 2
        )
        _ = try validatedAuthenticationMetadata(
            at: isolatedAuthenticationURL,
            expectedIdentity: sourceMetadata.identity,
            expectedLinkCount: 2
        )
        return CodexAuthenticationBridge(
            sourceAuthenticationURL: sourceAuthenticationURL,
            isolatedHomeURL: isolatedHomeURL,
            isolatedAuthenticationURL: isolatedAuthenticationURL,
            identity: sourceMetadata.identity
        )
    }

    static func createHardLink(sourceURL: URL, destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.link(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw BridgeError.system(errno) }
    }

    func verifyAfterChildExit() throws {
        _ = try Self.validatedAuthenticationMetadata(
            at: sourceAuthenticationURL,
            expectedIdentity: identity,
            expectedLinkCount: 2
        )
        _ = try Self.validatedAuthenticationMetadata(
            at: isolatedAuthenticationURL,
            expectedIdentity: identity,
            expectedLinkCount: 2
        )
    }

    func verifySourceAfterCleanup() throws {
        _ = try Self.validatedAuthenticationMetadata(
            at: sourceAuthenticationURL,
            expectedIdentity: identity,
            expectedLinkCount: 1
        )
    }

    private static func sourceHomeURL(
        parentEnvironment: [String: String],
        parentHomeDirectory: URL
    ) throws -> URL {
        if let configuredHome = parentEnvironment["CODEX_HOME"],
           !configuredHome.isEmpty
        {
            guard NSString(string: configuredHome).isAbsolutePath else {
                throw BridgeError.invalid
            }
            return URL(fileURLWithPath: configuredHome, isDirectory: true)
                .standardizedFileURL
        }
        return parentHomeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func validatePrivateDirectory(at url: URL) throws {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        guard result == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid(),
              status.st_mode & 0o777 == 0o700 else {
            throw BridgeError.invalid
        }
    }

    private static func validatedAuthenticationMetadata(
        at url: URL,
        expectedIdentity: Identity?,
        expectedLinkCount: nlink_t
    ) throws -> Metadata {
        var pathStatus = stat()
        let pathResult = url.path.withCString { Darwin.lstat($0, &pathStatus) }
        guard pathResult == 0 else { throw BridgeError.system(errno) }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw BridgeError.system(errno) }
        defer { _ = Darwin.close(descriptor) }
        var descriptorStatus = stat()
        guard Darwin.fstat(descriptor, &descriptorStatus) == 0 else {
            throw BridgeError.system(errno)
        }

        let pathIdentity = Identity(
            device: pathStatus.st_dev,
            inode: pathStatus.st_ino
        )
        let descriptorIdentity = Identity(
            device: descriptorStatus.st_dev,
            inode: descriptorStatus.st_ino
        )
        guard pathIdentity == descriptorIdentity,
              expectedIdentity == nil || pathIdentity == expectedIdentity,
              pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              descriptorStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              pathStatus.st_uid == geteuid(),
              descriptorStatus.st_uid == geteuid(),
              pathStatus.st_mode & 0o777 == 0o600,
              descriptorStatus.st_mode & 0o777 == 0o600,
              pathStatus.st_nlink == expectedLinkCount,
              descriptorStatus.st_nlink == expectedLinkCount else {
            throw BridgeError.invalid
        }
        return Metadata(
            identity: pathIdentity,
            owner: pathStatus.st_uid,
            permissions: pathStatus.st_mode & 0o777,
            linkCount: pathStatus.st_nlink
        )
    }
}

private final class CodexProcessLiveness: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private enum CodexJSONLChannelError: Error {
    case timedOut
    case closed
}

final class CodexJSONLChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let handle: FileHandle
    private var buffer = Data()
    private var lines: [Data] = []
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
            }
            self?.append(data)
        }
    }

    func nextLine(deadline: Date, honorCancellation: Bool = true) throws -> Data {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if !lines.isEmpty { return lines.removeFirst() }
            if closed { throw CodexJSONLChannelError.closed }
            if honorCancellation, Task.isCancelled { throw CancellationError() }
            let wake = min(deadline, Date().addingTimeInterval(0.05))
            guard Date() < deadline else { throw CodexJSONLChannelError.timedOut }
            _ = condition.wait(until: wake)
        }
    }

    func finish() {
        condition.lock()
        closed = true
        flushFinalLine()
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        handle.readabilityHandler = nil
        finish()
    }

    private func append(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        guard !data.isEmpty else {
            closed = true
            flushFinalLine()
            return
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
    }

    private func flushFinalLine() {
        guard !buffer.isEmpty else { return }
        lines.append(buffer)
        buffer.removeAll(keepingCapacity: false)
    }
}

private struct CodexTurnCollector {
    let threadID: String
    var turnID: String?
    private(set) var isTerminal = false
    private(set) var failure: String?
    private var completedMessages: [(phase: String?, text: String)] = []
    private var pending: [[String: Any]] = []

    init(threadID: String) {
        self.threadID = threadID
    }

    var finalText: String? {
        completedMessages.last(where: { $0.phase == "final_answer" })?.text
            ?? completedMessages.last?.text
    }

    mutating func consume(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any],
              relevantThread(params) else { return }
        guard let turnID else {
            pending.append(message)
            return
        }
        guard relevantTurn(params, turnID: turnID) else { return }
        switch message["method"] as? String {
        case "item/completed":
            if let item = params["item"] as? [String: Any] {
                remember(item)
            }
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any] else {
                failure = "turn/completed omitted its turn"
                isTerminal = true
                return
            }
            if let items = turn["items"] as? [[String: Any]] {
                for item in items { remember(item) }
            }
            let status = turn["status"] as? String
            if status != "completed" {
                failure = "turn did not complete successfully"
            }
            isTerminal = true
        case "error":
            failure = "app server reported an error"
            isTerminal = true
        default:
            break
        }
    }

    mutating func consumePending() {
        let messages = pending
        pending.removeAll(keepingCapacity: false)
        for message in messages { consume(message) }
    }

    private func relevantThread(_ params: [String: Any]) -> Bool {
        if let value = params["threadId"] as? String { return value == threadID }
        if let turn = params["turn"] as? [String: Any],
           let value = turn["threadId"] as? String {
            return value == threadID
        }
        return true
    }

    private func relevantTurn(_ params: [String: Any], turnID: String) -> Bool {
        if let value = params["turnId"] as? String { return value == turnID }
        if let turn = params["turn"] as? [String: Any],
           let value = turn["id"] as? String {
            return value == turnID
        }
        return true
    }

    private mutating func remember(_ item: [String: Any]) {
        guard item["type"] as? String == "agentMessage",
              let text = item["text"] as? String,
              !text.isEmpty else { return }
        let phase = item["phase"] as? String
        if !completedMessages.contains(where: { $0.phase == phase && $0.text == text }) {
            completedMessages.append((phase: phase, text: text))
        }
    }
}
