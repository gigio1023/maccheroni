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
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = workspaceURL
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = errorOutput
        process.terminationHandler = { [channel] _ in channel.finish() }
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
                    inheritedMCPServerNames: inheritedMCPServerNames
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

        var collector = CodexTurnCollector(threadID: threadID)
        let turnResult = try request(
            method: "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": invocation.prompt]],
                "approvalPolicy": "never",
                "model": invocation.model,
                "effort": "low",
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
            params: ["cwd": workspaceURL.path, "includeLayers": false]
        )
        guard let object = result as? [String: Any],
              let config = object["config"] as? [String: Any] else {
            throw protocolFailure("config/read returned no effective config")
        }
        guard let servers = config["mcp_servers"] else { return [] }
        guard let serverObject = servers as? [String: Any] else {
            throw protocolFailure("config/read returned invalid mcp_servers")
        }
        return serverObject.keys.sorted()
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
            if rpcID(message["id"]) == requestID { return }
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
        params: [String: Any],
        onNotification: (([String: Any]) -> Void)? = nil
    ) throws -> Any {
        let requestID = nextRequestID
        nextRequestID += 1
        try write(["id": requestID, "method": method, "params": params])
        while true {
            let message = try nextMessage()
            if rpcID(message["id"]) == requestID {
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

    private static let developerInstructions = """
    You are Maccheroni's bounded text post-processing worker. Transform only the supplied transcript text and return only the JSON required by the output schema. Do not call tools, inspect files, execute commands, edit anything, ask questions, or include secrets.
    """

    private static func boundedThreadConfig(
        inheritedMCPServerNames: [String]
    ) -> [String: Any] {
        let disabledMCPServers = Dictionary(
            uniqueKeysWithValues: inheritedMCPServerNames.map {
                ($0, ["enabled": false] as [String: Any])
            }
        )
        return [
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
