import Darwin
import Foundation
import MaccheroniCore
import Security
import Testing
@testable import MaccheroniPostprocess

private let loadTolerantTestTimeoutS: TimeInterval = 10
private let unavailableAuthenticationMessage =
    "Your Codex sign-in is expired or too close to expiry. Refresh or sign in through Codex, then retry, or select Local."
private let accountMismatchMessage =
    "Codex did not accept the ChatGPT subscription credential. Refresh or sign in through Codex, then retry, or select Local."
private let refreshAuthenticationMessage =
    "Codex requested a token refresh. Refresh or sign in through Codex, then retry, or select Local."

@Suite(.serialized)
struct CodexAppServerTests {
    @Test func runsInjectedSchemaConstrainedTurnInAnEmptyEphemeralHome() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let credentialBefore = try readCredentialMetadata(at: fixture.sourceAuthentication)
        let sourceBytesBefore = try Data(contentsOf: fixture.sourceAuthentication)
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
        #expect(try fixture.argumentVector() == [
            "app-server",
            "-c", #"openai_base_url="""#,
            "-c", #"chatgpt_base_url="https://chatgpt.com/backend-api/""#,
            "-c", #"cli_auth_credentials_store="ephemeral""#,
            "--listen", "stdio://",
        ])
        #expect(try fixture.metadataValue(prefix: "SECRETS:") == "unset|unset|unset")
        #expect(try fixture.metadataValue(prefix: "HOME_MODE:") == "700")
        #expect(try fixture.metadataValue(prefix: "HOME_ENTRIES:").isEmpty)

        let records = try fixture.rpcRecords()
        let clientMethods = records.compactMap { record -> String? in
            guard record.direction == .client else { return nil }
            return record.object["method"] as? String
        }
        #expect(clientMethods == [
            "initialize",
            "initialized",
            "account/login/start",
            "account/read",
            "config/read",
            "configRequirements/read",
            "model/list",
            "thread/start",
            "mcpServerStatus/list",
            "turn/start",
        ])

        let initialize = try #require(records.clientRequest(method: "initialize"))
        let initializeParams = try #require(initialize["params"] as? [String: Any])
        let capabilities = try #require(initializeParams["capabilities"] as? [String: Any])
        #expect(capabilities["experimentalApi"] as? Bool == true)

        let login = try #require(records.clientRequest(method: "account/login/start"))
        let loginParams = try #require(login["params"] as? [String: Any])
        #expect(Set(loginParams.keys) == [
            "type", "accessToken", "chatgptAccountId", "chatgptPlanType",
        ])
        #expect(loginParams["type"] as? String == "chatgptAuthTokens")
        #expect(loginParams["accessToken"] as? String == "<redacted>")
        #expect(loginParams["chatgptAccountId"] as? String == "account-fixture")
        #expect(loginParams["chatgptPlanType"] is NSNull)
        #expect(
            records.index(ofClientMethod: "account/login/start")
                < records.index(ofClientMethod: "account/read")
        )
        #expect(
            records.index(ofClientMethod: "account/read")
                < records.index(ofClientMethod: "thread/start")
        )

        let configResponse = try #require(records.serverResponse(id: 4))
        let configResult = try #require(configResponse["result"] as? [String: Any])
        let layers = try #require(configResult["layers"] as? [[String: Any]])
        let layerTypes = layers.compactMap {
            ($0["name"] as? [String: Any])?["type"] as? String
        }
        #expect(layerTypes == ["sessionFlags"])
        let config = try #require(configResult["config"] as? [String: Any])
        #expect(config["model_provider"] == nil)
        #expect(config["proxy"] == nil)
        #expect(config["otel"] == nil)

        let thread = try #require(records.clientRequest(method: "thread/start"))
        let threadParams = try #require(thread["params"] as? [String: Any])
        #expect(threadParams["model"] as? String == "gpt-test")
        #expect(threadParams["modelProvider"] as? String == "openai")
        #expect(threadParams["cwd"] as? String == fixture.workspace.path)
        #expect(threadParams["approvalPolicy"] as? String == "never")
        #expect(threadParams["sandbox"] as? String == "read-only")
        #expect(threadParams["ephemeral"] as? Bool == true)
        #expect((threadParams["environments"] as? [Any])?.isEmpty == true)
        #expect((threadParams["dynamicTools"] as? [Any])?.isEmpty == true)
        #expect((threadParams["selectedCapabilityRoots"] as? [Any])?.isEmpty == true)
        let threadConfig = try #require(threadParams["config"] as? [String: Any])
        #expect(threadConfig["openai_base_url"] as? String == "")
        #expect(threadConfig["chatgpt_base_url"] as? String == "https://chatgpt.com/backend-api/")
        #expect(threadConfig["model_reasoning_effort"] as? String == "high")
        #expect(threadConfig["features.code_mode"] as? Bool == false)
        #expect(threadConfig["features.plugins"] as? Bool == false)
        #expect(threadConfig["features.deferred_executor"] as? Bool == false)
        #expect(threadConfig["tools.update_plan.enabled"] as? Bool == false)
        let mcpConfig = try #require(threadConfig["mcp_servers"] as? [String: Any])
        let fixtureMCP = try #require(mcpConfig["fixture-mcp"] as? [String: Any])
        #expect(fixtureMCP["enabled"] as? Bool == false)

        let turn = try #require(records.clientRequest(method: "turn/start"))
        let turnParams = try #require(turn["params"] as? [String: Any])
        #expect(turnParams["model"] as? String == "gpt-test")
        #expect(turnParams["effort"] as? String == "high")
        #expect(turnParams["approvalPolicy"] as? String == "never")
        #expect(turnParams["outputSchema"] is [String: Any])
        #expect(turnParams["cwd"] == nil)

        let approval = try #require(records.firstClientResponse(id: 900))
        let approvalResult = try #require(approval["result"] as? [String: Any])
        #expect(approvalResult["decision"] as? String == "decline")
        #expect(!records.containsClientMethod("command/exec"))

        let childHome = try #require(fixture.childHomePaths().first)
        #expect(childHome.standardizedFileURL != fixture.sourceHome.standardizedFileURL)
        #expect(childHome.lastPathComponent == "codex-home")
        #expect(!FileManager.default.fileExists(atPath: childHome.path))
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileParentHomeUnchanged()
        #expect(try Data(contentsOf: fixture.sourceAuthentication) == sourceBytesBefore)
        #expect(try readCredentialMetadata(at: fixture.sourceAuthentication) == credentialBefore)
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(fixture.accessToken))
    }

    @Test func accountProbeInjectsThenRequiresAChatGPTSubscriptionAccount() async throws {
        let signedIn = try AppServerFixture(
            accountType: "chatgpt",
            credentialPlanType: "plus"
        )
        defer { signedIn.remove() }
        let signedInCredentialBefore = try Data(
            contentsOf: signedIn.sourceAuthentication
        )
        let signedInCredentialMetadataBefore = try readCredentialMetadata(
            at: signedIn.sourceAuthentication
        )
        #expect(try await accountStateAfterLoginReadiness(in: signedIn) == .chatGPT)
        let signedInLogin = try #require(
            signedIn.rpcRecords().clientRequest(method: "account/login/start")
        )
        #expect(
            (signedInLogin["params"] as? [String: Any])?["chatgptPlanType"] as? String
                == "plus"
        )

        let apiKey = try AppServerFixture(accountType: "apiKey")
        defer { apiKey.remove() }
        let apiKeyCredentialBefore = try Data(
            contentsOf: apiKey.sourceAuthentication
        )
        let apiKeyCredentialMetadataBefore = try readCredentialMetadata(
            at: apiKey.sourceAuthentication
        )
        #expect(try await accountStateAfterLoginReadiness(in: apiKey) == .unsupported)
        await #expect(throws: PostprocessError.authenticationRequired(accountMismatchMessage)) {
            _ = try await apiKey.executor().run(apiKey.invocation())
        }
        #expect(try !apiKey.rpcRecords().containsClientMethod("thread/start"))

        let signedOut = try AppServerFixture(accountType: nil)
        defer { signedOut.remove() }
        let signedOutCredentialBefore = try Data(
            contentsOf: signedOut.sourceAuthentication
        )
        let signedOutCredentialMetadataBefore = try readCredentialMetadata(
            at: signedOut.sourceAuthentication
        )
        #expect(try await accountStateAfterLoginReadiness(in: signedOut) == .signedOut)

        for (fixture, credentialBefore, credentialMetadataBefore) in [
            (signedIn, signedInCredentialBefore, signedInCredentialMetadataBefore),
            (apiKey, apiKeyCredentialBefore, apiKeyCredentialMetadataBefore),
            (signedOut, signedOutCredentialBefore, signedOutCredentialMetadataBefore),
        ] {
            try fixture.assertScratchIsEmpty()
            try fixture.assertHostileParentHomeUnchanged()
            #expect(
                try Data(contentsOf: fixture.sourceAuthentication)
                    == credentialBefore
            )
            #expect(
                try readCredentialMetadata(at: fixture.sourceAuthentication)
                    == credentialMetadataBefore
            )
            let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
            #expect(!transcript.contains(fixture.accessToken))
        }
    }

    @Test func rejectedLoginFailsAuthenticationBeforeAccountRead() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            loginBehavior: .reject
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.authenticationRequired(
            unavailableAuthenticationMessage
        )) {
            _ = try await fixture.executor().run(fixture.invocation())
        }

        let records = try fixture.rpcRecords()
        #expect(records.containsClientMethod("account/login/start"))
        #expect(!records.containsClientMethod("account/read"))
        #expect(!records.containsClientMethod("thread/start"))
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(fixture.accessToken))
        try fixture.assertScratchIsEmpty()
    }

    @Test func unavailableCredentialsFailBeforeLoginWithActionableGuidance() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let sources = [
            CodexCredentialSource(
                environment: fixture.environment,
                homeDirectory: fixture.root,
                keychainReader: { _ in .itemNotFound },
                fileReader: { _ in throw CocoaError(.fileReadNoSuchFile) },
                now: Date.init
            ),
            CodexCredentialSource(
                environment: fixture.environment,
                homeDirectory: fixture.root,
                keychainReader: { _ in
                    .found(syntheticAppServerCredential(expiration: 1).record)
                },
                now: Date.init
            ),
        ]

        for source in sources {
            await #expect(throws: PostprocessError.authenticationRequired(
                unavailableAuthenticationMessage
            )) {
                _ = try await fixture.executor(credentialSource: source).run(
                    fixture.invocation()
                )
            }
        }
        let records = try fixture.rpcRecords()
        #expect(records.filter {
            $0.direction == .client && $0.object["method"] as? String == "initialize"
        }.count == 2)
        #expect(!records.containsClientMethod("account/login/start"))
        #expect(!records.containsClientMethod("thread/start"))
        try fixture.assertScratchIsEmpty()
    }

    @Test func postAuthenticationServerTextCannotReachDiagnostics() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            accountReadErrorMessage: "reflected-secret-sentinel"
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: account/read failed with server error -32000: message unavailable after authentication"
        )) {
            _ = try await fixture.executor().accountState(
                executableURL: fixture.executable,
                workspaceURL: fixture.workspace,
                timeoutS: 2
            )
        }
        try fixture.assertScratchIsEmpty()
    }

    @Test func unexpectedTokenRefreshReturnsAnErrorAndDoesNotPromoteOutput() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            turnBehavior: .requestRefresh
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.authenticationRequired(
            refreshAuthenticationMessage
        )) {
            _ = try await fixture.executor().run(fixture.invocation())
        }

        let records = try fixture.rpcRecords()
        let refresh = try #require(records.serverRequest(
            method: "account/chatgptAuthTokens/refresh"
        ))
        #expect((refresh["params"] as? [String: Any])?["reason"] as? String == "unauthorized")
        let rejection = try #require(records.firstClientResponse(id: 901))
        #expect(rejection["result"] == nil)
        let error = try #require(rejection["error"] as? [String: Any])
        #expect((error["code"] as? NSNumber)?.intValue == -32000)
        #expect(error["message"] as? String == refreshAuthenticationMessage)
        #expect(records.containsClientMethod("turn/interrupt"))
        let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
        #expect(!transcript.contains(fixture.accessToken))
        try fixture.assertScratchIsEmpty()
    }

    @Test func createsAFreshEmptyIsolatedHomeForEveryProcess() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }

        for _ in 0 ..< 2 {
            #expect(try await fixture.executor().accountState(
                executableURL: fixture.executable,
                workspaceURL: fixture.workspace,
                timeoutS: 2
            ) == .chatGPT)
        }

        let homes = try fixture.childHomePaths()
        #expect(homes.count == 2)
        #expect(Set(homes.map(\.path)).count == 2)
        #expect(try fixture.metadataValues(prefix: "HOME_MODE:") == ["700", "700"])
        #expect(try fixture.metadataValues(prefix: "HOME_ENTRIES:") == ["", ""])
        #expect(homes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        try fixture.assertScratchIsEmpty()
    }

    @Test func drainsAnAccountResponseWrittenImmediatelyBeforeExit() async throws {
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
        try fixture.assertScratchIsEmpty()
    }

    @Test func managedHooksAndActiveMCPRemainFailClosed() async throws {
        let managed = try AppServerFixture(
            accountType: "chatgpt",
            requirementsJSON: #"{"hooks":{"SessionStart":[{"command":"managed"}]}}"#
        )
        defer { managed.remove() }
        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: cannot override managed hooks"
        )) {
            _ = try await managed.executor().run(managed.invocation())
        }
        #expect(try !managed.rpcRecords().containsClientMethod("thread/start"))

        let activeMCP = try AppServerFixture(
            accountType: "chatgpt",
            mcpDataJSON: #"[{"name":"managed-mcp"}]"#
        )
        defer { activeMCP.remove() }
        await #expect(throws: PostprocessError.backendFailed(
            "codex app server protocol error: mcpServerStatus/list found an active or unexpected server"
        )) {
            _ = try await activeMCP.executor().run(activeMCP.invocation())
        }
        #expect(try !activeMCP.rpcRecords().containsClientMethod("turn/start"))
        try managed.assertScratchIsEmpty()
        try activeMCP.assertScratchIsEmpty()
    }

    @Test func launchFailureCleansScratchWithoutReadingOrChangingNativeCredentials() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let credentialBefore = try readCredentialMetadata(at: fixture.sourceAuthentication)
        let bytesBefore = try Data(contentsOf: fixture.sourceAuthentication)
        let credentialReads = LockedInt()
        let source = CodexCredentialSource(
            environment: fixture.environment,
            homeDirectory: fixture.root,
            keychainReader: { _ in
                credentialReads.increment()
                return .failed
            },
            now: Date.init
        )

        await #expect(throws: PostprocessError.launchFailed(
            "could not launch codex app server"
        )) {
            _ = try await fixture.executor(credentialSource: source).accountState(
                executableURL: fixture.root.appendingPathComponent("missing-codex"),
                workspaceURL: fixture.workspace,
                timeoutS: 2
            )
        }

        #expect(try Data(contentsOf: fixture.log).isEmpty)
        #expect(credentialReads.value == 0)
        #expect(try Data(contentsOf: fixture.sourceAuthentication) == bytesBefore)
        #expect(try readCredentialMetadata(at: fixture.sourceAuthentication) == credentialBefore)
        try fixture.assertScratchIsEmpty()
    }

    @Test func protocolErrorsAreBoundedAndPathRedactedWithoutPersistedStderr() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let executable = fixture.root.appendingPathComponent("codex-protocol")
        try writeExecutable(
            """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' '{"id":1,"error":{"code":-32001,"message":"cannot read /Users/someone/private.txt \(String(repeating: "detail-", count: 80))"}}'
            done
            """,
            to: executable
        )

        do {
            _ = try await fixture.executor().accountState(
                executableURL: executable,
                workspaceURL: fixture.workspace,
                timeoutS: loadTolerantTestTimeoutS
            )
            Issue.record("expected protocol failure")
        } catch let error as PostprocessError {
            let description = try #require(error.errorDescription)
            #expect(description.contains("initialize failed with server error -32001"))
            #expect(description.contains("cannot read <redacted-path>"))
            #expect(description.hasSuffix(SubprocessFailureMessage.truncationMarker))
            #expect(!description.contains("/Users/"))
            #expect(description.utf8.count <= SubprocessFailureMessage.maximumUTF8Bytes)
        }
        try fixture.assertScratchIsEmpty()
    }

    @Test func deadAppServerInputSurfacesTypedFailureWithoutSIGPIPE() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            turnBehavior: .exitAfterStart
        )
        defer { fixture.remove() }

        await #expect(throws: PostprocessError.self) {
            _ = try await fixture.executor().run(fixture.invocation())
        }
        try fixture.assertScratchIsEmpty()
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

    @Test func cancellationRequestsTurnInterruptBeforeConfirmedCleanup() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt", turnBehavior: .wait)
        defer { fixture.remove() }
        let task = Task { try await fixture.executor().run(fixture.invocation(timeoutS: 30)) }
        try await waitForClientMethod("turn/start", in: fixture)

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        let records = try fixture.rpcRecords()
        let interrupt = try #require(records.clientRequest(method: "turn/interrupt"))
        let params = try #require(interrupt["params"] as? [String: Any])
        #expect(params["threadId"] as? String == "thread-1")
        #expect(params["turnId"] as? String == "turn-1")
        try fixture.assertScratchIsEmpty()
    }

    @Test func timeoutTerminatesTheExactAppServerDescendantTreeAndCleansScratch() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let credentialBefore = try Data(contentsOf: fixture.sourceAuthentication)
        let credentialMetadataBefore = try readCredentialMetadata(
            at: fixture.sourceAuthentication
        )
        let rootPIDURL = fixture.root.appendingPathComponent("root.pid")
        let childPIDURL = fixture.root.appendingPathComponent("child.pid")
        let executable = fixture.root.appendingPathComponent("codex-timeout")
        try writeExecutable(
            """
            #!/bin/sh
            printf '%s' "$$" > '\(rootPIDURL.path)'
            (trap '' TERM; while :; do sleep 1; done) &
            child=$!
            printf '%s' "$child" > '\(childPIDURL.path)'
            while IFS= read -r line; do :; done
            wait "$child"
            """,
            to: executable
        )

        let timeoutTask = Task {
            try await fixture.executor(
                terminationTiming: ProcessTerminationTiming(
                    gracePeriodS: 0.05,
                    pollIntervalS: 0.01,
                    exitWaitS: 0.5
                )
            ).accountState(
                executableURL: executable,
                workspaceURL: fixture.workspace,
                timeoutS: loadTolerantTestTimeoutS
            )
        }
        let processIDs: [Int32]
        do {
            processIDs = try await [rootPIDURL, childPIDURL].asyncMap(waitForPID)
        } catch {
            timeoutTask.cancel()
            _ = await timeoutTask.result
            throw error
        }
        await #expect(throws: PostprocessError.backendFailed(
            "codex app server timed out after \(Int(loadTolerantTestTimeoutS)) seconds"
        )) {
            _ = try await timeoutTask.value
        }
        try await waitForProcessesToExit(processIDs)
        #expect(processIDs.allSatisfy { !processExists($0) })
        try fixture.assertScratchIsEmpty()
        try fixture.assertHostileParentHomeUnchanged()
        #expect(try Data(contentsOf: fixture.sourceAuthentication) == credentialBefore)
        #expect(
            try readCredentialMetadata(at: fixture.sourceAuthentication)
                == credentialMetadataBefore
        )
    }

    @Test func cancellationTerminatesTheExactAppServerDescendantTreeAndCleansScratch() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let rootPIDURL = fixture.root.appendingPathComponent("cancel-root.pid")
        let childPIDURL = fixture.root.appendingPathComponent("cancel-child.pid")
        let executable = fixture.root.appendingPathComponent("codex-cancel")
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
                workspaceURL: fixture.workspace,
                timeoutS: 30
            )
        }
        let processIDs = try await [rootPIDURL, childPIDURL].asyncMap(waitForPID)

        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        try await waitForProcessesToExit(processIDs)
        #expect(processIDs.allSatisfy { !processExists($0) })
        try fixture.assertScratchIsEmpty()
    }

    @Test func unconfirmedTerminationRetainsEmptyScratchAndSurfacesSpecificFailure() async throws {
        let cases: [(ProcessTerminationResult, String)] = [
            (
                .signalFailed(errno: EPERM),
                "codex app server termination was not confirmed after signalling failed; scratch was retained"
            ),
            (
                .exitWaitTimedOut,
                "codex app server termination was not confirmed before the exit deadline; scratch was retained"
            ),
        ]
        for (reportedResult, expectedMessage) in cases {
            let fixture = try AppServerFixture(
                accountType: "chatgpt",
                lingerAfterEOF: true
            )
            defer { fixture.remove() }
            let executor = fixture.executor(terminateProcess: { _, _, _ in
                return reportedResult
            })

            do {
                _ = try await executor.accountState(
                    executableURL: fixture.executable,
                    workspaceURL: fixture.workspace,
                    timeoutS: 2
                )
                Issue.record("expected unconfirmed termination failure")
            } catch let error as PostprocessError {
                let description = try #require(error.errorDescription)
                #expect(description == expectedMessage)
            }
            let childPID = try #require(Int32(fixture.metadataValue(prefix: "CHILD_PID:")))
            #expect(processExists(childPID))
            let retained = try FileManager.default.contentsOfDirectory(
                at: fixture.temporaryDirectory,
                includingPropertiesForKeys: nil
            )
            #expect(retained.count == 1)
            let childHome = try #require(fixture.childHomePaths().first)
            #expect(FileManager.default.fileExists(atPath: childHome.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: childHome.path).isEmpty)
            let transcript = try String(contentsOf: fixture.log, encoding: .utf8)
            #expect(!transcript.contains(fixture.accessToken))
            _ = Darwin.kill(childPID, SIGKILL)
            try await waitForProcessesToExit([childPID])
            #expect(!processExists(childPID))
        }
    }

    @Test func completedOutputWinsOverPostCompletionScratchCleanupFailure() async throws {
        let fixture = try AppServerFixture(accountType: "chatgpt")
        defer { fixture.remove() }
        let executor = fixture.executor(removeScratch: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        let output = try await executor.run(fixture.invocation())

        #expect(String(decoding: output, as: UTF8.self) == #"{"answer":"ok"}"#)
        #expect(try !FileManager.default.contentsOfDirectory(
            atPath: fixture.temporaryDirectory.path
        ).isEmpty)
    }

    @Test func authenticationFailureWinsOverPostFailureScratchCleanupFailure() async throws {
        let fixture = try AppServerFixture(
            accountType: "chatgpt",
            loginBehavior: .reject
        )
        defer { fixture.remove() }
        let executor = fixture.executor(removeScratch: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        await #expect(throws: PostprocessError.authenticationRequired(
            unavailableAuthenticationMessage
        )) {
            _ = try await executor.run(fixture.invocation())
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment[
        "MACCHERONI_RUN_CODEX_AUTH_INTEGRATION"
    ] == "1"))
    func actualCodexEphemeralAuthProbeLeavesNativeCredentialMetadataUnchanged() async throws {
        let executable = try #require(CodexPostprocessBackend.defaultExecutableURL)
        let source = CodexCredentialSource()
        let home = try source.activeHomeURL()
        let account = try source.keychainAccount()
        let before = nativeCredentialMetadata(home: home, keychainAccount: account)
        let workspace = try freshDirectory(prefix: "maccheroni-real-codex-auth-")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let probe = try await FoundationCodexAppServerExecutor()
            .authenticationIntegrationProbe(
                executableURL: executable,
                workspaceURL: workspace,
                timeoutS: 5
            )

        let after = nativeCredentialMetadata(home: home, keychainAccount: account)
        #expect(probe.accountState == .chatGPT)
        // The real app-server always enumerates the user and system layers, so
        // only an empty layer proves isolation. Session flags are ours.
        #expect(probe.populatedConfigLayerTypes == ["sessionFlags"])
        #expect(before == after)
    }
}

