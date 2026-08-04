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

    public init(terminationTiming: ProcessTerminationTiming = .default) {
        self.terminationTiming = terminationTiming
    }

    public func accountState(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval
    ) async throws -> CodexAppServerAccountState {
        let timing = terminationTiming
        let task = Task.detached {
            let session = try CodexAppServerSession(
                executableURL: executableURL,
                workspaceURL: workspaceURL,
                timeoutS: timeoutS,
                terminationTiming: timing
            )
            do {
                try session.initialize()
                let state = try session.readAccountState()
                await session.shutdown()
                return state
            } catch {
                await session.shutdown()
                throw error
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
        let task = Task.detached {
            let session = try CodexAppServerSession(
                executableURL: invocation.executableURL,
                workspaceURL: invocation.workspaceURL,
                timeoutS: invocation.timeoutS,
                terminationTiming: timing
            )
            do {
                try session.initialize()
                guard try session.readAccountState() == .chatGPT else {
                    throw PostprocessError.authenticationRequired(
                        "Codex requires a ChatGPT subscription sign-in. Run `codex login` in Terminal, then try again, or select Local."
                    )
                }
                let output = try session.runTurn(invocation)
                await session.shutdown()
                return output
            } catch {
                await session.shutdown()
                throw error
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
    private let channel: CodexJSONLChannel
    private let deadline: Date
    private let timeoutS: TimeInterval
    private let terminationTiming: ProcessTerminationTiming
    private var nextRequestID = 1

    init(
        executableURL: URL,
        workspaceURL: URL,
        timeoutS: TimeInterval,
        terminationTiming: ProcessTerminationTiming
    ) throws {
        guard timeoutS > 0 else {
            throw PostprocessError.backendFailed("codex app server timeout must be positive")
        }
        self.timeoutS = timeoutS
        self.deadline = Date().addingTimeInterval(timeoutS)
        self.terminationTiming = terminationTiming
        self.scratchURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccheroni-codex-app-server-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: scratchURL,
                withIntermediateDirectories: false
            )
        } catch {
            throw PostprocessError.launchFailed(
                "cannot create Codex app server scratch directory"
            )
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
            try? FileManager.default.removeItem(at: scratchURL)
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
            "--listen", "stdio://",
        ]
        var environment = ProcessInfo.processInfo.environment
        for key in Self.strippedCredentialEnvironmentKeys {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        process.currentDirectoryURL = workspaceURL
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = errorOutput
        do {
            try process.run()
        } catch {
            channel.finish()
            try? input.close()
            try? output.close()
            try? errorOutput.close()
            try? FileManager.default.removeItem(at: scratchURL)
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

    func shutdown() async {
        channel.stop()
        try? input.close()
        if process.isRunning {
            let liveness = CodexProcessLiveness(process)
            _ = await ProcessTerminator.terminate(
                processID: process.processIdentifier,
                isRunning: { liveness.process.isRunning },
                timing: terminationTiming
            )
        }
        try? output.close()
        try? errorOutput.close()
        try? FileManager.default.removeItem(at: scratchURL)
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
                    _ = error
                    throw protocolFailure("\(method) failed")
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
        return .backendFailed("codex app server exited \(status)")
    }

    private func protocolFailure(_ message: String) -> PostprocessError {
        .backendFailed("codex app server protocol error: \(message)")
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

private final class CodexJSONLChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let handle: FileHandle
    private var buffer = Data()
    private var lines: [Data] = []
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            self?.append(readable.availableData)
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
