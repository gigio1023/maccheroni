import Darwin
import Foundation
import MaccheroniCore
import MaccheroniPostprocess
import Testing

@Suite(.serialized)
struct CodexAppServerTests {
    @Test func runsAuthenticatedSchemaConstrainedTurnAndDeclinesApprovals() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let schema = Data(#"{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}},"additionalProperties":false}"#.utf8)
        let output = try await FoundationCodexAppServerExecutor().run(
            CodexAppServerInvocation(
                executableURL: fixture.executable,
                model: "gpt-test",
                prompt: "bounded private prompt",
                outputSchema: schema,
                workspaceURL: fixture.workspace,
                timeoutS: 2
            )
        )

        #expect(String(decoding: output, as: UTF8.self) == #"{"answer":"ok"}"#)
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(transcript.contains(#"ARGS:app-server -c openai_base_url="" -c chatgpt_base_url="https://chatgpt.com/backend-api/" --listen stdio://"#))
        #expect(transcript.contains("ENV:unset|unset|unset"))
        #expect(transcript.contains(#""method":"initialize""#))
        #expect(transcript.contains(#""experimentalApi":true"#))
        #expect(transcript.contains(#""method":"initialized""#))
        #expect(transcript.contains(#""method":"account/read""#))
        #expect(transcript.contains(#""method":"config/read""#))
        #expect(transcript.contains(#""includeLayers":true"#))
        #expect(transcript.contains(#""method":"configRequirements/read""#))
        #expect(transcript.contains(#""method":"model/list""#))
        #expect(transcript.contains(#""method":"thread/start""#))
        #expect(transcript.contains(#""openai_base_url":"""#))
        #expect(transcript.contains(#""chatgpt_base_url":"https://chatgpt.com/backend-api/""#))
        #expect(transcript.contains(#""model_reasoning_effort":"high""#))
        #expect(transcript.contains(#""ephemeral":true"#))
        #expect(transcript.contains(#""environments":[]"#))
        #expect(transcript.contains(#""dynamicTools":[]"#))
        #expect(transcript.contains(#""selectedCapabilityRoots":[]"#))
        #expect(transcript.contains(#""features.code_mode":false"#))
        #expect(transcript.contains(#""features.deferred_executor":false"#))
        #expect(transcript.contains(#""features.plugins":false"#))
        #expect(transcript.contains(#""tools.update_plan.enabled":false"#))
        #expect(transcript.contains(#""fixture-mcp":{"enabled":false}"#))
        #expect(!transcript.contains("persistExtendedHistory"))
        #expect(transcript.contains(#""approvalPolicy":"never""#))
        #expect(transcript.contains(#""method":"mcpServerStatus/list""#))
        #expect(transcript.contains(#""method":"turn/start""#))
        #expect(transcript.contains(#""outputSchema""#))
        #expect(transcript.contains(#""effort":"high""#))
        #expect(transcript.contains("bounded private prompt"))
        #expect(transcript.contains(#""decision":"decline""#))
        #expect(!transcript.contains(#""method":"command/exec""#))
        let messages = transcript.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let turnStart = try #require(messages.first {
            $0["method"] as? String == "turn/start"
        })
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        #expect(turnParams["cwd"] == nil)
    }

