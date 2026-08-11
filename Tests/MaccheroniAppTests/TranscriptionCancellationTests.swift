import Darwin
import Foundation
import MaccheroniCore
import Testing
@testable import MaccheroniApp

struct TranscriptionCancellationTests {
    @Test @MainActor
    func uiCancellationTerminatesOnlyTheExactCLIProcessChainAndPreservesArtifacts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sentinel = try launchSentinel()
        defer { killOwnedProcess(sentinel.processIdentifier) }
        let runner = try makeRunner(fixture: fixture)
        let execution = Task { @MainActor in
            try await runner.run(fixture.request) { _ in }
        }
        let processIDs = try await waitForProcessIDs(at: fixture.pidURL, count: 3)
        defer { killOwnedProcesses(recordedAt: fixture.pidURL) }

        runner.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await execution.value
        }

        try await assertCancellationOutcome(
            fixture: fixture,
            processIDs: processIDs,
            sentinelPID: sentinel.processIdentifier
        )
    }

    @Test @MainActor
    func parentTaskCancellationTerminatesOnlyTheExactCLIProcessChainAndPreservesArtifacts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sentinel = try launchSentinel()
        defer { killOwnedProcess(sentinel.processIdentifier) }
        let runner = try makeRunner(fixture: fixture)
        let execution = Task { @MainActor in
            try await runner.run(fixture.request) { _ in }
        }
        let processIDs = try await waitForProcessIDs(at: fixture.pidURL, count: 3)
        defer { killOwnedProcesses(recordedAt: fixture.pidURL) }

        execution.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await execution.value
        }

        try await assertCancellationOutcome(
            fixture: fixture,
            processIDs: processIDs,
            sentinelPID: sentinel.processIdentifier
        )
    }

    @MainActor
    private func assertCancellationOutcome(
        fixture: TranscriptionFixture,
        processIDs: [Int32],
        sentinelPID: Int32
    ) async throws {
        for processID in processIDs {
            #expect(try await waitForAbsence(of: processID, timeoutS: 1.0))
        }
        #expect(isAlive(sentinelPID))

        #expect(FileManager.default.fileExists(atPath: fixture.partialRunURL.path))
        #expect(try Data(contentsOf: fixture.closedAttemptURL) == fixture.closedAttemptBytes)
        let requestDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.requestsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let requestDirectory = try #require(requestDirectories.first)
        #expect(
            try String(
                contentsOf: requestDirectory.appendingPathComponent("stdout.log"),
                encoding: .utf8
            ) == "fixture stdout\n"
        )
        #expect(
            try String(
                contentsOf: requestDirectory.appendingPathComponent("stderr.log"),
                encoding: .utf8
            ) == "fixture stderr\n"
        )
    }

    @MainActor
    private func makeRunner(fixture: TranscriptionFixture) throws -> ProcessTranscriptionRunner {
        try ProcessTranscriptionRunner(
            executableURL: fixture.script,
            requestsRoot: fixture.requestsRoot,
            terminationTiming: ProcessTerminationTiming(gracePeriodS: 0.02, pollIntervalS: 0.005, exitWaitS: 0.5)
        )
    }

    private func makeFixture() throws -> TranscriptionFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccheroni-transcription-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let pidURL = root.appendingPathComponent("chain-pids")
        let script = root.appendingPathComponent("ignores-term-chain.py")
        let outputRoot = root.appendingPathComponent("runs", isDirectory: true)
        let inputURL = root.appendingPathComponent("input.wav")
        try Data("synthetic cancellation fixture".utf8).write(
            to: inputURL,
            options: .withoutOverwriting
        )
        let partialRunURL = outputRoot.appendingPathComponent("partial-run", isDirectory: true)
        let closedAttemptURL = partialRunURL
            .appendingPathComponent("primary/attempts/fixture-root/outcome.json")
        let closedAttemptBytes = Data("{\"attempt_id\":\"fixture-root\",\"state\":\"canceled\",\"closed\":true}\n".utf8)
        try Data("""
        #!/usr/bin/python3
        import os
        import signal
        import subprocess
        import sys

        pid_path = '\(pidURL.path)'
        role = os.environ.get('MACCHERONI_FIXTURE_ROLE', 'root')
        signal.signal(signal.SIGTERM, lambda _signal, _frame: None)
        if role == 'root':
            output_root = sys.argv[sys.argv.index('--output-root') + 1]
            attempt = os.path.join(output_root, 'partial-run', 'primary', 'attempts', 'fixture-root', 'outcome.json')
            os.makedirs(os.path.dirname(attempt), exist_ok=True)
            with open(attempt, 'wb') as artifact:
                artifact.write(b'{"attempt_id":"fixture-root","state":"canceled","closed":true}\\n')
            print('fixture stdout', flush=True)
            print('fixture stderr', file=sys.stderr, flush=True)
        with open(pid_path, 'a') as pid_file:
            pid_file.write(f'{os.getpid()}\\n')
            pid_file.flush()
        if role != 'grandchild':
            environment = os.environ.copy()
            environment['MACCHERONI_FIXTURE_ROLE'] = 'child' if role == 'root' else 'grandchild'
            subprocess.Popen([sys.executable, __file__, *sys.argv[1:]], env=environment)
        while True:
            signal.pause()
        """.utf8).write(to: script, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let profile = try #require(AppProfileRegistry.load().first)
        return TranscriptionFixture(
            root: root,
            script: script,
            pidURL: pidURL,
            requestsRoot: root.appendingPathComponent("requests", isDirectory: true),
            partialRunURL: partialRunURL,
            closedAttemptURL: closedAttemptURL,
            closedAttemptBytes: closedAttemptBytes,
            request: TranscriptionRequest(
                sourceURL: inputURL,
                outputRoot: outputRoot,
                profile: profile,
                postprocess: .none,
                glossaryURL: nil
            )
        )
    }

    private func launchSentinel() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func waitForProcessIDs(at url: URL, count: Int) async throws -> [Int32] {
        for _ in 0 ..< 1_000 {
            let processIDs = (try? recordedProcessIDs(at: url)) ?? []
            if processIDs.count == count { return processIDs }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TranscriptionTimeoutError()
    }

    private func recordedProcessIDs(at url: URL) throws -> [Int32] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private func waitForAbsence(of processID: Int32, timeoutS: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeoutS)
        while isAlive(processID), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return !isAlive(processID)
    }

    private func killOwnedProcesses(recordedAt url: URL) {
        for processID in (try? recordedProcessIDs(at: url)) ?? [] {
            killOwnedProcess(processID)
        }
    }

    private func killOwnedProcess(_ processID: Int32) {
        guard processID > 0, isAlive(processID) else { return }
        _ = Darwin.kill(processID, SIGKILL)
    }

    private func isAlive(_ processID: Int32) -> Bool {
        let result = Darwin.kill(processID, 0)
        let probeErrno = errno
        return result == 0 || probeErrno == EPERM
    }
}

private struct TranscriptionFixture {
    let root: URL
    let script: URL
    let pidURL: URL
    let requestsRoot: URL
    let partialRunURL: URL
    let closedAttemptURL: URL
    let closedAttemptBytes: Data
    let request: TranscriptionRequest
}

private struct TranscriptionTimeoutError: Error {}