private enum FixtureLoginBehavior { case accept, reject }
private enum FixtureTurnBehavior { case complete, wait, requestRefresh, exitAfterStart }

private struct AppServerFixture {
    let root: URL
    let workspace: URL
    let executable: URL
    let log: URL
    let sourceHome: URL
    let sourceAuthentication: URL
    let temporaryDirectory: URL
    let accessToken: String

    private let hostileParentFiles: [URL: Data]

    init(
        accountType: String?,
        loginBehavior: FixtureLoginBehavior = .accept,
        turnBehavior: FixtureTurnBehavior = .complete,
        exitsAfterAccountResponse: Bool = false,
        lingerAfterEOF: Bool = false,
        credentialPlanType: String? = nil,
        accountReadErrorMessage: String? = nil,
        requirementsJSON: String = "null",
        mcpDataJSON: String = #"[{"name":"fixture-mcp","tools":{},"resources":[],"resourceTemplates":[],"serverInfo":null,"authStatus":"unsupported"}]"#
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
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceHome.path)

        let credential = syntheticAppServerCredential(planType: credentialPlanType)
        accessToken = credential.accessToken
        try credential.record.write(to: sourceAuthentication, options: .withoutOverwriting)
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
        hostileParentFiles = [
            config: Data("model_provider = \"hostile-provider\"\nproxy = \"hostile-proxy\"\notel = \"hostile-otel\"\n".utf8),
            profile: Data("model_provider = \"hostile-profile-provider\"\n".utf8),
            plugin: Data("hostile-plugin".utf8),
            mcp: Data("hostile-mcp".utf8),
            session: Data("hostile-session".utf8),
            modelState: Data("hostile-model-state".utf8),
        ]
        for (url, data) in hostileParentFiles {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .withoutOverwriting)
        }
        try Data().write(to: log, options: .withoutOverwriting)

        let accountJSON = accountType.map { #"{"type":"\#($0)"}"# } ?? "null"
        let accountExit = exitsAfterAccountResponse ? "exit 0" : ""
        let eofAction = lingerAfterEOF ? "/bin/sleep 5" : ""
        let accountReadAction = accountReadErrorMessage.map {
            "send '{\"id\":3,\"error\":{\"code\":-32000,\"message\":\"\($0)\"}}'"
        } ?? "send '{\"id\":3,\"result\":{\"account\":\(accountJSON),\"requiresOpenaiAuth\":true}}'"
        let serializedPlan = credentialPlanType.map { "\"\($0)\"" } ?? "null"
        let planValidation = credentialPlanType.map {
            "[ \"$login_plan_type\" = 'string' ] && [ \"$login_plan\" = '\($0)' ] || valid_login=0"
        } ?? "[ \"$login_plan_type\" = '(any)' ] || valid_login=0"
        let loginResponse = switch loginBehavior {
        case .accept:
            "send '{\"id\":2,\"result\":{\"type\":\"chatgptAuthTokens\"}}'"
        case .reject:
            "send '{\"id\":2,\"error\":{\"code\":-32000,\"message\":\"synthetic login rejection\"}}'"
        }
        let turnAction = switch turnBehavior {
        case .complete:
            """
            send '{"id":900,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1"}}'
            IFS= read -r approval
            printf 'C:%s\\n' "$approval" >> '\(log.path)'
            send '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"message-1","type":"agentMessage","phase":"final_answer","text":"{\\"answer\\":\\"ok\\"}"}}}'
            send '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","threadId":"thread-1","status":"completed","items":[]}}}'
            """
        case .wait:
            ""
        case .requestRefresh:
            """
            send '{"id":901,"method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized","previousAccountId":"account-fixture"}}'
            IFS= read -r refresh_response
            printf 'C:%s\\n' "$refresh_response" >> '\(log.path)'
            send '{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"message-partial","type":"agentMessage","phase":"final_answer","text":"{\\"answer\\":\\"partial\\"}"}}}'
            send '{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","threadId":"thread-1","status":"completed","items":[]}}}'
            """
        case .exitAfterStart:
            "exit 23"
        }

        try writeExecutable(
            """
            #!/bin/sh
            send() {
              printf 'S:%s\\n' "$1" >> '\(log.path)'
              printf '%s\\n' "$1"
            }
            for argument in "$@"; do
              printf 'ARG:%s\\n' "$argument" >> '\(log.path)'
            done
            printf 'SECRETS:%s|%s|%s\\n' "${OPENAI_API_KEY-unset}" "${CODEX_API_KEY-unset}" "${CODEX_ACCESS_TOKEN-unset}" >> '\(log.path)'
            printf 'CHILD_PID:%s\\n' "$$" >> '\(log.path)'
            printf 'CHILD_HOME:%s\\n' "$CODEX_HOME" >> '\(log.path)'
            printf 'HOME_MODE:%s\\n' "$(/usr/bin/stat -f '%Lp' "$CODEX_HOME")" >> '\(log.path)'
            printf 'HOME_ENTRIES:' >> '\(log.path)'
            /usr/bin/find "$CODEX_HOME" -mindepth 1 -maxdepth 1 -exec /usr/bin/basename '{}' ';' | /usr/bin/sort | /usr/bin/tr '\\n' ',' >> '\(log.path)'
            printf '\\n' >> '\(log.path)'
            while IFS= read -r line; do
              method=$(printf '%s' "$line" | /usr/bin/plutil -extract method raw -o - -- - 2>/dev/null || true)
              case "$method" in
                'account/login/start')
                  valid_login=1
                  parameter_keys=$(printf '%s' "$line" | /usr/bin/plutil -extract params raw -o - -- - 2>/dev/null || true)
                  expected_keys='accessToken
            chatgptAccountId
            chatgptPlanType
            type'
                  [ "$parameter_keys" = "$expected_keys" ] || valid_login=0
                  login_type=$(printf '%s' "$line" | /usr/bin/plutil -extract params.type raw -o - -- - 2>/dev/null || true)
                  login_access=$(printf '%s' "$line" | /usr/bin/plutil -extract params.accessToken raw -o - -- - 2>/dev/null || true)
                  login_account=$(printf '%s' "$line" | /usr/bin/plutil -extract params.chatgptAccountId raw -o - -- - 2>/dev/null || true)
                  login_plan_type=$(printf '%s' "$line" | /usr/bin/plutil -type params.chatgptPlanType -o - -- - 2>/dev/null || true)
                  login_plan=$(printf '%s' "$line" | /usr/bin/plutil -extract params.chatgptPlanType raw -o - -- - 2>/dev/null || true)
                  [ "$login_type" = 'chatgptAuthTokens' ] || valid_login=0
                  [ -n "$login_access" ] || valid_login=0
                  unset login_access
                  [ "$login_account" = 'account-fixture' ] || valid_login=0
                  \(planValidation)
                  printf 'C:%s\\n' '{"id":2,"method":"account/login/start","params":{"type":"chatgptAuthTokens","accessToken":"<redacted>","chatgptAccountId":"account-fixture","chatgptPlanType":\(serializedPlan)}}' >> '\(log.path)'
                  if [ "$valid_login" -ne 1 ]; then
                    send '{"id":2,"error":{"code":-32602,"message":"invalid external auth fields"}}'
                    continue
                  fi
                  \(loginResponse)
                  ;;
                *)
                  printf 'C:%s\\n' "$line" >> '\(log.path)'
                  case "$method" in
                    'initialize')
                      send '{"id":1,"result":{"userAgent":"maccheroni-test/0.147.0"}}'
                      ;;
                    'account/read')
                      \(accountReadAction)
                      \(accountExit)
                      ;;
                    'config/read')
                      if [ -e "$CODEX_HOME/config.toml" ]; then
                        send '{"id":4,"result":{"config":{"model_provider":"inherited"},"layers":[{"name":{"type":"user"}}]}}'
                      else
                        send '{"id":4,"result":{"config":{"mcp_servers":{"fixture-mcp":{"command":"fixture"}}},"layers":[{"name":{"type":"sessionFlags"}}]}}'
                      fi
                      ;;
                    'configRequirements/read')
                      send '{"id":5,"result":{"requirements":\(requirementsJSON)}}'
                      ;;
                    'model/list')
                      send '{"id":6,"result":{"data":[{"id":"gpt-test","model":"gpt-test","defaultReasoningEffort":"high"}],"nextCursor":null}}'
                      ;;
                    'thread/start')
                      send '{"id":700,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1"}}'
                      IFS= read -r collision_response
                      printf 'C:%s\\n' "$collision_response" >> '\(log.path)'
                      send '{"id":7,"result":{"thread":{"id":"thread-1"}}}'
                      ;;
                    'mcpServerStatus/list')
                      send '{"id":8,"result":{"data":\(mcpDataJSON),"nextCursor":null}}'
                      ;;
                    'turn/start')
                      send '{"id":9,"result":{"turn":{"id":"turn-1","status":"inProgress","items":[]}}}'
                      \(turnAction)
                      ;;
                    'turn/interrupt')
                      send '{"id":10,"result":{}}'
                      ;;
                  esac
                  ;;
              esac
            done
            \(eofAction)
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
        terminationTiming: ProcessTerminationTiming = .default,
        credentialSource: CodexCredentialSource? = nil,
        terminateProcess: @escaping @Sendable (
            Int32,
            @escaping @Sendable () -> Bool,
            ProcessTerminationTiming
        ) async -> ProcessTerminationResult = ProcessTerminator.terminate,
        removeScratch: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) -> FoundationCodexAppServerExecutor {
        FoundationCodexAppServerExecutor(
            terminationTiming: terminationTiming,
            environment: environment,
            temporaryDirectory: temporaryDirectory,
            credentialSource: credentialSource ?? CodexCredentialSource(
                environment: environment,
                homeDirectory: root.appendingPathComponent("unused-home", isDirectory: true),
                keychainReader: { _ in .itemNotFound },
                now: Date.init
            ),
            terminateProcess: terminateProcess,
            removeScratch: removeScratch
        )
    }

    func invocation(timeoutS: TimeInterval = 10) -> CodexAppServerInvocation {
        CodexAppServerInvocation(
            executableURL: executable,
            model: "gpt-test",
            prompt: "bounded private prompt",
            outputSchema: Data(#"{"type":"object"}"#.utf8),
            workspaceURL: workspace,
            timeoutS: timeoutS
        )
    }

    func rpcRecords() throws -> [RPCRecord] {
        try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let direction: RPCDirection
                if line.hasPrefix("C:") {
                    direction = .client
                } else if line.hasPrefix("S:") {
                    direction = .server
                } else {
                    return nil
                }
                let data = Data(line.dropFirst(2).utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return RPCRecord(direction: direction, object: object)
            }
    }

    func argumentVector() throws -> [String] {
        try metadataValues(prefix: "ARG:")
    }

    func childHomePaths() throws -> [URL] {
        try metadataValues(prefix: "CHILD_HOME:").map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    func metadataValue(prefix: String) throws -> String {
        try #require(metadataValues(prefix: prefix).first)
    }

    func metadataValues(prefix: String) throws -> [String] {
        try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line in
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }
    }

    func assertScratchIsEmpty(sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path).isEmpty,
            sourceLocation: sourceLocation
        )
    }

    func assertHostileParentHomeUnchanged(
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        for (url, expected) in hostileParentFiles {
            #expect(try Data(contentsOf: url) == expected, sourceLocation: sourceLocation)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum RPCDirection: Equatable { case client, server }

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private struct RPCRecord {
    let direction: RPCDirection
    let object: [String: Any]
}

private extension Array where Element == RPCRecord {
    func clientRequest(method: String) -> [String: Any]? {
        first { $0.direction == .client && $0.object["method"] as? String == method }?.object
    }

    func serverRequest(method: String) -> [String: Any]? {
        first { $0.direction == .server && $0.object["method"] as? String == method }?.object
    }

    func containsClientMethod(_ method: String) -> Bool {
        clientRequest(method: method) != nil
    }

    func index(ofClientMethod method: String) -> Int {
        firstIndex {
            $0.direction == .client && $0.object["method"] as? String == method
        } ?? Int.max
    }

    func serverResponse(id: Int) -> [String: Any]? {
        first {
            $0.direction == .server
                && $0.object["method"] == nil
                && ($0.object["id"] as? NSNumber)?.intValue == id
        }?.object
    }

    func firstClientResponse(id: Int) -> [String: Any]? {
        first {
            $0.direction == .client
                && $0.object["method"] == nil
                && ($0.object["id"] as? NSNumber)?.intValue == id
        }?.object
    }
}

private struct CredentialMetadata: Equatable {
    let fileType: mode_t
    let permissions: mode_t
    let owner: uid_t
    let group: gid_t
    let device: dev_t
    let inode: ino_t
    let linkCount: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
}

private func readCredentialMetadata(at url: URL) throws -> CredentialMetadata {
    var status = stat()
    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    return CredentialMetadata(
        fileType: status.st_mode & mode_t(S_IFMT),
        permissions: status.st_mode & 0o777,
        owner: status.st_uid,
        group: status.st_gid,
        device: status.st_dev,
        inode: status.st_ino,
        linkCount: status.st_nlink,
        size: status.st_size,
        modifiedSeconds: status.st_mtimespec.tv_sec,
        modifiedNanoseconds: status.st_mtimespec.tv_nsec,
        changedSeconds: status.st_ctimespec.tv_sec,
        changedNanoseconds: status.st_ctimespec.tv_nsec
    )
}

private struct NativeCredentialMetadata: Equatable {
    let file: CredentialMetadata?
    let keychainStatus: OSStatus
    let keychainCreationDate: Date?
    let keychainModificationDate: Date?
    let keychainService: String?
    let keychainAccount: String?
}

private func nativeCredentialMetadata(
    home: URL,
    keychainAccount: String
) -> NativeCredentialMetadata {
    let authURL = home.appendingPathComponent("auth.json")
    let file = try? readCredentialMetadata(at: authURL)
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "Codex Auth",
        kSecAttrAccount: keychainAccount,
        kSecReturnAttributes: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    let attributes = item as? NSDictionary
    return NativeCredentialMetadata(
        file: file,
        keychainStatus: status,
        keychainCreationDate: attributes?[kSecAttrCreationDate] as? Date,
        keychainModificationDate: attributes?[kSecAttrModificationDate] as? Date,
        keychainService: attributes?[kSecAttrService] as? String,
        keychainAccount: attributes?[kSecAttrAccount] as? String
    )
}

private func syntheticAppServerCredential(
    expiration: Int = Int(Date().timeIntervalSince1970) + 7_200,
    planType: String? = nil
) -> (record: Data, accessToken: String) {
    let accountID = "account-fixture"
    var authClaims: [String: Any] = ["chatgpt_account_id": accountID]
    if let planType { authClaims["chatgpt_plan_type"] = planType }
    let accessToken = syntheticAppServerJWT([
        "exp": expiration,
        "https://api.openai.com/auth": authClaims,
    ])
    let idToken = syntheticAppServerJWT([
        "https://api.openai.com/auth": authClaims,
    ])
    let record = try! JSONSerialization.data(withJSONObject: [
        "auth_mode": "chatgpt",
        "tokens": [
            "id_token": idToken,
            "access_token": accessToken,
            "refresh_token": "synthetic-refresh-token",
            "account_id": accountID,
        ],
    ], options: [.sortedKeys])
    return (record, accessToken)
}

private func syntheticAppServerJWT(_ claims: [String: Any]) -> String {
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "none"])
    let payload = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    return "\(appServerBase64URL(header)).\(appServerBase64URL(payload)).synthetic-signature"
}

private func appServerBase64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
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
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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

private func waitForClientMethod(_ method: String, in fixture: AppServerFixture) async throws {
    let deadline = Date().addingTimeInterval(loadTolerantTestTimeoutS)
    while Date() < deadline {
        if let records = try? fixture.rpcRecords(), records.containsClientMethod(method) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadUnknown)
}

private func accountStateAfterLoginReadiness(
    in fixture: AppServerFixture
) async throws -> CodexAppServerAccountState {
    let accountState = Task {
        try await fixture.executor().accountState(
            executableURL: fixture.executable,
            workspaceURL: fixture.workspace,
            timeoutS: loadTolerantTestTimeoutS
        )
    }
    do {
        try await waitForClientMethod("account/login/start", in: fixture)
    } catch {
        accountState.cancel()
        _ = await accountState.result
        throw error
    }
    return try await accountState.value
}

private func waitForProcessesToExit(_ processIDs: [Int32]) async throws {
    let deadline = Date().addingTimeInterval(loadTolerantTestTimeoutS)
    while processIDs.contains(where: processExists), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
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
        for element in self { result.append(try await transform(element)) }
        return result
    }
}