    @Test func accountProbeRequiresChatGPTSubscriptionAuthentication() async throws {
        let signedIn = try AppServerFixture(accountType: "chatgpt")
        defer { signedIn.remove() }
        #expect(try await FoundationCodexAppServerExecutor().accountState(
            executableURL: signedIn.executable,
            workspaceURL: signedIn.workspace,
            timeoutS: 2
        ) == .chatGPT)

        let apiKey = try AppServerFixture(accountType: "apiKey")
        defer { apiKey.remove() }
        #expect(try await FoundationCodexAppServerExecutor().accountState(
            executableURL: apiKey.executable,
            workspaceURL: apiKey.workspace,
            timeoutS: 2
        ) == .unsupported)

        let signedOut = try AppServerFixture(accountType: nil)
        defer { signedOut.remove() }
        #expect(try await FoundationCodexAppServerExecutor().accountState(
            executableURL: signedOut.executable,
            workspaceURL: signedOut.workspace,
            timeoutS: 2
        ) == .signedOut)
    }

    @Test func drainsAnAccountResponseWrittenImmediatelyBeforeProcessExit() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            exitsAfterAccountResponse: true
        )
        defer { fixture.remove() }

        #expect(try await FoundationCodexAppServerExecutor().accountState(
            executableURL: fixture.executable,
            workspaceURL: fixture.workspace,
            timeoutS: 2
        ) == .chatGPT)
    }

    @Test func rejectsManagedHooksThatTheThreadCannotOverride() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            requirementsJSON: #"{"hooks":{"SessionStart":[{"command":"managed"}]}}"#
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: cannot override managed hooks"
        )) {
            _ = try await FoundationCodexAppServerExecutor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: 2
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"thread/start""#))
    }

    @Test func rejectsAManagedHooksOnlyPolicyBeforeStartingAThread() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            requirementsJSON: #"{"allowManagedHooksOnly":true}"#
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: cannot override managed hooks"
        )) {
            _ = try await FoundationCodexAppServerExecutor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: 2
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"thread/start""#))
    }

    @Test func rejectsAnMCPServerThatRemainsEnabledAfterThreadStart() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            mcpDataJSON: #"[{"name":"managed-mcp"}]"#
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: mcpServerStatus/list found an active or unexpected server"
        )) {
            _ = try await FoundationCodexAppServerExecutor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: 2
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"turn/start""#))
    }

    @Test func rejectsNonChatGPTAccountBeforeStartingAThread() async throws {
        let fixture = try AppServerFixture(accountType: "apiKey")
        defer { fixture.remove() }
        await #expect(throws: PostprocessError.authenticationRequired(
            "Codex requires a ChatGPT subscription sign-in. Run `codex login` in Terminal, then try again, or select Local."
        )) {
            _ = try await FoundationCodexAppServerExecutor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: 2
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"thread/start""#))
    }

    @Test func protocolAndStderrFailuresAreBoundedAndPathRedacted() async throws {
        let root = try freshDirectory(prefix: "maccheroni-app-server-errors-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)

        let protocolFailure = root.appendingPathComponent("codex-protocol")
        try writeExecutable(
            """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' '{"id":1,"error":{"message":"cannot read /Users/someone/private.txt"}}'
            done
            """,
            to: protocolFailure
        )
        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: initialize failed"
        )) {
            _ = try await FoundationCodexAppServerExecutor().accountState(
                executableURL: protocolFailure,
                workspaceURL: workspace,
                timeoutS: 2
            )
        }

        let stderrFailure = root.appendingPathComponent("codex-stderr")
        try writeExecutable(
            """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' 'cannot read /Users/someone/private.txt' >&2
              exit 7
            done
            """,
            to: stderrFailure
        )
        await #expect(throws: PostprocessError.backendFailed(
            "codex app server exited with status 7"
        )) {
            _ = try await FoundationCodexAppServerExecutor().accountState(
                executableURL: stderrFailure,
                workspaceURL: workspace,
                timeoutS: 2
            )
        }

        let malformedFailure = root.appendingPathComponent("codex-malformed")
        try writeExecutable(
            """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' 'not-json-/Users/someone/private.txt'
            done
            """,
            to: malformedFailure
        )
        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: app server emitted malformed JSON"
        )) {
            _ = try await FoundationCodexAppServerExecutor().accountState(
                executableURL: malformedFailure,
                workspaceURL: workspace,
                timeoutS: 2
            )
        }
    }

    @Test func cancellationRequestsTurnInterruptBeforeShutdown() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt", completesTurn: false)
        defer { fixture.remove() }
        let task = Task {
            try await FoundationCodexAppServerExecutor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "bounded private prompt",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: 30
                )
            )
        }
        try await waitForText(#""method":"turn/start""#, in: fixture.log)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(transcript.contains(#""method":"turn/interrupt""#))
        #expect(transcript.contains(#""threadId":"thread-1""#))
        #expect(transcript.contains(#""turnId":"turn-1""#))
    }

    @Test func timeoutTerminatesTheExactAppServerDescendantTree() async throws {
        let root = try freshDirectory(prefix: "maccheroni-app-server-timeout-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let rootPIDURL = root.appendingPathComponent("root.pid")
        let childPIDURL = root.appendingPathComponent("child.pid")
        let executable = root.appendingPathComponent("codex")
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s' "$$" > '\(rootPIDURL.path)'
            (trap '' TERM; while :; do sleep 1; done) &
            child=$!
            printf '%s' "$child" > '\(childPIDURL.path)'
            while IFS= read -r line; do :; done
            """,
            to: executable
        )

        await #expect(throws: PostprocessError.self) {
            _ = try await FoundationCodexAppServerExecutor(
                terminationTiming: ProcessTerminationTiming(
                    gracePeriodS: 0.05,
                    pollIntervalS: 0.01,
                    exitWaitS: 0.5
                )
            ).accountState(
                executableURL: executable,
                workspaceURL: workspace,
                timeoutS: 0.5
            )
        }
        let processIDs = try await [rootPIDURL, childPIDURL].asyncMap(waitForPID)
        let deadline = Date().addingTimeInterval(2)
        while processIDs.contains(where: processExists), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(processIDs.allSatisfy { !processExists($0) })
    }

    @Test func cancellationTerminatesTheExactAppServerDescendantTree() async throws {
        let root = try freshDirectory(prefix: "maccheroni-app-server-cancel-")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let rootPIDURL = root.appendingPathComponent("root.pid")
        let childPIDURL = root.appendingPathComponent("child.pid")
        let executable = root.appendingPathComponent("codex")
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s' "$$" > '\(rootPIDURL.path)'
            (trap '' TERM; while :; do sleep 1; done) &
            child=$!
            printf '%s' "$child" > '\(childPIDURL.path)'
            while IFS= read -r line; do :; done
            """,
            to: executable
        )

        let task = Task {
            try await FoundationCodexAppServerExecutor(
                terminationTiming: ProcessTerminationTiming(
                    gracePeriodS: 0.05,
                    pollIntervalS: 0.01,
                    exitWaitS: 0.5
                )
            ).accountState(
                executableURL: executable,
                workspaceURL: workspace,
                timeoutS: 30
            )
        }
        let processIDs = try await [rootPIDURL, childPIDURL].asyncMap(waitForPID)
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let deadline = Date().addingTimeInterval(2)
        while processIDs.contains(where: processExists), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(processIDs.allSatisfy { !processExists($0) })
    }
}

