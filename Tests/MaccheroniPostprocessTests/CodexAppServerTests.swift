import Darwin
import Foundation
import MaccheroniCore
import Testing
@testable import MaccheroniPostprocess

private let loadTolerantTestTimeoutS: TimeInterval = 10

private let authenticationIsolationMessage =
    "Codex needs a private cached ChatGPT file sign-in. Run `codex -c 'cli_auth_credentials_store=\"file\"' login` in Terminal, stop other Codex activity, then try again, or select Local."

private let initialSyntheticAuthentication =
    Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh"}"#.utf8)

private let refreshedSyntheticAuthentication =
    Data(#"{"access_token":"synthetic-access-rotated","refresh_token":"synthetic-refresh-rotated"}"#.utf8)

@Suite(.serialized)
struct CodexAppServerTests {
    @Test func runsAuthenticatedSchemaConstrainedTurnAndDeclinesApprovals() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let sourceAuthenticationStatusBefore = try fileStatus(at: fixture.sourceAuthentication)
        #expect(sourceAuthenticationStatusBefore.fileType == mode_t(S_IFREG))
        #expect(sourceAuthenticationStatusBefore.permissions == 0o600)
        #expect(sourceAuthenticationStatusBefore.linkCount == 1)
        let schema = Data(#"{"type":"object","required":["answer"],"properties":{"answer":{"type":"string"}},"additionalProperties":false}"#.utf8)
        let output = try await fixture.executor().run(
            CodexAppServerInvocation(
                executableURL: fixture.executable,
                model: "gpt-test",
                prompt: "bounded private prompt",
                outputSchema: schema,
                workspaceURL: fixture.workspace,
                timeoutS: loadTolerantTestTimeoutS
            )
        )

        #expect(String(decoding: output, as: UTF8.self) == #"{"answer":"ok"}"#)
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(transcript.contains(#"ARGS:app-server -c openai_base_url="" -c chatgpt_base_url="https://chatgpt.com/backend-api/" -c cli_auth_credentials_store="file" --listen stdio://"#))
        #expect(transcript.contains("ENV:unset|unset|unset"))
        #expect(transcript.contains("HOME_MODE:700"))
        #expect(transcript.contains("HOME_ENTRIES:auth.json,"))
        #expect(transcript.contains("AUTH_READ:ok"))
        for marker in [
            "hostile-provider", "hostile-profile-provider", "hostile-proxy",
            "hostile-otel", "hostile-plugin", "hostile-session", "hostile-model-state",
        ] {
            #expect(!transcript.contains(marker))
        }
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
        let threadStart = try #require(messages.first {
            $0["method"] as? String == "thread/start"
        })
        let threadParams = try #require(threadStart["params"] as? [String: Any])
        #expect(threadParams["model"] as? String == "gpt-test")
        #expect(threadParams["modelProvider"] as? String == "openai")
        #expect(threadParams["cwd"] as? String == fixture.workspace.path)
        #expect(threadParams["approvalPolicy"] as? String == "never")
        #expect(threadParams["sandbox"] as? String == "read-only")
        #expect((threadParams["environments"] as? [Any])?.isEmpty == true)
        #expect((threadParams["dynamicTools"] as? [Any])?.isEmpty == true)
        #expect((threadParams["selectedCapabilityRoots"] as? [Any])?.isEmpty == true)
        #expect(threadParams["ephemeral"] as? Bool == true)
        let turnStart = try #require(messages.first {
            $0["method"] as? String == "turn/start"
        })
        let turnParams = try #require(turnStart["params"] as? [String: Any])
        #expect(turnParams["cwd"] == nil)
        #expect(turnParams["model"] as? String == "gpt-test")
        #expect(turnParams["effort"] as? String == "high")

        let childHomes = try fixture.childHomePaths()
        #expect(childHomes.count == 1)
        let childHome = try #require(childHomes.first)
        #expect(childHome.standardizedFileURL != fixture.sourceHome.standardizedFileURL)
        #expect(childHome.lastPathComponent == "codex-home")
        #expect(
            childHome.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == fixture.temporaryDirectory.standardizedFileURL
        )
        #expect(!FileManager.default.fileExists(atPath: childHome.path))
        let recordedAuthenticationStatus = try parsedAuthenticationStatus(from: transcript)
        let sourceAuthenticationStatus = try fileStatus(at: fixture.sourceAuthentication)
        #expect(recordedAuthenticationStatus.device == sourceAuthenticationStatus.device)
        #expect(recordedAuthenticationStatus.inode == sourceAuthenticationStatus.inode)
        #expect(sourceAuthenticationStatusBefore.device == sourceAuthenticationStatus.device)
        #expect(sourceAuthenticationStatusBefore.inode == sourceAuthenticationStatus.inode)
        #expect(recordedAuthenticationStatus.linkCount == 2)
        #expect(recordedAuthenticationStatus.permissions == 0o600)
        #expect(sourceAuthenticationStatus.linkCount == 1)
        #expect(sourceAuthenticationStatus.permissions == 0o600)
        #expect(sourceAuthenticationStatus.fileType == mode_t(S_IFREG))
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func accountProbeRequiresChatGPTSubscriptionAuthentication() async throws {
        let signedIn = try AppServerFixture(accountType: "chatgpt")
        defer { signedIn.remove() }
        #expect(try await signedIn.executor().accountState(
            executableURL: signedIn.executable,
            workspaceURL: signedIn.workspace,
            timeoutS: loadTolerantTestTimeoutS
        ) == .chatGPT)

        let apiKey = try AppServerFixture(accountType: "apiKey")
        defer { apiKey.remove() }
        #expect(try await apiKey.executor().accountState(
            executableURL: apiKey.executable,
            workspaceURL: apiKey.workspace,
            timeoutS: loadTolerantTestTimeoutS
        ) == .unsupported)

        let signedOut = try AppServerFixture(accountType: nil)
        defer { signedOut.remove() }
        #expect(try await signedOut.executor().accountState(
            executableURL: signedOut.executable,
            workspaceURL: signedOut.workspace,
            timeoutS: loadTolerantTestTimeoutS
        ) == .signedOut)

        for fixture in [signedIn, apiKey, signedOut] {
            try fixture.assertScratchIsEmpty()
            try fixture.assertHostileSentinelsAreUnchanged()
        }
    }

    @Test func createsAFreshIsolatedHomeForEveryProcess() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }

        for _ in 0 ..< 2 {
            #expect(try await fixture.executor().accountState(
                executableURL: fixture.executable,
                workspaceURL: fixture.workspace,
                timeoutS: 2
            ) == .chatGPT)
        }

        let childHomes = try fixture.childHomePaths()
        #expect(childHomes.count == 2)
        #expect(Set(childHomes.map(\.path)).count == 2)
        #expect(childHomes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func drainsAnAccountResponseWrittenImmediatelyBeforeProcessExit() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            exitsAfterAccountResponse: true
        )
        defer { fixture.remove() }

        #expect(try await fixture.executor().accountState(
            executableURL: fixture.executable,
            workspaceURL: fixture.workspace,
            timeoutS: loadTolerantTestTimeoutS
        ) == .chatGPT)
        #expect(try fixture.childHomePaths().count == 1)
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
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
            _ = try await fixture.executor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: loadTolerantTestTimeoutS
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"thread/start""#))
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
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
            _ = try await fixture.executor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: loadTolerantTestTimeoutS
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"thread/start""#))
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
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
            _ = try await fixture.executor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: loadTolerantTestTimeoutS
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"turn/start""#))
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func rejectsNonChatGPTAccountBeforeStartingAThread() async throws {
        let fixture = try AppServerFixture(accountType: "apiKey")
        defer { fixture.remove() }
        await #expect(throws: PostprocessError.authenticationRequired(
            "Codex requires a ChatGPT subscription sign-in. Run `codex login` in Terminal, then try again, or select Local."
        )) {
            _ = try await fixture.executor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "x",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: loadTolerantTestTimeoutS
                )
            )
        }
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(#""method":"thread/start""#))
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func rejectsUnavailableOrUnsafeCachedAuthenticationBeforeLaunch() async throws {
        var fixtures: [AppServerFixture] = []
        defer { fixtures.forEach { $0.remove() } }

        for kind in InvalidAuthenticationKind.allCases {
            let fixture = try AppServerFixture(accountType: "chatgpt")
            fixtures.append(fixture)
            try kind.apply(to: fixture)

            await #expect(throws: PostprocessError.authenticationIsolationFailed(
                authenticationIsolationMessage
            )) {
                _ = try await fixture.executor().accountState(
                    executableURL: fixture.executable,
                    workspaceURL: fixture.workspace,
                    timeoutS: 2
                )
            }
            #expect(try Data(contentsOf: fixture.log).isEmpty)
            try fixture.assertScratchIsEmpty()
            try fixture.assertHostileSentinelsAreUnchanged()
        }
    }

    @Test func rejectsALinkOperationThatDoesNotCreateTheExactHardLink() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let executor = FoundationCodexAppServerExecutor(
            environment: fixture.environment,
            homeDirectory: fixture.root.appendingPathComponent("unused-home", isDirectory: true),
            temporaryDirectory: fixture.temporaryDirectory,
            linkAuthenticationFile: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
            }
        )

        await #expect(throws: PostprocessError.authenticationIsolationFailed(
            authenticationIsolationMessage
        )) {
            _ = try await executor.accountState(
                executableURL: fixture.executable,
                workspaceURL: fixture.workspace,
                timeoutS: 2
            )
        }
        #expect(try Data(contentsOf: fixture.log).isEmpty)
        let sourceStatus = try fileStatus(at: fixture.sourceAuthentication)
        #expect(sourceStatus.linkCount == 1)
        #expect(sourceStatus.permissions == 0o600)
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func inPlaceAuthenticationRefreshUpdatesTheSourceHardLink() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            authenticationMutation: .inPlaceRefresh
        )
        defer { fixture.remove() }

        #expect(try await fixture.executor().accountState(
            executableURL: fixture.executable,
            workspaceURL: fixture.workspace,
            timeoutS: 2
        ) == .chatGPT)

        #expect(try Data(contentsOf: fixture.sourceAuthentication) == refreshedSyntheticAuthentication)
        let sourceStatus = try fileStatus(at: fixture.sourceAuthentication)
        #expect(sourceStatus.fileType == mode_t(S_IFREG))
        #expect(sourceStatus.permissions == 0o600)
        #expect(sourceStatus.linkCount == 1)
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func atomicAuthenticationReplacementFailsVisiblyAndCleansScratch() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            authenticationMutation: .atomicReplacement
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.authenticationIsolationFailed(
            authenticationIsolationMessage
        )) {
            _ = try await fixture.executor().accountState(
                executableURL: fixture.executable,
                workspaceURL: fixture.workspace,
                timeoutS: 2
            )
        }

        #expect(try Data(contentsOf: fixture.sourceAuthentication) == initialSyntheticAuthentication)
        let sourceStatus = try fileStatus(at: fixture.sourceAuthentication)
        #expect(sourceStatus.permissions == 0o600)
        #expect(sourceStatus.linkCount == 1)
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func launchFailureCleansThePreparedAuthenticationHome() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.launchFailed(
            "could not launch codex app server"
        )) {
            _ = try await fixture.executor().accountState(
                executableURL: fixture.root.appendingPathComponent("missing-codex"),
                workspaceURL: fixture.workspace,
                timeoutS: 2
            )
        }

        #expect(try Data(contentsOf: fixture.log).isEmpty)
        let sourceStatus = try fileStatus(at: fixture.sourceAuthentication)
        #expect(sourceStatus.linkCount == 1)
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func protocolAndStderrFailuresAreBoundedAndPathRedacted() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let root = fixture.root
        let workspace = fixture.workspace

        let protocolFailure = root.appendingPathComponent("codex-protocol")
        try writeExecutable(
            """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' '/Users/someone/\(String(repeating: "private,fragment-", count: 80)).log' >&2
              printf '%s\\n' 'safe stderr tail' >&2
              printf '%s\\n' '{"id":1,"error":{"code":-32001,"message":"cannot read /Users/someone/private.txt \(String(repeating: "detail-", count: 80))"}}'
            done
            """,
            to: protocolFailure
        )
        do {
            _ = try await fixture.executor().accountState(
                executableURL: protocolFailure,
                workspaceURL: workspace,
                timeoutS: loadTolerantTestTimeoutS
            )
            Issue.record("expected the JSON-RPC error response to fail")
        } catch let error as PostprocessError {
            let description = try #require(error.errorDescription)
            #expect(description.contains("initialize failed with server error -32001"))
            #expect(description.contains("cannot read <redacted-path>"))
            #expect(description.contains("stderr tail:"))
            #expect(description.contains("safe stderr tail"))
            #expect(!description.contains("private-"))
            #expect(!description.contains("fragment-"))
            #expect(!description.contains("/Users/"))
            #expect(description.utf8.count <= SubprocessFailureMessage.maximumUTF8Bytes)
        }
        try fixture.assertScratchIsEmpty()

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
            "codex app server exited with status 7; stderr tail: cannot read <redacted-path>"
        )) {
            _ = try await fixture.executor().accountState(
                executableURL: stderrFailure,
                workspaceURL: workspace,
                timeoutS: loadTolerantTestTimeoutS
            )
        }
        try fixture.assertScratchIsEmpty()

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
            _ = try await fixture.executor().accountState(
                executableURL: malformedFailure,
                workspaceURL: workspace,
                timeoutS: loadTolerantTestTimeoutS
            )
        }
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func deadAppServerInputSurfacesTypedFailureWithoutSIGPIPE() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            completesTurn: false,
            exitsAfterTurnStartResponse: true
        )
        defer { fixture.remove() }

        do {
            _ = try await FoundationCodexAppServerExecutor().run(
                CodexAppServerInvocation(
                    executableURL: fixture.executable,
                    model: "gpt-test",
                    prompt: "bounded private prompt",
                    outputSchema: Data(#"{"type":"object"}"#.utf8),
                    workspaceURL: fixture.workspace,
                    timeoutS: loadTolerantTestTimeoutS
                )
            )
            Issue.record("expected the dead app-server input to fail")
        } catch let error as PostprocessError {
            guard case .backendFailed = error else {
                Issue.record("expected backendFailed, got \(error)")
                return
            }
        }
    }

    @Test func jsonlChannelRemovesReadabilityHandlerAtEOF() throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let channel = CodexJSONLChannel(handle: reader)
        try pipe.fileHandleForWriting.close()

        do {
            _ = try channel.nextLine(deadline: Date().addingTimeInterval(loadTolerantTestTimeoutS))
            Issue.record("expected EOF to close the JSONL channel")
        } catch {
            #expect(reader.readabilityHandler == nil)
        }
        channel.stop()
        try? reader.close()
    }

    @Test func cancellationRequestsTurnInterruptBeforeShutdown() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt", completesTurn: false)
        defer { fixture.remove() }
        let task = Task {
            try await fixture.executor().run(
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
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func timeoutTerminatesTheExactAppServerDescendantTree() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let root = fixture.root
        let workspace = fixture.workspace
        let rootPIDURL = root.appendingPathComponent("root.pid")
        let childPIDURL = root.appendingPathComponent("child.pid")
        let executable = root.appendingPathComponent("codex-timeout")
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
            _ = try await fixture.executor(
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
        let deadline = Date().addingTimeInterval(loadTolerantTestTimeoutS)
        while processIDs.contains(where: processExists), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(processIDs.allSatisfy { !processExists($0) })
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }

    @Test func cancellationTerminatesTheExactAppServerDescendantTree() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let root = fixture.root
        let workspace = fixture.workspace
        let rootPIDURL = root.appendingPathComponent("root.pid")
        let childPIDURL = root.appendingPathComponent("child.pid")
        let executable = root.appendingPathComponent("codex-cancel")
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
            try await fixture.executor(
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
        let deadline = Date().addingTimeInterval(loadTolerantTestTimeoutS)
        while processIDs.contains(where: processExists), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(processIDs.allSatisfy { !processExists($0) })
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileSentinelsAreUnchanged()
    }
}

private struct AppServerFixture {
    enum AuthenticationMutation {
        case none
        case inPlaceRefresh
        case atomicReplacement
    }

    let root: URL
    let workspace: URL
    let executable: URL
    let log: URL
    let sourceHome: URL
    let sourceAuthentication: URL
    let temporaryDirectory: URL

    private let hostileSentinels: [URL: Data]

    init(
        accountType: String?,
        completesTurn: Bool = true,
        exitsAfterAccountResponse: Bool = false,
        exitsAfterTurnStartResponse: Bool = false,
        requirementsJSON: String = "null",
        mcpDataJSON: String = #"[{"name":"fixture-mcp","tools":{},"resources":[],"resourceTemplates":[],"serverInfo":null,"authStatus":"unsupported"}]"#,
        authenticationMutation: AuthenticationMutation = .none
    ) throws {
        root = try freshDirectory(prefix: "maccheroni-app-server-fixture-")
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        executable = root.appendingPathComponent("codex")
        log = root.appendingPathComponent("protocol.log")
        sourceHome = root.appendingPathComponent("parent-codex-home", isDirectory: true)
        sourceAuthentication = sourceHome.appendingPathComponent("auth.json")
        temporaryDirectory = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sourceHome.path
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        try initialSyntheticAuthentication.write(to: sourceAuthentication, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sourceAuthentication.path
        )

        let config = sourceHome.appendingPathComponent("config.toml")
        let profile = sourceHome.appendingPathComponent("hostile.config.toml")
        let plugin = sourceHome.appendingPathComponent("plugins/hostile-plugin/sentinel")
        let mcp = sourceHome.appendingPathComponent("mcp/hostile-mcp/sentinel")
        let session = sourceHome.appendingPathComponent("sessions/hostile-session.json")
        let modelState = sourceHome.appendingPathComponent("models.json")
        hostileSentinels = [
            config: Data("model_provider = \"hostile-provider\"\nproxy = \"hostile-proxy\"\notel = \"hostile-otel\"\n[mcp_servers.hostile-mcp]\ncommand = \"hostile\"\n".utf8),
            profile: Data("model_provider = \"hostile-profile-provider\"\n".utf8),
            plugin: Data("hostile-plugin".utf8),
            mcp: Data("hostile-mcp".utf8),
            session: Data("hostile-session".utf8),
            modelState: Data("hostile-model-state".utf8),
        ]
        for (url, data) in hostileSentinels {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .withoutOverwriting)
        }
        try Data().write(to: log, options: .withoutOverwriting)
        let accountJSON = accountType.map { #"{"type":"\#($0)"}"# } ?? "null"
        let accountExit = exitsAfterAccountResponse ? "exit 0" : ""
        let turnStartExit = exitsAfterTurnStartResponse ? "exit 23" : ""
        let authenticationMutationScript = switch authenticationMutation {
        case .none:
            ""
        case .inPlaceRefresh:
            """
            printf '%s' '{"access_token":"synthetic-access-rotated","refresh_token":"synthetic-refresh-rotated"}' > "$CODEX_HOME/auth.json"
            chmod 600 "$CODEX_HOME/auth.json"
            """
        case .atomicReplacement:
            """
            printf '%s' '{"access_token":"synthetic-access-rotated","refresh_token":"synthetic-refresh-rotated"}' > "$CODEX_HOME/auth.json.next"
            chmod 600 "$CODEX_HOME/auth.json.next"
            mv "$CODEX_HOME/auth.json.next" "$CODEX_HOME/auth.json"
            """
        }
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
            printf 'CHILD_HOME:%s\\n' "$CODEX_HOME" >> '\(log.path)'
            printf 'HOME_MODE:%s\\n' "$(/usr/bin/stat -f '%Lp' "$CODEX_HOME")" >> '\(log.path)'
            printf 'HOME_ENTRIES:' >> '\(log.path)'
            /usr/bin/find "$CODEX_HOME" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename '{}' ';' | /usr/bin/sort | /usr/bin/tr '\\n' ',' >> '\(log.path)'
            printf '\\n' >> '\(log.path)'
            if /usr/bin/grep -q '"access_token":"synthetic-access"' "$CODEX_HOME/auth.json"; then
              printf '%s\\n' 'AUTH_READ:ok' >> '\(log.path)'
            else
              printf '%s\\n' 'AUTH_READ:failed' >> '\(log.path)'
            fi
            printf 'AUTH_STAT:%s\\n' "$(/usr/bin/stat -f '%d:%i:%l:%Lp' "$CODEX_HOME/auth.json")" >> '\(log.path)'
            \(authenticationMutationScript)
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
                  \(turnStartExit)
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

    var environment: [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CODEX_HOME": sourceHome.path,
            "OPENAI_API_KEY": "synthetic-openai-key",
            "CODEX_API_KEY": "synthetic-codex-key",
            "CODEX_ACCESS_TOKEN": "synthetic-codex-token",
        ]
    }

    func executor(
        terminationTiming: ProcessTerminationTiming = .default
    ) -> FoundationCodexAppServerExecutor {
        FoundationCodexAppServerExecutor(
            terminationTiming: terminationTiming,
            environment: environment,
            homeDirectory: root.appendingPathComponent("unused-home", isDirectory: true),
            temporaryDirectory: temporaryDirectory
        )
    }

    func childHomePaths() throws -> [URL] {
        try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let prefix = "CHILD_HOME:"
                guard line.hasPrefix(prefix) else { return nil }
                return URL(fileURLWithPath: String(line.dropFirst(prefix.count)), isDirectory: true)
            }
    }

    func assertScratchIsEmpty(sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).isEmpty,
            sourceLocation: sourceLocation
        )
    }

    func assertHostileSentinelsAreUnchanged(sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(FileManager.default.fileExists(atPath: sourceHome.path), sourceLocation: sourceLocation)
        for (url, expected) in hostileSentinels {
            #expect(try Data(contentsOf: url) == expected, sourceLocation: sourceLocation)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum InvalidAuthenticationKind: CaseIterable {
    case missing
    case directory
    case symlink
    case worldReadable

    func apply(to fixture: AppServerFixture) throws {
        try FileManager.default.removeItem(at: fixture.sourceAuthentication)
        switch self {
        case .missing:
            break
        case .directory:
            try FileManager.default.createDirectory(
                at: fixture.sourceAuthentication,
                withIntermediateDirectories: false
            )
        case .symlink:
            let target = fixture.root.appendingPathComponent("synthetic-auth-target.json")
            try initialSyntheticAuthentication.write(to: target, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: target.path
            )
            try FileManager.default.createSymbolicLink(
                at: fixture.sourceAuthentication,
                withDestinationURL: target
            )
        case .worldReadable:
            try initialSyntheticAuthentication.write(
                to: fixture.sourceAuthentication,
                options: .withoutOverwriting
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: fixture.sourceAuthentication.path
            )
        }
    }
}

private struct FileStatus {
    let device: dev_t
    let inode: ino_t
    let linkCount: nlink_t
    let permissions: mode_t
    let fileType: mode_t
}

private func fileStatus(at url: URL) throws -> FileStatus {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    return FileStatus(
        device: status.st_dev,
        inode: status.st_ino,
        linkCount: status.st_nlink,
        permissions: status.st_mode & 0o777,
        fileType: status.st_mode & mode_t(S_IFMT)
    )
}

private func parsedAuthenticationStatus(from transcript: String) throws -> FileStatus {
    let prefix = "AUTH_STAT:"
    let line = try #require(transcript.split(whereSeparator: \.isNewline).first {
        $0.hasPrefix(prefix)
    })
    let fields = line.dropFirst(prefix.count).split(separator: ":")
    #expect(fields.count == 4)
    return FileStatus(
        device: try #require(dev_t(fields[0])),
        inode: try #require(ino_t(fields[1])),
        linkCount: try #require(nlink_t(fields[2])),
        permissions: try #require(mode_t(fields[3], radix: 8)),
        fileType: mode_t(S_IFREG)
    )
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
    let deadline = Date().addingTimeInterval(loadTolerantTestTimeoutS)
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
    let deadline = Date().addingTimeInterval(loadTolerantTestTimeoutS)
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