private struct AppServerFixture {
    let root: URL
    let workspace: URL
    let executable: URL
    let log: URL

    init(
        accountType: String?,
        completesTurn: Bool = true,
        exitsAfterAccountResponse: Bool = false,
        requirementsJSON: String = "null",
        mcpDataJSON: String = #"[{"name":"fixture-mcp","tools":{},"resources":[],"resourceTemplates":[],"serverInfo":null,"authStatus":"unsupported"}]"#
    ) throws {
        root = try freshDirectory(prefix: "maccheroni-app-server-fixture-")
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        executable = root.appendingPathComponent("codex")
        log = root.appendingPathComponent("protocol.log")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try Data().write(to: log, options: .withoutOverwriting)
        let accountJSON = accountType.map { #"{"type":"\#($0)"}"# } ?? "null"
        let accountExit = exitsAfterAccountResponse ? "exit 0" : ""
        let turnCompletion = completesTurn ? """
                  printf '%s\\n' '{"id":90,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1"}}'
                  IFS= read -r approval
                  printf '%s\\n' "$approval" >> '\(log.path)'
                  printf '%s\\n' '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"message-1","type":"agentMessage","phase":"final_answer","text":"{\\"answer\\":\\"ok\\"}"}}}'
                  printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","threadId":"thread-1","status":"completed","items":[]}}}'
        """ : ""
        try writeExecutable(
            """
            #!/bin/sh
            printf 'ARGS:%s\\n' "$*" >> '\(log.path)'
            printf 'ENV:%s|%s|%s\\n' "${OPENAI_API_KEY-unset}" "${CODEX_API_KEY-unset}" "${CODEX_ACCESS_TOKEN-unset}" >> '\(log.path)'
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> '\(log.path)'
              case "$line" in
                *'"method":"initialize"'*)
                  printf '%s\\n' '{"id":1,"result":{"userAgent":"maccheroni-test/0.146.0"}}'
                  ;;
                *'"method":"account/read"'*)
                  printf '%s\\n' '{"id":2,"result":{"account":\(accountJSON),"requiresOpenaiAuth":true}}'
                  \(accountExit)
                  ;;
                *'"method":"config/read"'*)
                  printf '%s\\n' '{"id":3,"result":{"config":{"mcp_servers":{"fixture-mcp":{"command":"fixture"}}},"layers":[{"name":{"type":"user"}},{"name":{"type":"sessionFlags"}}]}}'
                  ;;
                *'"method":"configRequirements/read"'*)
                  printf '%s\\n' '{"id":4,"result":{"requirements":\(requirementsJSON)}}'
                  ;;
                *'"method":"model/list"'*)
                  printf '%s\\n' '{"id":5,"result":{"data":[{"id":"gpt-test","model":"gpt-test","defaultReasoningEffort":"high"}],"nextCursor":null}}'
                  ;;
                *'"method":"thread/start"'*)
                  printf '%s\\n' '{"id":6,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}'
                  IFS= read -r collision_response
                  printf '%s\\n' "$collision_response" >> '\(log.path)'
                  printf '%s\\n' '{"id":6,"result":{"thread":{"id":"thread-1"}}}'
                  ;;
                *'"method":"mcpServerStatus/list"'*)
                  printf '%s\\n' '{"id":7,"result":{"data":\(mcpDataJSON),"nextCursor":null}}'
                  ;;
                *'"method":"turn/start"'*)
                  printf '%s\\n' '{"id":8,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}'
            \(turnCompletion)
                  ;;
                *'"method":"turn/interrupt"'*)
                  printf '%s\\n' '{"id":9,"result":{}}'
                  ;;
              esac
            done
            """,
            to: executable
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func freshDirectory(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "\(prefix)\(UUID().uuidString.lowercased())",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func writeExecutable(_ contents: String, to url: URL) throws {
    try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func waitForPID(at url: URL) async throws -> Int32 {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadNoSuchFile)
}

private func waitForText(_ text: String, in url: URL) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if let value = try? String(contentsOf: url, encoding: .utf8),
           value.contains(text) {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadUnknown)
}

private func processExists(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}

private extension Array {
    func asyncMap<Output>(
        _ transform: (Element) async throws -> Output
    ) async rethrows -> [Output] {
        var result: [Output] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
